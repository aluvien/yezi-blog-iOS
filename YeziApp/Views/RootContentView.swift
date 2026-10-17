import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import SafariServices

// MARK: - Admin site selection

@MainActor
private enum AdminSiteStore {
    static let defaultSiteRoot = URL(string: "https://yezi.me")!
    static let alternateSiteRoot = URL(string: "https://yezi.biaozhu.me")!
    static let customSiteToken = "__custom_site__"

#if DEBUG
    // Local API testing may use http://127.0.0.1, but release builds must
    // never accept an insecure admin endpoint for password or cookie traffic.
    private static let allowsInsecureHTTP = true
#else
    private static let allowsInsecureHTTP = false
#endif

    private static let defaults = UserDefaults.standard
    private static let selectedSiteRootKey = "yezi.admin.selectedSiteRoot"
    private static let customSiteRootsKey = "yezi.admin.customSiteRoots"

    static var selectedSiteRoot: URL {
        if let value = defaults.string(forKey: selectedSiteRootKey),
           let root = normalize(value) {
            return root
        }
        return defaultSiteRoot
    }

    static var savedCustomSiteRoots: [URL] {
        guard let data = defaults.data(forKey: customSiteRootsKey),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return values.compactMap(normalize)
    }

    static func saveSelected(_ root: URL) {
        defaults.set(root.absoluteString, forKey: selectedSiteRootKey)
    }

    static func addCustom(_ rawValue: String) -> URL? {
        guard let root = normalize(rawValue) else { return nil }

        var roots = savedCustomSiteRoots
        if !roots.contains(root), root != defaultSiteRoot, root != alternateSiteRoot {
            roots.append(root)
            let values = roots.map { $0.absoluteString }
            if let data = try? JSONEncoder().encode(values) {
                defaults.set(data, forKey: customSiteRootsKey)
            }
        }

        saveSelected(root)
        return root
    }

    static func normalize(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://") {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && allowsInsecureHTTP),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }

        components.scheme = scheme
        components.path = ""
        return components.url
    }
}

// MARK: - Session

@MainActor
final class AdminSessionModel: ObservableObject {
    private(set) var api: AdminAPIClient

    @Published private(set) var isChecking = true
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    init(siteRoot: URL = AdminSiteStore.selectedSiteRoot) {
        self.api = CreationPreview.makeAPI() ?? AdminAPIClient(siteRoot: siteRoot)
        bindUnauthorizedHandler(to: self.api)
    }

    private func bindUnauthorizedHandler(to api: AdminAPIClient) {
        api.unauthorizedHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAuthenticated = false
                self.errorMessage = "登录会话已过期，请重新登录"
            }
        }
    }

    func bootstrap() async {
        guard isChecking else { return }
        defer { isChecking = false }

#if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            isAuthenticated = false
            return
        }
#endif

        if CreationPreview.isEnabled {
            await CreationPreview.seed()
            isAuthenticated = true
            return
        }

        guard api.hasLocalSessionCookie() else {
            isAuthenticated = false
            return
        }

        do {
            let status = try await api.fetchSession()
            isAuthenticated = status.authenticated
        } catch {
            isAuthenticated = false
        }
    }

    func login(password: String, siteRoot: URL? = nil) async {
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isLoading else { return }

        if let siteRoot, siteRoot != api.siteRoot {
            let nextAPI = AdminAPIClient(siteRoot: siteRoot)
            bindUnauthorizedHandler(to: nextAPI)
            api = nextAPI
            isAuthenticated = false
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await api.login(password: value)
            let status = try await api.fetchSession()
            isAuthenticated = status.authenticated
            guard isAuthenticated else { throw APIError.http(status: 401, message: "登录会话无效") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() async {
        await api.logout()
        isAuthenticated = false
        errorMessage = nil
    }

    func handle(_ error: Error) {
        guard let apiError = error as? APIError,
              case .http(let status, _) = apiError,
              status == 401 else { return }
        isAuthenticated = false
    }
}

struct RootContentView: View {
    @StateObject private var session = AdminSessionModel()

    var body: some View {
        Group {
            if session.isChecking {
                AdminLaunchView()
            } else if session.isAuthenticated {
                AdminTabView(session: session)
            } else {
                AdminLoginView(session: session)
            }
        }
        .task {
            await session.bootstrap()
        }
    }
}

private struct AdminLaunchView: View {
    var body: some View {
        ZStack {
            AdminDesign.background.ignoresSafeArea()
            VStack(spacing: 16) {
                AdminLogo()
                Text("Yezi 管理")
                    .font(.title2.weight(.bold))
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct AdminLoginView: View {
    @ObservedObject var session: AdminSessionModel
    @State private var password = ""
    @State private var showingPassword = false
    @State private var selectedSiteRoot = AdminSiteStore.selectedSiteRoot.absoluteString
    @State private var customSiteRoot = ""
    @State private var siteErrorMessage: String?

    private var siteChoices: [String] {
        let values = [
            AdminSiteStore.defaultSiteRoot.absoluteString,
            AdminSiteStore.alternateSiteRoot.absoluteString,
        ] + AdminSiteStore.savedCustomSiteRoots.map { $0.absoluteString }

        return values.reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }

    private var resolvedSiteRoot: URL? {
        guard selectedSiteRoot != AdminSiteStore.customSiteToken else { return nil }
        return AdminSiteStore.normalize(selectedSiteRoot)
    }

    private func siteLabel(for value: String) -> String {
        if value == AdminSiteStore.defaultSiteRoot.absoluteString {
            return "默认站点 · \(value)"
        }
        if value == AdminSiteStore.alternateSiteRoot.absoluteString {
            return "备用站点 · \(value)"
        }
        return "自定义 · \(value)"
    }

    private func addCustomSite() {
        guard let root = AdminSiteStore.addCustom(customSiteRoot) else {
            siteErrorMessage = "请输入有效域名，例如 https://example.com"
            return
        }

        selectedSiteRoot = root.absoluteString
        customSiteRoot = ""
        siteErrorMessage = nil
    }

    var body: some View {
        ZStack {
            AdminDesign.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AdminLogo()

                    Text("Yezi 管理")
                        .font(.largeTitle.weight(.bold))
                        .padding(.top, 24)

                    Text("用原生 API 查看、编辑和管理你的博客内容。")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("站点地址")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .foregroundStyle(AdminDesign.accent)

                            Picker("站点地址", selection: $selectedSiteRoot) {
                                ForEach(siteChoices, id: \.self) { value in
                                    Text(siteLabel(for: value)).tag(value)
                                }
                                Text("自定义添加…")
                                    .tag(AdminSiteStore.customSiteToken)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        }

                        if selectedSiteRoot == AdminSiteStore.customSiteToken {
                            HStack(spacing: 10) {
                                TextField("例如 https://example.com", text: $customSiteRoot)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Button("添加并使用", action: addCustomSite)
                                    .font(.subheadline.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .tint(AdminDesign.accent)
                                    .disabled(customSiteRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } else if let root = resolvedSiteRoot {
                            Label(root.absoluteString, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let siteErrorMessage {
                            Text(siteErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 26)
                    .onChange(of: selectedSiteRoot) { _, newValue in
                        siteErrorMessage = nil
                        if let root = AdminSiteStore.normalize(newValue) {
                            AdminSiteStore.saveSelected(root)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("管理员密码")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 10) {
                            Group {
                                if showingPassword {
                                    TextField("输入管理员密码", text: $password)
                                } else {
                                    SecureField("输入管理员密码", text: $password)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                showingPassword.toggle()
                            } label: {
                                Image(systemName: showingPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        }
                    }
                    .padding(.top, 22)

                    if let errorMessage = session.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.top, 14)
                    }

                    Button {
                        guard let siteRoot = resolvedSiteRoot else {
                            siteErrorMessage = "请选择站点，或先添加自定义域名"
                            return
                        }

                        AdminSiteStore.saveSelected(siteRoot)
                        Task { await session.login(password: password, siteRoot: siteRoot) }
                    } label: {
                        HStack {
                            if session.isLoading {
                                ProgressView().tint(.white)
                            }
                            Text(session.isLoading ? "正在登录…" : "进入管理后台")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AdminDesign.accent)
                    .disabled(
                        password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || session.isLoading
                            || resolvedSiteRoot == nil
                    )
                    .padding(.top, 22)

                    Text("登录会话使用 admin_session Cookie 保存，不会保存管理员密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 44)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct AdminLogo: View {
    var body: some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 66, height: 66)
            .background(AdminDesign.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private enum AdminTab: Hashable {
    case dashboard
    case posts
    case moments
    case comments
    case more
    case drafts
}

private struct AdminTabView: View {
    @ObservedObject var session: AdminSessionModel
    @State private var selection: AdminTab = AdminManagementRoute(previewScreen: CreationPreview.screen) != nil || CreationPreview.screen == "manage" ? .more : (["comments", "reply"].contains(CreationPreview.screen) ? .comments : (["article", "articles", "settings", "reader"].contains(CreationPreview.screen) ? .posts : .moments))
    @State private var showingDrafts = CreationPreview.screen == "drafts"

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { MomentFeedView(api: session.api) { showingDrafts = true } }
                .tabItem { Label("絮语", systemImage: "quote.bubble") }.tag(AdminTab.moments)
            NavigationStack { CreationArticlesView(api: session.api) { showingDrafts = true } }
                .tabItem { Label("文章", systemImage: "book.closed") }.tag(AdminTab.posts)
            NavigationStack { AdminCommentsView(session: session) }
                .tabItem { Label("评论", systemImage: "bubble.left.and.bubble.right") }.tag(AdminTab.comments)
            NavigationStack { AdminMoreView(session: session) }
                .tabItem { Label("管理", systemImage: "slider.horizontal.3") }.tag(AdminTab.more)
        }.tint(CreationDesign.accent)
            .sheet(isPresented: $showingDrafts) { LocalDraftsView(api: session.api, dismissible: true) }
    }
}

private struct AdminBottomNav: View {
    @Binding var selection: AdminTab

    var body: some View {
        HStack(spacing: 0) {
            item(.dashboard, title: "概览", symbol: "house")
            item(.posts, title: "内容", symbol: "doc.text")
            item(.moments, title: "想法", symbol: "quote.bubble")
            item(.comments, title: "评论", symbol: "bubble.left")
            item(.more, title: "更多", symbol: "ellipsis")
        }
        .padding(.top, 9)
        .padding(.bottom, 12)
        .background(AdminDesign.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(AdminDesign.border).frame(height: 1)
        }
    }

    private func item(_ tab: AdminTab, title: String, symbol: String) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28, height: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .frame(height: 14, alignment: .center)
            }
            .foregroundStyle(selection == tab ? AdminDesign.accent : AdminDesign.muted)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct AdminInAppBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Dashboard

@MainActor
private final class AdminDashboardModel: ObservableObject {
    let api: AdminAPIClient
    @Published var dashboard: AdminDashboard?
    @Published var totalComments = 0
    @Published var recentItems: [AdminRecentPublishItem] = []
    @Published var lastLoadedAt: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?

    init(api: AdminAPIClient) {
        self.api = api
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let dashboardTask = api.fetchDashboard()
            async let momentsTask = api.fetchMoments(limit: 5)
            async let commentsTask = api.fetchComments(limit: 1, status: .all)

            let loadedDashboard = try await dashboardTask
            dashboard = loadedDashboard
            let recentMoments = (try? await momentsTask)?.items ?? []
            totalComments = (try? await commentsTask)?.meta.total ?? 0
            recentItems = (loadedDashboard.recentPosts.map(AdminRecentPublishItem.post) + recentMoments.map(AdminRecentPublishItem.moment))
                .sorted { $0.sortDate > $1.sortDate }
            lastLoadedAt = Date()
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private enum AdminRecentPublishItem: Identifiable {
    case post(AdminPostSummary)
    case moment(AdminMoment)

    var id: String {
        switch self {
        case .post(let post): return "post-\(post.id)"
        case .moment(let moment): return "moment-\(moment.id)"
        }
    }

    var sortDate: Date {
        switch self {
        case .post(let post): return AdminFormatters.date(from: post.updatedAt ?? post.createdAt) ?? .distantPast
        case .moment(let moment): return AdminFormatters.date(from: moment.updatedAt ?? moment.createdAt) ?? .distantPast
        }
    }
}

private func editingRoute(for moment: AdminMoment, api: AdminAPIClient) async throws -> CreationEditorRoute {
    let site = CreationDraftStore.canonicalSite(api.siteRoot)
    if let saved = try await CreationDraftStore.shared.list(site: site).first(where: { $0.kind == .moment && $0.serverID == moment.id }) {
        return CreationEditorRoute(draft: saved)
    }
    var draft = CreationDraft(site: site, kind: .moment, serverID: moment.id)
    let split = CreationMusic.split(moment.content)
    draft.text = split.text
    draft.music = split.music
    draft.media = moment.images.map { CreationMedia(remotePath: $0, state: .uploaded) }
    return CreationEditorRoute(draft: draft)
}

private struct AdminDashboardView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminDashboardModel
    @State private var showingSiteBrowser = false
    @State private var showingDrafts = false
    @State private var readingPost: AdminPostSummary?
    @State private var momentRoute: CreationEditorRoute?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminDashboardModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AdminPreviewHeader(overline: "YEZI ADMIN", title: "概览", subtitle: "管理你的站点内容") {
                    Text("叶")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(width: 38, height: 38)
                        .background(AdminDesign.surface, in: Circle())
                        .overlay(Circle().stroke(AdminDesign.border, lineWidth: 1))
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.top, 8)
                }

                if let dashboard = model.dashboard {
                    dashboardContent(dashboard)
                } else if model.isLoading {
                    ProgressView("正在加载概览…")
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    AdminEmptyState(title: "暂时没有数据", message: "下拉或点击刷新重新获取。", systemImage: "chart.bar.xaxis")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(AdminDesign.background)
        .adminNativeSwipeBack()
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $showingSiteBrowser) {
            AdminInAppBrowserView(url: session.api.siteRoot)
                .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showingDrafts) { LocalDraftsView(api: session.api, dismissible: true) }
        .sheet(item: $readingPost) { CreationArticleReader(post: $0, api: session.api) }
        .fullScreenCover(item: $momentRoute, onDismiss: { Task { await model.load() } }) { route in
            CreationComposerView(api: session.api, draft: route.draft)
        }
    }

    @ViewBuilder
    private func dashboardContent(_ dashboard: AdminDashboard) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AdminDesign.accent)
                .frame(width: 7, height: 7)
            Text("最近同步 · \(AdminFormatters.displayDate(model.lastLoadedAt))")
                .font(.caption)
        }
        .foregroundStyle(AdminDesign.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 2)

        Button {
            showingSiteBrowser = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天的站点")
                        .font(.system(size: 18, weight: .semibold))
                    Text("内容、评论和草稿都在这里。")
                        .font(.subheadline)
                        .foregroundStyle(AdminDesign.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AdminDesign.accent)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(
                colors: [AdminDesign.accentSoft, AdminDesign.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
        .padding(.top, 14)

        HStack(spacing: 8) {
            let pendingComments = dashboard.comments?.pending ?? 0
            AdminPreviewMetric(
                value: "\(pendingComments > 0 ? pendingComments : model.totalComments)",
                label: pendingComments > 0 ? "待处理评论" : "全部评论",
                destination: AdminCommentsView(session: session, initialFilter: pendingComments > 0 ? .pending : .all)
            )
            let draftCount = dashboard.posts?.draft ?? 0
            AdminPreviewMetric(
                value: "\(draftCount > 0 ? draftCount : (dashboard.posts?.published ?? 0))",
                label: draftCount > 0 ? "篇草稿" : "已发布文章",
                destination: CreationArticlesView(api: session.api, initialFilter: draftCount > 0 ? .draft : .published) { showingDrafts = true }
            )
            AdminPreviewMetric(
                value: "\(dashboard.moments ?? 0)",
                label: "条絮语",
                destination: MomentFeedView(api: session.api) { showingDrafts = true }
            )
        }
        .padding(.top, 10)

        AdminSectionTitle(title: "最近发布", actionTitle: "查看全部", destination: AdminRecentPublishView(session: session))
            .padding(.top, 7)
        if model.recentItems.isEmpty {
            AdminEmptyState(title: "还没有发布内容", message: "创建你的第一篇文章或记录一个想法。", systemImage: "doc.badge.plus")
        } else {
            VStack(spacing: 0) {
                ForEach(model.recentItems) { item in
                    switch item {
                    case .post(let post):
                        Button { readingPost = post } label: {
                            AdminPostRow(post: post, siteRoot: session.api.siteRoot, showsChevron: false)
                        }
                        .buttonStyle(.plain)
                    case .moment(let moment):
                        Button {
                            Task {
                                do { momentRoute = try await editingRoute(for: moment, api: session.api) }
                                catch { model.errorMessage = error.localizedDescription }
                            }
                        } label: {
                            AdminRecentMomentRow(moment: moment)
                        }
                        .buttonStyle(.plain)
                    }
                    if item.id != model.recentItems.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .padding(.horizontal, 2)
            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
        }

    }
}

private struct AdminRecentPublishView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminDashboardModel
    @State private var readingPost: AdminPostSummary?
    @State private var momentRoute: CreationEditorRoute?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminDashboardModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AdminPreviewHeader(overline: "TIMELINE", title: "最近发布", subtitle: "文章和想法的时间线") {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(width: 38, height: 38)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.bottom, 12)
                }

                if model.recentItems.isEmpty && !model.isLoading {
                    AdminEmptyState(title: "还没有发布内容", message: "创建文章或记录一个想法后会出现在这里。", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                } else if model.recentItems.isEmpty {
                    ProgressView("正在加载时间线…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.recentItems) { item in
                            switch item {
                            case .post(let post):
                                Button { readingPost = post } label: {
                                    AdminPostRow(post: post, siteRoot: session.api.siteRoot, showsChevron: true)
                                }
                                .buttonStyle(.plain)
                            case .moment(let moment):
                                Button {
                                    Task {
                                        do { momentRoute = try await editingRoute(for: moment, api: session.api) }
                                        catch { model.errorMessage = error.localizedDescription }
                                    }
                                } label: {
                                    AdminRecentMomentRow(moment: moment)
                                }
                                .buttonStyle(.plain)
                            }
                            if item.id != model.recentItems.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .adminNativeSwipeBack()
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $readingPost) { CreationArticleReader(post: $0, api: session.api) }
        .fullScreenCover(item: $momentRoute, onDismiss: { Task { await model.load() } }) { route in
            CreationComposerView(api: session.api, draft: route.draft)
        }
    }
}

private struct AdminPreviewMetric<Destination: View>: View {
    let value: String
    let label: String
    let destination: Destination

    init(value: String, label: String, destination: Destination) {
        self.value = value
        self.label = label
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination.adminNativeSwipeBack()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(value)
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .foregroundStyle(AdminDesign.foreground)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
    }
}

private struct AdminRecentMomentRow: View {
    let moment: AdminMoment

    private var summary: String {
        let split = CreationMusic.split(moment.content)
        let text = split.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !text.isEmpty { return text }
        if let music = split.music.first {
            return music.title == music.artist ? music.title : "\(music.title) · \(music.artist)"
        }
        return moment.images.isEmpty ? "一条絮语" : "\(moment.images.count) 张照片"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AdminDesign.accent)
                .frame(width: 38, height: 38)
                .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AdminDesign.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("絮语 · \(AdminFormatters.displayDate(moment.updatedAt ?? moment.createdAt)) · \(moment.images.count) 张图片")
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AdminDesign.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Posts

@MainActor
private final class AdminPostsModel: ObservableObject {
    let api: AdminAPIClient
    @Published var items: [AdminPostSummary] = []
    @Published var meta: AdminPaginationMeta?
    @Published var counts: [AdminPostFilter: Int] = [:]
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    private var requestSerial = 0

    init(api: AdminAPIClient) {
        self.api = api
    }

    func load(filter: AdminPostFilter, search: String) async {
        requestSerial += 1
        let requestID = requestSerial
        isLoading = true
        errorMessage = nil
        defer {
            if requestID == requestSerial {
                isLoading = false
            }
        }

        do {
            async let allTask = api.fetchPosts(page: 1, limit: 1, status: .all, search: search)
            async let publishedTask = api.fetchPosts(page: 1, limit: 1, status: .published, search: search)
            async let draftTask = api.fetchPosts(page: 1, limit: 1, status: .draft, search: search)
            async let selectedTask = api.fetchPosts(page: 1, limit: 20, status: filter, search: search)
            let results = try await (allTask, publishedTask, draftTask, selectedTask)
            guard requestID == requestSerial else { return }
            counts = [
                .all: results.0.meta.total ?? results.0.items.count,
                .published: results.1.meta.total ?? results.1.items.count,
                .draft: results.2.meta.total ?? results.2.items.count,
            ]
            items = results.3.items
            meta = results.3.meta
        } catch {
            guard requestID == requestSerial else { return }
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func loadMore(filter: AdminPostFilter, search: String) async {
        guard !isLoading, !isLoadingMore, let currentMeta = meta else { return }
        let currentPage = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 20, 1)
        let hasMore: Bool
        if let totalPages = currentMeta.totalPages {
            hasMore = currentPage < totalPages
        } else if let total = currentMeta.total {
            hasMore = currentPage * limit < total
        } else {
            hasMore = items.count >= currentPage * limit
        }
        guard hasMore else { return }

        let requestID = requestSerial
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.fetchPosts(page: currentPage + 1, limit: limit, status: filter, search: search)
            guard requestID == requestSerial else { return }
            items.append(contentsOf: next.items)
            meta = next.meta
        } catch {
            if !isAdminRequestCancellation(error), requestID == requestSerial {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(post: AdminPostSummary) async {
        do {
            try await api.deletePost(id: post.id)
            items.removeAll { $0.id == post.id }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminPostsView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminPostsModel
    @State private var filter: AdminPostFilter = .all
    @State private var pendingDelete: AdminPostSummary?

    init(session: AdminSessionModel, initialFilter: AdminPostFilter = .all) {
        self.session = session
        _model = StateObject(wrappedValue: AdminPostsModel(api: session.api))
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AdminPreviewHeader(
                    overline: "CONTENT",
                    title: "文章",
                    subtitle: "共 \(model.meta?.total ?? model.items.count) 篇文章"
                ) {
                    NavigationLink {
                        AdminPostEditorView(session: session) {
                            Task { await model.load(filter: filter, search: "") }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AdminDesign.accent)
                            .frame(width: 38, height: 38)
                            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                    }
                    .accessibilityLabel("新建文章")
                }

                AdminFilterScroll {
                    ForEach(AdminPostFilter.allCases) { item in
                        AdminFilterChip(
                            title: filterTitle(item),
                            selected: filter == item
                        ) {
                            filter = item
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.bottom, 12)
                }

                if model.items.isEmpty && !model.isLoading {
                    AdminEmptyState(title: "没有文章", message: "试试切换状态或创建新文章。", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                } else if model.isLoading && model.items.isEmpty {
                    ProgressView("正在加载文章…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.items) { post in
                            NavigationLink {
                                AdminPostEditorView(session: session, postID: post.id) {
                                    Task { await model.load(filter: filter, search: "") }
                                }
                            } label: {
                                AdminPostRow(post: post, siteRoot: session.api.siteRoot)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                guard post.id == model.items.last?.id else { return }
                                Task { await model.loadMore(filter: filter, search: "") }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = post
                                } label: {
                                    Label("删除文章", systemImage: "trash")
                                }
                            }
                            if post.id != model.items.last?.id {
                                Divider().padding(.leading, 63)
                            }
                        }
                    }
                    .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: filter) { _, _ in
            Task { await model.load(filter: filter, search: "") }
        }
        .refreshable {
            await model.load(filter: filter, search: "")
        }
        .task {
            await model.load(filter: filter, search: "")
        }
        .confirmationDialog(
            "删除文章？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { post in
            Button("删除「\(post.title)」", role: .destructive) {
                Task {
                    await model.delete(post: post)
                    await model.load(filter: filter, search: "")
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("文章及其评论、互动和引用关系会按后台逻辑清理。")
        }
    }

    private func filterTitle(_ item: AdminPostFilter) -> String {
        let count = model.counts[item] ?? (item == filter ? model.meta?.total ?? model.items.count : 0)
        return "\(item.title) \(count)"
    }
}

private struct AdminPostRow: View {
    let post: AdminPostSummary
    let siteRoot: URL
    let showsChevron: Bool

    init(post: AdminPostSummary, siteRoot: URL, showsChevron: Bool = true) {
        self.post = post
        self.siteRoot = siteRoot
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AdminDesign.accent)
                .frame(width: 38, height: 38)
                .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(post.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AdminDesign.foreground)
                    .lineLimit(1)
                Text(metaText)
                    .font(.system(size: 11))
                    .foregroundStyle(AdminDesign.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AdminStatusBadge(status: post.status)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdminDesign.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var metaText: String {
        let date = AdminFormatters.displayDate(post.updatedAt ?? post.createdAt)
        if let views = post.metrics?.views {
            return "\(date) · 阅读 \(views)"
        }
        return date
    }

    private var iconName: String {
        switch abs(post.id) % 3 {
        case 0: return "sparkles"
        case 1: return "circle.lefthalf.filled"
        default: return "wind"
        }
    }
}

// MARK: - Post editor

private struct AdminPostEditorView: View {
    @ObservedObject var session: AdminSessionModel
    let postID: Int?
    let onSaved: (() -> Void)?
    init(session: AdminSessionModel, postID: Int? = nil, onSaved: (() -> Void)? = nil) {
        self.session = session
        self.postID = postID
        self.onSaved = onSaved
    }
    var body: some View {
        CreationComposerView(api: session.api, draft: CreationDraft(site: CreationDraftStore.canonicalSite(session.api.siteRoot), kind: .post, serverID: postID)) { onSaved?() }
            .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
    }
}

private struct AdminEditorTool: View {
    let title: String
    var weight: Font.Weight = .regular
    var italic = false
    let action: () -> Void

    init(title: String, weight: Font.Weight = .regular, italic: Bool = false, action: @escaping () -> Void = {}) {
        self.title = title
        self.weight = weight
        self.italic = italic
        self.action = action
    }

    var body: some View {
        Button(action: action) { AdminEditorToolLabel(title: title, weight: weight, italic: italic) }
        .buttonStyle(.plain)
    }
}

private struct AdminEditorToolLabel: View {
    let title: String
    var weight: Font.Weight = .regular
    var italic = false

    var body: some View {
        Text(title)
            .font(italic ? .system(size: 11, weight: weight).italic() : .system(size: 11, weight: weight))
            .foregroundStyle(AdminDesign.muted)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AdminEditorField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AdminDesign.muted)
                .frame(width: 54, alignment: .leading)
            TextField(placeholder.isEmpty ? label : placeholder, text: $text)
                .font(.system(size: 12))
                .foregroundStyle(AdminDesign.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AdminTaxonomyField: View {
    let label: String
    let value: String
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AdminDesign.muted)
                .frame(width: 54, alignment: .leading)
            Text(value.isEmpty ? "未选择" : value)
                .font(.system(size: 12))
                .foregroundStyle(value.isEmpty ? AdminDesign.muted : AdminDesign.foreground)
                .lineLimit(1)
            Spacer()
            Menu {
                if options.isEmpty {
                    Text("暂无可选项")
                } else {
                    Button("清除") { onSelect("") }
                    ForEach(options, id: \.self) { option in
                        Button(option) { onSelect(option) }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AdminDesign.accent)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AdminTagsField: View {
    let value: String
    let options: [String]
    let onChange: (String) -> Void

    private var selected: [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("标签")
                .font(.system(size: 11))
                .foregroundStyle(AdminDesign.muted)
                .frame(width: 54, alignment: .leading)
            Text(selected.isEmpty ? "选择标签" : selected.joined(separator: ", "))
                .font(.system(size: 12))
                .foregroundStyle(selected.isEmpty ? AdminDesign.muted : AdminDesign.foreground)
                .lineLimit(2)
            Spacer()
            Menu {
                if options.isEmpty {
                    Text("暂无可选标签")
                } else {
                    ForEach(options, id: \.self) { option in
                        Button {
                            var next = selected
                            if let index = next.firstIndex(of: option) { next.remove(at: index) }
                            else { next.append(option) }
                            onChange(next.joined(separator: ", "))
                        } label: {
                            Label(option, systemImage: selected.contains(option) ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Image(systemName: "tag")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AdminDesign.accent)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Comments

@MainActor
final class AdminCommentsModel: ObservableObject {
    let api: AdminAPIClient
    @Published var items: [AdminComment] = []
    @Published var meta: AdminPaginationMeta?
    @Published var total = 0
    @Published var counts: [AdminCommentFilter: Int] = [:]
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    private var requestSerial = 0

    init(api: AdminAPIClient) {
        self.api = api
    }

    func load(filter: AdminCommentFilter) async {
        requestSerial += 1
        let requestID = requestSerial
        isLoading = true
        errorMessage = nil
        defer {
            if requestID == requestSerial {
                isLoading = false
            }
        }
        do {
            async let allTask = api.fetchComments(page: 1, limit: 1, status: .all)
            async let pendingTask = api.fetchComments(page: 1, limit: 1, status: .pending)
            async let approvedTask = api.fetchComments(page: 1, limit: 1, status: .approved)
            async let selectedTask = api.fetchComments(page: 1, limit: 20, status: filter)
            let results = try await (allTask, pendingTask, approvedTask, selectedTask)
            guard requestID == requestSerial else { return }
            counts = [
                .all: results.0.meta.total ?? results.0.items.count,
                .pending: results.1.meta.total ?? results.1.items.count,
                .approved: results.2.meta.total ?? results.2.items.count,
            ]
            items = results.3.items
            meta = results.3.meta
            total = results.3.meta.total ?? results.3.items.count
        } catch {
            guard requestID == requestSerial else { return }
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func loadMore(filter: AdminCommentFilter) async {
        guard !isLoading, !isLoadingMore, let currentMeta = meta else { return }
        let currentPage = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 20, 1)
        let hasMore: Bool
        if let totalPages = currentMeta.totalPages {
            hasMore = currentPage < totalPages
        } else if let count = currentMeta.total {
            hasMore = currentPage * limit < count
        } else {
            hasMore = items.count >= currentPage * limit
        }
        guard hasMore else { return }

        let requestID = requestSerial
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.fetchComments(page: currentPage + 1, limit: limit, status: filter)
            guard requestID == requestSerial else { return }
            items.append(contentsOf: next.items)
            meta = next.meta
        } catch {
            if !isAdminRequestCancellation(error), requestID == requestSerial {
                errorMessage = error.localizedDescription
            }
        }
    }

    @Published private(set) var isMutating = false

    func update(_ comment: AdminComment, action: AdminCommentAction, reply: String? = nil) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            let updated = try await api.updateComment(id: comment.id, action: action, reply: reply)
            if let index = items.firstIndex(where: { $0.id == updated.id }) {
                items[index] = updated
            }
            return true
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
            return false
        }
    }

    func delete(_ comment: AdminComment) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await api.deleteComment(id: comment.id)
            items.removeAll { $0.id == comment.id }
            return true
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
            return false
        }
    }
}

private struct AdminCommentsView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminCommentsModel
    @State private var filter: AdminCommentFilter = .pending
    @State private var replyTarget: AdminComment?
    @State private var pendingDelete: AdminComment?

    init(session: AdminSessionModel, initialFilter: AdminCommentFilter = .pending) {
        self.session = session
        _model = StateObject(wrappedValue: AdminCommentsModel(api: session.api))
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                CreationPageHeader(title: "评论", subtitle: "听见读者的声音，及时回应。") {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2).foregroundStyle(CreationDesign.accent)
                        .frame(width: 48, height: 48).background(CreationDesign.surface, in: Circle())
                }

                AdminFilterScroll {
                    ForEach(AdminCommentFilter.allCases) { item in
                        CreationFilterChip(
                            title: commentFilterTitle(item),
                            selected: filter == item
                        ) {
                            filter = item
                        }
                    }
                }

                CreationSectionHeading(title: filter.title, detail: "\(model.total) 条评论")

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.bottom, 12)
                }

                if model.items.isEmpty && !model.isLoading {
                    AdminEmptyState(title: "没有评论", message: "新的访客评论会显示在这里。", systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                } else if model.isLoading && model.items.isEmpty {
                    ProgressView("正在加载评论…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(model.items) { comment in
                            AdminCommentRow(comment: comment) {
                                replyTarget = comment
                            } onAction: { action in
                                Task {
                                    if await model.update(comment, action: action) {
                                        await model.load(filter: filter)
                                    }
                                }
                            } onDelete: {
                                pendingDelete = comment
                            }
                            .disabled(model.isMutating)
                            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22))
                            .onAppear {
                                guard comment.id == model.items.last?.id else { return }
                                Task { await model.loadMore(filter: filter) }
                            }
                        }
                        if model.isLoadingMore { ProgressView().padding() }
                    }
                }
            }
            .padding(20)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: filter) { _, _ in
            Task { await model.load(filter: filter) }
        }
        .refreshable { await model.load(filter: filter) }
        .task {
            await model.load(filter: filter)
            if CreationPreview.isEnabled && CreationPreview.screen == "reply" { replyTarget = model.items.first }
        }
        .sheet(item: $replyTarget) { comment in
            AdminReplySheet(comment: comment) { reply in
                guard await model.update(comment, action: .reply, reply: reply) else {
                    throw APIError.transport(model.errorMessage ?? "回复未保存，请重试。")
                }
                await model.load(filter: filter)
            }
        }
        .confirmationDialog(
            "删除评论？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { comment in
            Button("删除评论", role: .destructive) {
                Task {
                    if await model.delete(comment) { await model.load(filter: filter) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { comment in
            Text("将删除 \(comment.nickname) 的评论，此操作不可撤销。")
        }
    }

    private func commentFilterTitle(_ item: AdminCommentFilter) -> String {
        switch item {
        case .pending:
            return "待审核 \(model.counts[item] ?? 0)"
        case .approved:
            return "已通过 \(model.counts[item] ?? 0)"
        case .all:
            return "全部 \(model.counts[item] ?? 0)"
        }
    }
}

private struct AdminCommentRow: View {
    let comment: AdminComment
    var onReply: (() -> Void)?
    var onAction: ((AdminCommentAction) -> Void)?
    var onDelete: (() -> Void)?

    init(
        comment: AdminComment,
        onReply: (() -> Void)? = nil,
        onAction: ((AdminCommentAction) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.comment = comment
        self.onReply = onReply
        self.onAction = onAction
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(AdminFormatters.initials(comment.nickname))
                    .font(.headline).foregroundStyle(AdminDesign.accent)
                    .frame(width: 44, height: 44).background(AdminDesign.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(comment.nickname).font(.headline).foregroundStyle(AdminDesign.foreground)
                    Text(AdminFormatters.displayDate(comment.createdAt)).font(.caption).foregroundStyle(AdminDesign.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                AdminStatusBadge(status: comment.status)
            }
            if let target = comment.targetLabel?.trimmedNonEmpty {
                Label(target, systemImage: comment.targetType == "moment" ? "quote.bubble" : "doc.text")
                    .font(.caption).foregroundStyle(AdminDesign.muted).lineLimit(2)
            }
            Text(comment.content).font(.body).foregroundStyle(AdminDesign.foreground).textSelection(.enabled)
            if let reply = comment.adminReply?.trimmedNonEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("我的回复", systemImage: "arrow.turn.down.right").font(.caption.weight(.semibold))
                    Text(reply).font(.subheadline)
                }.foregroundStyle(AdminDesign.accent).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 14))
            }
            if onAction != nil || onReply != nil || onDelete != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
            }
        }.padding(18)
    }

    @ViewBuilder private var actions: some View {
        if let onAction, comment.status != "approved" {
            Button { onAction(.approve) } label: { Label("通过", systemImage: "checkmark") }
                .buttonStyle(AdminSmallActionButtonStyle())
        }
        if let onReply {
            Button(action: onReply) { Label(comment.adminReply?.isEmpty == false ? "修改回复" : "回复", systemImage: "arrowshape.turn.up.left") }
                .buttonStyle(AdminSmallActionButtonStyle())
        }
        if onAction != nil || onDelete != nil {
            Menu {
                if let onAction { Button("标记垃圾", systemImage: "nosign", role: .destructive) { onAction(.hide) } }
                if let onDelete { Button("删除评论", systemImage: "trash", role: .destructive, action: onDelete) }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .foregroundStyle(AdminDesign.muted).accessibilityLabel("更多评论操作")
        }
    }
}

private struct AdminCommentActionChip: View {
    let title: String
    var isDanger = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isDanger ? AdminDesign.danger : AdminDesign.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isDanger ? AdminDesign.dangerSoft : AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AdminReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let comment: AdminComment
    let save: (String) async throws -> Void
    @State private var reply: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(comment: AdminComment, save: @escaping (String) async throws -> Void) {
        self.comment = comment
        self.save = save
        _reply = State(initialValue: comment.adminReply ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AdminSettingsCard(title: comment.nickname, subtitle: "访客评论 · \(AdminFormatters.displayDate(comment.createdAt))") {
                        Text(comment.content).font(.body).foregroundStyle(CreationDesign.foreground).textSelection(.enabled)
                    }
                    AdminSettingsCard(title: "我的回复", subtitle: "保存后会显示在这条评论下方") {
                        AdminSettingsMultilineField(text: $reply, placeholder: "写下给读者的回复…", minHeight: 180)
                    }
                    if let errorMessage { CreationNotice(text: errorMessage, isError: true) }
                }.padding(20).disabled(isSaving)
            }.background(CreationDesign.canvas)
            .safeAreaInset(edge: .bottom) {
                CreationSaveBar(title: "保存回复", message: "回应每一份认真。", isSaving: isSaving, canSave: !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task {
                        isSaving = true
                        errorMessage = nil
                        defer { isSaving = false }
                        do { try await save(reply); dismiss() }
                        catch { if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription } }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("回复评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
            }
        }.tint(CreationDesign.accent).interactiveDismissDisabled(isSaving)
    }
}

// MARK: - Settings, attachments and music

private enum AdminSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case site
    case music
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .site: return "基础信息"
        case .music: return "音乐设置"
        case .appearance: return "外观主题"
        }
    }

    var subtitle: String {
        switch self {
        case .site: return "站点信息、作者资料和页面入口"
        case .music: return "默认歌单与前台播放器行为"
        case .appearance: return "配色、版式和深色模式"
        }
    }

    var overline: String {
        switch self {
        case .site: return "SITE SETTINGS"
        case .music: return "MUSIC SETTINGS"
        case .appearance: return "APPEARANCE"
        }
    }

    var symbol: String {
        switch self {
        case .site: return "globe"
        case .music: return "music.note"
        case .appearance: return "paintpalette"
        }
    }
}

@MainActor
private final class AdminSettingsModel: ObservableObject {
    let api: AdminAPIClient
    @Published var values: [String: String] = [:]
    @Published private(set) var savedValues: [String: String] = [:]
    @Published private(set) var hasLoaded = false
    var hasChanges: Bool { hasLoaded && values != savedValues }
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    init(api: AdminAPIClient) {
        self.api = api
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            values = try await api.fetchSettings()
            applyDefaults()
            savedValues = values
            hasLoaded = true
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func save() async {
        guard !isSaving, hasChanges else { return }
        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { isSaving = false }
        do {
            values = try await api.updateSettings(values)
            applyDefaults()
            savedValues = values
            hasLoaded = true
            successMessage = "设置已保存"
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func value(_ key: String, fallback: String = "") -> String {
        values[key] ?? fallback
    }

    func set(_ key: String, _ value: String) {
        values[key] = value
        successMessage = nil
    }

    private func applyDefaults() {
        let defaults: [String: String] = [
            "show_related_posts": "1",
            "show_more_posts": "1",
            "show_table_of_contents": "1",
            "show_home_page": "1",
            "show_moments_page": "1",
            "show_posts_page": "1",
            "show_references_page": "1",
            "show_works_page": "1",
            "show_about_page": "1",
            "music_float_enabled": "1",
            "music_float_info_enabled": "1",
            "music_position": "left",
            "default_music_shuffle": "0",
            "qq_music_health_check_sync": "1",
            "theme": "default",
            "layout_theme": "classic",
            "dark_mode": "auto",
            "classic_sidebar_intro": "A minimal Astro theme\nfor essays, notes, and docs.\nDesigned for reading,\nopen-source.",
            "classic_home_include_bits": "1",
            "classic_show_interactions": "1",
            "classic_show_comments": "1",
        ]
        for (key, value) in defaults where values[key] == nil {
            values[key] = value
        }
    }
}

private enum AdminSettingsImageTarget: Sendable {
    case siteLogo
    case authorAvatar
    case classicHomeImage

    var settingKey: String {
        switch self {
        case .siteLogo: return "site_logo"
        case .authorAvatar: return "author_avatar"
        case .classicHomeImage: return "classic_home_image"
        }
    }
}

@MainActor
private final class AdminQQMusicModel: ObservableObject {
    let api: AdminAPIClient
    @Published var status: AdminQQMusicStatus?
    @Published var qr: AdminQQMusicQR?
    @Published var playlists: [AdminMusicPlaylist] = []
    @Published var isLoading = false
    @Published var isBusy = false
    @Published var message: String?
    private var pollingTask: Task<Void, Never>?

    init(api: AdminAPIClient) { self.api = api }

    func load() async {
        await refreshStatus()
        if status?.loggedIn == true { await loadPlaylists() }
    }

    func refreshStatus() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let latestStatus = try await api.fetchQQMusicStatus()
            status = latestStatus
            // 登录会话保存在服务器本地，而 available 只是一次上游探测结果。
            // 探测瞬时失败不能把仍有效的账号显示成“未登录/不可用”。
            if latestStatus.loggedIn && !latestStatus.available {
                message = "账号仍已登录；QQ 音乐服务探测暂时不可用，歌单和播放可稍后重试。"
            } else if !latestStatus.loggedIn && !latestStatus.available {
                message = "QQ 音乐服务当前不可用"
            } else if message?.hasPrefix("账号仍已登录；") == true {
                message = nil
            }
        } catch {
            if !isAdminRequestCancellation(error) { message = error.localizedDescription }
        }
    }

    func startLogin(channel: String) async {
        pollingTask?.cancel()
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            qr = try await api.fetchQQMusicQR(channel: channel)
            guard let qr else { return }
            let appLogin = qr.isNativeAppQR
            message = appLogin
                ? "请使用 QQ 音乐 App 扫码，并在 App 中确认登录。"
                : "请使用手机 QQ 扫码，并在 QQ 中确认登录。"
            pollingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let expiresAt = qr.expirationDate ?? Date().addingTimeInterval(120)
                while !Task.isCancelled && Date() < expiresAt && self.qr != nil {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        let result: AdminQQMusicPollResult
                        if qr.isNativeAppQR {
                            guard let key = qr.key?.trimmedNonEmpty else {
                                throw APIError.transport("QQ 音乐二维码信息无效，请重新生成")
                            }
                            result = try await self.api.pollNativeQQMusicLogin(key: key)
                        } else {
                            guard let qrsig = qr.qrsig?.trimmedNonEmpty,
                                  let ptqrtoken = qr.ptqrtoken?.trimmedNonEmpty else {
                                throw APIError.transport("QQ 二维码信息无效，请重新生成")
                            }
                            result = try await self.api.pollQQMusicLogin(qrsig: qrsig, ptqrtoken: ptqrtoken)
                        }
                        if result.state == "success" {
                            self.status = AdminQQMusicStatus(available: true, loggedIn: true, uin: result.uin)
                            self.qr = nil
                            self.message = "\(appLogin ? "QQ 音乐 App" : "QQ")扫码登录成功，登录状态只保存在网站后台。"
                            await self.loadPlaylists()
                            break
                        } else if result.state == "expired" {
                            self.qr = nil
                            self.message = result.message?.trimmedNonEmpty ?? "二维码已过期，请重新生成。"
                            break
                        } else if let responseMessage = result.message, !responseMessage.isEmpty {
                            self.message = responseMessage
                        }
                    } catch {
                        if !isAdminRequestCancellation(error) && !(error is CancellationError) {
                            self.message = error.localizedDescription
                        }
                    }
                }
                if self.qr != nil && Date() >= expiresAt {
                    self.qr = nil
                    self.message = "二维码已过期，请重新生成。"
                }
            }
        } catch {
            if !isAdminRequestCancellation(error) { message = error.localizedDescription }
        }
    }

    func cancelLogin() {
        pollingTask?.cancel()
        pollingTask = nil
        let key = qr?.isNativeAppQR == true ? qr?.key?.trimmedNonEmpty : nil
        qr = nil
        if let key {
            Task { await api.cancelNativeQQMusicLogin(key: key) }
        }
    }

    func loadPlaylists() async {
        guard status?.loggedIn == true else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await api.fetchQQMusicPlaylists()
            playlists = response.playlists
            if let warning = response.warning, !warning.isEmpty { message = warning }
            else { message = "已读取 \(playlists.count) 个 QQ 音乐歌单。" }
        } catch {
            if !isAdminRequestCancellation(error) { message = error.localizedDescription }
        }
    }

    deinit {
        pollingTask?.cancel()
    }
}

private struct AdminSettingsView: View {
    @ObservedObject var session: AdminSessionModel
    let section: AdminSettingsSection
    @StateObject private var model: AdminSettingsModel
    @StateObject private var qqMusicModel: AdminQQMusicModel
    @State private var selectedLogoItem: PhotosPickerItem?
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedClassicHomeImageItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var showingMusicPicker = false
    @State private var telegramStatus: AdminTelegramStatus?
    @State private var isTelegramChecking = false
    @State private var telegramMessage: String?
    @State private var telegramError: String?

    init(session: AdminSessionModel, section: AdminSettingsSection) {
        self.session = session
        self.section = section
        _model = StateObject(wrappedValue: AdminSettingsModel(api: session.api))
        _qqMusicModel = StateObject(wrappedValue: AdminQQMusicModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(section.subtitle).font(.subheadline).foregroundStyle(CreationDesign.secondary).padding(.vertical, 16)

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.bottom, 12)
                }
                if let successMessage = model.successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AdminDesign.accent)
                        .padding(.bottom, 12)
                }

                if model.isLoading && model.values.isEmpty {
                    ProgressView("正在加载设置…")
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    sectionContent.disabled(model.isSaving || !model.hasLoaded)
                    if !model.hasLoaded { Button("重新加载设置") { Task { await model.load() } }.padding(.vertical) }

                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            CreationSaveBar(title: "保存设置", message: model.hasChanges ? "有未保存的修改" : (model.hasLoaded ? "设置已同步" : "正在读取设置"), isSaving: model.isSaving, canSave: model.hasChanges && !isUploadingImage) {
                Task { await model.save() }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AdminDesign.background)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
        .task {
            await model.load()
            if section == .music {
                await qqMusicModel.load()
            } else if section == .site {
                await loadTelegram()
            }
        }
        .onChange(of: selectedLogoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                await uploadImage(item, target: .siteLogo)
                selectedLogoItem = nil
            }
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                await uploadImage(item, target: .authorAvatar)
                selectedAvatarItem = nil
            }
        }
        .onChange(of: selectedClassicHomeImageItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                await uploadImage(item, target: .classicHomeImage)
                selectedClassicHomeImageItem = nil
            }
        }
        .sheet(isPresented: $showingMusicPicker) {
            MusicPickerView(api: session.api) { music in
                model.set("default_music", music.spec)
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .site:
            siteContent
        case .music:
            musicContent
        case .appearance:
            appearanceContent
        }
    }

    private var siteContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdminSettingsCard(title: "站点信息", subtitle: "网站标题、副标题和页脚文案") {
                AdminSettingsField(label: "站点名称", placeholder: "Yezi's Blog", text: textBinding("site_name"))
                AdminSettingsField(label: "副标题", placeholder: "文章 · 絮语 · 作品", text: textBinding("site_subtitle"))
                AdminSettingsField(label: "页脚文案", placeholder: "认真写字，也认真生活。", text: textBinding("footer_text"))
            }

            AdminSettingsCard(title: "品牌与作者", subtitle: "上传后会进入统一附件管理") {
                AdminSettingsField(label: "作者名称", placeholder: "Yezi", text: textBinding("author_name"))
                AdminSettingsField(label: "作者邮箱", placeholder: "you@example.com", text: textBinding("author_email"))

                HStack(spacing: 12) {
                    AdminImageView(rawURL: model.value("site_logo"), siteRoot: session.api.siteRoot, size: CGSize(width: 56, height: 56), cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("站点 Logo")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.value("site_logo").isEmpty ? "尚未设置" : model.value("site_logo"))
                            .font(.system(size: 10))
                            .foregroundStyle(AdminDesign.muted)
                            .lineLimit(1)
                        PhotosPicker(selection: $selectedLogoItem, matching: .images) {
                            Text("上传 Logo")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AdminDesign.accent)
                        }
                    }
                    Spacer()
                }

                AdminSettingsToggle(title: "隐藏 Logo 图片边框", isOn: toggleBinding("site_logo_no_border", defaultValue: false))

                HStack(spacing: 12) {
                    AdminImageView(rawURL: model.value("author_avatar"), siteRoot: session.api.siteRoot, size: CGSize(width: 56, height: 56), cornerRadius: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("作者头像")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.value("author_avatar").isEmpty ? "尚未设置" : model.value("author_avatar"))
                            .font(.system(size: 10))
                            .foregroundStyle(AdminDesign.muted)
                            .lineLimit(1)
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                            Text("上传头像")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AdminDesign.accent)
                        }
                    }
                    Spacer()
                }

                AdminSettingsToggle(title: "隐藏头像图片边框", isOn: toggleBinding("author_avatar_no_border", defaultValue: false))
                AdminSettingsToggle(title: "允许使用 Gravatar", isOn: toggleBinding("gravatar_enabled", defaultValue: false))
                AdminSettingsField(label: "Gravatar 镜像", placeholder: "https://secure.gravatar.com", text: textBinding("gravatar_mirror"))

            }

            AdminSettingsCard(title: "社交链接", subtitle: "每行一个，格式：名称 | URL") {
                AdminSettingsMultilineField(text: textBinding("social_links"), placeholder: "GitHub | https://github.com/…\nEmail | mailto:you@example.com", minHeight: 110)
            }

            AdminSettingsCard(title: "通知与服务", subtitle: "同步网页版中的音乐健康检查和评论通知开关") {
                AdminSettingsToggle(title: "启用 QQ 音乐健康检查", isOn: toggleBinding("qq_music_health_check_enabled"))
                HStack(spacing: 8) {
                    AdminSettingsField(label: "检查间隔", placeholder: "6", text: textBinding("qq_music_health_check_interval_hours"))
                        .keyboardType(.numberPad)
                    Text("小时/次")
                        .font(.subheadline)
                        .foregroundStyle(AdminDesign.muted)
                        .fixedSize()
                }
                Label("健康检查配置直接与网站后台同步。", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
                AdminSettingsToggle(title: "启用 Telegram 评论通知", isOn: toggleBinding("telegram_comment_notifications_enabled"))
                Label("保存设置后会通过原生 API 同步到网站后台调度器。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
                if let telegramStatus {
                    HStack(spacing: 8) {
                        Image(systemName: telegramStatus.configured ? "checkmark.shield" : "exclamationmark.triangle")
                            .foregroundStyle(telegramStatus.configured ? AdminDesign.accent : AdminDesign.danger)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(telegramStatus.configured ? "Telegram 服务已配置" : "Telegram 服务未配置")
                                .font(.subheadline.weight(.medium))
                            if let lastCheckedAt = telegramStatus.qqMusic.lastCheckedAt {
                                Text("QQ 音乐健康检查：\(telegramStatus.qqMusic.label ?? telegramStatus.qqMusic.status ?? "未知") · \(AdminFormatters.displayDate(lastCheckedAt))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AdminDesign.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await checkTelegram() }
                        } label: {
                            Image(systemName: isTelegramChecking ? "hourglass" : "arrow.clockwise")
                        }
                        .buttonStyle(AdminSmallActionButtonStyle())
                        .disabled(isTelegramChecking)
                    }
                    HStack(spacing: 8) {
                        Button("发送 Telegram 测试通知") {
                            Task { await testTelegram() }
                        }
                        .buttonStyle(AdminSmallActionButtonStyle())
                        .disabled(isTelegramChecking || !telegramStatus.configured)
                        if let telegramMessage {
                            Text(telegramMessage)
                                .font(.system(size: 10))
                                .foregroundStyle(AdminDesign.accent)
                        }
                    }
                    if let telegramError {
                        Text(telegramError)
                            .font(.system(size: 10))
                            .foregroundStyle(AdminDesign.danger)
                            .lineLimit(2)
                    }
                }
            }

        }
    }

    private var musicContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdminSettingsCard(title: "默认音乐", subtitle: "文章和絮语中的音乐仍可单独添加") {
                HStack(spacing: 8) {
                    AdminSettingsField(label: "列表", placeholder: "qqvip:id:playlist", text: textBinding("default_music"))
                    Button {
                        showingMusicPicker = true
                    } label: {
                        Text("选择").frame(minWidth: 40, minHeight: 40)
                    }
                    .buttonStyle(AdminSmallActionButtonStyle())
                    .accessibilityLabel("选择默认音乐")
                }
                AdminSettingsToggle(title: "随机播放默认歌单", isOn: toggleBinding("default_music_shuffle", defaultValue: false))
            }

            AdminQQMusicPanel(model: qqMusicModel, defaultMusic: textBinding("default_music"))

            AdminSettingsCard(title: "前台播放器", subtitle: "控制音乐入口在网站上的显示方式") {
                AdminSettingsToggle(title: "显示音乐图标按钮", isOn: toggleBinding("music_float_enabled"))
                AdminSettingsToggle(title: "桌面端显示歌曲名和歌词", isOn: toggleBinding("music_float_info_enabled"))
                Picker("播放器位置", selection: textBinding("music_position", fallback: "left")) {
                    Text("左下角图标").tag("left")
                    Text("底部展开播放器").tag("bottom")
                }
                .pickerStyle(.menu)
                .font(.subheadline)
            }
        }
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                AdminSettingsCard(title: "配色方案", subtitle: currentThemePalette.description) {
                    HStack(spacing: 6) {
                        AdminThemeSwatch(palette: currentThemePalette)
                        Picker("配色", selection: textBinding("theme", fallback: "default")) {
                            ForEach(themePaletteOptions) { palette in
                                Text(palette.name).tag(palette.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.subheadline)
                    }
                }

                AdminSettingsCard(title: "版式主题", subtitle: "页面结构") {
                    Picker("前台版式", selection: textBinding("layout_theme", fallback: "classic")) {
                        Text("经典版").tag("classic")
                        Text("编辑版").tag("editorial")
                    }
                    .pickerStyle(.menu)
                    .font(.subheadline)
                }
            }

            AdminSettingsCard(title: "深色模式", subtitle: "访客也可以在前台页头切换") {
                Picker("模式", selection: textBinding("dark_mode", fallback: "auto")) {
                    Text("跟随系统").tag("auto")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            if model.value("layout_theme", fallback: "classic") == "classic" {
                AdminSettingsCard(title: "经典版首页", subtitle: "书香版首页内容与互动选项") {
                    HStack(spacing: 12) {
                        AdminImageView(rawURL: model.value("classic_home_image"), siteRoot: session.api.siteRoot, size: CGSize(width: 80, height: 52), cornerRadius: 12)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("首页图片")
                                .font(.system(size: 12, weight: .semibold))
                            Text(model.value("classic_home_image").isEmpty ? "可选" : model.value("classic_home_image"))
                                .font(.system(size: 10))
                                .foregroundStyle(AdminDesign.muted)
                                .lineLimit(1)
                            PhotosPicker(selection: $selectedClassicHomeImageItem, matching: .images) {
                                Text("上传首页图片")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AdminDesign.accent)
                            }
                        }
                        Spacer()
                    }
                    AdminSettingsMultilineField(text: textBinding("classic_home_intro"), placeholder: "首页引导文字", minHeight: 78)
                    AdminSettingsMultilineField(text: textBinding("classic_home_more"), placeholder: "首页补充文字", minHeight: 78)
                    AdminSettingsField(label: "信息流标题", placeholder: "索引", text: textBinding("classic_home_section_title"))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("桌面侧栏介绍")
                            .font(.system(size: 12, weight: .semibold))
                        AdminSettingsMultilineField(
                            text: textBinding("classic_sidebar_intro"),
                            placeholder: "A minimal Astro theme\nfor essays, notes, and docs.\nDesigned for reading,\nopen-source.",
                            minHeight: 96
                        )
                        Text("显示在经典版桌面左侧的站点名称与菜单之间；支持换行，清空后不显示。")
                            .font(.system(size: 10))
                            .foregroundStyle(AdminDesign.muted)
                    }
                    AdminSettingsToggle(title: "首页混入想法时间流", isOn: toggleBinding("classic_home_include_bits"))
                    AdminSettingsToggle(title: "显示互动信息", isOn: toggleBinding("classic_show_interactions"))
                    AdminSettingsToggle(title: "显示评论区", isOn: toggleBinding("classic_show_comments"))
                }
            } else {
                AdminSettingsCard(title: "编辑版页面显示", subtitle: "文章列表、文章页和导航入口") {
                    AdminSettingsToggle(title: "显示文章页“继续阅读”", isOn: toggleBinding("show_related_posts"))
                    AdminSettingsToggle(title: "显示文章列表页“查看更多文章”", isOn: toggleBinding("show_more_posts"))
                    AdminSettingsToggle(title: "显示文章右侧目录", isOn: toggleBinding("show_table_of_contents"))
                    Divider().overlay(AdminDesign.border)
                    AdminSettingsToggle(title: "显示首页", isOn: toggleBinding("show_home_page"))
                    AdminSettingsToggle(title: "显示想法页面", isOn: toggleBinding("show_moments_page"))
                    AdminSettingsToggle(title: "显示文章页面", isOn: toggleBinding("show_posts_page"))
                    AdminSettingsToggle(title: "显示引用页面", isOn: toggleBinding("show_references_page"))
                    AdminSettingsToggle(title: "显示作品页面", isOn: toggleBinding("show_works_page"))
                    AdminSettingsToggle(title: "显示关于页面", isOn: toggleBinding("show_about_page"))
                }
            }
        }
    }

    private var themePaletteOptions: [AdminThemePalette] {
        AdminThemePalette.options(layoutTheme: model.value("layout_theme", fallback: "classic"))
    }

    private var currentThemePalette: AdminThemePalette {
        let theme = model.value("theme", fallback: "default")
        return themePaletteOptions.first(where: { $0.id == theme }) ?? themePaletteOptions[0]
    }

    private func textBinding(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(
            get: { model.value(key, fallback: fallback) },
            set: { model.set(key, $0) }
        )
    }

    private func toggleBinding(_ key: String, defaultValue: Bool = true) -> Binding<Bool> {
        Binding(
            get: { model.value(key, fallback: defaultValue ? "1" : "0") != "0" },
            set: { model.set(key, $0 ? "1" : "0") }
        )
    }

    private func uploadImage(_ item: PhotosPickerItem, target: AdminSettingsImageTarget) async {
        guard !isUploadingImage else { return }
        isUploadingImage = true
        defer { isUploadingImage = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw APIError.emptyData }
            let type = item.supportedContentTypes.first
            let extensionName = type?.preferredFilenameExtension ?? "jpg"
            let attachment = try await session.api.uploadFile(
                data: data,
                filename: "photo-\(UUID().uuidString).\(extensionName)",
                mimeType: type?.preferredMIMEType ?? "image/jpeg"
            )
            model.set(target.settingKey, attachment.path)
        } catch {
            if !isAdminRequestCancellation(error) { model.errorMessage = error.localizedDescription }
        }
    }

    private func loadTelegram() async {
        do {
            telegramStatus = try await session.api.fetchTelegramStatus()
        } catch {
            if !isAdminRequestCancellation(error) { telegramError = error.localizedDescription }
        }
    }

    private func checkTelegram() async {
        isTelegramChecking = true
        telegramError = nil
        defer { isTelegramChecking = false }
        do {
            let result = try await session.api.checkTelegram()
            telegramMessage = result.label ?? result.detail ?? "健康检查已完成"
            await loadTelegram()
        } catch {
            if !isAdminRequestCancellation(error) { telegramError = error.localizedDescription }
        }
    }

    private func testTelegram() async {
        isTelegramChecking = true
        telegramError = nil
        telegramMessage = nil
        defer { isTelegramChecking = false }
        do {
            let result = try await session.api.testTelegram()
            telegramMessage = result.message ?? "测试通知已发送"
        } catch {
            if !isAdminRequestCancellation(error) { telegramError = error.localizedDescription }
        }
    }
}

private struct AdminSettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AdminDesign.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
            }
            content
        }
        .padding(18)
        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Shared native Markdown editing surface used by long-form settings pages
/// and idea editing. Keeping the toolbar and text field in one component
/// prevents the editors from drifting apart visually and behaviorally.
private struct AdminMarkdownEditorCard<Controls: View>: View {
    let title: String
    let subtitle: String
    let placeholder: String
    let minHeight: CGFloat
    @Binding var text: String
    let controls: Controls

    init(
        title: String,
        subtitle: String,
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.subtitle = subtitle
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.controls = controls()
    }

    var body: some View {
        AdminSettingsCard(title: title, subtitle: subtitle) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    controls
                }
            }

            AdminSettingsMultilineField(
                text: $text,
                placeholder: placeholder,
                minHeight: minHeight
            )
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct AdminQQMusicPanel: View {
    @ObservedObject var model: AdminQQMusicModel
    @Binding var defaultMusic: String

    private var selectedPlaylistID: String {
        defaultMusic.split(separator: ":").dropFirst().first.map(String.init) ?? ""
    }

    var body: some View {
        AdminSettingsCard(title: "QQ 音乐账号", subtitle: "登录状态、歌单读取和默认播放列表") {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.status?.loggedIn == true ? AdminDesign.accent : AdminDesign.muted)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AdminDesign.foreground)
                Spacer()
                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(AdminSmallActionButtonStyle())
            }

            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.startLogin(channel: "qqmusic") }
                } label: {
                    Label(model.status?.loggedIn == true ? "QQ 音乐重新扫码" : "QQ 音乐 App 扫码", systemImage: "qrcode")
                }
                .buttonStyle(AdminSmallActionButtonStyle())
                .disabled(model.isBusy)
                Button {
                    Task { await model.startLogin(channel: "qq") }
                } label: {
                    Label("手机 QQ 扫码", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(AdminSmallActionButtonStyle())
                .disabled(model.isBusy)
                if model.status?.loggedIn == true {
                    Button {
                        Task { await model.loadPlaylists() }
                    } label: {
                        Label(model.isBusy ? "读取中…" : "刷新歌单", systemImage: "music.note.list")
                    }
                    .buttonStyle(AdminSmallActionButtonStyle())
                    .disabled(model.isBusy)
                }
            }
            }

            if let qr = model.qr {
                HStack(spacing: 12) {
                    AdminQRImage(rawValue: qr.image)
                        .frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("请使用\(qr.isNativeAppQR ? " QQ 音乐 App" : "手机 QQ")扫码")
                            .font(.system(size: 12, weight: .semibold))
                        Text("扫码并确认后会自动更新登录状态。")
                            .font(.caption)
                            .foregroundStyle(AdminDesign.muted)
                        if let source = qr.source,
                           let label = source.label?.trimmedNonEmpty {
                            Text("来源：\(label)\(source.website?.trimmedNonEmpty.map { "（\($0)）" } ?? "")")
                                .font(.system(size: 10))
                                .foregroundStyle(AdminDesign.muted)
                        }
                        Button("取消扫码") { model.cancelLogin() }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AdminDesign.accent)
                    }
                }
                .padding(10)
                .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if model.status?.loggedIn == true {
                Picker("默认歌单", selection: Binding(
                    get: { selectedPlaylistID },
                    set: { id in defaultMusic = id.isEmpty ? "" : "qqvip:\(id):playlist" }
                )) {
                    Text("不使用 QQ 默认歌单").tag("")
                    ForEach(["created", "collected"], id: \.self) { kind in
                        let group = model.playlists.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Section(kind == "created" ? "自建歌单" : "收藏歌单") {
                                ForEach(group) { playlist in
                                    Text("\(playlist.name)\(playlist.count.map { "（\($0) 首）" } ?? "")")
                                        .tag(playlist.id)
                                }
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
            }

            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
            }
        }
    }

    private var statusText: String {
        guard let status = model.status else { return "正在检查 QQ 音乐状态…" }
        if status.loggedIn { return "已登录\(status.uin.map { " · \($0)" } ?? "")" }
        if !status.available { return "QQ 音乐服务不可用" }
        return "尚未登录 QQ 音乐"
    }
}

private struct AdminQRImage: View {
    let rawValue: String

    var body: some View {
        if let image = decodedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let url = URL(string: rawValue), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFit() }
                else { ProgressView() }
            }
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 44))
                .foregroundStyle(AdminDesign.muted)
        }
    }

    private var decodedImage: UIImage? {
        guard let payload = rawValue.split(separator: ",", maxSplits: 1).last,
              let data = Data(base64Encoded: String(payload)) else { return nil }
        return UIImage(data: data)
    }
}

private struct AdminThemePalette: Identifiable {
    let id: String
    let name: String
    let description: String
    let lightAccent: Color
    let darkAccent: Color
    let lightBackground: Color
    let darkBackground: Color

    static func options(layoutTheme: String) -> [AdminThemePalette] {
        layoutTheme == "editorial" ? editorial : classic
    }

    private static let editorial: [AdminThemePalette] = [
        .init(id: "default", name: "砖红 · 默认", description: "暖白底 + 砖红点缀，本站原配色", lightAccent: .init(red: 0.76, green: 0.37, blue: 0.24), darkAccent: .init(red: 0.85, green: 0.48, blue: 0.35), lightBackground: .init(red: 0.97, green: 0.97, blue: 0.98), darkBackground: .init(red: 0.09, green: 0.09, blue: 0.09)),
        .init(id: "ocean", name: "青绿", description: "清爽的蓝绿色调", lightAccent: .init(red: 0.05, green: 0.58, blue: 0.53), darkAccent: .init(red: 0.18, green: 0.83, blue: 0.75), lightBackground: .init(red: 0.96, green: 0.98, blue: 0.98), darkBackground: .init(red: 0.05, green: 0.09, blue: 0.08)),
        .init(id: "indigo", name: "墨蓝", description: "沉稳的靛蓝色调", lightAccent: .init(red: 0.39, green: 0.40, blue: 0.95), darkAccent: .init(red: 0.51, green: 0.55, blue: 0.97), lightBackground: .init(red: 0.97, green: 0.97, blue: 0.99), darkBackground: .init(red: 0.07, green: 0.07, blue: 0.13)),
        .init(id: "forest", name: "森林", description: "自然的绿色调", lightAccent: .init(red: 0.09, green: 0.64, blue: 0.29), darkAccent: .init(red: 0.29, green: 0.87, blue: 0.50), lightBackground: .init(red: 0.97, green: 0.98, blue: 0.96), darkBackground: .init(red: 0.07, green: 0.08, blue: 0.06)),
        .init(id: "amber", name: "暖阳", description: "温暖的琥珀色调", lightAccent: .init(red: 0.85, green: 0.47, blue: 0.02), darkAccent: .init(red: 0.96, green: 0.62, blue: 0.04), lightBackground: .init(red: 0.99, green: 0.98, blue: 0.95), darkBackground: .init(red: 0.09, green: 0.07, blue: 0.06)),
    ]

    private static let classic: [AdminThemePalette] = [
        .init(id: "default", name: "朱砂书页", description: "暖白纸张 + 朱砂点缀，经典版默认配色", lightAccent: .init(red: 0.73, green: 0.11, blue: 0.11), darkAccent: .init(red: 0.97, green: 0.44, blue: 0.44), lightBackground: .init(red: 1.0, green: 1.0, blue: 0.99), darkBackground: .init(red: 0.10, green: 0.10, blue: 0.10)),
        .init(id: "ocean", name: "松石青笺", description: "淡青纸色 + 松石墨色，清雅通透", lightAccent: .init(red: 0.06, green: 0.46, blue: 0.43), darkAccent: .init(red: 0.37, green: 0.92, blue: 0.83), lightBackground: .init(red: 0.98, green: 1.0, blue: 0.99), darkBackground: .init(red: 0.06, green: 0.09, blue: 0.09)),
        .init(id: "indigo", name: "黛蓝旧札", description: "冷白纸色 + 黛蓝墨色，沉静克制", lightAccent: .init(red: 0.31, green: 0.27, blue: 0.90), darkAccent: .init(red: 0.65, green: 0.71, blue: 0.99), lightBackground: .init(red: 0.99, green: 0.99, blue: 1.0), darkBackground: .init(red: 0.08, green: 0.08, blue: 0.13)),
        .init(id: "forest", name: "松柏墨绿", description: "米白纸色 + 松柏绿，温润自然", lightAccent: .init(red: 0.08, green: 0.50, blue: 0.24), darkAccent: .init(red: 0.53, green: 0.94, blue: 0.67), lightBackground: .init(red: 0.99, green: 1.0, blue: 0.98), darkBackground: .init(red: 0.08, green: 0.09, blue: 0.07)),
        .init(id: "amber", name: "琥珀宣纸", description: "浅宣纸色 + 琥珀棕，温暖复古", lightAccent: .init(red: 0.71, green: 0.33, blue: 0.04), darkAccent: .init(red: 0.98, green: 0.73, blue: 0.14), lightBackground: .init(red: 1.0, green: 0.99, blue: 0.97), darkBackground: .init(red: 0.10, green: 0.09, blue: 0.07)),
    ]
}

private struct AdminThemeSwatch: View {
    let palette: AdminThemePalette

    var body: some View {
        HStack(spacing: 4) {
            swatch(background: palette.lightBackground, accent: palette.lightAccent, border: AdminDesign.border)
            swatch(background: palette.darkBackground, accent: palette.darkAccent, border: Color.white.opacity(0.2))
        }
        .padding(4)
        .background(AdminDesign.surfaceSoft, in: Capsule())
    }

    private func swatch(background: Color, accent: Color, border: Color) -> some View {
        Circle()
            .fill(background)
            .frame(width: 17, height: 17)
            .overlay(Circle().fill(accent).frame(width: 7, height: 7))
            .overlay(Circle().stroke(border, lineWidth: 1))
    }
}

private struct AdminSettingsField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AdminDesign.muted)
            TextField(placeholder, text: $text)
                .font(.body)
                .foregroundStyle(AdminDesign.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct AdminSettingsMultilineField: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(AdminDesign.muted.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            TextEditor(text: $text)
                .font(.body)
                .foregroundStyle(AdminDesign.foreground)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(7)
        }
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AdminSettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .font(.subheadline)
            .tint(AdminDesign.accent)
    }
}

@MainActor
private final class AdminAttachmentsModel: ObservableObject {
    let api: AdminAPIClient
    private let postID: Int?
    private let selectedIDs: Set<Int>
    private let restrictToCurrentPage: Bool
    @Published var items: [AdminAttachment] = []
    @Published var meta: AdminPaginationMeta?
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isUploading = false
    @Published var errorMessage: String?
    private var requestSerial = 0

    var hasMore: Bool {
        guard let meta else { return false }
        let page = meta.page ?? 1
        if let pages = meta.totalPages { return page < pages }
        if let total = meta.total { return page * (meta.limit ?? 50) < total }
        return items.count >= page * (meta.limit ?? 50)
    }

    init(api: AdminAPIClient, postID: Int? = nil, selectedIDs: [Int] = [], restrictToCurrentPage: Bool = false) {
        self.api = api
        self.postID = postID
        self.selectedIDs = Set(selectedIDs)
        self.restrictToCurrentPage = restrictToCurrentPage
    }

    func load() async {
        requestSerial += 1
        let requestID = requestSerial
        isLoading = true
        errorMessage = nil
        defer {
            if requestID == requestSerial { isLoading = false }
        }
        do {
            let page = try await api.fetchAttachments(page: 1, limit: restrictToCurrentPage ? 100 : 50, postID: postID)
            guard requestID == requestSerial else { return }
            items = filter(page.items)
            meta = page.meta
        } catch {
            guard requestID == requestSerial else { return }
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let currentMeta = meta else { return }
        let page = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 50, 1)
        let hasMore: Bool
        if let totalPages = currentMeta.totalPages {
            hasMore = page < totalPages
        } else if let total = currentMeta.total {
            hasMore = page * limit < total
        } else {
            hasMore = items.count >= page * limit
        }
        guard hasMore else { return }

        let requestID = requestSerial
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.fetchAttachments(page: page + 1, limit: limit, postID: postID)
            guard requestID == requestSerial else { return }
            items.append(contentsOf: filter(next.items))
            meta = next.meta
        } catch {
            if !isAdminRequestCancellation(error), requestID == requestSerial {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func filter(_ attachments: [AdminAttachment]) -> [AdminAttachment] {
        guard restrictToCurrentPage else { return attachments }
        return attachments.filter { attachment in
            if let id = attachment.id, selectedIDs.contains(id) { return true }
            guard let postID else { return false }
            if attachment.postId == postID { return true }
            return attachment.references.contains { reference in
                reference.type == "post" && reference.id == postID
            }
        }
    }

    func upload(url: URL) async {
        guard !isUploading else { return }
        isUploading = true
        errorMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            isUploading = false
        }
        do {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize,
               fileSize > 25 * 1024 * 1024 {
                throw APIError.transport("文件不能超过 25 MB，请压缩后重试")
            }
            let data = try Data(contentsOf: url)
            let attachment = try await api.uploadFile(data: data, filename: url.lastPathComponent, mimeType: uploadMIMEType(for: url))
            items.insert(attachment, at: 0)
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func upload(data: Data, filename: String, mimeType: String) async {
        guard !isUploading else { return }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            let attachment = try await api.uploadFile(data: data, filename: filename, mimeType: mimeType)
            items.insert(attachment, at: 0)
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func delete(_ attachment: AdminAttachment) async {
        guard !attachment.referenced else {
            errorMessage = "附件正在被使用，请先移除文章或想法中的引用"
            return
        }
        do {
            if let id = attachment.id, id > 0 {
                try await api.deleteAttachment(id: id)
            } else {
                _ = try await api.deleteUntrackedAttachment(path: attachment.path)
            }
            items.removeAll { $0.stableID == attachment.stableID }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func cleanupUnused() async {
        do {
            _ = try await api.cleanupUnusedAttachments()
            await load()
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminAttachmentsView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminAttachmentsModel
    @State private var showingImporter = false
    @State private var showingPhotos = false
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var pendingDelete: AdminAttachment?
    @State private var showingCleanupConfirmation = false
    @State private var search = ""
    @State private var kind = LibraryFileKind.all
    @State private var sort = "最近上传"
    @State private var preview: AttachmentReaderRoute?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminAttachmentsModel(api: session.api))
    }
    private var visibleItems: [AdminAttachment] {
        let items = model.items.filter { item in
            (kind == .all || LibraryFileKind.kind(mime: item.mimeType, name: item.originalName) == kind)
                && (search.isEmpty || item.originalName.localizedStandardContains(search))
        }
        switch sort {
        case "文件名称": return items.sorted { $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending }
        case "文件大小": return items.sorted { $0.size > $1.size }
        default: return items.sorted { $0.createdAt > $1.createdAt }
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                AdminPreviewHeader(overline: "FILES", title: "文件管理", subtitle: "随时翻阅，让素材井井有条。") {
                    Menu {
                        Picker("排序", selection: $sort) { ForEach(["最近上传", "文件名称", "文件大小"], id: \.self) { Text($0).tag($0) } }
                        Button("清理未使用文件", systemImage: "trash.slash", role: .destructive) { showingCleanupConfirmation = true }
                    } label: { Image(systemName: "arrow.up.arrow.down").font(.title3).frame(width: 48, height: 48).background(CreationDesign.surface, in: Circle()) }.accessibilityLabel("文件排序与管理")
                }
                CreationSearchField(placeholder: "搜索已加载的文件", text: $search)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibraryFileKind.allCases, id: \.self) { value in
                            CreationFilterChip(title: value.rawValue, symbol: value == .all ? nil : value.symbol, selected: kind == value) { kind = value }
                        }
                    }
                }
                CreationSectionHeading(title: sort, detail: "已加载 \(model.items.count) 个")
                if model.isUploading { Label("正在上传，请稍候…", systemImage: "arrow.up.circle").font(.subheadline).foregroundStyle(CreationDesign.accent) }
                if let error = model.errorMessage { CreationNotice(text: error, isError: true); Button("重新加载") { Task { await model.load() } } }
                if model.isLoading && model.items.isEmpty { ProgressView("正在加载文件…").frame(maxWidth: .infinity, minHeight: 200) }
                else if visibleItems.isEmpty && model.errorMessage == nil {
                    ContentUnavailableView(model.items.isEmpty ? "文件库还是空的" : "没有匹配的文件", systemImage: "folder", description: Text(model.items.isEmpty ? "上传图片或文档，在这里整理和阅读。" : "调整筛选条件，或加载更多文件。"))
                }
                ForEach(visibleItems, id: \.stableID) { attachment in
                    fileRow(attachment)
                }
                if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                if model.hasMore { Button("加载更多文件") { Task { await model.loadMore() } }.frame(maxWidth: .infinity, minHeight: 44).disabled(model.isLoading || model.isLoadingMore) }
            }.padding(20).padding(.bottom, 80)
        }.background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground)
            .adminNativeSwipeBack()
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    Button("从文件选择", systemImage: "folder") { showingImporter = true }
                    Button("从相册选择", systemImage: "photo") { showingPhotos = true }
                } label: { Label("上传文件", systemImage: "plus").padding(.vertical, 4) }
                    .buttonStyle(CreationPrimaryButtonStyle()).padding(20).disabled(model.isUploading)
                    .shadow(color: CreationDesign.accent.opacity(0.2), radius: 12, x: 0, y: 5)
            }
            .photosPicker(isPresented: $showingPhotos, selection: $selectedImageItem, matching: .images)
            .onChange(of: selectedImageItem) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw APIError.emptyData }
                        let type = item.supportedContentTypes.first
                        await model.upload(data: data, filename: "photo-\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "jpg")", mimeType: type?.preferredMIMEType ?? "image/jpeg")
                    } catch { if !isAdminRequestCancellation(error) { model.errorMessage = error.localizedDescription } }
                    selectedImageItem = nil
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { Task { await model.upload(url: url) } }
                case .failure(let error): if !isRequestCancellation(error) { model.errorMessage = error.localizedDescription }
                }
            }
            .sheet(item: $preview) { value in AttachmentReaderView(attachment: value.attachment, api: session.api) }
            .confirmationDialog("删除文件？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { attachment in
                Button("删除「\(attachment.originalName)」", role: .destructive) { Task { await model.delete(attachment) } }
            } message: { attachment in Text(attachment.referenced ? "文件正在被使用，请先移除引用。" : "文件会从服务器移除，删除后无法恢复。") }
            .confirmationDialog("清理未使用文件？", isPresented: $showingCleanupConfirmation) {
                Button("清理未使用文件", role: .destructive) { Task { await model.cleanupUnused() } }
            } message: { Text("删除未被文章、絮语或站点设置引用的文件，此操作不可撤销。") }
            .refreshable { await model.load() }
            .task {
                await model.load()
                if CreationPreview.isEnabled {
                    let mime = ["file-reader": "text/markdown", "file-pdf": "application/pdf", "file-image": "image/jpeg"][CreationPreview.screen]
                    if let mime, let item = model.items.first(where: { $0.mimeType == mime }) { preview = AttachmentReaderRoute(attachment: item) }
                }
            }
    }
    private func fileRow(_ attachment: AdminAttachment) -> some View {
        HStack(spacing: 10) {
            Button { preview = AttachmentReaderRoute(attachment: attachment) } label: {
                HStack(spacing: 14) {
                    if attachment.mimeType.hasPrefix("image/") {
                        CreationRemoteImage(path: attachment.path, site: session.api.siteRoot).frame(width: 54, height: 62).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: LibraryFileKind.kind(mime: attachment.mimeType, name: attachment.originalName).symbol)
                            .font(.title2).foregroundStyle(CreationDesign.accent).frame(width: 54, height: 62)
                            .background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(attachment.originalName).font(.body.weight(.medium)).foregroundStyle(CreationDesign.foreground).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(AdminFormatters.fileSize(attachment.size)) · \(String(attachment.createdAt.prefix(10)))").font(.caption).foregroundStyle(CreationDesign.secondary)
                        if attachment.referenced { Label("正在使用", systemImage: "link").font(.caption2).foregroundStyle(CreationDesign.accent) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("打开并阅读文件")
            Menu {
                Button("打开文件", systemImage: "doc.text.magnifyingglass") { preview = AttachmentReaderRoute(attachment: attachment) }
                NavigationLink { AdminAttachmentDetailView(attachment: attachment, api: session.api) } label: { Label("详情与引用", systemImage: "info.circle") }
                if let url = SiteURLResolver(siteRoot: session.api.siteRoot).absoluteURL(attachment.path) {
                    ShareLink(item: url) { Label("分享链接", systemImage: "square.and.arrow.up") }
                    Button("复制链接", systemImage: "link") { UIPasteboard.general.url = url }
                }
                Button("删除文件", systemImage: "trash", role: .destructive) { pendingDelete = attachment }.disabled(attachment.referenced)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("管理\(attachment.originalName)")
        }.padding(14).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct AdminAttachmentDetailView: View {
    let attachment: AdminAttachment
    let api: AdminAPIClient
    @State private var x = "0"
    @State private var y = "0"
    @State private var width = ""
    @State private var height = ""
    @State private var isCropping = false
    @State private var isCompressing = false
    @State private var compressionProfile: AdminAttachmentCompressionProfile = .balanced
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var createdAttachment: AdminAttachment?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(overline: "ATTACHMENT DETAIL", title: "附件详情", subtitle: "文件信息、引用关系和图片操作") {
                    Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(width: 38, height: 38)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }

                if let errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }
                if let message {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AdminDesign.accent)
                }

                AdminSettingsCard(title: "文件信息", subtitle: attachment.tracked ? "已登记到网站附件库" : "目录扫描到的未入库文件") {
                    HStack(alignment: .top, spacing: 12) {
                        if attachment.mimeType.hasPrefix("image/") {
                            AdminImageView(rawURL: attachment.path, siteRoot: api.siteRoot, size: CGSize(width: 92, height: 92), cornerRadius: 14)
                        } else {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(AdminDesign.accent)
                                .frame(width: 92, height: 92)
                                .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(attachment.originalName)
                                .font(.headline)
                                .foregroundStyle(AdminDesign.foreground)
                            Text(attachment.mimeType)
                                .font(.caption)
                                .foregroundStyle(AdminDesign.muted)
                            Text(AdminFormatters.fileSize(attachment.size))
                                .font(.caption)
                                .foregroundStyle(AdminDesign.muted)
                            Text("上传：\(AdminFormatters.displayDate(attachment.createdAt))")
                                .font(.caption)
                                .foregroundStyle(AdminDesign.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let url = attachmentURL {
                        Link(destination: url) {
                            Label("打开附件", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                                .foregroundStyle(AdminDesign.accent)
                        }
                    }
                }

                AdminSettingsCard(title: "引用关系", subtitle: "查看该附件被哪些文章、想法或站点设置使用") {
                    if attachment.references.isEmpty {
                        Text("当前没有检测到引用")
                            .font(.subheadline)
                            .foregroundStyle(AdminDesign.muted)
                    } else {
                        ForEach(Array(attachment.references.enumerated()), id: \.offset) { _, reference in
                            HStack(spacing: 8) {
                                Image(systemName: reference.type == "post" ? "doc.text" : "link")
                                    .foregroundStyle(AdminDesign.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reference.label)
                                        .font(.body.weight(.medium))
                                    Text([reference.type, reference.usage].compactMap { $0?.trimmedNonEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(AdminDesign.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if attachment.mimeType.hasPrefix("image/") {
                    AdminSettingsCard(title: "图片压缩", subtitle: "保留原链接，直接替换服务器上的图片文件") {
                        Picker("压缩级别", selection: $compressionProfile) {
                            ForEach(AdminAttachmentCompressionProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                        .pickerStyle(.segmented)
                        Button {
                            Task { await compress() }
                        } label: {
                            HStack {
                                if isCompressing { ProgressView().tint(.white) }
                                Text(isCompressing ? "压缩中…" : "开始压缩")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(AdminDesign.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isCompressing)
                    }
                }

                if attachment.mimeType.hasPrefix("image/"), attachment.id != nil {
                    AdminSettingsCard(title: "图片裁切", subtitle: "按像素输入选区，保留原图并生成新的 WebP 附件") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            AdminAttachmentNumberField(label: "X", text: $x)
                            AdminAttachmentNumberField(label: "Y", text: $y)
                            AdminAttachmentNumberField(label: "宽", text: $width)
                            AdminAttachmentNumberField(label: "高", text: $height)
                        }
                        Button {
                            Task { await crop() }
                        } label: {
                            HStack {
                                if isCropping { ProgressView().tint(.white) }
                                Text(isCropping ? "裁切中…" : "生成裁切附件")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(AdminDesign.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isCropping)

                        if let createdAttachment {
                            Text("已生成：\(createdAttachment.originalName)")
                                .font(.system(size: 11))
                                .foregroundStyle(AdminDesign.accent)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
    }

    private var attachmentURL: URL? {
        if let absolute = URL(string: attachment.path), absolute.scheme != nil { return absolute }
        return URL(string: attachment.path, relativeTo: api.siteRoot)?.absoluteURL
    }

    private func crop() async {
        guard let id = attachment.id,
              let x = Int(x), let y = Int(y), let width = Int(width), let height = Int(height),
              x >= 0, y >= 0, width > 0, height > 0 else {
            errorMessage = "请输入有效的 X、Y、宽度和高度"
            return
        }
        isCropping = true
        message = nil
        errorMessage = nil
        defer { isCropping = false }
        do {
            createdAttachment = try await api.cropAttachment(id: id, x: x, y: y, width: width, height: height)
            message = "裁切附件已生成，返回附件列表后可刷新查看。"
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func compress() async {
        isCompressing = true
        message = nil
        errorMessage = nil
        defer { isCompressing = false }
        do {
            let result: AdminAttachmentMaintenanceResult
            if let id = attachment.id, id > 0 {
                result = try await api.compressAttachment(id: id, profile: compressionProfile)
            } else {
                result = try await api.compressUntrackedAttachment(path: attachment.path, profile: compressionProfile)
            }
            if result.changed == false {
                message = "压缩后体积没有变小，已保留原图。"
            } else if let savedPercent = result.savedPercent {
                message = "压缩完成，体积减少约 \(savedPercent)%。"
            } else {
                message = "压缩完成。"
            }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminAttachmentNumberField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AdminDesign.muted)
            TextField("0", text: $text)
                .keyboardType(.numberPad)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AdminAttachmentPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let api: AdminAPIClient
    let postID: Int?
    let selectedIDs: [Int]
    let onSelect: (AdminAttachment) -> Void
    @StateObject private var model: AdminAttachmentsModel

    init(api: AdminAPIClient, postID: Int? = nil, selectedIDs: [Int] = [], onSelect: @escaping (AdminAttachment) -> Void) {
        self.api = api
        self.postID = postID
        self.selectedIDs = selectedIDs
        self.onSelect = onSelect
        _model = StateObject(wrappedValue: AdminAttachmentsModel(api: api, postID: postID, selectedIDs: selectedIDs, restrictToCurrentPage: true))
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(model.items, id: \.stableID) { attachment in
                    Button {
                        onSelect(attachment)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            if attachment.mimeType.hasPrefix("image/") {
                                AdminImageView(rawURL: attachment.path, siteRoot: api.siteRoot, size: CGSize(width: 44, height: 44), cornerRadius: 9)
                            } else {
                                Image(systemName: "paperclip")
                                    .frame(width: 44, height: 44)
                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attachment.originalName).lineLimit(1)
                                Text(attachment.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        guard attachment.stableID == model.items.last?.stableID else { return }
                        Task { await model.loadMore() }
                    }
                }
                if model.items.isEmpty && !model.isLoading {
                    Text("暂无附件，请先上传文件").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("选择附件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .overlay { if model.isLoading { ProgressView() } }
            .task { await model.load() }
        }
    }
}

private struct AdminMusicInsertSheet: View {
    @Environment(\.dismiss) private var dismiss
    let api: AdminAPIClient
    let onInsert: (String) -> Void
    @State private var searchType: AdminMusicSearchType = .song
    @State private var query = ""
    @State private var manualSpec = ""
    @State private var shuffle = false
    @State private var result = AdminMusicSearchResult()
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("选择类型") {
                    Picker("搜索", selection: $searchType) {
                        Text("歌曲").tag(AdminMusicSearchType.song)
                        Text("歌单").tag(AdminMusicSearchType.playlist)
                    }
                    .pickerStyle(.segmented)
                    Toggle("歌单随机播放", isOn: $shuffle)
                        .disabled(searchType != .playlist)
                }

                Section("搜索 QQ 音乐") {
                    HStack {
                        TextField(searchType == .song ? "歌曲名或歌手" : "歌单名称", text: $query)
                        Button {
                            Task { await search() }
                        } label: {
                            if isLoading { ProgressView() } else { Image(systemName: "magnifyingglass") }
                        }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }

                if searchType == .song {
                    Section("歌曲结果") {
                        ForEach(result.tracks) { track in
                            Button {
                                insert(MarkdownParser.makeMusicSpec(
                                    id: track.mid,
                                    type: "song",
                                    title: track.name,
                                    artist: track.artist,
                                    cover: track.cover
                                ))
                            } label: {
                                HStack(spacing: 10) {
                                    AdminImageView(rawURL: track.cover, siteRoot: api.siteRoot, size: CGSize(width: 42, height: 42), cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.name).foregroundStyle(.primary).lineLimit(1)
                                        Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Section("歌单结果") {
                        ForEach(result.playlists) { playlist in
                            Button {
                                insert(MarkdownParser.makeMusicSpec(
                                    id: playlist.id,
                                    type: "playlist",
                                    shuffle: shuffle,
                                    title: playlist.name,
                                    artist: playlist.creator,
                                    cover: playlist.cover
                                ))
                            } label: {
                                HStack(spacing: 10) {
                                    AdminImageView(rawURL: playlist.cover, siteRoot: api.siteRoot, size: CGSize(width: 42, height: 42), cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(playlist.name).foregroundStyle(.primary).lineLimit(1)
                                        Text("\(playlist.creator) · \(playlist.count ?? 0) 首").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("手动输入") {
                    TextField("qqvip:歌曲 ID:song 或 qqvip:歌单 ID:playlist", text: $manualSpec)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("插入手动格式") {
                        insert(manualSpec)
                    }
                    .disabled(manualSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("插入音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func search() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            result = try await api.searchQQMusic(query: query, type: searchType)
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func insert(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("qqvip:") else {
            errorMessage = "请输入 qqvip:id:type 格式"
            return
        }
        onInsert(value)
        dismiss()
    }
}

struct AdminVideoInsertSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onInsert: (String) -> Void
    @State private var url = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AdminSettingsCard(title: "视频链接", subtitle: "支持 MP4、M3U8 直链，也可以添加 B 站、YouTube 等网页链接。") {
                        AdminSettingsField(label: "地址", placeholder: "https://example.com/video.mp4", text: $url).keyboardType(.URL)
                    }
                    if let errorMessage { CreationNotice(text: errorMessage, isError: true) }
                }.padding(20)
            }.background(CreationDesign.canvas)
            .safeAreaInset(edge: .bottom) {
                CreationSaveBar(title: "插入视频", message: "添加到正文的光标位置", canSave: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: insert)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("插入视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }.tint(CreationDesign.accent)
    }

    private func insert() {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: value),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errorMessage = "请输入 http 或 https 视频地址"
            return
        }
        onInsert(value)
        dismiss()
    }
}

struct AdminMarkdownPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let content: String
    let api: AdminAPIClient
    let siteRoot: URL
    let references: [AdminReferenceSnapshot]

    init(content: String, api: AdminAPIClient, siteRoot: URL, references: [AdminReferenceSnapshot] = []) {
        self.content = content
        self.api = api
        self.siteRoot = siteRoot
        self.references = references
    }

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(content, references: references.map {
            ArticleReferenceSnapshot(
                url: $0.url ?? $0.canonicalUrl,
                canonicalURL: $0.canonicalUrl,
                title: $0.title,
                source: $0.source,
                author: $0.author,
                publishedAt: $0.publishedAt,
                cover: $0.cover,
                coverURL: $0.coverUrl,
                description: $0.description,
                summary: $0.summary,
                keyPoints: $0.keyPoints
            )
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: siteRoot)
                    }
                }
                .padding(20)
            }
            .background(AdminDesign.background)
            .navigationTitle("Markdown 预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

struct AdminPreviewMarkdownBlock: View {
    let block: MarkdownBlock
    let api: AdminAPIClient
    let siteRoot: URL

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.attributed(text))
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.bold) : .headline.weight(.semibold))
                .foregroundStyle(AdminDesign.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            Text(MarkdownParser.attributed(text))
                .font(.body)
                .foregroundStyle(AdminDesign.foreground)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unorderedList(let items):
            AdminPreviewList(items: items, ordered: false)
        case .orderedList(let items):
            AdminPreviewList(items: items, ordered: true)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AdminDesign.accent)
                    .frame(width: 3)
                Text(MarkdownParser.attributed(text))
                    .font(.body.italic())
                    .foregroundStyle(AdminDesign.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        case .music(let spec):
            AdminPreviewMusicCard(spec: spec, api: api)
        case .video(let url):
            AdminPreviewVideoCard(rawURL: url, siteRoot: siteRoot)
        case .code(let language, let text):
            if language?.lowercased() == "music" || language?.lowercased() == "qqvip" {
                AdminPreviewMusicCard(spec: text, api: api)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let language, language != "text" {
                        Text(language)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AdminDesign.muted)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(AdminDesign.foreground)
                            .textSelection(.enabled)
                            .padding(14)
                    }
                }
                .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .image(let url, let alt):
            VStack(alignment: .leading, spacing: 6) {
                AdminImageView(rawURL: url, siteRoot: siteRoot, size: CGSize(width: 320, height: 210), cornerRadius: 12)
                    .frame(maxWidth: .infinity)
                if !alt.isEmpty {
                    Text(alt)
                        .font(.system(size: 11))
                        .foregroundStyle(AdminDesign.muted)
                }
            }
        case .divider:
            Divider()
        case .reference(let reference):
            AdminPreviewReferenceCard(reference: reference, siteRoot: siteRoot)
        case .unresolvedReference(let payload):
            Label(payload.isEmpty ? "引用内容暂不可用" : "引用内容暂不可用：\(payload)", systemImage: "link.badge.plus")
                .font(.system(size: 12))
                .foregroundStyle(AdminDesign.muted)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct AdminPreviewList: View {
    let items: [String]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
                    Text(MarkdownParser.attributed(item))
                        .font(.body)
                        .foregroundStyle(AdminDesign.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct AdminPreviewVideoCard: View {
    let rawURL: String
    let siteRoot: URL

    init(rawURL: String, siteRoot: URL) {
        self.rawURL = rawURL
        self.siteRoot = siteRoot
    }

    private var resolvedURL: URL? {
        SiteURLResolver(siteRoot: siteRoot).absoluteURL(rawURL)
    }

    private var isWebPageEmbed: Bool {
        guard let host = resolvedURL?.host?.lowercased() else { return false }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return ["youtube.com", "youtu.be", "bilibili.com", "b23.tv", "vimeo.com", "tiktok.com"].contains {
            normalizedHost == $0 || normalizedHost.hasSuffix(".\($0)")
        }
    }

    private var sourceLabel: String {
        guard let host = resolvedURL?.host?.lowercased() else { return "视频" }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if normalizedHost == "bilibili.com" || normalizedHost.hasSuffix(".bilibili.com") || normalizedHost == "b23.tv" {
            return "Bilibili 视频"
        }
        if normalizedHost == "youtube.com" || normalizedHost == "youtu.be" || normalizedHost.hasSuffix(".youtube.com") {
            return "YouTube 视频"
        }
        return "视频"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if resolvedURL != nil {
                HStack(spacing: 12) {
                    Image(systemName: isWebPageEmbed ? "play.rectangle.fill" : "video.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(width: 48, height: 48)
                        .background(AdminDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(sourceLabel)占位卡片")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AdminDesign.foreground)
                        Text("Markdown 预览不播放视频")
                            .font(.system(size: 11))
                            .foregroundStyle(AdminDesign.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .background(AdminDesign.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Label("视频地址不可用", systemImage: "video.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(AdminDesign.muted)
                    .frame(maxWidth: .infinity, minHeight: 76)
            }

            Text(rawURL)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AdminDesign.muted)
                .lineLimit(2)
        }
        .padding(14)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AdminPreviewMusicCard: View {
    let spec: String
    let api: AdminAPIClient

    @State private var track: AdminMusicTrack?
    @State private var playlistTrackCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(spec: String, api: AdminAPIClient) {
        self.spec = spec
        self.api = api
        _track = State(initialValue: nil)
        _playlistTrackCount = State(initialValue: nil)
    }

    private var musicID: String? {
        marker?.id
    }

    private var musicType: String? {
        marker?.type
    }

    private var isRandomPlaylist: Bool {
        marker?.shuffle == true
    }

    private var marker: MusicMarker? {
        MarkdownParser.musicMarker(from: spec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let track {
                HStack(spacing: 12) {
                    AdminImageView(rawURL: track.cover, siteRoot: api.siteRoot, size: CGSize(width: 72, height: 72), cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.name.trimmedNonEmpty ?? "未命名歌曲")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AdminDesign.foreground)
                            .lineLimit(2)
                        Text(track.artist.trimmedNonEmpty ?? "未知歌手")
                            .font(.system(size: 12))
                            .foregroundStyle(AdminDesign.muted)
                            .lineLimit(1)
                        if let album = track.album.trimmedNonEmpty {
                            Text(album)
                                .font(.system(size: 11))
                                .foregroundStyle(AdminDesign.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let marker {
                HStack(spacing: 12) {
                    AdminImageView(rawURL: marker.cover, siteRoot: api.siteRoot, size: CGSize(width: 72, height: 72), cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(marker.title ?? (marker.type == "playlist" ? "QQ 音乐歌单" : "QQ 音乐歌曲"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AdminDesign.foreground)
                            .lineLimit(2)
                        if let artist = marker.artist {
                            Text(artist)
                                .font(.system(size: 12))
                                .foregroundStyle(AdminDesign.muted)
                                .lineLimit(1)
                        }
                        if marker.type == "playlist", let playlistTrackCount {
                            Text("歌单 ID：\(marker.id) · \(playlistTrackCount) 首\(isRandomPlaylist ? " · 随机播放" : "")")
                                .font(.system(size: 11))
                                .foregroundStyle(AdminDesign.muted)
                        } else {
                            Text("音乐 ID：\(marker.id)\(marker.shuffle ? " · 随机播放" : "")")
                                .font(.system(size: 11))
                                .foregroundStyle(AdminDesign.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取音乐信息…")
                        .font(.system(size: 12))
                        .foregroundStyle(AdminDesign.muted)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(AdminDesign.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("音乐信息暂不可用")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AdminDesign.foreground)
                        Text("请检查音乐标记格式")
                            .font(.system(size: 11))
                            .foregroundStyle(AdminDesign.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if marker != nil {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                    Text("音乐卡片（预览占位，不播放）")
                }
                .font(.system(size: 11))
                .foregroundStyle(AdminDesign.muted)
            }

            if let errorMessage, track == nil {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(AdminDesign.danger)
            }

        }
        .padding(14)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: spec) { await loadMusic() }
    }

    @MainActor
    private func loadMusic() async {
        guard track == nil, let musicID, let musicType else {
            if musicID == nil || (musicType != "song" && musicType != "playlist") {
                errorMessage = "不支持的音乐格式"
            }
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if musicType == "song" {
                track = try await api.fetchQQMusicTrack(id: musicID)
            } else {
                let response = try await api.fetchQQMusicPlaylistTracks(id: musicID)
                playlistTrackCount = response.total
                if response.total == 0 { errorMessage = "这个歌单没有可用歌曲" }
            }
        } catch {
            if !isAdminRequestCancellation(error), !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

}

private struct AdminPreviewReferenceCard: View {
    let reference: ArticleReferenceSnapshot
    let siteRoot: URL

    private var sourceURL: URL? {
        SiteURLResolver(siteRoot: siteRoot).absoluteURL(reference.url ?? reference.canonicalURL)
    }

    private var metadata: String {
        [
            reference.displaySource,
            reference.author?.trimmedNonEmpty,
            reference.publishedAt.map { AdminFormatters.displayDate($0) },
        ]
        .compactMap { $0?.trimmedNonEmpty }
        .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AdminImageView(
                    rawURL: reference.resolvedCoverValue,
                    siteRoot: siteRoot,
                    size: CGSize(width: 82, height: 72),
                    cornerRadius: 10
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(reference.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AdminDesign.foreground)
                        .lineLimit(3)
                    Text(metadata)
                        .font(.system(size: 11))
                        .foregroundStyle(AdminDesign.muted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let summary = (reference.summary ?? reference.description)?.trimmedNonEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(AdminDesign.foreground)
                    .lineSpacing(3)
                    .lineLimit(4)
            }

            if let keyPoints = reference.keyPoints?.compactMap({ $0.trimmedNonEmpty }).prefix(6), !keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(keyPoints), id: \.self) { point in
                        Label(point, systemImage: "checkmark")
                            .font(.system(size: 11))
                            .foregroundStyle(AdminDesign.muted)
                    }
                }
            }

            if let sourceURL {
                Link(destination: sourceURL) {
                    Label("阅读原文", systemImage: "arrow.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AdminDesign.accent)
                }
            }
        }
        .padding(14)
        .background(AdminDesign.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct AdminReferencePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let api: AdminAPIClient
    let onSelect: (AdminReferenceSnapshot) -> Void
    @State private var url = ""
    @State private var history: [AdminReferenceSnapshot] = []
    @State private var preview: AdminReferenceSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("读取站外文章")
                            .font(.headline)
                        HStack(spacing: 8) {
                            TextField("粘贴文章网址", text: $url)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body).frame(minHeight: 48)
                            Button {
                                Task { await loadPreview() }
                            } label: {
                                if isLoading { ProgressView() } else { Image(systemName: "arrow.down.circle") }
                            }
                            .buttonStyle(AdminSmallActionButtonStyle())
                            .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                        }
                    }
                    .padding(18)
                    .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    if let errorMessage {
                        AdminErrorBanner(message: errorMessage)
                    }

                    if let preview {
                        AdminReferencePreviewCard(snapshot: preview) {
                            onSelect(preview)
                            dismiss()
                        }
                    }

                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近引用")
                                .font(.headline)
                            ForEach(history.indices, id: \.self) { index in
                                let snapshot = history[index]
                                Button {
                                    onSelect(snapshot)
                                    dismiss()
                                } label: {
                                    AdminReferencePreviewCard(snapshot: snapshot)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AdminDesign.background)
            .navigationTitle("引用文章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .task { await loadHistory() }
        }
    }

    private func loadHistory() async {
        do {
            history = try await api.fetchReferenceHistory()
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func loadPreview() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            preview = try await api.previewReference(url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminReferencePreviewCard: View {
    let snapshot: AdminReferenceSnapshot
    var onSelect: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AdminDesign.accent)
                .frame(width: 36, height: 36)
                .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title?.trimmedNonEmpty ?? "引用文章")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AdminDesign.foreground)
                    .lineLimit(2)
                Text([snapshot.source, snapshot.author, snapshot.url].compactMap { $0?.trimmedNonEmpty }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(AdminDesign.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onSelect {
                Button("引用文章", action: onSelect)
                    .buttonStyle(AdminSmallActionButtonStyle())
            }
        }
        .padding(11)
        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
    }
}

// MARK: - More, moments, works and taxonomy

private enum AdminManagementRoute: String, Identifiable, Hashable {
    case files, siteSettings, musicSettings, appearance, updates, works, workEditor, taxonomy, references, referenceCache, referenceReader, about, overview
    var id: String { rawValue }

    init?(previewScreen: String) {
        switch previewScreen {
        case "files", "file-reader", "file-pdf", "file-image": self = .files
        case "site-settings": self = .siteSettings
        case "music-settings": self = .musicSettings
        case "appearance": self = .appearance
        case "updates": self = .updates
        case "works": self = .works
        case "work-editor": self = .workEditor
        case "taxonomy", "taxonomy-editor": self = .taxonomy
        case "references", "reference-editor": self = .references
        case "reference-cache": self = .referenceCache
        case "reference-reader": self = .referenceReader
        case "about": self = .about
        case "overview": self = .overview
        default: return nil
        }
    }
}

private struct AdminMoreView: View {
    @ObservedObject var session: AdminSessionModel
    @State private var confirmingLogout = false
    @State private var previewRoute: AdminManagementRoute?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CreationPageHeader(title: "管理", subtitle: "照顾好你的小小世界。") {
                    Image(systemName: "leaf").font(.title2).foregroundStyle(CreationDesign.accent)
                        .frame(width: 48, height: 48).background(CreationDesign.surface, in: Circle())
                }
                HStack(spacing: 16) {
                    Image(systemName: "leaf.fill").font(.system(size: 30)).frame(width: 58, height: 66)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("我的小站").font(.title2.weight(.semibold))
                        Text(session.api.siteRoot.host ?? "当前站点").font(.subheadline)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Link(destination: session.api.siteRoot) { Image(systemName: "arrow.up.right").frame(width: 44, height: 44).background(.white.opacity(0.15), in: Circle()) }.accessibilityLabel("打开网站")
                }.padding(20).foregroundStyle(CreationDesign.primaryText)
                    .background(CreationDesign.accent, in: RoundedRectangle(cornerRadius: 24))
                NavigationLink { AdminAttachmentsView(session: session) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "folder.fill").font(.title2).foregroundStyle(CreationDesign.accent)
                            .frame(width: 54, height: 54).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("文件管理").font(.headline).foregroundStyle(CreationDesign.foreground)
                            Text("上传、整理与阅读图片和文档").font(.subheadline).foregroundStyle(CreationDesign.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(CreationDesign.secondary)
                    }.padding(18).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 22))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("management.文件管理")
                VStack(alignment: .leading, spacing: 14) {
                    CreationSectionHeading(title: "常用设置")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        managementTile("基础信息", subtitle: "站点、作者与通知", symbol: "person.crop.rectangle") { AdminSettingsView(session: session, section: .site) }
                        managementTile("音乐", subtitle: "QQ 登录与播放器", symbol: "music.note") { AdminSettingsView(session: session, section: .music) }
                        managementTile("外观", subtitle: "配色与页面布局", symbol: "paintpalette") { AdminSettingsView(session: session, section: .appearance) }
                        managementTile("GitHub 更新", subtitle: "检查版本与同步", symbol: "arrow.triangle.2.circlepath") { AdminDeploymentView(session: session) }
                    }
                }
                AdminMoreGroup(title: "内容与资料") {
                    AdminMoreNavigationRow(title: "草稿箱", subtitle: "继续未完成的絮语与文章", symbol: "tray") { LocalDraftsView(api: session.api) }
                    AdminMoreNavigationRow(title: "分类与标签", subtitle: "整理文章的目录", symbol: "tag") { AdminTaxonomyView(session: session) }
                    AdminMoreNavigationRow(title: "引用资料", subtitle: "收藏与阅读参考文章", symbol: "link") { AdminReferenceManagementView(session: session) }
                    AdminMoreNavigationRow(title: "作品", subtitle: "管理作品展示", symbol: "briefcase") { AdminWorksView(session: session) }
                    AdminMoreNavigationRow(title: "关于页面", subtitle: "向读者介绍自己", symbol: "person.text.rectangle") { AdminAboutManagementView(session: session) }
                }
                AdminMoreGroup(title: "站点与账号") {
                    AdminMoreNavigationRow(title: "站点概览", subtitle: "统计与最近发布", symbol: "chart.bar.xaxis") { AdminDashboardView(session: session) }
                    Button { confirmingLogout = true } label: { Label("退出登录 / 切换站点", systemImage: "rectangle.portrait.and.arrow.right").font(.subheadline).frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle()) }.foregroundStyle(CreationDesign.secondary)
                }
            }.padding(20).padding(.bottom, 12)
        }.background(CreationDesign.canvas).toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("退出当前站点？", isPresented: $confirmingLogout) {
                Button("退出登录", role: .destructive) { Task { await session.logout() } }
            } message: { Text("本机草稿会保留，重新登录此站点后可继续编辑。") }
            .navigationDestination(item: $previewRoute) { route in
                Group {
                    switch route {
                    case .files: AdminAttachmentsView(session: session)
                    case .siteSettings: AdminSettingsView(session: session, section: .site)
                    case .musicSettings: AdminSettingsView(session: session, section: .music)
                    case .appearance: AdminSettingsView(session: session, section: .appearance)
                    case .updates: AdminDeploymentView(session: session)
                    case .works: AdminWorksView(session: session)
                    case .workEditor: AdminWorkEditor(api: session.api, item: nil) {}
                    case .taxonomy: AdminTaxonomyView(session: session)
                    case .references: AdminReferenceManagementView(session: session)
                    case .referenceCache: AdminReferenceCacheView(session: session)
                    case .referenceReader: AdminReferenceReaderView(referenceID: 701, api: session.api)
                    case .about: AdminAboutManagementView(session: session)
                    case .overview: AdminDashboardView(session: session)
                    }
                }.adminNativeSwipeBack()
            }
            .task {
                guard CreationPreview.isEnabled else { return }
                previewRoute = AdminManagementRoute(previewScreen: CreationPreview.screen)
            }
    }
    private func managementTile<Destination: View>(_ title: String, subtitle: String, symbol: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink { destination().adminNativeSwipeBack() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).font(.title3).foregroundStyle(CreationDesign.accent); Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(CreationDesign.secondary) }
                Text(title).font(.headline).foregroundStyle(CreationDesign.foreground)
                Text(subtitle).font(.caption).foregroundStyle(CreationDesign.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 20))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("management.\(title)")
    }
}

private struct AdminMoreGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AdminDesign.muted)
            VStack(spacing: 0) {
                content
            }
            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
        }
    }
}

private struct AdminMoreNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let destination: Destination

    init(title: String, subtitle: String, symbol: String, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination.adminNativeSwipeBack()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AdminDesign.accent)
                    .frame(width: 42, height: 42)
                    .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AdminDesign.foreground)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AdminDesign.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdminDesign.muted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("management.\(title)")
    }
}

private struct AdminDeploymentView: View {
    @ObservedObject var session: AdminSessionModel
    @State private var status: AdminDeployStatus?
    @State private var version: AdminDeployVersionStatus?
    @State private var health: AdminDeploymentHealth?
    @State private var isLoading = false
    @State private var isSyncing = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(overline: "DEPLOYMENT STATUS", title: "GitHub 更新", subtitle: "检查版本、同步代码与查看运行状态") {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(width: 38, height: 38)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }

                if let errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }
                if let message {
                    Label(message, systemImage: isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSyncing ? AdminDesign.warning : AdminDesign.accent)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: message)
                }

                AdminSettingsCard(title: "版本状态", subtitle: "检查当前站点与 GitHub 的版本") {
                    HStack {
                        Text(versionTitle)
                            .font(.headline)
                            .foregroundStyle(versionStatusColor)
                        Spacer()
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: isLoading ? "hourglass" : "arrow.clockwise")
                        }
                        .buttonStyle(AdminSmallActionButtonStyle())
                        .disabled(isLoading)
                    }
                    if let version {
                        if version.status != "up-to-date", let local = shortCommit(version.localCommit), let remote = shortCommit(version.remoteCommit) {
                            HStack(spacing: 8) {
                                Text("本地 \(local)")
                                Text("远端 \(remote)")
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(versionStatusColor)
                        } else if let local = shortCommit(version.localCommit) {
                            Text("本地与远端 \(local)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(versionStatusColor)
                        }
                        if let error = version.error?.trimmedNonEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(AdminDesign.muted)
                                .lineLimit(3)
                        }
                    }
                }

                AdminSettingsCard(title: "部署状态", subtitle: "同步更新后，自动检查网站是否正常运行") {
                    HStack {
                        Text(statusTitle)
                            .font(.headline)
                            .foregroundStyle(statusColor)
                        Spacer()
                        if let updatedAt = status?.updatedAt {
                            Text(AdminFormatters.displayDate(updatedAt))
                                .font(.caption)
                                .foregroundStyle(AdminDesign.muted)
                        }
                    }
                    if isSyncing {
                        ProgressView()
                            .tint(AdminDesign.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = status?.error?.trimmedNonEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(AdminDesign.danger)
                            .lineLimit(3)
                    }
                    if let health, health.status == "ok" {
                        HStack(spacing: 7) {
                            Image(systemName: "heart.text.square.fill")
                                .foregroundStyle(AdminDesign.accent)
                            Text("运行健康")
                            if let commit = shortCommit(health.commit) {
                                Text("release \(commit)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AdminDesign.muted)
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task { await sync() }
                        } label: {
                            HStack {
                                if isSyncing { ProgressView().tint(CreationDesign.primaryText) }
                                Text(isSyncing ? "同步中…" : "同步 GitHub")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(CreationDesign.primaryText)
                            .background(AdminDesign.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSyncing || isDeploymentInProgress)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
        .task {
            await load()
            await resumeDeploymentTrackingIfNeeded()
        }
        .refreshable {
            await load()
            await resumeDeploymentTrackingIfNeeded()
        }
    }

    private var versionTitle: String {
        switch version?.status {
        case "up-to-date":
            if let commit = shortCommit(version?.localCommit) {
                return "版本一致 · \(commit)"
            }
            return "版本一致"
        case "outdated": return "版本不一致"
        case "dirty": return "服务器有未提交修改"
        case "unavailable": return "暂时无法检查"
        default: return isLoading ? "正在检测版本…" : "尚未检查"
        }
    }

    private var versionStatusColor: Color {
        switch version?.status {
        case "up-to-date": return AdminDesign.accent
        case "outdated": return AdminDesign.warning
        case "dirty", "unavailable": return AdminDesign.danger
        default: return AdminDesign.muted
        }
    }

    private var statusTitle: String {
        switch status?.status {
        case "queued": return "等待部署任务启动"
        case "building": return "正在安装依赖并构建"
        case "switching": return "正在备份数据并切换新版本"
        case "checking": return "新版本已启动，正在检查运行状态"
        case "rolling_back": return "健康检查失败，正在自动回滚"
        case "success": return "更新完成，网站运行正常"
        case "failed": return "部署失败"
        default: return isSyncing ? "正在提交部署任务" : "尚未检测"
        }
    }

    private var statusColor: Color {
        switch status?.status {
        case "success": return AdminDesign.accent
        case "failed": return AdminDesign.danger
        case "rolling_back": return AdminDesign.warning
        case "queued", "building", "switching", "checking": return AdminDesign.warning
        default: return isSyncing ? AdminDesign.warning : AdminDesign.muted
        }
    }

    private var isDeploymentInProgress: Bool {
        ["queued", "building", "switching", "checking", "rolling_back"].contains(status?.status ?? "")
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let nextStatus = session.api.fetchDeployStatus()
        async let nextVersion = session.api.fetchDeployVersion()
        async let nextHealth = session.api.fetchDeploymentHealth()
        var requestErrors: [String] = []

        do {
            status = try await nextStatus
        } catch {
            if !isAdminRequestCancellation(error) { requestErrors.append(error.localizedDescription) }
        }
        do {
            version = try await nextVersion
        } catch {
            if !isAdminRequestCancellation(error) { requestErrors.append(error.localizedDescription) }
        }
        health = try? await nextHealth
        errorMessage = requestErrors.first
    }

    private func sync() async {
        isSyncing = true
        message = "正在备份数据库并同步 GitHub，构建完成后自动切换…"
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let result = try await session.api.syncDeployment()
            message = result.message?.trimmedNonEmpty ?? "部署任务已启动，正在跟踪构建状态…"
            await trackDeployment()
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func resumeDeploymentTrackingIfNeeded() async {
        guard isDeploymentInProgress, !isSyncing else { return }
        isSyncing = true
        message = "检测到正在执行的部署任务，正在跟踪状态…"
        defer { isSyncing = false }
        await trackDeployment()
    }

    private func trackDeployment() async {
        var statusReadFailures = 0
        for attempt in 0..<180 {
            if attempt > 0 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            do {
                let latestStatus = try await session.api.fetchDeployStatus()
                status = latestStatus
                statusReadFailures = 0

                switch latestStatus.status {
                case "success":
                    message = "同步、构建和服务切换均已成功，正在确认 GitHub 版本…"
                    await confirmLatestVersion()
                    await refreshDeploymentHealth()
                    return
                case "failed":
                    message = nil
                    errorMessage = "部署失败：\(latestStatus.error?.trimmedNonEmpty ?? "未知错误")"
                    await confirmLatestVersion()
                    return
                default:
                    message = deploymentStageMessage(for: latestStatus.status)
                }
            } catch {
                guard !isAdminRequestCancellation(error) else { return }
                statusReadFailures += 1
                if statusReadFailures >= 5 {
                    message = nil
                    errorMessage = "连续无法读取部署状态，服务可能未正常启动；请刷新页面查看失败详情。"
                    return
                }
                message = "服务正在切换，暂时无法读取部署状态（\(statusReadFailures)/5）…"
            }
        }

        message = "部署仍在服务器后台运行，可稍后刷新本页查看最终状态。"
        await load()
    }

    private func confirmLatestVersion() async {
        for attempt in 0..<10 {
            guard !Task.isCancelled else { return }
            do {
                let latestVersion = try await session.api.fetchDeployVersion()
                version = latestVersion
                if latestVersion.status == "up-to-date" { return }
            } catch {
                // Release 刚完成切换时，新旧进程交接会短暂不可达；与网页后台
                // 一致，继续等待稳定 JSON 版本接口恢复。
            }
            guard attempt < 9 else { break }
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
        }
    }

    private func refreshDeploymentHealth() async {
        for attempt in 0..<10 {
            guard !Task.isCancelled else { return }
            if attempt > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
            do {
                let nextHealth = try await session.api.fetchDeploymentHealth()
                health = nextHealth
                guard nextHealth.status == "ok" else { continue }
                if let commit = shortCommit(nextHealth.commit) {
                    message = "release \(commit) 已对外生效，健康检查通过。"
                } else {
                    message = "新 release 已对外生效，健康检查通过。"
                }
                return
            } catch {
                continue
            }
        }
        message = "服务器已完成部署；运行健康状态暂未确认，可稍后刷新此页查看。"
    }

    private func deploymentStageMessage(for status: String) -> String {
        switch status {
        case "queued": return "等待部署任务启动…"
        case "building": return "正在独立 release 中安装依赖并构建…"
        case "switching": return "正在停止旧进程、备份数据库并切换 release…"
        case "checking": return "新 release 已启动，正在执行健康检查…"
        case "rolling_back": return "健康检查失败，正在自动回滚…"
        default: return "正在部署…"
        }
    }

    private func shortCommit(_ commit: String?) -> String? {
        guard let commit = commit?.trimmedNonEmpty else { return nil }
        return String(commit.prefix(7))
    }

}

private struct AdminAboutManagementView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminSettingsModel
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var showingMusicSheet = false
    @State private var showingVideoSheet = false
    @State private var showingPreview = false
    @State private var showingReferencePicker = false
    @State private var referenceSnapshots: [AdminReferenceSnapshot] = []
    @State private var isUploadingImage = false
    @StateObject private var writing = MarkdownWritingController()
    @State private var focused = false

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminSettingsModel(api: session.api))
    }

    var body: some View {
        let uploading = isUploadingImage
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(overline: "ABOUT PAGE", title: "关于页面", subtitle: "把你的故事，介绍给来到这里的人。") {
                    Button { focused = false; showingPreview = true } label: { Image(systemName: "eye") }
                        .buttonStyle(CreationIconButtonStyle()).accessibilityLabel("预览关于页面")
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }
                if let successMessage = model.successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AdminDesign.accent)
                }

                if model.isLoading && !model.hasLoaded { ProgressView("正在读取关于页面…").frame(maxWidth: .infinity, minHeight: 180) }
                else {
                    AdminSettingsCard(title: "正文", subtitle: "支持 Markdown，选中文字即可排版。") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                PhotosPicker(selection: $selectedImageItem, matching: .images) { Label(uploading ? "上传中…" : "图片", systemImage: "photo") }.disabled(isUploadingImage)
                                Button { focused = false; showingMusicSheet = true } label: { Label("音乐", systemImage: "music.note") }
                                Button { focused = false; showingVideoSheet = true } label: { Label("视频", systemImage: "video") }
                                Button { focused = false; showingReferencePicker = true } label: { Label("引用", systemImage: "link") }
                            }.buttonStyle(AdminSmallActionButtonStyle())
                        }
                        ZStack(alignment: .topLeading) {
                            if model.value("about_content").isEmpty {
                                Text("写下你的介绍、联系方式和站点说明…").font(.body).foregroundStyle(CreationDesign.secondary).padding(.top, 12).allowsHitTesting(false)
                            }
                            MarkdownWritingView(text: Binding(get: { model.value("about_content") }, set: { model.set("about_content", $0) }), focused: $focused, controller: writing, editable: model.hasLoaded && !model.isSaving, label: "关于页面正文", minimumHeight: 320)
                        }
                    }
                    .disabled(!model.hasLoaded || model.isSaving)
                    if !model.hasLoaded {
                        Button("重新读取关于页面") { Task { await model.load() } }.buttonStyle(AdminSmallActionButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AdminDesign.background)
        .adminNativeSwipeBack()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.hasLoaded {
                    HStack(spacing: 0) {
                        MarkdownFormatBar(controller: writing).disabled(model.isSaving)
                        if focused {
                            Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44) }
                                .accessibilityLabel("收起键盘")
                        }
                    }.background(CreationDesign.soft)
                }
                CreationSaveBar(title: "保存页面", message: model.hasChanges ? "有未保存的修改" : "保存后更新网站关于页面", isSaving: model.isSaving, canSave: model.hasChanges && !isUploadingImage) {
                    focused = false
                    Task { await model.save() }
                }
            }
        }
        .onChange(of: selectedImageItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                await uploadImage(item)
                selectedImageItem = nil
            }
        }
        .sheet(isPresented: $showingMusicSheet) {
            MusicPickerView(api: session.api) { music in
                appendMusicBlock(music.spec)
            }
        }
        .sheet(isPresented: $showingVideoSheet) {
            AdminVideoInsertSheet { url in
                appendVideoBlock(url)
            }
        }
        .sheet(isPresented: $showingReferencePicker) {
            AdminReferencePickerSheet(api: session.api) { snapshot in
                referenceSnapshots.append(snapshot)
                appendMarkdown(makeReferenceMarker(snapshot))
            }
        }
        .sheet(isPresented: $showingPreview) {
            AdminMarkdownPreviewSheet(
                content: model.value("about_content"),
                api: session.api,
                siteRoot: session.api.siteRoot,
                references: referenceSnapshots
            )
        }
        .task { await model.load() }
    }

    private func appendMarkdown(_ snippet: String) {
        if writing.insert("\n\n" + snippet + "\n\n") { return }
        let current = model.value("about_content")
        let separator: String
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            separator = ""
        } else if current.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        model.set("about_content", current + separator + snippet)
    }

    private func appendMusicBlock(_ spec: String) {
        appendMarkdown("!music \(spec)")
    }

    private func appendVideoBlock(_ url: String) {
        appendMarkdown("!video:\(url)")
    }

    private func uploadImage(_ item: PhotosPickerItem) async {
        guard !isUploadingImage else { return }
        isUploadingImage = true
        model.errorMessage = nil
        defer { isUploadingImage = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw APIError.emptyData
            }
            let type = item.supportedContentTypes.first
            let extensionName = type?.preferredFilenameExtension ?? "jpg"
            let attachment = try await session.api.uploadFile(
                data: data,
                filename: "about-\(UUID().uuidString).\(extensionName)",
                mimeType: type?.preferredMIMEType ?? "image/jpeg"
            )
            appendMarkdown("![\(attachment.originalName)](\(attachment.path))")
        } catch {
            if !isAdminRequestCancellation(error) {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class AdminReferenceManagementModel: ObservableObject {
    let api: AdminAPIClient
    @Published var items: [ReferenceLibraryItem] = []
    @Published var meta: AdminPaginationMeta?
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    private var requestSerial = 0

    init(api: AdminAPIClient) { self.api = api }

    var hasMore: Bool {
        guard let currentMeta = meta else { return false }
        let page = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 50, 1)
        if let totalPages = currentMeta.totalPages { return page < totalPages }
        if let total = currentMeta.total { return page * limit < total }
        return items.count >= page * limit
    }

    func load(query: String = "") async {
        requestSerial += 1
        let requestID = requestSerial
        isLoading = true
        errorMessage = nil
        defer {
            if requestID == requestSerial { isLoading = false }
        }
        do {
            let page = try await api.fetchReferenceLibrary(page: 1, limit: 50, query: query)
            guard requestID == requestSerial else { return }
            items = page.items
            meta = page.meta
        } catch {
            guard requestID == requestSerial else { return }
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func loadMore(query: String = "") async {
        guard !isLoading, !isLoadingMore, let currentMeta = meta else { return }
        let page = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 50, 1)
        let hasMore: Bool
        if let totalPages = currentMeta.totalPages {
            hasMore = page < totalPages
        } else if let total = currentMeta.total {
            hasMore = page * limit < total
        } else {
            hasMore = items.count >= page * limit
        }
        guard hasMore else { return }

        let requestID = requestSerial
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.fetchReferenceLibrary(page: page + 1, limit: limit, query: query)
            guard requestID == requestSerial else { return }
            items.append(contentsOf: next.items)
            meta = next.meta
        } catch {
            if !isAdminRequestCancellation(error), requestID == requestSerial {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateReference(_ reference: ReferenceLibraryItem, category: String, tags: String) async throws {
        guard let id = reference.id else { return }
        let updated = try await api.updateReferenceMetadata(id: id, category: category, tags: tags)
        if let index = items.firstIndex(where: { $0.identity == reference.identity }) {
            items[index] = updated
        }
    }

    func deleteReference(_ reference: ReferenceLibraryItem) async {
        guard let id = reference.id else { return }
        do {
            try await api.deleteReference(id: id)
            items.removeAll { $0.identity == reference.identity }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func deleteReferences(ids: [Int]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await api.deleteReferences(ids: ids)
            let selected = Set(ids)
            items.removeAll { item in
                guard let id = item.id else { return false }
                return selected.contains(id)
            }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminReferenceManagementView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminReferenceManagementModel
    @State private var searchText = ""
    @State private var selectedIDs: Set<Int> = []
    @State private var editingReference: ReferenceLibraryItem?
    @State private var pendingDelete: ReferenceLibraryItem?
    @State private var showingReferencePicker = false
    @State private var confirmingBulkDelete = false

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminReferenceManagementModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(overline: "ARTICLE REFERENCES", title: "引用管理", subtitle: "资料库与文章引用快照") {
                    HStack(spacing: 8) {
                        if !selectedIDs.isEmpty {
                            Button(role: .destructive) { confirmingBulkDelete = true } label: {
                                Image(systemName: "trash").foregroundStyle(AdminDesign.danger)
                            }
                            .buttonStyle(CreationIconButtonStyle())
                            .accessibilityLabel("删除已选引用")
                        }
                        Button {
                            showingReferencePicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(CreationIconButtonStyle())
                        .accessibilityLabel("添加引用")
                    }
                }

                CreationSearchField(placeholder: "搜索引用标题或来源", text: $searchText)
                NavigationLink { AdminReferenceCacheView(session: session).adminNativeSwipeBack() } label: {
                    Label("阅读缓存", systemImage: "books.vertical").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(AdminSmallActionButtonStyle())

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }

                if model.isLoading && model.items.isEmpty {
                    ProgressView("正在加载引用资料…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if model.items.isEmpty {
                    AdminEmptyState(title: "还没有引用资料", message: "在文章编辑器中点击“引用”即可读取站外文章。", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.items, id: \.identity) { reference in
                        AdminReferenceManagementRow(
                            reference: reference,
                            api: session.api,
                            isSelected: reference.id.map { selectedIDs.contains($0) } ?? false,
                            onToggleSelection: {
                                guard let id = reference.id else { return }
                                if selectedIDs.contains(id) {
                                    selectedIDs.remove(id)
                                } else {
                                    selectedIDs.insert(id)
                                }
                            },
                            onEdit: { editingReference = reference },
                            onDelete: { pendingDelete = reference }
                        )
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }

                    if model.hasMore {
                        Button {
                            Task { await model.loadMore(query: searchText) }
                        } label: {
                            HStack {
                                Text(model.isLoadingMore ? "正在加载更多引用…" : "加载更多引用")
                                Spacer()
                                if model.isLoadingMore { ProgressView().controlSize(.small) }
                                else { Image(systemName: "chevron.down") }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AdminDesign.accent)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingMore)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
        .refreshable { await model.load(query: searchText) }
        .task(id: searchText) {
            do {
                if !searchText.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                await model.load(query: searchText)
                if CreationPreview.isEnabled && CreationPreview.screen == "reference-editor" { editingReference = model.items.first }
            } catch { }
        }
        .sheet(isPresented: $showingReferencePicker) {
            AdminReferencePickerSheet(api: session.api) { snapshot in
                Task {
                    do {
                        _ = try await session.api.saveReferenceLibrary(snapshot: snapshot)
                        await model.load(query: searchText)
                    } catch {
                        if !isAdminRequestCancellation(error) { model.errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { editingReference != nil }, set: { if !$0 { editingReference = nil } })) {
            if let editingReference {
                AdminReferenceMetadataSheet(reference: editingReference) { category, tags in
                    try await model.updateReference(editingReference, category: category, tags: tags)
                }
            }
        }
        .confirmationDialog(
            "删除引用？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { reference in
            Button("删除“\(reference.displayTitle)”", role: .destructive) {
                Task { await model.deleteReference(reference) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只删除引用资料库记录，不会修改已经引用它的文章正文。")
        }
        .confirmationDialog("删除已选的 \(selectedIDs.count) 条引用？", isPresented: $confirmingBulkDelete) {
            Button("删除所选引用", role: .destructive) {
                let ids = Array(selectedIDs)
                Task {
                    await model.deleteReferences(ids: ids)
                    selectedIDs = selectedIDs.intersection(Set(model.items.compactMap(\.id)))
                }
            }
        } message: { Text("只删除引用资料库记录，不会修改文章正文。") }
    }

}

private struct AdminReferenceTabs: View {
    let items: [ReferenceLibraryItem]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.identity) { index, reference in
                    Button {
                        selection = reference.identity
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("引用 \(index + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(selection == reference.identity ? AdminDesign.accent : AdminDesign.muted)
                            Text(reference.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AdminDesign.foreground)
                                .lineLimit(2)
                            Text(reference.sourceName?.trimmedNonEmpty ?? "网页文章")
                                .font(.system(size: 10))
                                .foregroundStyle(AdminDesign.muted)
                                .lineLimit(1)
                        }
                        .frame(width: 148, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .background(selection == reference.identity ? AdminDesign.accentSoft : AdminDesign.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(selection == reference.identity ? AdminDesign.accent.opacity(0.55) : AdminDesign.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("引用选项卡")
    }
}

private struct AdminReferenceCacheView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminReferenceManagementModel
    @State private var selectedReferenceIdentity: String?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminReferenceManagementModel(api: session.api))
    }

    private var cachedItems: [ReferenceLibraryItem] {
        model.items.filter { $0.archiveCapturedAt != nil || $0.archiveUpdatedAt != nil }
    }

    private var activeReference: ReferenceLibraryItem? {
        if let selectedReferenceIdentity {
            return cachedItems.first { $0.identity == selectedReferenceIdentity }
        }
        return cachedItems.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(overline: "READING CACHE", title: "阅读缓存", subtitle: "已保存的引用正文、摘要和缓存报告") {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AdminDesign.accent)
                        .frame(width: 38, height: 38)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }

                if model.isLoading && model.items.isEmpty {
                    ProgressView("正在加载阅读缓存…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if cachedItems.isEmpty {
                    AdminEmptyState(title: "还没有阅读缓存", message: "在引用管理中点击“更新缓存”后，保存的阅读快照会出现在这里。", systemImage: "internaldrive")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                } else {
                    Text("共 \(cachedItems.count) 个缓存")
                        .font(.subheadline)
                        .foregroundStyle(AdminDesign.muted)
                    AdminReferenceTabs(items: cachedItems, selection: $selectedReferenceIdentity)

                    if let activeReference {
                        AdminReferenceCacheDetail(reference: activeReference, api: session.api)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: cachedItems.map(\.identity)) { _, identities in
            guard let first = identities.first else {
                selectedReferenceIdentity = nil
                return
            }
            if let selectedReferenceIdentity, identities.contains(selectedReferenceIdentity) { return }
            selectedReferenceIdentity = first
        }
    }
}

private struct AdminReferenceCacheDetail: View {
    let reference: ReferenceLibraryItem
    let api: AdminAPIClient

    private var imageCount: Int? {
        guard let report = reference.archiveCacheReport else { return nil }
        let count = (report.cachedImages ?? 0) + (report.reusedImages ?? 0)
        return count > 0 ? count : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                AdminImageView(rawURL: reference.coverURL, siteRoot: api.siteRoot, size: CGSize(width: 64, height: 64), cornerRadius: 13)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.displayTitle)
                        .font(.headline)
                        .foregroundStyle(AdminDesign.foreground)
                    Text([reference.sourceName, reference.author].compactMap { $0?.trimmedNonEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(AdminDesign.muted)
                        .lineLimit(2)
                    if let cachedAt = reference.archiveUpdatedAt ?? reference.archiveCapturedAt {
                        Text("缓存于 \(AdminFormatters.displayDate(cachedAt))")
                            .font(.caption)
                            .foregroundStyle(AdminDesign.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 6) {
                AdminReferenceStatusBadge(title: "已缓存正文", symbol: "checkmark.circle.fill")
                if let textCharacters = reference.archiveCacheReport?.textCharacters, textCharacters > 0 {
                    AdminReferenceStatusBadge(title: "正文 \(textCharacters) 字", symbol: "doc.text")
                }
                if let imageCount {
                    AdminReferenceStatusBadge(title: "图片 \(imageCount) 张", symbol: "photo")
                }
                if let quality = reference.archiveCacheReport?.quality?.trimmedNonEmpty {
                    AdminReferenceStatusBadge(title: quality, symbol: "checkmark.seal")
                }
              }
            }

            if let summary = reference.summary?.trimmedNonEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI 摘要")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AdminDesign.accent)
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(AdminDesign.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let keyPoints = reference.keyPoints, !keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("要点")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AdminDesign.muted)
                    ForEach(Array(keyPoints.prefix(6).enumerated()), id: \.offset) { _, point in
                        Text("• \(point)")
                            .font(.body)
                            .foregroundStyle(AdminDesign.foreground)
                    }
                }
            }

            if let description = reference.description?.trimmedNonEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(AdminDesign.muted)
                    .lineLimit(5)
            }

            if let url = reference.url.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Label("打开原文", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                .tint(AdminDesign.accent)
            }

            if let id = reference.id {
                NavigationLink {
                    AdminReferenceReaderView(referenceID: id, api: api)
                } label: {
                    Label("阅读缓存正文", systemImage: "book.pages")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AdminSmallActionButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct AdminReferenceReaderView: View {
    let referenceID: Int
    let api: AdminAPIClient
    @State private var reader: AdminReferenceReader?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var blocks: [MarkdownBlock] {
        guard let reader else { return [] }
        return MarkdownParser.parse(reader.markdown)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading && reader == nil {
                    ProgressView("正在读取缓存正文…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if let errorMessage {
                    AdminErrorBanner(message: errorMessage)
                } else if let reader {
                    AdminPreviewHeader(
                        overline: "PRIVATE READING ARCHIVE",
                        title: "阅读缓存",
                        subtitle: "保存的参考文章，随时静心阅读。"
                    ) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AdminDesign.accent)
                            .frame(width: 38, height: 38)
                            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                    }

                    Text(reader.title?.trimmedNonEmpty ?? "参考文章").font(.system(.title, design: .serif, weight: .bold)).foregroundStyle(AdminDesign.foreground)

                    VStack(alignment: .leading, spacing: 5) {
                        let source = [reader.sourceName, reader.author, reader.publishedAt]
                            .compactMap { $0?.trimmedNonEmpty }
                            .joined(separator: " · ")
                        if !source.isEmpty {
                            Text(source)
                                .font(.subheadline)
                                .foregroundStyle(AdminDesign.accent)
                        }
                        if let updatedAt = reader.updatedAt ?? reader.capturedAt {
                            Text("缓存更新于 \(AdminFormatters.displayDate(updatedAt))")
                                .font(.caption)
                                .foregroundStyle(AdminDesign.muted)
                        }
                    }

                    if let summary = reader.summary?.trimmedNonEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AI 摘要")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AdminDesign.accent)
                            Text(summary)
                                .font(.body)
                                .foregroundStyle(AdminDesign.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }

                    if let points = reader.keyPoints, !points.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("要点")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AdminDesign.muted)
                            ForEach(Array(points.prefix(6).enumerated()), id: \.offset) { _, point in
                                Text("• \(point)")
                                    .font(.body)
                                    .foregroundStyle(AdminDesign.foreground)
                            }
                        }
                    }

                    if let report = reader.report, report.keptBlocks != nil || report.textCharacters != nil {
                        ScrollView(.horizontal, showsIndicators: false) {
                          HStack(spacing: 6) {
                            if let count = report.textCharacters, count > 0 { AdminReferenceStatusBadge(title: "正文 \(count) 字", symbol: "doc.text") }
                            if let count = report.keptBlocks, count > 0 { AdminReferenceStatusBadge(title: "保留 \(count) 块", symbol: "square.stack") }
                            if let count = report.cachedImages, count > 0 { AdminReferenceStatusBadge(title: "缓存图片 \(count) 张", symbol: "photo") }
                          }
                        }
                    }

                    Divider().overlay(AdminDesign.border)
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .navigationTitle("阅读缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            reader = try await api.fetchReferenceReader(id: referenceID)
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminReferenceManagementRow: View {
    let reference: ReferenceLibraryItem
    let api: AdminAPIClient
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var summary: String
    @State private var keyPoints: [String]
    @State private var cachedAt: String?
    @State private var linkedPostCount: Int?
    @State private var isSummarizing = false
    @State private var isCaching = false
    @State private var message: String?
    @State private var errorMessage: String?

    init(
        reference: ReferenceLibraryItem,
        api: AdminAPIClient,
        isSelected: Bool = false,
        onToggleSelection: @escaping () -> Void = {},
        onEdit: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) {
        self.reference = reference
        self.api = api
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
        self.onEdit = onEdit
        self.onDelete = onDelete
        _summary = State(initialValue: reference.summary?.trimmedNonEmpty ?? "")
        _keyPoints = State(initialValue: reference.keyPoints ?? [])
        _cachedAt = State(initialValue: reference.archiveCapturedAt ?? reference.archiveUpdatedAt)
        _linkedPostCount = State(initialValue: reference.linkedPostCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                AdminImageView(rawURL: reference.coverURL, siteRoot: api.siteRoot, size: CGSize(width: 54, height: 64), cornerRadius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.displayTitle)
                        .font(.headline)
                        .foregroundStyle(AdminDesign.foreground)
                        .lineLimit(2)
                    Text([reference.sourceName, reference.author, AdminFormatters.displayDate(reference.updatedAt)].compactMap { $0?.trimmedNonEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(AdminDesign.muted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                AdminReferenceStatusBadge(
                    title: summary.isEmpty ? "未生成 AI 摘要" : "AI 摘要",
                    symbol: summary.isEmpty ? "sparkles" : "checkmark"
                )
                AdminReferenceStatusBadge(
                    title: cachedAt == nil ? "未缓存阅读正文" : "已缓存阅读正文",
                    symbol: cachedAt == nil ? "arrow.down.circle" : "internaldrive"
                )
                if let textCharacters = reference.archiveCacheReport?.textCharacters, textCharacters > 0 {
                    AdminReferenceStatusBadge(title: "正文 \(textCharacters) 字", symbol: "doc.text")
                }
                if let report = reference.archiveCacheReport {
                    let imageCount = (report.cachedImages ?? 0) + (report.reusedImages ?? 0)
                    if imageCount > 0 {
                        AdminReferenceStatusBadge(title: "图片 \(imageCount) 张", symbol: "photo")
                    }
                }
                if let linkedPostCount {
                    AdminReferenceStatusBadge(title: "关联 \(linkedPostCount) 篇文章", symbol: "link")
                }
            }
            }

            ScrollView(.horizontal, showsIndicators: false) {
            if let category = reference.category?.trimmedNonEmpty,
               !category.isEmpty {
                HStack(spacing: 6) {
                    AdminReferenceStatusBadge(title: category, symbol: "folder")
                    ForEach(reference.tags ?? [], id: \.self) { tag in
                        AdminReferenceStatusBadge(title: tag, symbol: "number")
                    }
                }
            } else if let tags = reference.tags, !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        AdminReferenceStatusBadge(title: tag, symbol: "number")
                    }
                }
            }
            }

            if let linkedPostTitles = reference.linkedPostTitles?.trimmedNonEmpty,
               !linkedPostTitles.isEmpty {
                Text("关联文章：\(linkedPostTitles)")
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
                    .lineLimit(2)
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(AdminDesign.foreground)
                    .lineLimit(3)
            }
            if !keyPoints.isEmpty {
                Text(keyPoints.prefix(3).map { "• \($0)" }.joined(separator: "  "))
                    .font(.subheadline)
                    .foregroundStyle(AdminDesign.muted)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                if let id = reference.id, cachedAt != nil {
                    NavigationLink { AdminReferenceReaderView(referenceID: id, api: api) } label: { Label("阅读", systemImage: "book") }
                        .buttonStyle(AdminSmallActionButtonStyle())
                }
                Menu {
                    if let url = reference.url.flatMap(URL.init(string:)) { Link("打开原文", destination: url) }
                    Button(summary.isEmpty ? "生成摘要" : "刷新摘要", systemImage: "sparkles") { Task { await generateSummary() } }
                        .disabled(isSummarizing || isCaching || reference.url?.trimmedNonEmpty == nil)
                    Button("更新阅读缓存", systemImage: "arrow.triangle.2.circlepath") { Task { await updateCache() } }
                        .disabled(isSummarizing || isCaching || reference.url?.trimmedNonEmpty == nil)
                    if reference.id != nil {
                        Button("编辑分类与标签", systemImage: "tag", action: onEdit)
                        Button("删除引用", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: { Label("更多", systemImage: "ellipsis") }.buttonStyle(AdminSmallActionButtonStyle())
                Spacer(minLength: 0)
                if reference.id != nil {
                    Button(action: onToggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundStyle(isSelected ? AdminDesign.accent : AdminDesign.muted).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel(isSelected ? "取消选择此引用" : "选择此引用").accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            if isSummarizing || isCaching { ProgressView(isCaching ? "正在更新阅读缓存…" : "正在生成摘要…").font(.caption) }

            if let cachedAt {
                Text("阅读缓存更新时间：\(AdminFormatters.displayDate(cachedAt))")
                    .font(.caption)
                    .foregroundStyle(AdminDesign.muted)
            }
            if let message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AdminDesign.accent)
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(AdminDesign.danger)
                    .lineLimit(2)
            }
        }
        .padding(18)
    }

    private func generateSummary() async {
        guard let url = reference.url?.trimmedNonEmpty else { return }
        isSummarizing = true
        message = nil
        errorMessage = nil
        defer { isSummarizing = false }
        do {
            let result = try await api.summarizeReference(url: url)
            if result.configured == false {
                message = "未配置 AI 摘要服务，可在网页后台配置后重试。"
            } else if let error = result.error?.trimmedNonEmpty {
                errorMessage = error
            } else if let nextSummary = result.summary?.trimmedNonEmpty, !nextSummary.isEmpty {
                summary = nextSummary
                keyPoints = result.keyPoints ?? []
                message = "AI 摘要已更新"
            } else {
                message = "接口未返回摘要内容"
            }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func updateCache() async {
        guard let url = reference.url?.trimmedNonEmpty else { return }
        isCaching = true
        message = "正在读取原文、缓存图片并生成 AI 摘要…"
        errorMessage = nil
        defer { isCaching = false }
        do {
            let response = try await api.startReferenceArchive(url: url, cacheImages: true)
            guard let jobID = response.job?.id?.trimmedNonEmpty else {
                if let error = response.error?.trimmedNonEmpty { throw APIError.transport(error) }
                message = "缓存任务已提交，请稍后刷新引用管理。"
                return
            }

            var job = response.job
            for _ in 0..<100 {
                guard let current = job else { break }
                if current.state == "completed" { break }
                if current.state == "failed" {
                    throw APIError.transport(current.error?.trimmedNonEmpty ?? "阅读缓存失败")
                }
                try await Task.sleep(nanoseconds: 1_200_000_000)
                job = try await api.fetchReferenceArchiveJob(id: jobID).job
            }

            guard let completed = job else {
                message = "缓存任务已提交，请稍后刷新引用管理。"
                return
            }
            if completed.state != "completed" {
                message = "缓存仍在后台处理，请稍后刷新页面查看。"
                return
            }
            cachedAt = completed.archive?.capturedAt ?? completed.archive?.updatedAt ?? cachedAt
            if let snapshot = try? await api.previewReference(url: url),
               let nextSummary = snapshot.summary?.trimmedNonEmpty,
               !nextSummary.isEmpty {
                summary = nextSummary
                keyPoints = snapshot.keyPoints ?? keyPoints
            }
            message = completed.ai?.summaryGenerated == true
                ? "阅读缓存已更新，AI 摘要也已更新。"
                : "阅读缓存已更新。"
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminReferenceMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reference: ReferenceLibraryItem
    let save: (String, String) async throws -> Void
    @State private var category: String
    @State private var tags: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(reference: ReferenceLibraryItem, save: @escaping (String, String) async throws -> Void) {
        self.reference = reference
        self.save = save
        _category = State(initialValue: reference.category ?? "")
        _tags = State(initialValue: reference.tags?.joined(separator: ", ") ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AdminSettingsCard(title: "引用资料", subtitle: reference.sourceName ?? "参考文章") { Text(reference.displayTitle).font(.headline) }
                    AdminSettingsCard(title: "分类与标签", subtitle: "用分类整理主题，用标签记录关键词。") {
                        AdminSettingsField(label: "分类", placeholder: "例如：设计与生活", text: $category)
                        AdminSettingsField(label: "标签", placeholder: "多个标签用逗号分隔", text: $tags)
                    }.disabled(isSaving)
                    if let errorMessage { CreationNotice(text: errorMessage, isError: true) }
                }.padding(20)
            }.background(CreationDesign.canvas)
            .safeAreaInset(edge: .bottom) {
                CreationSaveBar(title: "保存", message: "更新资料库中的分类和标签", isSaving: isSaving) {
                    Task {
                        isSaving = true
                        errorMessage = nil
                        defer { isSaving = false }
                        do { try await save(category.trimmingCharacters(in: .whitespacesAndNewlines), tags); dismiss() }
                        catch { if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription } }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑引用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
            }
        }.tint(CreationDesign.accent).interactiveDismissDisabled(isSaving)
    }
}

private struct AdminReferenceStatusBadge: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(AdminDesign.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(AdminDesign.surfaceSoft, in: Capsule())
    }
}

@MainActor
private final class AdminMomentsModel: ObservableObject {
    let api: AdminAPIClient
    @Published var items: [AdminMoment] = []
    @Published var meta: AdminPaginationMeta?
    @Published var total = 0
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    private var requestSerial = 0

    init(api: AdminAPIClient) { self.api = api }

    func load() async {
        requestSerial += 1
        let requestID = requestSerial
        isLoading = true
        errorMessage = nil
        defer {
            if requestID == requestSerial { isLoading = false }
        }
        do {
            let page = try await api.fetchMoments(page: 1, limit: 20)
            guard requestID == requestSerial else { return }
            items = page.items
            meta = page.meta
            total = page.meta.total ?? page.items.count
        } catch {
            guard requestID == requestSerial else { return }
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let currentMeta = meta else { return }
        let page = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 20, 1)
        let hasMore: Bool
        if let totalPages = currentMeta.totalPages {
            hasMore = page < totalPages
        } else if let total = currentMeta.total {
            hasMore = page * limit < total
        } else {
            hasMore = items.count >= page * limit
        }
        guard hasMore else { return }

        let requestID = requestSerial
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.fetchMoments(page: page + 1, limit: limit)
            guard requestID == requestSerial else { return }
            items.append(contentsOf: next.items)
            meta = next.meta
        } catch {
            if !isAdminRequestCancellation(error), requestID == requestSerial {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ item: AdminMoment) async {
        do {
            try await api.deleteMoment(id: item.id)
            items.removeAll { $0.id == item.id }
            total = max(0, total - 1)
        } catch { if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription } }
    }
}

private struct AdminMomentsView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminMomentsModel
    @State private var editor: AdminMoment?
    @State private var creating = false
    @State private var pendingDelete: AdminMoment?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminMomentsModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AdminPreviewHeader(overline: "IDEAS", title: "想法", subtitle: "共 \(model.total) 个想法") {
                    Button { creating = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AdminDesign.accent)
                            .frame(width: 38, height: 38)
                            .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                    }
                    .accessibilityLabel("新建想法")
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.bottom, 12)
                }

                if model.items.isEmpty && !model.isLoading {
                    AdminEmptyState(title: "还没有想法", message: "记录今天的灵感。", systemImage: "quote.bubble")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                } else if model.isLoading && model.items.isEmpty {
                    ProgressView("正在加载想法…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.items) { item in
                            Button { editor = item } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "quote.bubble")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(AdminDesign.accent)
                                        .frame(width: 38, height: 38)
                                        .background(AdminDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.content.replacingOccurrences(of: "\n", with: " "))
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(AdminDesign.foreground)
                                            .lineLimit(3)
                                        Text("\(AdminFormatters.displayDate(item.updatedAt ?? item.createdAt)) · \(item.images.count) 张图片")
                                            .font(.system(size: 11))
                                            .foregroundStyle(AdminDesign.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AdminDesign.muted)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = item } label: {
                                    Label("删除想法", systemImage: "trash")
                                }
                            }
                            .onAppear {
                                guard item.id == model.items.last?.id else { return }
                                Task { await model.loadMore() }
                            }
                            if item.id != model.items.last?.id { Divider().padding(.leading, 64) }
                        }
                    }
                    .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.load() }
        .task { await model.load() }
        .navigationDestination(isPresented: $creating) {
            AdminMomentEditor(api: session.api, item: nil) {
                await model.load()
            }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { editor != nil },
                set: { if !$0 { editor = nil } }
            )
        ) {
            if let editor {
                AdminMomentEditor(api: session.api, item: editor) {
                    await model.load()
                }
            }
        }
        .confirmationDialog(
            "删除想法？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("删除想法", role: .destructive) {
                Task { await model.delete(item) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除后无法恢复，请确认操作。")
        }
    }
}

private struct AdminMomentEditor: View {
    let api: AdminAPIClient
    let item: AdminMoment?
    let onSaved: () async -> Void
    @State private var draft: CreationDraft?
    var body: some View {
        Group {
            if let draft { CreationComposerView(api: api, draft: draft) { Task { await onSaved() } } }
            else { ProgressView("正在读取本机草稿…") }
        }
        .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .task {
            let site = CreationDraftStore.canonicalSite(api.siteRoot)
            if let local = try? await CreationDraftStore.shared.list(site: site).first(where: { $0.kind == .moment && $0.serverID == item?.id }) { draft = local; return }
            var value = CreationDraft(site: site, kind: .moment, serverID: item?.id)
            let split = CreationMusic.split(item?.content ?? "")
            value.text = split.text
            value.music = split.music
            value.media = (item?.images ?? []).map { CreationMedia(remotePath: $0, state: .uploaded) }
            draft = value
        }
    }
}

@MainActor
private final class AdminWorksModel: ObservableObject {
    let api: AdminAPIClient
    @Published var items: [AdminWork] = []
    @Published var meta: AdminPaginationMeta?
    @Published var total = 0
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    private var requestSerial = 0

    init(api: AdminAPIClient) { self.api = api }

    func load() async {
        requestSerial += 1
        let requestID = requestSerial
        isLoading = true
        errorMessage = nil
        defer {
            if requestID == requestSerial { isLoading = false }
        }
        do {
            let page = try await api.fetchWorks(page: 1, limit: 20)
            guard requestID == requestSerial else { return }
            items = page.items
            meta = page.meta
            total = page.meta.total ?? page.items.count
        } catch {
            guard requestID == requestSerial else { return }
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let currentMeta = meta else { return }
        let page = currentMeta.page ?? 1
        let limit = max(currentMeta.limit ?? 20, 1)
        let hasMore: Bool
        if let totalPages = currentMeta.totalPages {
            hasMore = page < totalPages
        } else if let total = currentMeta.total {
            hasMore = page * limit < total
        } else {
            hasMore = items.count >= page * limit
        }
        guard hasMore else { return }

        let requestID = requestSerial
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.fetchWorks(page: page + 1, limit: limit)
            guard requestID == requestSerial else { return }
            items.append(contentsOf: next.items)
            meta = next.meta
        } catch {
            if !isAdminRequestCancellation(error), requestID == requestSerial {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ item: AdminWork) async {
        do {
            try await api.deleteWork(id: item.id)
            items.removeAll { $0.id == item.id }
            total = max(0, total - 1)
        } catch { if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription } }
    }
}

private struct AdminWorksView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminWorksModel
    @State private var editor: AdminWork?
    @State private var creating = false
    @State private var pendingDelete: AdminWork?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminWorksModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                AdminPreviewHeader(overline: "WORKS", title: "作品", subtitle: "共 \(model.total) 个作品") {
                    Image(systemName: "briefcase").font(.title2).foregroundStyle(CreationDesign.accent)
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                        .padding(.bottom, 12)
                }

                if model.items.isEmpty && !model.isLoading {
                    AdminEmptyState(title: "还没有作品", message: "添加你的项目或作品。", systemImage: "briefcase")
                        .frame(maxWidth: .infinity)
                        .background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AdminDesign.border, lineWidth: 1))
                } else if model.isLoading && model.items.isEmpty {
                    ProgressView("正在加载作品…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(model.items) { item in
                            HStack(spacing: 8) {
                              Button { editor = item } label: {
                                HStack(spacing: 12) {
                                    AdminImageView(rawURL: item.cover, siteRoot: session.api.siteRoot, size: CGSize(width: 64, height: 76), cornerRadius: 16)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.headline)
                                            .foregroundStyle(AdminDesign.foreground)
                                            .lineLimit(2)
                                        Text(item.description)
                                            .font(.subheadline)
                                            .foregroundStyle(AdminDesign.muted)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .multilineTextAlignment(.leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                                Menu {
                                    Button("编辑作品", systemImage: "pencil") { editor = item }
                                    Button("删除作品", systemImage: "trash", role: .destructive) { pendingDelete = item }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(AdminDesign.muted)
                                }
                                .accessibilityLabel("\(item.title)的操作")
                            }
                            .padding(16).background(AdminDesign.surface, in: RoundedRectangle(cornerRadius: 22))
                            .onAppear {
                                guard item.id == model.items.last?.id else { return }
                                Task { await model.loadMore() }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 80)
        }         
        .background(AdminDesign.background)
        .adminNativeSwipeBack()
        .overlay(alignment: .bottomTrailing) { CreationFloatingButton(title: "新建作品") { creating = true } }
        .refreshable { await model.load() }
        .task { await model.load() }
        .navigationDestination(isPresented: $creating) {
            AdminWorkEditor(api: session.api, item: nil) { await model.load() }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { editor != nil },
                set: { if !$0 { editor = nil } }
            )
        ) {
            if let editor {
                AdminWorkEditor(api: session.api, item: editor) { await model.load() }
            }
        }
        .confirmationDialog(
            "删除作品？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("删除「\(item.title)」", role: .destructive) {
                Task { await model.delete(item) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除后无法恢复，请确认操作。")
        }
    }
}

private struct AdminWorkEditor: View {
    @Environment(\.dismiss) private var dismiss
    let api: AdminAPIClient
    let item: AdminWork?
    let onSaved: () async -> Void
    @State private var title: String
    @State private var description: String
    @State private var cover: String
    @State private var link: String
    @State private var sortOrder: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var hasChanges: Bool {
        title != (item?.title ?? "") || description != (item?.description ?? "") || cover != (item?.cover ?? "") || link != (item?.link ?? "") || sortOrder != String(item?.sortOrder ?? 0)
    }

    init(api: AdminAPIClient, item: AdminWork?, onSaved: @escaping () async -> Void) {
        self.api = api
        self.item = item
        self.onSaved = onSaved
        _title = State(initialValue: item?.title ?? "")
        _description = State(initialValue: item?.description ?? "")
        _cover = State(initialValue: item?.cover ?? "")
        _link = State(initialValue: item?.link ?? "")
        _sortOrder = State(initialValue: String(item?.sortOrder ?? 0))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(
                    overline: "WORK",
                    title: item == nil ? "新建作品" : "编辑作品",
                    subtitle: "作品信息与展示链接"
                ) {
                    EmptyView()
                }

                AdminSettingsCard(title: "作品信息", subtitle: "标题、描述、封面和外部链接") {
                    AdminSettingsField(label: "标题", placeholder: "作品名称", text: $title)
                    AdminSettingsMultilineField(text: $description, placeholder: "简要介绍这个作品…", minHeight: 110)
                    AdminSettingsField(label: "封面", placeholder: "可选的图片地址", text: $cover)
                    AdminSettingsField(label: "链接", placeholder: "https://…", text: $link)
                    AdminSettingsField(label: "排序", placeholder: "0", text: $sortOrder)
                        .keyboardType(.numberPad)
                }

                if let errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }

            }
            .padding(20).disabled(isSaving)
        }
        .background(AdminDesign.background)
        .safeAreaInset(edge: .bottom) {
            CreationSaveBar(title: "保存作品", message: hasChanges ? "有未保存的修改" : "填写作品信息", isSaving: isSaving, canSave: hasChanges && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task { await save() }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .adminNativeSwipeBack()
        .preference(key: AdminBottomNavVisibilityKey.self, value: false)
    }

    private func save() async {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入标题"
            return
        }
        isSaving = true
        errorMessage = nil
        do {
            let payload = AdminWorkWriteRequest(
                title: title,
                description: description,
                cover: cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cover,
                link: link,
                sortOrder: Int(sortOrder) ?? 0
            )
            if let item {
                _ = try await api.updateWork(id: item.id, payload: payload)
            } else {
                _ = try await api.createWork(payload)
            }
            await onSaved()
            dismiss()
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
        isSaving = false
    }
}

@MainActor
private final class AdminTaxonomyModel: ObservableObject {
    let api: AdminAPIClient
    @Published var categories: [AdminCategory] = []
    @Published var tags: [AdminTag] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    init(api: AdminAPIClient) { self.api = api }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            categories = try await api.fetchCategories().items
            tags = try await api.fetchTags().items
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func createCategory(name: String) async throws {
        _ = try await api.createCategory(name: name)
        await load()
    }

    func updateCategory(id: Int, name: String) async throws {
        _ = try await api.updateCategory(id: id, name: name)
        await load()
    }

    func deleteCategory(id: Int) async {
        do {
            try await api.deleteCategory(id: id)
            categories.removeAll { $0.id == id }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func renameTag(oldTag: String, newTag: String) async throws {
        _ = try await api.renameTag(oldTag: oldTag, newTag: newTag)
        await load()
    }

    func deleteTag(tag: String) async {
        do {
            _ = try await api.deleteTag(tag: tag)
            tags.removeAll { $0.tag == tag }
        } catch {
            if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription }
        }
    }
}

private struct AdminTaxonomyView: View {
    @ObservedObject var session: AdminSessionModel
    @StateObject private var model: AdminTaxonomyModel
    @State private var showingCategoryEditor = false
    @State private var categoryEditingID: Int?
    @State private var categoryEditingName = ""
    @State private var showingTagEditor = false
    @State private var tagEditingName = ""
    @State private var pendingCategoryDelete: AdminCategory?
    @State private var pendingTagDelete: AdminTag?

    init(session: AdminSessionModel) {
        self.session = session
        _model = StateObject(wrappedValue: AdminTaxonomyModel(api: session.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AdminPreviewHeader(overline: "TAXONOMY", title: "分类与标签", subtitle: "文章筛选与编辑时使用的已有选项") {
                    Button {
                        categoryEditingID = nil
                        categoryEditingName = ""
                        showingCategoryEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(CreationIconButtonStyle())
                    .accessibilityLabel("新增分类")
                }

                if let errorMessage = model.errorMessage {
                    AdminErrorBanner(message: errorMessage)
                }
                if model.isLoading { ProgressView("正在读取分类与标签…").frame(maxWidth: .infinity).padding() }

                AdminSettingsCard(title: "分类", subtitle: "共 \(model.categories.count) 个分类") {
                    if model.categories.isEmpty {
                        Text("暂无分类")
                            .font(.subheadline)
                            .foregroundStyle(AdminDesign.muted)
                    } else {
                        ForEach(model.categories) { category in
                            AdminTaxonomyRow(title: category.name, detail: "\(category.postsCount ?? 0) 篇文章", symbol: "folder") {
                                    categoryEditingID = category.id
                                    categoryEditingName = category.name
                                    showingCategoryEditor = true
                            } onDelete: { pendingCategoryDelete = category }
                            if category.id != model.categories.last?.id { Divider() }
                        }
                    }
                }

                AdminSettingsCard(title: "标签", subtitle: "共 \(model.tags.count) 个标签") {
                    if model.tags.isEmpty {
                        Text("暂无标签")
                            .font(.subheadline)
                            .foregroundStyle(AdminDesign.muted)
                    } else {
                        ForEach(model.tags) { tag in
                            AdminTaxonomyRow(title: tag.tag, detail: "\(tag.count) 次使用", symbol: "number") {
                                    tagEditingName = tag.tag
                                    showingTagEditor = true
                            } onDelete: { pendingTagDelete = tag }
                            if tag.tag != model.tags.last?.tag { Divider() }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(AdminDesign.background)
        .adminNativeSwipeBack()
        .refreshable { await model.load() }
        .task {
            await model.load()
            if CreationPreview.isEnabled && CreationPreview.screen == "taxonomy-editor" { showingCategoryEditor = true }
        }
        .sheet(isPresented: $showingCategoryEditor) {
            AdminTaxonomyEditorSheet(
                title: categoryEditingID == nil ? "新增分类" : "编辑分类",
                initialName: categoryEditingName
            ) { name in
                if let categoryEditingID {
                    try await model.updateCategory(id: categoryEditingID, name: name)
                } else {
                    try await model.createCategory(name: name)
                }
            }
        }
        .sheet(isPresented: $showingTagEditor) {
            AdminTaxonomyEditorSheet(title: "重命名标签", initialName: tagEditingName) { name in
                try await model.renameTag(oldTag: tagEditingName, newTag: name)
            }
        }
        .confirmationDialog(
            "删除分类？",
            isPresented: Binding(get: { pendingCategoryDelete != nil }, set: { if !$0 { pendingCategoryDelete = nil } }),
            presenting: pendingCategoryDelete
        ) { category in
            Button("删除“\(category.name)”", role: .destructive) {
                Task { await model.deleteCategory(id: category.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { category in
            Text("删除分类不会删除文章，但会移除文章的分类归属。")
        }
        .confirmationDialog(
            "删除标签？",
            isPresented: Binding(get: { pendingTagDelete != nil }, set: { if !$0 { pendingTagDelete = nil } }),
            presenting: pendingTagDelete
        ) { tag in
            Button("删除“\(tag.tag)”", role: .destructive) {
                Task { await model.deleteTag(tag: tag.tag) }
            }
            Button("取消", role: .cancel) {}
        } message: { tag in
            Text("删除后会从文章和想法中移除这个标签。")
        }
    }
}

private struct AdminTaxonomyRow: View {
    let title: String
    let detail: String
    let symbol: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(CreationDesign.accent)
                .frame(width: 40, height: 44).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(CreationDesign.foreground)
                Text(detail).font(.caption).foregroundStyle(CreationDesign.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("编辑名称", systemImage: "pencil", action: onEdit)
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(CreationDesign.secondary) }
                .accessibilityLabel("\(title)的操作")
        }
    }
}

private struct AdminTaxonomyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialName: String
    let save: (String) async throws -> Void
    @State private var name: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(title: String, initialName: String, save: @escaping (String) async throws -> Void) {
        self.title = title
        self.initialName = initialName
        self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    AdminSettingsCard(title: "名称", subtitle: "简短清晰的名称，方便整理和查找。") {
                        AdminSettingsField(label: "显示名称", placeholder: "输入名称", text: $name)
                    }.disabled(isSaving)
                    if let errorMessage { CreationNotice(text: errorMessage, isError: true) }
                }.padding(20)
            }.background(CreationDesign.canvas)
            .safeAreaInset(edge: .bottom) {
                CreationSaveBar(title: "保存", message: initialName.isEmpty ? "创建一个新的文章分类" : "保存后更新已有名称", isSaving: isSaving, canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != initialName) {
                    Task {
                        isSaving = true
                        errorMessage = nil
                        defer { isSaving = false }
                        do { try await save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                        catch { if !isAdminRequestCancellation(error) { errorMessage = error.localizedDescription } }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
            }
        }.tint(CreationDesign.accent).interactiveDismissDisabled(isSaving)
    }
}

// MARK: - Shared UI

private struct AdminBottomNavVisibilityKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
    }
}

private enum AdminDesign {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let background = CreationDesign.canvas
    static let surface = CreationDesign.surface
    static let surfaceSoft = CreationDesign.soft
    static let foreground = CreationDesign.foreground
    static let muted = CreationDesign.secondary
    static let border = CreationDesign.border
    static let accent = CreationDesign.accent
    static let accentSoft = CreationDesign.accentSoft
    static let warning = adaptive(
        light: UIColor(red: 162.0 / 255.0, green: 108.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        dark: UIColor(red: 236.0 / 255.0, green: 183.0 / 255.0, blue: 99.0 / 255.0, alpha: 1)
    )
    static let warningSoft = adaptive(
        light: UIColor(red: 251.0 / 255.0, green: 239.0 / 255.0, blue: 217.0 / 255.0, alpha: 1),
        dark: UIColor(red: 76.0 / 255.0, green: 57.0 / 255.0, blue: 27.0 / 255.0, alpha: 1)
    )
    static let danger = adaptive(
        light: UIColor(red: 182.0 / 255.0, green: 76.0 / 255.0, blue: 76.0 / 255.0, alpha: 1),
        dark: UIColor(red: 245.0 / 255.0, green: 130.0 / 255.0, blue: 130.0 / 255.0, alpha: 1)
    )
    static let dangerSoft = adaptive(
        light: UIColor(red: 250.0 / 255.0, green: 226.0 / 255.0, blue: 226.0 / 255.0, alpha: 1),
        dark: UIColor(red: 78.0 / 255.0, green: 41.0 / 255.0, blue: 42.0 / 255.0, alpha: 1)
    )
}

private extension View {
    /// Re-enables the navigation controller's interactive-pop recognizer for
    /// admin destinations that use a custom header. This preserves UIKit's native
    /// progress-driven transition instead of dismissing at gesture end.
    func adminNativeSwipeBack() -> some View {
        background(AdminInteractivePopGestureBridge()).toolbar(.visible, for: .navigationBar).toolbar(.hidden, for: .tabBar).navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdminInteractivePopGestureBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AdminInteractivePopGestureController {
        AdminInteractivePopGestureController()
    }

    func updateUIViewController(_ uiViewController: AdminInteractivePopGestureController, context: Context) {
        uiViewController.enableInteractivePop()
    }
}

private final class AdminInteractivePopGestureController: UIViewController {
    override func loadView() {
        view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableInteractivePop()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        enableInteractivePop()
    }

    func enableInteractivePop() {
        DispatchQueue.main.async { [weak self] in
            guard let navigationController = self?.navigationController else { return }
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
            navigationController.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

private struct AdminPreviewHeader<Trailing: View>: View {
    let overline: String
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(
        overline: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.overline = overline
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(subtitle).font(.subheadline).foregroundStyle(AdminDesign.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }.padding(.vertical, 10).padding(.bottom, 8).navigationTitle(title)
    }
}

private struct AdminFilterScroll<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                content
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .padding(.bottom, 12)
    }
}

private struct AdminFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        CreationFilterChip(title: title, selected: selected, action: action)
    }
}

private struct AdminSectionTitle<Destination: View>: View {
    let title: String
    let actionTitle: String?
    let destination: Destination?

    init(title: String, actionTitle: String? = nil, destination: Destination? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.destination = destination
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AdminDesign.foreground)
            Spacer()
            if let actionTitle, let destination {
                NavigationLink(actionTitle) { destination.adminNativeSwipeBack() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AdminDesign.accent)
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 9)
    }
}

private struct AdminStatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(backgroundColor, in: Capsule())
    }

    fileprivate static func label(for status: String) -> String {
        switch status {
        case "published": return "已发布"
        case "draft": return "草稿"
        case "approved": return "已通过"
        case "pending": return "待审核"
        case "spam", "hidden": return "垃圾评论"
        default: return status
        }
    }

    private var label: String { Self.label(for: status) }

    private var color: Color {
        switch status {
        case "published", "approved": return AdminDesign.accent
        case "draft": return AdminDesign.warning
        case "pending": return AdminDesign.danger
        default: return AdminDesign.muted
        }
    }

    private var backgroundColor: Color {
        switch status {
        case "published", "approved": return AdminDesign.accentSoft
        case "draft": return AdminDesign.warningSoft
        case "pending": return AdminDesign.dangerSoft
        default: return AdminDesign.surfaceSoft
        }
    }
}

private struct AdminErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(AdminDesign.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AdminDesign.dangerSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AdminSmallActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AdminDesign.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(AdminDesign.accentSoft.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct AdminEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(AdminDesign.muted)
            Text(title)
                .font(.headline)
                .foregroundStyle(AdminDesign.foreground)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AdminDesign.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 34)
    }
}

private struct AdminImageView: View {
    let rawURL: String?
    let siteRoot: URL
    let size: CGSize
    let cornerRadius: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if CreationPreview.isEnabled {
                placeholder
            } else if let rawURL,
                      let url = SiteURLResolver(siteRoot: siteRoot).absoluteURL(rawURL) {
                RemoteImageView(url: url, loader: .shared, maxPixelSize: Int(ceil(max(size.width, size.height) * displayScale))) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum AdminFormatters {
    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func displayDate(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            let output = DateFormatter()
            output.locale = Locale(identifier: "zh_CN")
            output.dateFormat = "M月d日 HH:mm"
            return output.string(from: date)
        }
        return value.replacingOccurrences(of: "T", with: " ").prefix(16).description
    }

    static func displayDate(_ value: Date?) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: value)
    }

    static func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.first ?? "访").uppercased()
    }

    static func fileSize(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
    }
}

private func isAdminRequestCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let apiError = error as? APIError { return apiError.isCancellation }
    if let urlError = error as? URLError { return urlError.code == .cancelled }
    return false
}

func makeReferenceMarker(_ snapshot: AdminReferenceSnapshot, compact: Bool = false) -> String {
    guard let url = (snapshot.url ?? snapshot.canonicalUrl)?.trimmedNonEmpty else {
        return "!reference:"
    }
    let reference = ArticleReferenceSnapshot(
        url: url,
        canonicalURL: snapshot.canonicalUrl,
        title: snapshot.title,
        source: snapshot.source,
        author: snapshot.author,
        publishedAt: snapshot.publishedAt,
        cover: snapshot.cover,
        coverURL: snapshot.coverUrl,
        description: snapshot.description,
        summary: snapshot.summary,
        keyPoints: snapshot.keyPoints
    )
    if compact {
        return "!reference:\(MarkdownParser.referenceToken(for: reference))"
    }

    guard let data = try? JSONEncoder().encode(snapshot) else {
        return "!reference:\(url)"
    }
    let payload = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "!reference:\(payload)"
}

private func uploadMIMEType(for url: URL) -> String {
    if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
        return mime
    }
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "pdf": return "application/pdf"
    case "md": return "text/markdown"
    case "txt": return "text/plain"
    case "zip": return "application/zip"
    default: return "application/octet-stream"
    }
}
