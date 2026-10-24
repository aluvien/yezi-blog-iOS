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
        if let count, momentCounts[momentID] != count, replace || momentCounts[momentID] == nil { momentCounts[momentID] = count }
    }
    func seedCounts(_ moments: [AdminMoment]) {
        var next = momentCounts
        for moment in moments { if let count = moment.commentCount { next[moment.id] = count } }
        if next != momentCounts { momentCounts = next }
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
    private(set) var presentations: [Int: CreationMomentPresentation] = [:]
    init(api: AdminAPIClient) { self.api = api }

    func loadIfNeeded() async {
        guard page == 0, !(isLoading && request?.isCancelled == false) else { return }
        await load(reset: true, reuseLoaded: true)
    }

    func load(reset: Bool = false, reuseLoaded: Bool = false) async {
        guard !Task.isCancelled else { return }
        if reset { request?.cancel(); generation += 1 }
        let token = generation
        guard reset || (!isLoading && hasMore) else { return }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false; request = nil } }
        if reset && !reuseLoaded { await api.discardLoadedData(for: ["moments"]) }
        guard token == generation, !Task.isCancelled else { return }
        let next = reset ? 1 : page + 1
        let api = api
        let task = Task { try await api.fetchMoments(page: next, reuseLoaded: reuseLoaded || !reset) }
        request = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard token == generation, !Task.isCancelled else { return }
            api.commentStore.seedCounts(result.items)
            var nextPresentations = reset ? [:] : presentations
            for moment in result.items {
                nextPresentations[moment.id] = presentations[moment.id].flatMap { $0.source == moment.content && $0.createdAt == moment.createdAt ? $0 : nil }
                    ?? CreationMomentPresentation(moment.content, createdAt: moment.createdAt)
            }
            presentations = nextPresentations
            let current = reset ? [] : moments
            var existing = Set(current.map(\.id))
            moments = current + result.items.filter { existing.insert($0.id).inserted }
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
    func includes(_ moment: AdminMoment, presentation: CreationMomentPresentation? = nil) -> Bool {
        switch self {
        case .all: true
        case .photos: !moment.images.isEmpty
        case .music: presentation?.hasMusic ?? !CreationMusic.split(moment.content).music.isEmpty
        case .text: moment.images.isEmpty && !(presentation?.hasMusic ?? !CreationMusic.split(moment.content).music.isEmpty)
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
    @State private var showingMusic = false
    @State private var childPresented = false
    @State private var composeVisible = true
    @State private var authorName = ""
    @State private var authorAvatar: String?
    @State private var loadedAuthor = false
    private var visibleMoments: [AdminMoment] {
        model.moments.filter { contentFilter.includes($0, presentation: model.presentations[$0.id]) && (search.isEmpty || $0.content.localizedStandardContains(search)) }
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
                            Image(systemName: "magnifyingglass").font(CreationDesign.interface(.title3)).modifier(CreationHeaderIconFrame())
                        }.accessibilityLabel("搜索絮语")
                        Button { showingMusic = true } label: { Image(systemName: "music.note").font(CreationDesign.interface(.title3)).modifier(CreationHeaderIconFrame()) }.accessibilityLabel("播放音乐列表")
                        Menu {
                            Picker("筛选絮语", selection: $contentFilter) {
                                ForEach(MomentContentFilter.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                            }
                            Divider()
                            Button("发布照片絮语", systemImage: "photo") { start(.photos) }
                            Button("查看本机草稿", systemImage: "tray", action: openDrafts)
                        } label: { Image(systemName: "ellipsis").font(CreationDesign.interface(.title3)).modifier(CreationHeaderIconFrame()) }.accessibilityLabel("更多絮语操作")
                    }
                }
                if let recent {
                    Button { route = CreationEditorRoute(draft: recent) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("继续上次记录").font(CreationDesign.interface(.caption).weight(.semibold))
                                Text(recent.summary).font(CreationDesign.interface(.subheadline)).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(CreationDesign.interface(.caption))
                        }.padding(12).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).foregroundStyle(CreationDesign.accent)
                }
                if published { CreationNotice(text: "已发布") }
                if let draftError { CreationNotice(text: draftError, isError: true); Button("重试读取草稿") { Task { await loadRecent() } } }
                if showingSearch { CreationSearchField(placeholder: "搜索已加载的絮语", text: $search, autofocus: true) }
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
                MomentFeedCard(moment: moment, presentation: model.presentations[moment.id], api: api, authorName: authorName, authorAvatar: authorAvatar)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(CreationDesign.canvas)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = moment }
                        Button("编辑", systemImage: "square.and.pencil") { Task { await edit(moment) } }
                    }
            }
            if model.isLoading { ProgressView("正在加载…").frame(maxWidth: .infinity).listRowBackground(CreationDesign.canvas) }
            if model.hasMore && !model.moments.isEmpty {
                Group {
                    if model.error != nil {
                        Button("重试加载更多絮语") { Task { await model.load() } }
                    } else {
                        Text("继续上滑加载更多").foregroundStyle(.secondary)
                            .onAppear { Task { await model.load() } }
                    }
                }.frame(maxWidth: .infinity, minHeight: 44)
                    .font(CreationDesign.copy(14, relativeTo: .caption))
                    .listRowSeparator(.hidden).listRowBackground(CreationDesign.canvas)
                    .accessibilityIdentifier("moments.pagination")
            }
            Color.clear.frame(height: 80)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) {
                CreationFloatingButton(title: "写絮语", symbol: "plus", verticalPadding: 8) { start(.text) }
                    .modifier(CreationComposeVisibility(visible: composeVisible && !showingSearch && !showingMusic && route == nil && pendingDelete == nil && !childPresented))
            }
            .preference(key: CreationMiniPlayerHiddenKey.self, value: !composeVisible || showingSearch || showingMusic || route != nil || pendingDelete != nil || childPresented)
            .onPreferenceChange(CreationOverlayPresentedKey.self) { childPresented = $0 }
            .modifier(CreationScrollActionVisibility(visible: $composeVisible))
            .sheet(isPresented: $showingMusic) { CreationListeningView(api: api, moments: model.moments) }
            .task {
                guard !loadedAuthor else { return }
                if let settings = try? await api.fetchSettings(reuseLoaded: true), !Task.isCancelled {
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

final class CreationMomentPresentation {
    let source: String
    let createdAt: String?
    let dateText: String
    let blocks: [MarkdownBlock]
    let hasMusic: Bool
    let foldedMusic: [String]
    let paragraphs: [String: AttributedString]
    let tags: [String]
    init(_ source: String, createdAt: String? = nil) {
        self.source = source
        self.createdAt = createdAt
        dateText = Self.displayDate(createdAt)
        blocks = MarkdownParser.parse(source)
        hasMusic = blocks.contains { if case .music = $0 { return true }; return false }
        foldedMusic = blocks.compactMap { block in
            guard case .music(let spec) = block, MarkdownParser.musicMarker(from: spec)?.folded == true else { return nil }
            return spec
        }
        var text: [String: AttributedString] = [:]
        for case .paragraph(let value) in blocks where !CreationMomentTags.isTagOnlyParagraph(value) {
            text[value] = MarkdownParser.attributed(value)
        }
        paragraphs = text
        tags = CreationMomentTags.parse(source)
    }
    private static func displayDate(_ raw: String?) -> String {
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

struct MomentFeedCard: View {
    let moment: AdminMoment
    let api: AdminAPIClient
    let presentation: CreationMomentPresentation
    var authorName = ""
    var authorAvatar: String?
    @ObservedObject private var comments: AdminCommentStore
    @State private var showingComments = false
    @State private var expanded = false
    @State private var image: CreationImageSelection?
    init(moment: AdminMoment, presentation: CreationMomentPresentation? = nil, api: AdminAPIClient, authorName: String = "", authorAvatar: String? = nil) {
        self.moment = moment; self.api = api; self.authorName = authorName; self.authorAvatar = authorAvatar
        self.presentation = presentation ?? CreationMomentPresentation(moment.content, createdAt: moment.createdAt)
        _comments = ObservedObject(wrappedValue: api.commentStore)
    }
    private var foldedMusic: [String] {
        presentation.foldedMusic
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                if let authorAvatar, !authorAvatar.isEmpty {
                    CreationRemoteImage(path: authorAvatar, site: api.siteRoot).frame(width: 32, height: 32).clipShape(Circle())
                } else { Image(systemName: "leaf.circle.fill").font(CreationDesign.interface(.title)).foregroundStyle(.secondary) }
                Text(authorName.isEmpty ? "博主" : authorName)
                    .font(CreationDesign.interface(.subheadline, weight: .medium))
                    .lineLimit(1).frame(minHeight: 32, alignment: .center)
                if let spec = foldedMusic.first {
                    CreationMusicCard(music: CreationMusic(spec: spec), api: api, compact: true, inline: true)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(foldedMusic.dropFirst().enumerated()), id: \.offset) { _, spec in
                CreationMusicCard(music: CreationMusic(spec: spec), api: api, compact: true, inline: true)
            }
            ForEach(Array(presentation.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .music(let spec):
                    if MarkdownParser.musicMarker(from: spec)?.folded != true {
                        CreationMusicCard(music: CreationMusic(spec: spec), api: api)
                    }
                case .paragraph(let text):
                    if let attributed = presentation.paragraphs[text] {
                        Text(attributed).font(CreationDesign.copy()).lineSpacing(5).lineLimit(expanded ? nil : 6).textSelection(.enabled)
                    }
                default: AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot)
                }
            }
            if moment.content.count > 220 { Button(expanded ? "收起" : "展开全文") { expanded.toggle() }.font(CreationDesign.interface(.subheadline)) }
            if !moment.images.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: moment.images.count == 1 ? 1 : (moment.images.count == 2 || moment.images.count == 4 ? 2 : 3)), spacing: 6) {
                    ForEach(Array(moment.images.enumerated()), id: \.offset) { index, path in
                        Button { image = CreationImageSelection(items: moment.images.map { CreationMedia(remotePath: $0, state: .uploaded) }, index: index) } label: { CreationRemoteImage(path: path, site: api.siteRoot).frame(height: moment.images.count == 1 ? 260 : 140).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel("查看絮语图片")
                            .accessibilityIdentifier("moment.\(moment.id).image.\(index)")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                let tags = moment.tags?.isEmpty == false ? moment.tags! : presentation.tags
                (Text(presentation.dateText).font(CreationDesign.time()).foregroundColor(.secondary)
                 + Text(moment.location?.trimmedNonEmpty.map { "  ·  📍" + $0 } ?? "").foregroundColor(.secondary)
                 + Text(tags.isEmpty ? "" : "  ·  " + tags.map { "#" + $0 }.joined(separator: "  ")).foregroundColor(CreationDesign.accent))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                let count = comments.momentCounts[moment.id] ?? moment.commentCount ?? 0
                if count > 0 {
                    Button {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { showingComments.toggle() }
                    } label: {
                        Text("\(count) 条评论").fixedSize()
                            .frame(minWidth: 88, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(CreationDesign.accent)
                        .accessibilityIdentifier("moment-comments-\(moment.id)")
                        .accessibilityValue(showingComments ? "已展开" : "已收起")
                }
            }.font(CreationDesign.time())
            MomentInlineComments(momentID: moment.id, api: api, expanded: showingComments)
        }.padding(.top, 14).padding(.bottom, 24)
            .onAppear { comments.seedCount(moment.commentCount, momentID: moment.id) }
            .onChange(of: moment.commentCount) { _, value in comments.seedCount(value, momentID: moment.id, replace: true) }
            .onChange(of: comments.momentCounts[moment.id]) { _, value in if value == 0 { showingComments = false } }
            .contextMenu { Button("复制文字", systemImage: "doc.on.doc") { UIPasteboard.general.string = CreationMusic.split(moment.content).text } }
            .preference(key: CreationOverlayPresentedKey.self, value: image != nil)
            .fullScreenCover(item: $image) { selection in CreationImagePreview(selection: selection, api: api, site: CreationDraftStore.canonicalSite(api.siteRoot)) }
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
                                    Text(comment.nickname).font(CreationDesign.interface(.subheadline).weight(.medium))
                                    Text(AdminFormatters.displayDate(comment.createdAt)).font(CreationDesign.time(.caption2)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if comment.status == "pending" { Text("待审核").font(CreationDesign.interface(.caption)).foregroundStyle(.secondary) }
                            }
                            Text(comment.content).font(CreationDesign.copy(15, relativeTo: .subheadline)).textSelection(.enabled)
                            if let reply = comment.adminReply?.trimmedNonEmpty {
                                Text("我的回复：" + reply).font(CreationDesign.copy(15, relativeTo: .subheadline)).foregroundStyle(CreationDesign.accent)
                            }
                            Button(comment.adminReply?.trimmedNonEmpty == nil ? "回复" : "修改回复", systemImage: "arrowshape.turn.up.left") {
                                replyID = comment.id
                                if drafts[comment.id] == nil { drafts[comment.id] = comment.adminReply ?? "" }
                            }.font(CreationDesign.interface(.caption)).buttonStyle(.borderless)
                            if replyID == comment.id {
                                TextField("回复评论", text: Binding(get: { drafts[comment.id] ?? "" }, set: { drafts[comment.id] = $0 }), axis: .vertical)
                                    .font(CreationDesign.copy()).textFieldStyle(.roundedBorder).lineLimit(3...8).disabled(sending)
                                HStack {
                                    Button("取消") { replyID = nil }.disabled(sending)
                                    Spacer()
                                    Button(sending ? "发送中…" : "发送回复") {
                                        Task { await reply(to: comment) }
                                    }.disabled(sending || drafts[comment.id]?.trimmedNonEmpty == nil)
                                }.buttonStyle(.borderless).font(CreationDesign.interface(.subheadline))
                            }
                        }
                        Divider()
                    }
                    if loading { ProgressView("加载评论…") }
                    if let error { Text(error).font(CreationDesign.interface(.caption)).foregroundStyle(.secondary) }
                    if !loading && hasMore { Button(error == nil ? "加载更多评论" : "重试加载") { pageTask = Task { await load() } }.buttonStyle(.borderless) }
                    if !loading && ids.allSatisfy({ store.records[$0] == nil }) && page > 0 { Text("暂无评论").foregroundStyle(.secondary) }
                }
            }
        }.preference(key: CreationOverlayPresentedKey.self, value: expanded && replyID != nil)
            .task(id: expanded) { if expanded && page == 0 { await load() } }
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
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { loading = true; error = nil }
        defer { if generation == loadGeneration { withTransaction(transaction) { loading = false } } }
        do {
            let response = try await api.fetchComments(page: page + 1, momentID: momentID)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            withTransaction(transaction) {
                store.ingest(response.items, since: revision)
                ids += response.items.map(\.id).filter { !ids.contains($0) }
                page += 1
                hasMore = response.meta.totalPages.map { page < $0 } ?? (response.items.count == 20)
                store.seedCount(response.meta.total, momentID: momentID, replace: true)
                loading = false
            }
        } catch {
            if generation == loadGeneration, !isRequestCancellation(error) {
                withTransaction(transaction) { self.error = error.localizedDescription }
            }
        }
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
    @Published private(set) var total: Int?
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
        await load(filter: filter, search: search, reset: true, reuseLoaded: true)
    }
    func load(filter: AdminPostFilter, search: String, reset: Bool = false, reuseLoaded: Bool = false) async {
        guard !Task.isCancelled else { return }
        let query = Query(filter: filter, search: search)
        guard reset || loadedQuery == query else { return }
        if reset { request?.cancel(); generation += 1 }
        let token = generation
        guard reset || (!isLoading && hasMore) else { return }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false; request = nil } }
        if reset && !reuseLoaded { await api.discardLoadedData(for: ["posts"]) }
        guard token == generation, !Task.isCancelled else { return }
        let next = reset ? 1 : page + 1
        activeQuery = query
        let api = api
        let task = Task { try await api.fetchPosts(page: next, status: filter, search: search, reuseLoaded: reuseLoaded || !reset) }
        request = task
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard token == generation, !Task.isCancelled else { return }
            if filter == .all && search.isEmpty { total = response.meta.total }
            if reset { posts = [] }
            let existing = Set(posts.map(\.id))
            posts.append(contentsOf: response.items.filter { !existing.contains($0.id) })
            page = next
            loadedQuery = query
            hasMore = response.meta.totalPages.map { next < $0 } ?? (response.items.count == 20)
        } catch { if token == generation, !Task.isCancelled, !isCreationCancellation(error) { self.error = error.localizedDescription } }
    }
    func delete(_ post: AdminPostSummary) async {
        do { try await api.deletePost(id: post.id); posts.removeAll { $0.id == post.id }; if let count = total { total = max(0, count - 1) } }
        catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
}

struct CreationArticlesView: View {
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
                CreationPageHeader(title: "随笔", subtitle: model.total.map { "随笔与杂记 · 共 \($0) 篇" } ?? "随笔与杂记") {
                    HStack(spacing: 12) {
                        Button { withAnimation { showingSearch.toggle() }; if !showingSearch { search = "" } } label: {
                            Image(systemName: "magnifyingglass").font(CreationDesign.interface(.title3)).modifier(CreationHeaderIconFrame())
                        }.accessibilityLabel("搜索随笔")
                        Menu {
                            Picker("随笔状态", selection: $filter) {
                                ForEach(AdminPostFilter.allCases) { item in
                                    Label(item.title, systemImage: item == .all ? "doc.on.doc" : item == .published ? "checkmark.circle" : "doc.badge.ellipsis").tag(item)
                                }
                            }
                            Divider()
                            Button("查看本机草稿", systemImage: "tray", action: openDrafts)
                        } label: { Image(systemName: "ellipsis").font(CreationDesign.interface(.title3)).modifier(CreationHeaderIconFrame()) }
                            .accessibilityLabel("更多随笔操作").accessibilityValue(filter.title)
                    }
                }
                if showingSearch { CreationSearchField(placeholder: "搜索站点随笔", text: $search, autofocus: true) }
                if let error = model.error ?? localError { CreationNotice(text: error, isError: true); Button("重试加载") { Task { await reload() } } }
                if model.posts.isEmpty && !model.isLoading && model.error == nil { ContentUnavailableView(search.isEmpty ? "还没有随笔" : "没有找到随笔", systemImage: "doc.text", description: Text(search.isEmpty ? "把零散的灵感，写成一篇随笔。" : "试试其他标题或关键词。")) }
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
                CreationFloatingButton(title: "写随笔", symbol: "plus", verticalPadding: 8) { Task { await newArticle() } }
                    .modifier(CreationComposeVisibility(visible: composeVisible && !showingSearch && route == nil && reading == nil && pendingDelete == nil))
            }
            .preference(key: CreationMiniPlayerHiddenKey.self, value: !composeVisible || showingSearch || route != nil || reading != nil || pendingDelete != nil)
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
                        .font(CreationDesign.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
                        .frame(maxWidth: 90).fixedSize(horizontal: true, vertical: false).layoutPriority(2)
                    Text(post.title).font(CreationDesign.contentTitle(17, bold: true)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                }
                if let excerpt = post.excerpt?.trimmedNonEmpty {
                    Text(excerpt).font(CreationDesign.copy(15, relativeTo: .subheadline)).foregroundStyle(.secondary).lineSpacing(4).lineLimit(3)
                }
                Text(metadata).font(CreationDesign.interface(.caption)).lineSpacing(4)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).multilineTextAlignment(.leading)
    }
    private var metadata: AttributedString {
        let updated = post.updatedAt != nil && post.updatedAt != post.createdAt
        let date = String((post.updatedAt ?? post.createdAt ?? "").prefix(10))
        var result = AttributedString("\(updated ? "更新于" : "发布于") ")
        var timestamp = AttributedString(date)
        timestamp.font = CreationDesign.time()
        result.append(timestamp)
        result.append(AttributedString(" · \(post.status == "published" ? "已发布" : "草稿")"))
        result.foregroundColor = .secondary
        if !post.tags.isEmpty {
            var tags = AttributedString("  " + post.tags.map { "#" + $0 }.joined(separator: "  "))
            tags.font = CreationDesign.time()
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
    @State private var requestingShare = false
    @State private var shareError: String?
    @State private var share: CreationArticleShare?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let detail {
                        if let cover = detail.cover, !cover.isEmpty { CreationRemoteImage(path: cover, site: api.siteRoot).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 2)) }
                        Text(detail.title).font(CreationDesign.contentTitle(26, relativeTo: .title2, bold: true))
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reader.title")
                        let date = String((detail.updatedAt ?? detail.createdAt ?? "").prefix(10))
                        (Text(detail.category).foregroundColor(CreationDesign.accent)
                         + Text((!detail.category.isEmpty && !date.isEmpty ? "  ·  " : "") + date).font(CreationDesign.time()).foregroundColor(CreationDesign.secondary)
                         + Text(detail.tags.isEmpty ? "" : ((!detail.category.isEmpty || !date.isEmpty ? "  ·  " : "") + detail.tags.map { "#" + $0 }.joined(separator: "  "))).font(CreationDesign.time()).foregroundColor(CreationDesign.accent))
                            .font(CreationDesign.interface(.caption)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reader.metadata")
                        Divider()
                        ForEach(Array(creationMarkdownBlocks(detail.content, references: detail.referenceSnapshots).enumerated()), id: \.offset) { _, block in
                            AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot, mediaPlayback: true)
                        }
                    } else if let error { CreationNotice(text: error, isError: true); Button("重新加载") { Task { await load() } } }
                    else { ProgressView("正在打开文章…").frame(maxWidth: .infinity, minHeight: 200) }
                }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }.background(CreationDesign.surface).foregroundStyle(CreationDesign.foreground)
                .navigationTitle("阅读").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { route = CreationEditorRoute(draft: CreationDraft(site: CreationDraftStore.canonicalSite(api.siteRoot), kind: .post, serverID: post.id)) } label: { Label("编辑", systemImage: "square.and.pencil") }.disabled(detail == nil)
                        Button { requestingShare = true } label: {
                            if requestingShare { ProgressView() }
                            else { Label("分享短链接", systemImage: "square.and.arrow.up") }
                        }.disabled(detail?.status != "published" || requestingShare)
                            .accessibilityIdentifier("reader.share")
                    }
                }
                .sheet(item: $share) { item in CreationArticleShareSheet(url: item.url) }
                .alert("分享失败", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                    Button("重试") { requestingShare = true }; Button("取消", role: .cancel) { shareError = nil }
                } message: { Text(shareError ?? "") }
                .task(id: requestingShare) {
                    guard requestingShare else { return }
                    defer { requestingShare = false }
                    do {
                        let url = try await api.articleShortLink(id: post.id)
                        guard !Task.isCancelled else { return }
                        share = CreationArticleShare(url: url)
                    } catch { if !isRequestCancellation(error) { shareError = error.localizedDescription } }
                }
                .task { await load(reuseLoaded: true) }
                .fullScreenCover(item: $route, onDismiss: {
                    if refreshAfterEditing { refreshAfterEditing = false; Task { await load() } }
                }) { route in CreationComposerView(api: api, draft: route.draft) { refreshAfterEditing = true; onChanged() } }
        }.tint(CreationDesign.accent)
            .creationMiniPlayer(api: api, visible: route == nil && share == nil && !requestingShare)
    }
    private func load(reuseLoaded: Bool = false) async {
        error = nil
        do { let value = try await api.fetchPost(id: post.id, reuseLoaded: reuseLoaded); guard !Task.isCancelled else { return }; detail = value }
        catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
}

private struct CreationArticleShare: Identifiable {
    let url: URL
    var id: URL { url }
}
private struct CreationArticleShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
                Text("本机保存 · 仅在修改后自动保存").font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary)
                Text(api.siteRoot.host ?? "当前站点").font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary)
                if let error { CreationNotice(text: error, isError: true); Button("重试读取") { Task { await load() } } }
                if drafts.isEmpty && error == nil { ContentUnavailableView("没有本机草稿", systemImage: "tray", description: Text("未完成的絮语和文章会留在这里，不会自动发布。")) }
                ForEach(drafts) { draft in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { route = CreationEditorRoute(draft: draft) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(draft.kind == .moment ? "絮语" : "文章").font(CreationDesign.interface(.caption)).padding(6).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(CreationDesign.accent)
                                    Text(draft.summary).font(CreationDesign.interface(.body)).lineLimit(3).foregroundStyle(CreationDesign.foreground)
                                    if draft.submission == .uncertain { Text("发布结果待确认").font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.danger) }
                                    HStack { Text(draft.updatedAt, style: .relative).font(CreationDesign.time()); Text("\(draft.media.count) 张图片 · \(draft.music.count) 首音乐") }.font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let media = draft.media.first { CreationLocalImage(media: media, site: draft.site, api: api).frame(width: 66, height: 66).clipped().clipShape(RoundedRectangle(cornerRadius: 10)) }
                            }
                        }.buttonStyle(.plain)
                        HStack { Spacer(); Button("删除本机草稿", role: .destructive) { pendingDelete = draft }.font(CreationDesign.interface(.subheadline)).frame(minHeight: 44) }
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
