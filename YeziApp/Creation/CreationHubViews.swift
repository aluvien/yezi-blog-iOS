import SwiftUI
import UIKit

/// One store per authenticated API client; list queries keep their own pagination.
@MainActor
final class AdminCommentStore: ObservableObject {
    struct Change { let old: AdminComment?; let updated: AdminComment? }
    @Published private(set) var records: [Int: AdminComment] = [:]
    @Published private(set) var deleted: Set<Int> = []
    @Published private(set) var momentCounts: [Int: Int] = [:]
    @Published private(set) var change: Change?
    private(set) var revision = 0
    private var editedAt: [Int: Int] = [:]
    private unowned let api: AdminAPIClient
    init(api: AdminAPIClient) { self.api = api }
    func ingest(_ comments: [AdminComment], since revision: Int? = nil) {
        for comment in comments where !deleted.contains(comment.id) {
            if let revision, (editedAt[comment.id] ?? 0) > revision { continue }
            records[comment.id] = comment
        }
    }
    func seedCount(_ count: Int?, momentID: Int, replace: Bool = false) {
        if let count, replace || momentCounts[momentID] == nil { momentCounts[momentID] = count }
    }
    func didUpdate(_ comment: AdminComment) {
        revision += 1; editedAt[comment.id] = revision
        let old = records[comment.id]
        records[comment.id] = comment
        deleted.remove(comment.id)
        change = Change(old: old, updated: comment)
    }
    func didDelete(_ id: Int) {
        revision += 1; editedAt[id] = revision
        let old = records.removeValue(forKey: id)
        deleted.insert(id)
        if let old, old.targetType == "moment", let count = momentCounts[old.targetId] {
            momentCounts[old.targetId] = max(0, count - 1)
        }
        change = Change(old: old, updated: nil)
    }
    func clear() { records = [:]; deleted = []; momentCounts = [:]; change = nil; editedAt = [:]; revision += 1 }
}

private func isCreationCancellation(_ error: Error) -> Bool {
    isRequestCancellation(error)
}

struct CreationEditorRoute: Identifiable {
    let draft: CreationDraft
    var intent: CreationIntent = .text
    var id: UUID { draft.id }
}

@MainActor
final class CreationFeedModel: ObservableObject {
    let api: AdminAPIClient
    @Published private(set) var moments: [AdminMoment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    private var page = 0
    private var generation = 0
    private var request: Task<AdminPage<AdminMoment>, Error>?
    init(api: AdminAPIClient) { self.api = api }

    func loadIfNeeded() async {
        guard page == 0, !(isLoading && request?.isCancelled == false) else { return }
        await load(reset: true)
    }

    func load(reset: Bool = false) async {
        guard !Task.isCancelled else { return }
        if reset { request?.cancel(); generation += 1 }
        let token = generation
        guard reset || (!isLoading && hasMore) else { return }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false; request = nil } }
        let next = reset ? 1 : page + 1
        let api = api
        let task = Task { try await api.fetchMoments(page: next) }
        request = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard token == generation, !Task.isCancelled else { return }
            for moment in result.items { api.commentStore.seedCount(moment.commentCount, momentID: moment.id, replace: true) }
            if reset { moments = [] }
            let existing = Set(moments.map(\.id))
            moments.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = next
            hasMore = result.meta.totalPages.map { next < $0 } ?? (result.items.count == 20)
        } catch {
            if token == generation, !Task.isCancelled, !isCreationCancellation(error) { self.error = error.localizedDescription }
        }
    }

    func delete(_ moment: AdminMoment) async {
        do { try await api.deleteMoment(id: moment.id); moments.removeAll { $0.id == moment.id } }
        catch { if !Task.isCancelled, !isCreationCancellation(error) { self.error = error.localizedDescription } }
    }
}

private enum MomentContentFilter: String, CaseIterable {
    case all = "全部", photos = "照片", music = "音乐", text = "文字"
    var symbol: String {
        switch self { case .all: "square.grid.2x2"; case .photos: "photo"; case .music: "music.note"; case .text: "text.alignleft" }
    }
    func includes(_ moment: AdminMoment) -> Bool {
        switch self {
        case .all: true
        case .photos: !moment.images.isEmpty
        case .music: !CreationMusic.split(moment.content).music.isEmpty
        case .text: moment.images.isEmpty && CreationMusic.split(moment.content).music.isEmpty
        }
    }
}

struct MomentFeedView: View {
    @Environment(\.creationMiniPlayerHeight) private var miniPlayerHeight
    let api: AdminAPIClient
    let openDrafts: () -> Void
    @StateObject private var model: CreationFeedModel
    @State private var route: CreationEditorRoute?
    @State private var recent: CreationDraft?
    @State private var draftError: String?
    @State private var pendingDelete: AdminMoment?
    @State private var search = ""
    @State private var showingSearch = false
    @State private var contentFilter = MomentContentFilter.all
    @State private var showingMusic = false
    @State private var composeVisible = true
    @State private var authorName = ""
    @State private var authorAvatar: String?
    @State private var loadedAuthor = false
    private var visibleMoments: [AdminMoment] {
        model.moments.filter { contentFilter.includes($0) && (search.isEmpty || $0.content.localizedStandardContains(search)) }
    }
    @State private var published = false
    @State private var refreshAfterEditing = false
    @State private var didPreview = false

    init(api: AdminAPIClient, openDrafts: @escaping () -> Void) {
        self.api = api
        self.openDrafts = openDrafts
        _model = StateObject(wrappedValue: CreationFeedModel(api: api))
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 20) {
                CreationPageHeader(title: "絮语", subtitle: contentFilter == .all ? "记录日常的片刻" : "仅看\(contentFilter.rawValue)") {
                    HStack(spacing: 12) {
                        Button { withAnimation { showingSearch.toggle() }; if !showingSearch { search = "" } } label: {
                            Image(systemName: "magnifyingglass").font(.title3).modifier(CreationHeaderIconFrame())
                        }.accessibilityLabel("搜索絮语")
                        Button { showingMusic = true } label: { Image(systemName: "music.note").font(.title3).modifier(CreationHeaderIconFrame()) }.accessibilityLabel("播放音乐列表")
                        Menu {
                            Picker("筛选絮语", selection: $contentFilter) {
                                ForEach(MomentContentFilter.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                            }
                            Divider()
                            Button("发布照片絮语", systemImage: "photo") { start(.photos) }
                            Button("查看本机草稿", systemImage: "tray", action: openDrafts)
                        } label: { Image(systemName: "ellipsis").font(.title3).modifier(CreationHeaderIconFrame()) }.accessibilityLabel("更多絮语操作")
                    }
                }
                if let recent {
                    Button { route = CreationEditorRoute(draft: recent) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("继续上次记录").font(.caption.weight(.semibold))
                                Text(recent.summary).font(.subheadline).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(12).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).foregroundStyle(CreationDesign.accent)
                }
                if published { CreationNotice(text: "已发布") }
                if let draftError { CreationNotice(text: draftError, isError: true); Button("重试读取草稿") { Task { await loadRecent() } } }
                if showingSearch { CreationSearchField(placeholder: "搜索已加载的絮语", text: $search) }
                if visibleMoments.isEmpty && !model.moments.isEmpty {
                    ContentUnavailableView("没有匹配的絮语", systemImage: "magnifyingglass", description: Text("换个关键词，或加载更多内容。"))
                }
                if let error = model.error { CreationNotice(text: error, isError: true); Button("重试加载") { Task { await model.load(reset: model.moments.isEmpty) } } }
                if model.moments.isEmpty && !model.isLoading && model.error == nil {
                    ContentUnavailableView("还没有絮语", systemImage: "quote.bubble", description: Text("不必想好标题，先记下这一刻。"))
                }
            }.listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CreationDesign.canvas)
            ForEach(visibleMoments) { moment in
                MomentFeedCard(moment: moment, api: api, authorName: authorName, authorAvatar: authorAvatar)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(CreationDesign.canvas)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = moment }
                        Button("编辑", systemImage: "square.and.pencil") { Task { await edit(moment) } }
                    }
            }
            if model.isLoading { ProgressView("正在加载…").frame(maxWidth: .infinity).listRowBackground(CreationDesign.canvas) }
            if model.hasMore && !model.moments.isEmpty && !model.isLoading { Button("加载更多絮语") { Task { await model.load() } }.frame(maxWidth: .infinity, minHeight: 44).listRowBackground(CreationDesign.canvas) }
            Color.clear.frame(height: 80)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) {
                CreationFloatingButton(title: "写絮语", symbol: "plus", verticalPadding: 8) { start(.text) }
                    .padding(.bottom, miniPlayerHeight)
                    .opacity(composeVisible ? 1 : 0).offset(y: composeVisible ? 0 : 12)
                    .allowsHitTesting(composeVisible).accessibilityHidden(!composeVisible)
            }
            .modifier(CreationScrollActionVisibility(visible: $composeVisible))
            .sheet(isPresented: $showingMusic) { CreationListeningView(api: api, moments: model.moments) }
            .task {
                guard !loadedAuthor else { return }
                if let settings = try? await api.fetchSettings(), !Task.isCancelled {
                    authorName = settings["author_name"] ?? settings["site_name"] ?? ""
                    authorAvatar = settings["author_avatar"]
                    loadedAuthor = true
                }
            }
            .refreshable { await model.load(reset: true); await loadRecent() }
            .task {
                await model.loadIfNeeded()
                await loadRecent()
                if CreationPreview.isEnabled && !didPreview {
                    didPreview = true
                    if CreationPreview.screen == "composer", let recent { route = CreationEditorRoute(draft: recent) }
                    if CreationPreview.screen == "music", let recent { route = CreationEditorRoute(draft: recent, intent: .music) }
                }
            }
            .fullScreenCover(item: $route, onDismiss: {
                Task {
                    if refreshAfterEditing { refreshAfterEditing = false; await model.load(reset: true) }
                    await loadRecent()
                }
            }) { route in
                CreationComposerView(api: api, draft: route.draft, intent: route.intent) {
                    published = true
                    refreshAfterEditing = true
                }
            }
            .task(id: published) {
                guard published else { return }
                do { try await Task.sleep(for: .seconds(3)); published = false } catch {}
            }
            .confirmationDialog("删除絮语？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { moment in
                Button("删除絮语", role: .destructive) { Task { await model.delete(moment) } }
            } message: { _ in Text("删除后无法恢复。") }
    }

    private func start(_ intent: CreationIntent) {
        let draft = recent ?? CreationDraft(site: CreationDraftStore.canonicalSite(api.siteRoot), kind: .moment)
        route = CreationEditorRoute(draft: draft, intent: intent)
    }
    private func loadRecent() async {
        do { let scan = try await CreationDraftStore.shared.scan(site: CreationDraftStore.canonicalSite(api.siteRoot)); recent = scan.drafts.first { $0.kind == .moment && $0.serverID == nil }; draftError = scan.warnings.first }
        catch { if !Task.isCancelled, !isCreationCancellation(error) { draftError = error.localizedDescription } }
    }
    private func edit(_ moment: AdminMoment) async {
        do {
            if let saved = try await CreationDraftStore.shared.list(site: CreationDraftStore.canonicalSite(api.siteRoot)).first(where: { $0.kind == .moment && $0.serverID == moment.id }) { route = CreationEditorRoute(draft: saved); return }
            var draft = CreationDraft(site: CreationDraftStore.canonicalSite(api.siteRoot), kind: .moment, serverID: moment.id)
            let split = CreationMusic.split(moment.content)
            draft.text = split.text
            draft.music = split.music
            draft.media = moment.images.map { CreationMedia(remotePath: $0, state: .uploaded) }
            route = CreationEditorRoute(draft: draft)
        } catch { draftError = error.localizedDescription }
    }
}

struct MomentFeedCard: View {
    let moment: AdminMoment
    let api: AdminAPIClient
    var authorName = ""
    var authorAvatar: String?
    @ObservedObject private var comments: AdminCommentStore
    @State private var showingComments = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var image: CreationMedia?
    init(moment: AdminMoment, api: AdminAPIClient, authorName: String = "", authorAvatar: String? = nil) {
        self.moment = moment; self.api = api; self.authorName = authorName; self.authorAvatar = authorAvatar
        _comments = ObservedObject(wrappedValue: api.commentStore)
    }
    private var foldedMusic: [String] {
        MarkdownParser.parse(moment.content).compactMap { block in
            guard case .music(let spec) = block, MarkdownParser.musicMarker(from: spec)?.folded == true else { return nil }
            return spec
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let authorAvatar, !authorAvatar.isEmpty {
                    CreationRemoteImage(path: authorAvatar, site: api.siteRoot).frame(width: 32, height: 32).clipShape(Circle())
                } else { Image(systemName: "leaf.circle.fill").font(.title).foregroundStyle(.secondary) }
                Text(authorName.isEmpty ? "博主" : authorName).font(.subheadline.weight(.medium)).lineLimit(1)
                if let spec = foldedMusic.first {
                    CreationMusicCard(music: CreationMusic(spec: spec), api: api, compact: true, inline: true)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(foldedMusic.dropFirst().enumerated()), id: \.offset) { _, spec in
                CreationMusicCard(music: CreationMusic(spec: spec), api: api, compact: true, inline: true)
            }
            ForEach(Array(MarkdownParser.parse(moment.content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .music(let spec):
                    if MarkdownParser.musicMarker(from: spec)?.folded != true {
                        CreationMusicCard(music: CreationMusic(spec: spec), api: api)
                    }
                case .paragraph(let text):
                    if !CreationMomentTags.isTagOnlyParagraph(text) {
                        Text(MarkdownParser.attributed(text)).font(.body).lineSpacing(5).lineLimit(expanded ? nil : 6).textSelection(.enabled)
                    }
                default: AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot)
                }
            }
            if moment.content.count > 220 { Button(expanded ? "收起" : "展开全文") { expanded.toggle() }.font(.subheadline) }
            if !moment.images.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: moment.images.count == 1 ? 1 : (moment.images.count == 2 || moment.images.count == 4 ? 2 : 3)), spacing: 6) {
                    ForEach(Array(moment.images.enumerated()), id: \.offset) { _, path in
                        Button { image = CreationMedia(remotePath: path, state: .uploaded) } label: { CreationRemoteImage(path: path, site: api.siteRoot).frame(height: moment.images.count == 1 ? 260 : 140).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel("查看絮语图片")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                let tags = moment.tags?.isEmpty == false ? moment.tags! : CreationMomentTags.parse(moment.content)
                (Text(displayDate(moment.createdAt)).foregroundColor(.secondary)
                 + Text(moment.location?.trimmedNonEmpty.map { "  ·  📍" + $0 } ?? "").foregroundColor(.secondary)
                 + Text(tags.isEmpty ? "" : "  ·  " + tags.map { "#" + $0 }.joined(separator: "  ")).foregroundColor(CreationDesign.accent))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                let count = comments.momentCounts[moment.id] ?? moment.commentCount ?? 0
                if count > 0 {
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showingComments.toggle() } } label: {
                        Text("\(count) 条评论").fixedSize().frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(CreationDesign.accent)
                        .accessibilityIdentifier("moment-comments-\(moment.id)")
                }
            }.font(.caption)
            MomentInlineComments(momentID: moment.id, api: api, expanded: showingComments)
        }.padding(.top, 14).padding(.bottom, 24).overlay(alignment: .bottom) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }
            .onAppear { comments.seedCount(moment.commentCount, momentID: moment.id) }
            .onChange(of: moment.commentCount) { _, value in comments.seedCount(value, momentID: moment.id, replace: true) }
            .onChange(of: comments.momentCounts[moment.id]) { _, value in if value == 0 { showingComments = false } }
            .contextMenu { Button("复制文字", systemImage: "doc.on.doc") { UIPasteboard.general.string = CreationMusic.split(moment.content).text } }
            .sheet(item: $image) { media in CreationImagePreview(media: media, api: api, site: CreationDraftStore.canonicalSite(api.siteRoot)) }
    }
    private func displayDate(_ raw: String?) -> String {
        guard let raw else { return "时间未知" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "yyyy-MM-dd HH:mm"
        return display.string(from: date)
    }
}

private struct MomentInlineComments: View {
    let momentID: Int
    let api: AdminAPIClient
    let expanded: Bool
    @ObservedObject private var store: AdminCommentStore
    @State private var ids: [Int] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var replyID: Int?
    @State private var drafts: [Int: String] = [:]
    @State private var sending = false
    @State private var pageTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    init(momentID: Int, api: AdminAPIClient, expanded: Bool) {
        self.momentID = momentID; self.api = api; self.expanded = expanded
        _store = ObservedObject(wrappedValue: api.commentStore)
    }
    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    ForEach(ids.compactMap { store.records[$0] }) { comment in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                AdminCommentAvatar(comment: comment, siteRoot: api.siteRoot)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(comment.nickname).font(.subheadline.weight(.medium))
                                    Text(AdminFormatters.displayDate(comment.createdAt)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if comment.status == "pending" { Text("待审核").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(comment.content).font(.subheadline).textSelection(.enabled)
                            if let reply = comment.adminReply?.trimmedNonEmpty {
                                Text("我的回复：" + reply).font(.subheadline).foregroundStyle(CreationDesign.accent)
                            }
                            Button(comment.adminReply?.trimmedNonEmpty == nil ? "回复" : "修改回复", systemImage: "arrowshape.turn.up.left") {
                                replyID = comment.id
                                if drafts[comment.id] == nil { drafts[comment.id] = comment.adminReply ?? "" }
                            }.font(.caption).buttonStyle(.borderless)
                            if replyID == comment.id {
                                TextField("回复评论", text: Binding(get: { drafts[comment.id] ?? "" }, set: { drafts[comment.id] = $0 }), axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(3...8).disabled(sending)
                                HStack {
                                    Button("取消") { replyID = nil }.disabled(sending)
                                    Spacer()
                                    Button(sending ? "发送中…" : "发送回复") {
                                        Task { await reply(to: comment) }
                                    }.disabled(sending || drafts[comment.id]?.trimmedNonEmpty == nil)
                                }.buttonStyle(.borderless).font(.subheadline)
                            }
                        }
                        Divider()
                    }
                    if loading { ProgressView("加载评论…") }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if !loading && hasMore { Button(error == nil ? "加载更多评论" : "重试加载") { pageTask = Task { await load() } }.buttonStyle(.borderless) }
                    if !loading && ids.allSatisfy({ store.records[$0] == nil }) && page > 0 { Text("暂无评论").foregroundStyle(.secondary) }
                }
            }
        }.task(id: expanded) { if expanded && page == 0 { await load() } }
            .onChange(of: expanded) { _, value in if !value { pageTask?.cancel(); loadGeneration += 1; loading = false } }
            .onDisappear { pageTask?.cancel() }
            .onReceive(store.$change) { change in
                guard let change, change.updated == nil, change.old?.targetType == "moment", change.old?.targetId == momentID else { return }
                pageTask?.cancel(); loadGeneration += 1; loading = false; page = 0; hasMore = true; ids = []
                if expanded { pageTask = Task { await load() } }
            }
    }
    private func load() async {
        guard !loading, hasMore else { return }
        let generation = loadGeneration
        let revision = store.revision
        loading = true; error = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            let response = try await api.fetchComments(page: page + 1, momentID: momentID)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            store.ingest(response.items, since: revision)
            ids += response.items.map(\.id).filter { !ids.contains($0) }
            page += 1
            hasMore = response.meta.totalPages.map { page < $0 } ?? (response.items.count == 20)
            store.seedCount(response.meta.total, momentID: momentID, replace: true)
        } catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
    private func reply(to comment: AdminComment) async {
        guard !sending else { return }; sending = true; error = nil
        defer { sending = false }
        do {
            _ = try await api.updateComment(id: comment.id, action: .reply, reply: drafts[comment.id])
            replyID = nil; drafts[comment.id] = nil
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class CreationArticlesModel: ObservableObject {
    struct Query: Hashable {
        let filter: AdminPostFilter
        let search: String
    }
    let api: AdminAPIClient
    @Published private(set) var posts: [AdminPostSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    private var page = 0
    private var generation = 0
    private var request: Task<AdminPage<AdminPostSummary>, Error>?
    private var activeQuery: Query?
    private var loadedQuery: Query?
    init(api: AdminAPIClient) { self.api = api }
    func loadIfNeeded(filter: AdminPostFilter, search: String) async {
        guard page == 0 || loadedQuery != Query(filter: filter, search: search) else { return }
        guard !(isLoading && activeQuery == Query(filter: filter, search: search) && request?.isCancelled == false) else { return }
        await load(filter: filter, search: search, reset: true)
    }
    func load(filter: AdminPostFilter, search: String, reset: Bool = false) async {
        guard !Task.isCancelled else { return }
        let query = Query(filter: filter, search: search)
        guard reset || loadedQuery == query else { return }
        if reset { request?.cancel(); generation += 1 }
        let token = generation
        guard reset || (!isLoading && hasMore) else { return }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false; request = nil } }
        let next = reset ? 1 : page + 1
        activeQuery = query
        let api = api
        let task = Task { try await api.fetchPosts(page: next, status: filter, search: search) }
        request = task
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard token == generation, !Task.isCancelled else { return }
            if reset { posts = [] }
            let existing = Set(posts.map(\.id))
            posts.append(contentsOf: response.items.filter { !existing.contains($0.id) })
            page = next
            loadedQuery = query
            hasMore = response.meta.totalPages.map { next < $0 } ?? (response.items.count == 20)
        } catch { if token == generation, !Task.isCancelled, !isCreationCancellation(error) { self.error = error.localizedDescription } }
    }
    func delete(_ post: AdminPostSummary) async {
        do { try await api.deletePost(id: post.id); posts.removeAll { $0.id == post.id } }
        catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
}

struct CreationArticlesView: View {
    @Environment(\.creationMiniPlayerHeight) private var miniPlayerHeight
    let api: AdminAPIClient
    var openDrafts: () -> Void = {}
    @StateObject private var model: CreationArticlesModel
    @State private var showingSearch = false
    @State private var filter = AdminPostFilter.all
    @State private var search = ""
    @State private var route: CreationEditorRoute?
    @State private var reading: AdminPostSummary?
    @State private var pendingDelete: AdminPostSummary?
    @State private var didPreview = false
    @State private var localError: String?
    @State private var refreshAfterEditing = false
    @State private var refreshAfterReading = false
    @State private var composeVisible = true
    private var query: CreationArticlesModel.Query { .init(filter: filter, search: search) }
    init(api: AdminAPIClient, initialFilter: AdminPostFilter = .all, openDrafts: @escaping () -> Void = {}) {
        self.api = api; self.openDrafts = openDrafts
        _model = StateObject(wrappedValue: CreationArticlesModel(api: api))
        _filter = State(initialValue: initialFilter)
    }
    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 20) {
                CreationPageHeader(title: "文章", subtitle: "") {
                    HStack(spacing: 12) {
                        Button { withAnimation { showingSearch.toggle() }; if !showingSearch { search = "" } } label: {
                            Image(systemName: "magnifyingglass").font(.title3).modifier(CreationHeaderIconFrame())
                        }.accessibilityLabel("搜索文章")
                        Button(action: openDrafts) { Image(systemName: "tray").font(.title3).modifier(CreationHeaderIconFrame()) }.accessibilityLabel("查看本机草稿")
                    }
                }
                if showingSearch { CreationSearchField(placeholder: "搜索站点文章", text: $search) }
                Menu {
                    Picker("文章状态", selection: $filter) {
                        ForEach(AdminPostFilter.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label(filter == .all ? "全部文章" : filter.title, systemImage: "line.3.horizontal.decrease") }
                    .font(.subheadline).accessibilityLabel("筛选文章：\(filter.title)")
                Rectangle().fill(CreationDesign.border).frame(height: 0.5)
                if let error = model.error ?? localError { CreationNotice(text: error, isError: true); Button("重试加载") { Task { await reload() } } }
                if model.posts.isEmpty && !model.isLoading && model.error == nil { ContentUnavailableView(search.isEmpty ? "还没有文章" : "没有找到文章", systemImage: "doc.text", description: Text(search.isEmpty ? "把零散的灵感，写成一篇文章。" : "试试其他标题或关键词。")) }
            }.listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden).listRowBackground(CreationDesign.canvas)
            ForEach(model.posts) { post in
                CreationArticleCard(post: post, api: api, read: { reading = post })
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(CreationDesign.canvas)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = post }
                        Button("编辑", systemImage: "square.and.pencil") { edit(post) }
                    }
            }
            if model.isLoading { ProgressView("正在加载…").frame(maxWidth: .infinity).listRowBackground(CreationDesign.canvas) }
            if model.hasMore && !model.posts.isEmpty && !model.isLoading { Button("加载更多文章") { Task { await model.load(filter: filter, search: search) } }.frame(maxWidth: .infinity, minHeight: 44).listRowBackground(CreationDesign.canvas) }
            Color.clear.frame(height: 80)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground).toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) {
                CreationFloatingButton(title: "写文章", symbol: "plus", verticalPadding: 8) { Task { await newArticle() } }
                    .padding(.bottom, miniPlayerHeight)
                    .opacity(composeVisible ? 1 : 0).offset(y: composeVisible ? 0 : 12)
                    .allowsHitTesting(composeVisible).accessibilityHidden(!composeVisible)
            }
            .modifier(CreationScrollActionVisibility(visible: $composeVisible))
            .refreshable { await reload() }
            .task(id: query) {
                if !search.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                await model.loadIfNeeded(filter: filter, search: search)
                guard !Task.isCancelled else { return }
                if CreationPreview.isEnabled && ["article", "settings"].contains(CreationPreview.screen) && !didPreview { didPreview = true; await newArticle() }
                if CreationPreview.isEnabled && CreationPreview.screen == "reader" && !didPreview { didPreview = true; reading = model.posts.first }
            }
            .sheet(item: $reading, onDismiss: {
                if refreshAfterReading { refreshAfterReading = false; Task { await reload() } }
            }) { post in CreationArticleReader(post: post, api: api) { refreshAfterReading = true } }
            .fullScreenCover(item: $route, onDismiss: {
                if refreshAfterEditing { refreshAfterEditing = false; Task { await reload() } }
            }) { route in CreationComposerView(api: api, draft: route.draft) { refreshAfterEditing = true } }
            .confirmationDialog("删除文章？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { post in
                Button("删除「\(post.title)」", role: .destructive) { Task { await model.delete(post) } }
            } message: { _ in Text("删除后无法恢复。") }
    }
    private func edit(_ post: AdminPostSummary) { route = CreationEditorRoute(draft: CreationDraft(site: CreationDraftStore.canonicalSite(api.siteRoot), kind: .post, serverID: post.id)) }
    private func reload() async { await model.load(filter: filter, search: search, reset: true) }
    private func newArticle() async {
        do {
            let local = try await CreationDraftStore.shared.list(site: CreationDraftStore.canonicalSite(api.siteRoot)).first { $0.kind == .post && $0.serverID == nil }
            route = CreationEditorRoute(draft: local ?? CreationDraft(site: CreationDraftStore.canonicalSite(api.siteRoot), kind: .post))
        } catch { localError = error.localizedDescription }
    }
}

private struct CreationArticleCard: View {
    let post: AdminPostSummary
    let api: AdminAPIClient
    let read: () -> Void
    var body: some View {
        Button(action: read) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(post.category.isEmpty ? "未分类" : post.category)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
                        .frame(maxWidth: 90).fixedSize(horizontal: true, vertical: false).layoutPriority(2)
                    Text(post.title).font(.headline).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                }
                if let excerpt = post.excerpt?.trimmedNonEmpty {
                    Text(excerpt).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4).lineLimit(3)
                }
                Text(metadata).font(.caption).lineSpacing(4)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).multilineTextAlignment(.leading)
            .overlay(alignment: .bottom) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }
    }
    private var metadata: AttributedString {
        let updated = post.updatedAt != nil && post.updatedAt != post.createdAt
        let date = String((post.updatedAt ?? post.createdAt ?? "").prefix(10))
        var result = AttributedString("\(updated ? "更新于" : "发布于") \(date) · \(post.status == "published" ? "已发布" : "草稿")")
        result.foregroundColor = .secondary
        if !post.tags.isEmpty {
            var tags = AttributedString("  " + post.tags.map { "#" + $0 }.joined(separator: "  "))
            tags.foregroundColor = CreationDesign.accent
            result.append(tags)
        }
        return result
    }
}

enum CreationMomentTags {
    static func isTagOnlyParagraph(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        return !tokens.isEmpty && tokens.allSatisfy { token in
            token.range(of: #"^#[\p{L}\p{N}_-]{1,32}$"#, options: .regularExpression) != nil
        }
    }
    static func parse(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s，。！？,.!?；;：:、])#([\p{L}\p{N}_-]{1,32})"#) else { return [] }
        let source = CreationMusic.split(text).text as NSString
        var seen = Set<String>()
        return Array(regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let value = source.substring(with: match.range(at: 1))
            return seen.insert(value.lowercased()).inserted ? value : nil
        }.prefix(8))
    }
}

struct CreationArticleReader: View {
    let post: AdminPostSummary
    let api: AdminAPIClient
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AdminPostDetail?
    @State private var error: String?
    @State private var route: CreationEditorRoute?
    @State private var refreshAfterEditing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let detail {
                        if let cover = detail.cover, !cover.isEmpty { CreationRemoteImage(path: cover, site: api.siteRoot).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 2)) }
                        Text(detail.title).font(CreationDesign.editorial(34, relativeTo: .largeTitle, bold: true))
                        Text("\(detail.category) · \(String((detail.updatedAt ?? detail.createdAt ?? "").prefix(10)))").font(.subheadline).foregroundStyle(CreationDesign.secondary)
                        Divider()
                        ForEach(Array(creationMarkdownBlocks(detail.content, references: detail.referenceSnapshots).enumerated()), id: \.offset) { _, block in
                            AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot)
                        }
                    } else if let error { CreationNotice(text: error, isError: true); Button("重新加载") { Task { await load() } } }
                    else { ProgressView("正在打开文章…").frame(maxWidth: .infinity, minHeight: 200) }
                }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }.background(CreationDesign.surface).foregroundStyle(CreationDesign.foreground)
                .navigationTitle("阅读").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { route = CreationEditorRoute(draft: CreationDraft(site: CreationDraftStore.canonicalSite(api.siteRoot), kind: .post, serverID: post.id)) } label: { Label("编辑", systemImage: "square.and.pencil") }.disabled(detail == nil)
                    }
                }
                .task { await load() }
                .fullScreenCover(item: $route, onDismiss: {
                    if refreshAfterEditing { refreshAfterEditing = false; Task { await load() } }
                }) { route in CreationComposerView(api: api, draft: route.draft) { refreshAfterEditing = true; onChanged() } }
        }.tint(CreationDesign.accent)
    }
    private func load() async {
        error = nil
        do { let value = try await api.fetchPost(id: post.id); guard !Task.isCancelled else { return }; detail = value }
        catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
}

struct LocalDraftsView: View {
    let api: AdminAPIClient
    var dismissible = false
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [CreationDraft] = []
    @State private var error: String?
    @State private var route: CreationEditorRoute?
    @State private var pendingDelete: CreationDraft?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CreationPageHeader(title: "草稿箱", subtitle: "没写完的，留着慢慢写。") {
                    if dismissible { Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("关闭草稿箱") }
                }
                Text("本机保存 · 仅在修改后自动保存").font(.caption).foregroundStyle(CreationDesign.secondary)
                Text(api.siteRoot.host ?? "当前站点").font(.caption).foregroundStyle(CreationDesign.secondary)
                if let error { CreationNotice(text: error, isError: true); Button("重试读取") { Task { await load() } } }
                if drafts.isEmpty && error == nil { ContentUnavailableView("没有本机草稿", systemImage: "tray", description: Text("未完成的絮语和文章会留在这里，不会自动发布。")) }
                ForEach(drafts) { draft in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { route = CreationEditorRoute(draft: draft) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(draft.kind == .moment ? "絮语" : "文章").font(.caption).padding(6).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(CreationDesign.accent)
                                    Text(draft.summary).font(.body).lineLimit(3).foregroundStyle(CreationDesign.foreground)
                                    if draft.submission == .uncertain { Text("发布结果待确认").font(.caption).foregroundStyle(CreationDesign.danger) }
                                    HStack { Text(draft.updatedAt, style: .relative); Text("\(draft.media.count) 张图片 · \(draft.music.count) 首音乐") }.font(.caption).foregroundStyle(CreationDesign.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let media = draft.media.first { CreationLocalImage(media: media, site: draft.site, api: api).frame(width: 66, height: 66).clipped().clipShape(RoundedRectangle(cornerRadius: 10)) }
                            }
                        }.buttonStyle(.plain)
                        HStack { Spacer(); Button("删除本机草稿", role: .destructive) { pendingDelete = draft }.font(.subheadline).frame(minHeight: 44) }
                    }.padding(.vertical, 18).overlay(alignment: .bottom) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }
                }
            }.padding(20)
        }.background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground)
            .navigationTitle("草稿箱").navigationBarTitleDisplayMode(.inline)
            .toolbar(dismissible ? .hidden : .visible, for: .navigationBar)
            .task { await load() }.refreshable { await load() }
            .fullScreenCover(item: $route, onDismiss: { Task { await load() } }) { route in CreationComposerView(api: api, draft: route.draft) { Task { await load() } } }
            .confirmationDialog("删除此本机草稿？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { draft in
                Button("删除本机草稿", role: .destructive) { Task { do { try await CreationDraftStore.shared.remove(draft); await load() } catch { self.error = error.localizedDescription } } }
            } message: { _ in Text("仅清理此草稿的本地文件，服务器内容与附件不受影响。") }
    }
    private func load() async {
        do { let scan = try await CreationDraftStore.shared.scan(site: CreationDraftStore.canonicalSite(api.siteRoot)); drafts = scan.drafts; error = scan.warnings.first }
        catch { self.error = error.localizedDescription }
    }
}
