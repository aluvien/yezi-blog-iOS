import Foundation
import SwiftUI

@MainActor
final class CreationComposerModel: ObservableObject {
    let api: AdminAPIClient
    let store: CreationDraftStore
    @Published private(set) var draft: CreationDraft
    @Published private(set) var savedRevision = -1
    @Published private(set) var isSaving = false
    @Published private(set) var isLoading = false
    @Published private(set) var canEdit = true
    @Published var errorMessage: String?
    @Published var storageError: String?
    @Published private(set) var didPublish = false
    private var debounce: Task<Void, Never>?
    private var loaded = false
    private var terminal = false
    private var initialRevision: Int
    private lazy var queue: MediaUploadQueue = {
        let queue = MediaUploadQueue(store: store, site: draft.site) { [api] data, filename, mime in
            try await api.uploadFile(data: data, filename: filename, mimeType: mime)
        }
        queue.onChange = { [weak self] media in
            guard let self, !self.terminal, let index = self.draft.media.firstIndex(where: { $0.id == media.id }) else { return }
            self.edit { $0.media[index] = media }
        }
        return queue
    }()

    init(api: AdminAPIClient, draft: CreationDraft, store: CreationDraftStore = .shared) {
        self.api = api
        self.draft = draft
        self.store = store
        initialRevision = draft.revision
        canEdit = draft.kind != .post || draft.serverID == nil
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        if draft.kind == .post, let id = draft.serverID {
            isLoading = true
            errorMessage = nil
            do {
                let post = try await api.fetchPost(id: id)
                guard post.id == id else { throw APIError.decoding("文章身份不匹配") }
                if draft.revision == 0 && !draft.hasContent {
                    draft.title = post.title
                    draft.slug = post.slug
                    draft.text = post.content
                    draft.cover = post.cover ?? ""
                    draft.category = post.category
                    draft.tags = post.tags.joined(separator: ", ")
                    draft.status = post.status
                    draft.attachmentIDs = post.attachmentIds
                    draft.references = post.referenceSnapshots
                    if let local = try await store.list(site: draft.site).first(where: { $0.kind == .post && $0.serverID == id }) {
                        draft = local
                        initialRevision = local.revision
                    }
                }
                draft.status = post.status
                canEdit = true
            } catch {
                canEdit = false
                errorMessage = "文章加载失败，不能保存空内容：\(error.localizedDescription)"
                loaded = false
            }
            isLoading = false
        }
        guard canEdit else { return }
        queue.restore(draft.media)
    }

    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<CreationDraft, Value>) -> Binding<Value> {
        Binding(get: { self.draft[keyPath: keyPath] }, set: { value in
            guard self.draft[keyPath: keyPath] != value else { return }
            self.edit { $0[keyPath: keyPath] = value }
        })
    }

    func edit(_ change: (inout CreationDraft) -> Void) {
        guard !terminal else { return }
        change(&draft)
        draft.revision += 1
        draft.updatedAt = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        guard !terminal else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            Task { _ = await self.flush() }
        }
    }

    @discardableResult
    func flush() async -> Bool {
        guard !terminal else { return true }
        debounce?.cancel()
        debounce = nil
        guard draft.revision != initialRevision else { return true }
        let snapshot = draft
        do {
            try await store.save(snapshot)
            savedRevision = max(savedRevision, snapshot.revision)
            storageError = nil
            return true
        } catch {
            storageError = "暂未保存，请保持此页并重试：\(error.localizedDescription)"
            return false
        }
    }

    var localStatus: String {
        if let storageError { return storageError }
        if draft.submission == .uncertain { return "发布结果待确认 · 查看想法或文章" }
        if draft.revision == initialRevision { return "尚未修改 · 修改后自动保存到本机" }
        return savedRevision >= draft.revision ? "已保存到本机" : "正在保存…"
    }

    var previewContent: String { draft.kind == .post ? draft.articleSubmissionContent : draft.serializedContent }

    var submitBlocker: String? {
        if isLoading || !canEdit { return "请先成功加载文章" }
        if isSaving { return "正在提交，请稍候" }
        if draft.submission == .uncertain { return "发布结果待确认，请先查看列表，勿重复发布" }
        if draft.kind == .moment && draft.serializedContent.utf16.count > 20_000 { return "正文不能超过 20,000 字符" }
        let pending = draft.media.filter { [.preparing, .waiting, .uploading].contains($0.state) }.count
        if pending > 0 { return "还有 \(pending) 张图片待上传" }
        let failed = draft.media.filter { $0.state == .failed }.count
        if failed > 0 { return "\(failed) 张图片失败，请重试或移除" }
        if draft.kind == .post {
            if draft.title.trimmedNonEmpty == nil { return "请输入文章标题" }
            if draft.articleSubmissionContent.trimmedNonEmpty == nil { return "发布文章前请填写正文" }
        } else if draft.serializedContent.trimmedNonEmpty == nil && draft.media.isEmpty { return "写点文字，或添加照片、音乐" }
        return nil
    }

    func reserveImages(count: Int) -> [UUID] {
        let media = (0..<min(count, max(0, 9 - draft.media.count))).map { _ in CreationMedia() }
        for item in media { queue.add(item) }
        edit { $0.media.append(contentsOf: media) }
        return media.map(\.id)
    }

    func prepareImage(id: UUID, data: Data) async { await queue.prepare(id: id, data: data) }
    func failedImage(id: UUID, message: String) { queue.failedPreparation(id, message: message) }
    func retryImage(_ id: UUID) { queue.retry(id) }
    func removeImage(_ id: UUID) {
        queue.remove(id)
        edit { $0.media.removeAll { $0.id == id } }
    }
    func moveImage(_ id: UUID, offset: Int) {
        guard let index = draft.media.firstIndex(where: { $0.id == id }), draft.media.indices.contains(index + offset) else { return }
        edit { $0.media.swapAt(index, index + offset) }
    }

    func addMusic(_ music: CreationMusic, replacing: UUID? = nil) async {
        guard music.marker != nil else { return }
        edit { draft in
            if let replacing, let index = draft.music.firstIndex(where: { $0.id == replacing }) { draft.music[index] = music }
            else { draft.music.append(music) }
        }
        do { try await store.remember(music, site: draft.site) }
        catch { errorMessage = "音乐已添加，最近记录保存失败：\(error.localizedDescription)" }
    }

    func removeMusic(_ id: UUID) { edit { draft in draft.music.removeAll { $0.id == id } } }

    func setMusicFolded(_ id: UUID, folded: Bool) {
        guard draft.kind == .moment,
              let music = draft.music.first(where: { $0.id == id }),
              let marker = music.marker, marker.folded != folded else { return }
        let spec = MarkdownParser.makeMusicSpec(
            id: marker.id, type: marker.type, shuffle: marker.shuffle, folded: folded,
            title: marker.title, artist: marker.artist, cover: marker.cover
        )
        edit { draft in
            guard let index = draft.music.firstIndex(where: { $0.id == id }) else { return }
            draft.music[index].spec = spec
        }
    }

    func insertReference(_ reference: AdminReferenceSnapshot) {
        edit { draft in
            draft.references.append(reference)
            draft.text += "\n\n\(makeReferenceMarker(reference, compact: draft.kind == .post))\n"
        }
    }

    func selectCover(_ attachment: AdminAttachment) {
        edit { draft in
            draft.cover = attachment.path
            if let id = attachment.id, !draft.attachmentIDs.contains(id) { draft.attachmentIDs.append(id) }
        }
    }

    func insertAttachment(_ attachment: AdminAttachment) {
        edit { draft in
            if let id = attachment.id, !draft.attachmentIDs.contains(id) { draft.attachmentIDs.append(id) }
            draft.text += "\n\n![\(attachment.originalName)](\(attachment.path))\n"
        }
    }

    func registerGeneratedImage(_ attachment: AdminAttachment, asCover: Bool) {
        edit { draft in
            if let id = attachment.id, !draft.attachmentIDs.contains(id) { draft.attachmentIDs.append(id) }
            if asCover && draft.kind == .post { draft.cover = attachment.path }
        }
    }

    func submit(serverDraft: Bool = false) async -> Bool {
        guard !isSaving, canEdit, !isLoading, draft.submission != .uncertain else { return false }
        if !serverDraft, let blocker = submitBlocker { errorMessage = blocker; return false }
        if serverDraft {
            guard draft.title.trimmedNonEmpty != nil, draft.status != "published" else { errorMessage = "已发布文章不会隐式转为草稿"; return false }
            guard draft.media.allSatisfy({ $0.state == .uploaded }) else { errorMessage = "请先完成所有图片上传"; return false }
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        if draft.kind == .post && draft.slug.trimmedNonEmpty == nil { edit { $0.slug = "post-\(UUID().uuidString.lowercased())" } }
        edit { $0.submission = .sending }
        guard await flush() else { edit { $0.submission = .idle }; return false }
        let snapshot = draft
        do {
            if snapshot.kind == .moment {
                let payload = AdminMomentWriteRequest(content: snapshot.serializedContent, images: snapshot.media.compactMap(\.remotePath))
                let saved: AdminMoment
                if let id = snapshot.serverID { saved = try await api.updateMoment(id: id, payload: payload) }
                else { saved = try await api.createMoment(payload) }
                guard saved.id > 0, snapshot.serverID == nil || snapshot.serverID == saved.id else { throw APIError.decoding("发布响应缺少有效想法") }
                draft.serverID = saved.id
            } else {
                let payload = AdminPostWriteRequest(title: snapshot.title, slug: snapshot.slug, content: snapshot.articleSubmissionContent, cover: snapshot.cover.trimmedNonEmpty, category: snapshot.category, tags: snapshot.tags, attachmentIds: Array(Set(snapshot.attachmentIDs + snapshot.media.compactMap(\.attachmentID))), referenceSnapshots: snapshot.references, status: serverDraft ? "draft" : "published")
                let saved: AdminPostDetail
                if let id = snapshot.serverID { saved = try await api.updatePost(id: id, payload: payload) }
                else { saved = try await api.createPost(payload) }
                guard snapshot.serverID == nil || snapshot.serverID == saved.id else { throw APIError.decoding("文章响应身份不匹配") }
                draft.serverID = saved.id
                draft.status = saved.status
                if serverDraft {
                    edit { $0.submission = .idle }
                    _ = await flush()
                    return true
                }
            }
            edit { $0.submission = .idle }
            if draft.revision == snapshot.revision + 1 {
                terminal = true
                debounce?.cancel()
                debounce = nil
                queue.onChange = nil
                queue.suspend()
                do { try await store.remove(draft) }
                catch { errorMessage = "已发布，但本机草稿清理失败：\(error.localizedDescription)" }
                didPublish = true
            } else {
                _ = await flush()
                errorMessage = "已保存提交时的版本；最新编辑仍保留在本机"
            }
            return true
        } catch {
            let uncertain: Bool
            if let apiError = error as? APIError, case .http(let status, _) = apiError { uncertain = status >= 500 }
            else { uncertain = true }
            edit { $0.submission = uncertain ? .uncertain : .idle }
            _ = await flush()
            errorMessage = uncertain ? "发布结果待确认 · 查看列表，确认后再继续。内容保留在本机。" : "发布失败，内容已保留：\(error.localizedDescription)"
            return false
        }
    }

    func confirmNotPublished() async { edit { $0.submission = .idle }; _ = await flush() }

    func close() async -> Bool {
        guard !isSaving, await flush() else { return false }
        queue.suspend()
        return true
    }

    func discard() async -> Bool {
        guard !isSaving else { return false }
        debounce?.cancel()
        debounce = nil
        terminal = true
        do { try await store.remove(draft); queue.onChange = nil; queue.suspend(); return true }
        catch { terminal = false; storageError = error.localizedDescription; return false }
    }
}
