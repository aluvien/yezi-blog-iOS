import SwiftUI
import UIKit

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
    init(api: AdminAPIClient) { self.api = api }

    func load(reset: Bool = false) async {
        if reset { generation += 1 }
        let token = generation
        guard reset || (!isLoading && hasMore) else { return }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false } }
        let next = reset ? 1 : page + 1
        do {
            let result = try await api.fetchMoments(page: next)
            guard token == generation, !Task.isCancelled else { return }
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
    private var visibleMoments: [AdminMoment] {
        model.moments.filter { contentFilter.includes($0) && (search.isEmpty || $0.content.localizedStandardContains(search)) }
    }
    @State private var published = false
    @State private var didPreview = false

    init(api: AdminAPIClient, openDrafts: @escaping () -> Void) {
        self.api = api
        self.openDrafts = openDrafts
        _model = StateObject(wrappedValue: CreationFeedModel(api: api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CreationPageHeader(title: "絮语", subtitle: "一些日常，一点心事。") {
                    HStack(spacing: 6) {
                        Button { withAnimation { showingSearch.toggle() }; if !showingSearch { search = "" } } label: {
                            Image(systemName: "magnifyingglass").font(.title3).frame(width: 44, height: 44).background(CreationDesign.surface, in: Circle())
                        }.accessibilityLabel("搜索絮语")
                        Button(action: openDrafts) { Image(systemName: "tray").font(.title3).frame(width: 44, height: 44).background(CreationDesign.surface, in: Circle()) }.accessibilityLabel("查看本机草稿")
                    }
                }
                HStack(spacing: 10) {
                    Button { start(.text) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "leaf.fill").foregroundStyle(CreationDesign.accent).frame(width: 36, height: 44)
                            Text("写点什么…").font(.body).foregroundStyle(CreationDesign.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { start(.photos) } label: { VStack(spacing: 4) { Image(systemName: "photo").font(.title3); Text("照片").font(.caption2) }.frame(width: 44, height: 48) }.accessibilityLabel("发布照片絮语")
                    Button { start(.music) } label: { VStack(spacing: 4) { Image(systemName: "music.note").font(.title3); Text("音乐").font(.caption2) }.frame(width: 44, height: 48) }.accessibilityLabel("分享音乐")
                }.padding(12).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 20))
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MomentContentFilter.allCases, id: \.self) { value in
                            CreationFilterChip(title: value.rawValue, selected: contentFilter == value) { contentFilter = value }
                        }
                    }
                }
                CreationSectionHeading(title: "日常片刻", detail: "已加载 \(model.moments.count) 条")
                if visibleMoments.isEmpty && !model.moments.isEmpty {
                    ContentUnavailableView("没有匹配的絮语", systemImage: "magnifyingglass", description: Text("换个关键词，或加载更多内容。"))
                }
                if let error = model.error { CreationNotice(text: error, isError: true); Button("重试加载") { Task { await model.load(reset: model.moments.isEmpty) } } }
                if model.moments.isEmpty && !model.isLoading && model.error == nil {
                    ContentUnavailableView("还没有絮语", systemImage: "quote.bubble", description: Text("不必想好标题，先记下这一刻。"))
                }
                ForEach(visibleMoments) { moment in
                    MomentFeedCard(moment: moment, api: api, edit: { Task { await edit(moment) } }, delete: { pendingDelete = moment })
                }
                if model.isLoading { ProgressView("正在加载…").frame(maxWidth: .infinity) }
                if model.hasMore && !model.moments.isEmpty && !model.isLoading { Button("加载更多絮语") { Task { await model.load() } }.frame(maxWidth: .infinity, minHeight: 44) }
            }.padding(20).padding(.bottom, 72)
        }.background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) { CreationFloatingButton(title: "写絮语", symbol: "square.and.pencil") { start(.text) } }
            .refreshable { await model.load(reset: true); await loadRecent() }
            .task {
                await model.load(reset: true)
                await loadRecent()
                if CreationPreview.isEnabled && !didPreview {
                    didPreview = true
                    if CreationPreview.screen == "composer", let recent { route = CreationEditorRoute(draft: recent) }
                    if CreationPreview.screen == "music", let recent { route = CreationEditorRoute(draft: recent, intent: .music) }
                }
            }
            .fullScreenCover(item: $route, onDismiss: { Task { await model.load(reset: true); await loadRecent() } }) { route in
                CreationComposerView(api: api, draft: route.draft, intent: route.intent) {
                    published = true
                    Task { await model.load(reset: true); await loadRecent(); try? await Task.sleep(for: .seconds(3)); published = false }
                }
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
    let edit: () -> Void
    let delete: () -> Void
    @State private var expanded = false
    @State private var image: CreationMedia?
    private var foldedMusic: [String] {
        MarkdownParser.parse(moment.content).compactMap { block in
            guard case .music(let spec) = block, MarkdownParser.musicMarker(from: spec)?.folded == true else { return nil }
            return spec
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(displayDate(moment.createdAt)).font(.caption).foregroundStyle(CreationDesign.secondary)
                Spacer()
                Button(action: edit) { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }.accessibilityLabel("编辑絮语")
                Menu {
                    Button("编辑絮语", action: edit)
                    Button("复制文字") { UIPasteboard.general.string = CreationMusic.split(moment.content).text }
                    Button("删除絮语", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("絮语操作")
            }
            ForEach(Array(foldedMusic.enumerated()), id: \.offset) { _, spec in
                CreationMusicCard(music: CreationMusic(spec: spec), api: api, compact: true)
            }
            ForEach(Array(MarkdownParser.parse(moment.content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .music(let spec):
                    if MarkdownParser.musicMarker(from: spec)?.folded != true {
                        CreationMusicCard(music: CreationMusic(spec: spec), api: api)
                    }
                case .paragraph(let text): Text(MarkdownParser.attributed(text)).font(.body).lineSpacing(5).lineLimit(expanded ? nil : 6).textSelection(.enabled)
                default: AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot)
                }
            }
            if moment.content.count > 220 { Button(expanded ? "收起" : "展开全文") { expanded.toggle() }.font(.subheadline) }
            if !moment.images.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: moment.images.count == 1 ? 1 : (moment.images.count == 2 || moment.images.count == 4 ? 2 : 3)), spacing: 6) {
                    ForEach(Array(moment.images.enumerated()), id: \.offset) { _, path in
                        Button { image = CreationMedia(remotePath: path, state: .uploaded) } label: { CreationRemoteImage(path: path, site: api.siteRoot).frame(height: moment.images.count == 1 ? 190 : 115).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel("查看絮语图片")
                    }
                }
            }
        }.padding(16).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 20))
            .sheet(item: $image) { media in CreationImagePreview(media: media, api: api, site: CreationDraftStore.canonicalSite(api.siteRoot)) }
    }
    private func displayDate(_ raw: String?) -> String {
        guard let raw else { return "时间未知" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? raw
    }
}

@MainActor
final class CreationArticlesModel: ObservableObject {
    let api: AdminAPIClient
    @Published private(set) var posts: [AdminPostSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    private var page = 0
    private var generation = 0
    init(api: AdminAPIClient) { self.api = api }
    func load(filter: AdminPostFilter, search: String, reset: Bool = false) async {
        if reset { generation += 1 }
        let token = generation
        guard reset || (!isLoading && hasMore) else { return }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false } }
        let next = reset ? 1 : page + 1
        do {
            let response = try await api.fetchPosts(page: next, status: filter, search: search)
            guard token == generation, !Task.isCancelled else { return }
            if reset { posts = [] }
            let existing = Set(posts.map(\.id))
            posts.append(contentsOf: response.items.filter { !existing.contains($0.id) })
            page = next
            hasMore = response.meta.totalPages.map { next < $0 } ?? (response.items.count == 20)
        } catch { if token == generation, !Task.isCancelled, !isCreationCancellation(error) { self.error = error.localizedDescription } }
    }
    func delete(_ post: AdminPostSummary) async {
        do { try await api.deletePost(id: post.id); posts.removeAll { $0.id == post.id } }
        catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
}

struct CreationArticlesView: View {
    let api: AdminAPIClient
    var openDrafts: () -> Void = {}
    @StateObject private var model: CreationArticlesModel
    @State private var filter = AdminPostFilter.all
    @State private var search = ""
    @State private var route: CreationEditorRoute?
    @State private var reading: AdminPostSummary?
    @State private var pendingDelete: AdminPostSummary?
    @State private var didPreview = false
    @State private var localError: String?
    init(api: AdminAPIClient, initialFilter: AdminPostFilter = .all, openDrafts: @escaping () -> Void = {}) {
        self.api = api; self.openDrafts = openDrafts
        _model = StateObject(wrappedValue: CreationArticlesModel(api: api))
        _filter = State(initialValue: initialFilter)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                CreationPageHeader(title: "文章", subtitle: "整理思绪，写成自己的故事。") {
                    Button(action: openDrafts) { Image(systemName: "tray").font(.title3).frame(width: 48, height: 48).background(CreationDesign.surface, in: Circle()) }.accessibilityLabel("查看本机草稿")
                }
                CreationSearchField(placeholder: "搜索站点文章", text: $search) { Task { await reload() } }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AdminPostFilter.allCases) { value in
                            CreationFilterChip(title: value.title, selected: filter == value) { filter = value }
                        }
                    }
                }
                CreationSectionHeading(title: "我的文章", detail: "点开阅读 · 随时编辑")
                if let error = model.error ?? localError { CreationNotice(text: error, isError: true); Button("重试加载") { Task { await reload() } } }
                ForEach(model.posts) { post in
                    CreationArticleCard(post: post, api: api, read: { reading = post }, edit: { edit(post) })
                        .contextMenu {
                            Button("阅读", systemImage: "book") { reading = post }
                            Button("编辑 Markdown", systemImage: "square.and.pencil") { edit(post) }
                            Button("删除文章", systemImage: "trash", role: .destructive) { pendingDelete = post }
                        }
                }
                if model.posts.isEmpty && !model.isLoading && model.error == nil { ContentUnavailableView(search.isEmpty ? "还没有文章" : "没有找到文章", systemImage: "doc.text", description: Text(search.isEmpty ? "把零散的灵感，写成一篇文章。" : "试试其他标题或关键词。")) }
                if model.isLoading { ProgressView("正在加载…").frame(maxWidth: .infinity) }
                if model.hasMore && !model.posts.isEmpty && !model.isLoading { Button("加载更多文章") { Task { await model.load(filter: filter, search: search) } }.frame(maxWidth: .infinity, minHeight: 44) }
            }.padding(20).padding(.bottom, 80)
        }.background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground).toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) { CreationFloatingButton(title: "写文章", symbol: "square.and.pencil") { Task { await newArticle() } } }
            .onChange(of: filter) { _, _ in Task { await reload() } }
            .task(id: search) { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { await reload() } }
            .refreshable { await reload() }
            .task {
                if CreationPreview.isEnabled && ["article", "settings"].contains(CreationPreview.screen) && !didPreview { didPreview = true; await newArticle() }
                if CreationPreview.isEnabled && CreationPreview.screen == "reader" && !didPreview { didPreview = true; await reload(); reading = model.posts.first }
            }
            .sheet(item: $reading, onDismiss: { Task { await reload() } }) { post in CreationArticleReader(post: post, api: api) }
            .fullScreenCover(item: $route, onDismiss: { Task { await reload() } }) { route in CreationComposerView(api: api, draft: route.draft) { Task { await reload() } } }
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
    let edit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: read) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(post.category.isEmpty ? "未分类" : post.category).font(.caption.weight(.medium)).foregroundStyle(CreationDesign.accent)
                        Text(post.title).font(.system(.title3, design: .serif, weight: .semibold)).foregroundStyle(CreationDesign.foreground).multilineTextAlignment(.leading).lineLimit(3)
                        Text(String((post.updatedAt ?? post.createdAt ?? "").prefix(10))).font(.caption).foregroundStyle(CreationDesign.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let cover = post.cover, !cover.isEmpty { CreationRemoteImage(path: cover, site: api.siteRoot).frame(width: 84, height: 92).clipShape(RoundedRectangle(cornerRadius: 14)) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack {
                Label(post.status == "published" ? "已发布" : "服务器草稿", systemImage: post.status == "published" ? "checkmark.circle" : "doc.badge.clock")
                    .font(.caption).foregroundStyle(CreationDesign.secondary)
                Spacer()
                Button(action: edit) { Label("编辑", systemImage: "square.and.pencil").font(.subheadline.weight(.medium)).frame(minHeight: 44) }
            }
        }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct CreationArticleReader: View {
    let post: AdminPostSummary
    let api: AdminAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AdminPostDetail?
    @State private var error: String?
    @State private var route: CreationEditorRoute?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let detail {
                        if let cover = detail.cover, !cover.isEmpty { CreationRemoteImage(path: cover, site: api.siteRoot).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 20)) }
                        Text(detail.title).font(.system(.largeTitle, design: .serif, weight: .bold))
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
                .fullScreenCover(item: $route, onDismiss: { Task { await load() } }) { route in CreationComposerView(api: api, draft: route.draft) }
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
                    if dismissible { Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).background(CreationDesign.surface, in: Circle()) }.accessibilityLabel("关闭草稿箱") }
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
                    }.padding(17).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 18))
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
