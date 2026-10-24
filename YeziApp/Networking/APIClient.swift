import Foundation
import OSLog

enum APIError: LocalizedError, Sendable {
    case invalidURL
    case transport(String)
    case http(status: Int, message: String?)
    case decoding(String)
    case emptyData

    var isCancellation: Bool {
        if case .transport(let message) = self {
            return message == "请求已取消"
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "接口地址无效"
        case .transport(let message):
            return message.isEmpty ? "网络连接失败，请检查网络后重试" : message
        case .http(let status, let message):
            return message?.trimmedNonEmpty ?? "服务器返回错误（\(status)）"
        case .decoding(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "接口数据格式暂时无法识别" : "接口数据格式暂时无法识别：\(trimmed)"
        case .emptyData:
            return "接口没有返回可用数据"
        }
    }
}

func isRequestCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    if let apiError = error as? APIError, apiError.isCancellation { return true }
    return (error as NSError).domain == String(reflecting: CancellationError.self)
}

private func decodingFailureMessage(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else {
        return error.localizedDescription
    }

    func path(_ codingPath: [CodingKey]) -> String {
        let value = codingPath.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "根对象" : value
    }

    switch decodingError {
    case .keyNotFound(let key, let context):
        return "缺少字段 \(path(context.codingPath + [key]))"
    case .typeMismatch(let type, let context):
        return "字段 \(path(context.codingPath)) 类型不匹配（需要 \(type)）"
    case .valueNotFound(let type, let context):
        return "字段 \(path(context.codingPath)) 为空（需要 \(type)）"
    case .dataCorrupted(let context):
        return "字段 \(path(context.codingPath)) 数据损坏"
    @unknown default:
        return error.localizedDescription
    }
}

private func isHTMLDocument(_ data: Data) -> Bool {
    guard let body = String(data: data, encoding: .utf8) else { return false }
    let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.hasPrefix("<!doctype html")
        || normalized.hasPrefix("<html")
        || normalized.contains("<html lang=")
}

struct APIEndpoint: Equatable, Sendable {
    let path: String
    let queryItems: [URLQueryItem]

    init(path: String, queryItems: [URLQueryItem] = []) {
        self.path = path
        self.queryItems = queryItems
    }
}

final class APIClient: @unchecked Sendable {
    static let defaultBaseURL = URL(string: "https://yezi.me/api/v1")!

    let baseURL: URL
    let session: URLSession
    let urlCache: URLCache
    let responseCache: ResponseCache
    let diagnostics: DiagnosticsCenter
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "me.yezi.YeziApp", category: "API")

    init(
        baseURL: URL = APIClient.defaultBaseURL,
        session: URLSession? = nil,
        urlCache: URLCache? = nil,
        responseCache: ResponseCache = ResponseCache(),
        diagnostics: DiagnosticsCenter = DiagnosticsCenter()
    ) {
        self.baseURL = baseURL
        self.responseCache = responseCache
        self.diagnostics = diagnostics
        let configuredCache = urlCache ?? URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 30 * 1024 * 1024, diskPath: "YeziAPICache")
        self.urlCache = configuredCache

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = configuredCache
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            self.session = URLSession(configuration: configuration)
        }

        decoder = JSONDecoder()
    }

    func makeURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appendingPathComponent(trimmedPath)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    func getEnvelope<Value: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        as type: Value.Type = Value.self,
        cacheable: Bool = true
    ) async throws -> APIEnvelope<Value> {
        let data = try await requestData(method: "GET", path: path, queryItems: queryItems, body: nil, cacheable: cacheable)
        do {
            return try decoder.decode(APIEnvelope<Value>.self, from: data)
        } catch {
            throw APIError.decoding(decodingFailureMessage(error))
        }
    }

    func postEnvelope<Value: Decodable & Sendable, Body: Encodable & Sendable>(
        path: String,
        body: Body,
        as type: Value.Type = Value.self,
        visitorID: String? = nil
    ) async throws -> APIEnvelope<Value> {
        let encoded = try JSONEncoder().encode(body)
        let data = try await requestData(method: "POST", path: path, queryItems: [], body: encoded, cacheable: false, visitorID: visitorID)
        do {
            return try decoder.decode(APIEnvelope<Value>.self, from: data)
        } catch {
            throw APIError.decoding(decodingFailureMessage(error))
        }
    }

    private func requestData(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?,
        cacheable: Bool,
        visitorID: String? = nil
    ) async throws -> Data {
        guard let url = makeURL(path: path, queryItems: queryItems) else { throw APIError.invalidURL }
        let cacheKey = url.absoluteString
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = cacheable ? .useProtocolCachePolicy : .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YeziApp/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let visitorID, !visitorID.isEmpty {
            request.setValue(visitorID, forHTTPHeaderField: "X-Yezi-Visitor-Id")
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("服务器响应无效")
            }
            recordAPIVersion(from: http, url: url)
            guard (200..<300).contains(http.statusCode) else {
                let message = try? decoder.decode(APIErrorPayload.self, from: data).error
                throw APIError.http(status: http.statusCode, message: message ?? nil)
            }
            guard !data.isEmpty else { throw APIError.emptyData }
            if cacheable { await responseCache.store(data, for: cacheKey) }
            return data
        } catch {
            if isRequestCancellation(error) || Task.isCancelled { throw CancellationError() }
            if cacheable, let cached = await responseCache.data(for: cacheKey) {
                await diagnostics.record("网络请求失败，已使用公开离线缓存：\(url.path)")
                return cached
            }
            if let apiError = error as? APIError { throw apiError }
            logger.error("API request failed: \(url.path, privacy: .public)")
            throw APIError.transport(Self.userFacingTransportMessage(for: error))
        }
    }

    private static func userFacingTransportMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed:
            return "网络连接失败，请检查网络后重试"
        case .timedOut:
            return "网络请求超时，请稍后重试"
        case .cancelled:
            return "请求已取消"
        default:
            return "网络请求失败，请稍后重试"
        }
    }

    private func recordAPIVersion(from response: HTTPURLResponse, url: URL) {
        let version = response.value(forHTTPHeaderField: "X-API-Version")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version != "v1" else { return }
        let actual = version?.isEmpty == false ? version! : "缺失"
        Task {
            await diagnostics.record("API 版本异常：期望 v1，实际 \(actual)，请求 \(url.path)")
        }
    }
}

private struct APIErrorPayload: Decodable {
    let error: String?
}

final class ContentRepository: @unchecked Sendable {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func fetchSite() async throws -> SiteInfo {
        let envelope = try await api.getEnvelope(path: "site", as: SiteInfo.self)
        return envelope.data ?? SiteInfo(name: nil, subtitle: nil, description: nil, logo: nil, author: nil, aboutContent: nil, socialLinks: nil, navigation: nil)
    }

    func fetchPosts(page: Int, limit: Int = 20, category: String? = nil, tag: String? = nil) async throws -> PageResult<PostSummary> {
        var query = [URLQueryItem(name: "view", value: "summary"), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
        if let category, !category.isEmpty { query.append(URLQueryItem(name: "category", value: category)) }
        if let tag, !tag.isEmpty { query.append(URLQueryItem(name: "tag", value: tag)) }
        let envelope = try await api.getEnvelope(path: "posts", queryItems: query, as: [PostSummary].self)
        return PageResult(items: envelope.data ?? [], meta: normalizedMeta(envelope.meta, page: page, limit: limit, itemCount: envelope.data?.count ?? 0))
    }

    func fetchPost(slug: String) async throws -> PostDetail {
        let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? slug
        let envelope = try await api.getEnvelope(path: "posts/\(encodedSlug)", as: PostDetail.self)
        guard let post = envelope.data else { throw APIError.emptyData }
        return post
    }

    func fetchCategories() async throws -> [Category] {
        let envelope = try await api.getEnvelope(path: "categories", as: [Category].self)
        return envelope.data ?? []
    }

    func fetchTags() async throws -> [Tag] {
        let envelope = try await api.getEnvelope(path: "tags", queryItems: [URLQueryItem(name: "limit", value: "50")], as: [Tag].self)
        return envelope.data ?? []
    }

    func fetchMoments(page: Int, limit: Int = 20) async throws -> PageResult<Moment> {
        let envelope = try await api.getEnvelope(path: "moments", queryItems: pageQuery(page: page, limit: limit), as: [Moment].self)
        return PageResult(items: envelope.data ?? [], meta: normalizedMeta(envelope.meta, page: page, limit: limit, itemCount: envelope.data?.count ?? 0))
    }

    func fetchWorks(page: Int, limit: Int = 20) async throws -> PageResult<Work> {
        let envelope = try await api.getEnvelope(path: "works", queryItems: pageQuery(page: page, limit: limit), as: [Work].self)
        return PageResult(items: envelope.data ?? [], meta: normalizedMeta(envelope.meta, page: page, limit: limit, itemCount: envelope.data?.count ?? 0))
    }

    func fetchReferences(page: Int, limit: Int = 20, query: String? = nil, category: String? = nil) async throws -> PageResult<ReferenceLibraryItem> {
        var items = pageQuery(page: page, limit: limit)
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let category, !category.isEmpty { items.append(URLQueryItem(name: "category", value: category)) }
        let cacheable = query?.trimmedNonEmpty == nil
        let envelope = try await api.getEnvelope(path: "references", queryItems: items, as: [ReferenceLibraryItem].self, cacheable: cacheable)
        return PageResult(items: envelope.data ?? [], meta: normalizedMeta(envelope.meta, page: page, limit: limit, itemCount: envelope.data?.count ?? 0))
    }

    func search(query: String, page: Int = 1, limit: Int = 20) async throws -> PageResult<SearchResult> {
        let items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
        // Search terms are user input. Do not persist search responses in the
        // app's public offline cache or URLCache.
        let envelope = try await api.getEnvelope(path: "search", queryItems: items, as: [SearchResult].self, cacheable: false)
        return PageResult(items: envelope.data ?? [], meta: normalizedMeta(envelope.meta, page: page, limit: limit, itemCount: envelope.data?.count ?? 0))
    }

    func sendInteraction(targetType: String, targetID: Int, kind: String, visitorID: String) async throws -> ContentMetrics {
        let body = InteractionRequest(targetType: targetType, targetID: targetID, kind: kind)
        let envelope = try await api.postEnvelope(path: "interactions", body: body, as: ContentMetrics.self, visitorID: visitorID)
        return envelope.data ?? ContentMetrics(views: nil, likes: nil, liked: nil)
    }

    private func pageQuery(page: Int, limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
    }

    private func normalizedMeta(_ meta: PaginationMeta?, page: Int, limit: Int, itemCount: Int) -> PaginationMeta {
        meta ?? PaginationMeta(page: page, limit: limit, total: itemCount, totalPages: itemCount < limit ? page : page + 1)
    }
}

// MARK: - Native admin API

/// Session-only snapshots for page re-entry. Never shares the public/disk cache.
private actor AdminReadCache {
    private struct Value { let group: String; let data: Data }
    private struct Flight {
        let id: UUID
        let group: String
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }
    private var values: [URL: Value] = [:]
    private var flights: [URL: Flight] = [:]

    func data(for key: URL, group: String, reuseLoaded: Bool, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        if reuseLoaded, let value = values[key] { return value.data }
        if !reuseLoaded {
            values.removeValue(forKey: key)
            flights.removeValue(forKey: key)?.task.cancel()
        }
        let waiter = UUID()
        if flights[key] == nil {
            flights[key] = Flight(id: UUID(), group: group, task: Task { try await load() }, waiters: [])
        }
        flights[key]!.waiters.insert(waiter)
        let flight = flights[key]!
        do {
            let data = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                Task { await self.release(key, flightID: flight.id, waiter: waiter) }
            }
            try Task.checkCancellation()
            // A write or logout may have invalidated this read while it was running.
            guard flights[key]?.id == flight.id else { throw CancellationError() }
            // Bound memory even when many different searches are opened in one session.
            if data.count <= 8 * 1024 * 1024 {
                while !values.isEmpty && (values.count >= 64 || values.values.reduce(0, { $0 + $1.data.count }) + data.count > 8 * 1024 * 1024) {
                    values.removeValue(forKey: values.keys.first!)
                }
                values[key] = Value(group: group, data: data)
            }
            release(key, flightID: flight.id, waiter: waiter)
            return data
        } catch {
            release(key, flightID: flight.id, waiter: waiter)
            throw error
        }
    }

    private func release(_ key: URL, flightID: UUID, waiter: UUID) {
        guard flights[key]?.id == flightID else { return }
        flights[key]!.waiters.remove(waiter)
        if flights[key]!.waiters.isEmpty {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    func invalidate(groups: Set<String>? = nil) {
        values = values.filter { groups != nil && !groups!.contains($0.value.group) }
        for (key, flight) in flights where groups == nil || groups!.contains(flight.group) {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }
}

/// The private management API uses the same `admin_session` HttpOnly cookie as
/// the web admin. Keeping this client separate from the public API client makes
/// it impossible for admin requests to accidentally use the public cache.
final class AdminAPIClient: @unchecked Sendable {
    static let defaultSiteRoot = URL(string: "https://yezi.me")!
    private static let maxUploadBytes = 25 * 1024 * 1024

    let siteRoot: URL
    /// Called whenever an authenticated admin request receives 401. The
    /// session model uses this to return the app to the login screen instead
    /// of leaving a stale, apparently empty admin page on screen.
    var unauthorizedHandler: (() -> Void)?
    @MainActor lazy var commentStore = AdminCommentStore(api: self)
    @MainActor lazy var siteOverview = AdminSiteOverviewModel(api: self)
    private let session: URLSession
    private let decoder: JSONDecoder
    private let cookieStorage: HTTPCookieStorage
    private let readCache = AdminReadCache()

    init(siteRoot: URL = AdminAPIClient.defaultSiteRoot, session: URLSession? = nil) {
        self.siteRoot = siteRoot
        if let session {
            self.session = session
            self.cookieStorage = session.configuration.httpCookieStorage ?? HTTPCookieStorage.shared
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = HTTPCookieStorage.shared
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
            self.cookieStorage = HTTPCookieStorage.shared
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func hasLocalSessionCookie() -> Bool {
        adminCookie() != nil
    }

    /// An explicit page refresh also expires previously viewed filters/details.
    func discardLoadedData(for resources: Set<String>) async {
        await readCache.invalidate(groups: resources)
    }

    func login(password: String) async throws {
        await readCache.invalidate()
        let body = try JSONEncoder().encode(AdminLoginRequest(password: password))
        _ = try await requestData(method: "POST", url: siteRoot.appendingPathComponent("api/admin/login"), body: body)
    }

    func logout() async {
        await readCache.invalidate()
        await commentStore.clear()
        await siteOverview.clearPrivateData()
        let url = siteRoot.appendingPathComponent("api/admin/logout")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YeziAdmin-iOS/1.0", forHTTPHeaderField: "User-Agent")
        applyNativeAdminWriteHeaders(to: &request)
        _ = try? await session.data(for: request)
        clearLocalSessionCookie()
    }

    func fetchSession() async throws -> AdminSessionStatus {
        let envelope = try await get(path: "session", as: AdminSessionStatus.self)
        return try requireData(envelope)
    }

    func fetchDashboard(reuseLoaded: Bool = true) async throws -> AdminDashboard {
        let envelope = try await get(path: "dashboard", reuseLoaded: reuseLoaded, as: AdminDashboard.self)
        let value = try requireData(envelope)
        try Task.checkCancellation()
        await siteOverview.apply(dashboard: value)
        return value
    }

    func fetchPosts(page: Int = 1, limit: Int = 20, status: AdminPostFilter = .all, search: String = "", reuseLoaded: Bool = true) async throws -> AdminPage<AdminPostSummary> {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "status", value: status.rawValue),
        ]
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        let envelope = try await get(path: "posts", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminPostSummary].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func fetchPost(id: Int, reuseLoaded: Bool = true) async throws -> AdminPostDetail {
        let envelope = try await get(path: "posts/\(id)", reuseLoaded: reuseLoaded, as: AdminPostDetail.self)
        return try requireData(envelope)
    }

    func createPost(_ payload: AdminPostWriteRequest) async throws -> AdminPostDetail {
        let envelope = try await send(method: "POST", path: "posts", body: payload, as: AdminPostDetail.self)
        return try requireData(envelope)
    }

    func updatePost(id: Int, payload: AdminPostWriteRequest) async throws -> AdminPostDetail {
        let envelope = try await send(method: "PATCH", path: "posts/\(id)", body: payload, as: AdminPostDetail.self)
        return try requireData(envelope)
    }

    func deletePost(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "posts/\(id)")
    }

    func fetchComments(page: Int = 1, limit: Int = 20, status: AdminCommentFilter = .all, momentID: Int? = nil, reuseLoaded: Bool = true) async throws -> AdminPage<AdminComment> {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "status", value: status.rawValue),
        ]
        if let momentID {
            query += [URLQueryItem(name: "target_type", value: "moment"), URLQueryItem(name: "target_id", value: String(momentID))]
        }
        let envelope = try await get(path: "comments", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminComment].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func fetchComment(id: Int) async throws -> AdminComment {
        try requireData(await get(path: "comments/\(id)", as: AdminComment.self))
    }
    func registerPushDevice(_ value: YeziPushRegistration) async throws {
        _ = try await send(method: "POST", path: "push-devices", body: value, as: YeziPushAck.self)
    }
    func unregisterPushDevice(_ installationID: String) async throws {
        _ = try await send(method: "DELETE", path: "push-devices", body: YeziPushDeviceID(installation_id: installationID), as: YeziPushAck.self)
    }
    func testPushDevice(_ installationID: String) async throws {
        _ = try await send(method: "POST", path: "push-devices/test", body: YeziPushDeviceID(installation_id: installationID), as: YeziPushAck.self)
    }

    func updateComment(id: Int, action: AdminCommentAction, reply: String? = nil) async throws -> AdminComment {
        let envelope = try await send(method: "PATCH", path: "comments/\(id)", body: AdminCommentActionRequest(action: action.rawValue, reply: reply), as: AdminComment.self)
        let comment = try requireData(envelope)
        await commentStore.didUpdate(comment)
        return comment
    }

    func deleteComment(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "comments/\(id)")
        await commentStore.didDelete(id)
    }

    func fetchMoments(page: Int = 1, limit: Int = 20, reuseLoaded: Bool = true) async throws -> AdminPage<AdminMoment> {
        let query = pageQuery(page: page, limit: limit)
        let envelope = try await get(path: "moments", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminMoment].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func fetchBackups() async throws -> AdminBackupOverview {
        try requireData(await get(path: "native-backups", as: AdminBackupOverview.self))
    }

    func startBackup(action: String, kind: String, backupID: String? = nil) async throws -> AdminBackupJob {
        let body = AdminBackupOperation(action: action, kind: kind, backupId: backupID, confirmation: action == "restore" ? backupID : nil)
        return try requireData(await send(method: "POST", path: "native-backups", body: body, as: AdminBackupJob.self))
    }

    func downloadBackup(_ backup: AdminBackup) async throws -> URL {
        var request = URLRequest(url: makeURL(path: "native-backups/download", queryItems: [URLQueryItem(name: "id", value: backup.id)]))
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        let configuration = session.configuration
        configuration.timeoutIntervalForResource = 3600
        let downloadSession = URLSession(configuration: configuration)
        defer { downloadSession.finishTasksAndInvalidate() }
        let (temporary, response) = try await downloadSession.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            if (response as? HTTPURLResponse)?.statusCode == 401 { unauthorizedHandler?() }
            throw APIError.transport("下载失败，请确认登录状态或刷新备份列表。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yezi-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent((backup.name as NSString).lastPathComponent)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func createMoment(_ payload: AdminMomentWriteRequest) async throws -> AdminMoment {
        let envelope = try await send(method: "POST", path: "moments", body: payload, as: AdminMoment.self)
        return try requireData(envelope)
    }

    func updateMoment(id: Int, payload: AdminMomentWriteRequest) async throws -> AdminMoment {
        let envelope = try await send(method: "PATCH", path: "moments/\(id)", body: payload, as: AdminMoment.self)
        return try requireData(envelope)
    }

    func deleteMoment(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "moments/\(id)")
    }

    func fetchWorks(page: Int = 1, limit: Int = 20, reuseLoaded: Bool = false) async throws -> AdminPage<AdminWork> {
        let query = pageQuery(page: page, limit: limit)
        let envelope = try await get(path: "works", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminWork].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func createWork(_ payload: AdminWorkWriteRequest) async throws -> AdminWork {
        let envelope = try await send(method: "POST", path: "works", body: payload, as: AdminWork.self)
        return try requireData(envelope)
    }

    func updateWork(id: Int, payload: AdminWorkWriteRequest) async throws -> AdminWork {
        let envelope = try await send(method: "PATCH", path: "works/\(id)", body: payload, as: AdminWork.self)
        return try requireData(envelope)
    }

    func deleteWork(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "works/\(id)")
    }

    func fetchCategories(page: Int = 1, limit: Int = 100, reuseLoaded: Bool = false) async throws -> AdminPage<AdminCategory> {
        let query = pageQuery(page: page, limit: limit)
        let envelope = try await get(path: "categories", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminCategory].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func createCategory(name: String) async throws -> AdminCategory {
        let envelope = try await send(method: "POST", path: "categories", body: AdminCategoryCreateRequest(name: name), as: AdminCategory.self)
        return try requireData(envelope)
    }

    func updateCategory(id: Int, name: String) async throws -> AdminCategory {
        let envelope = try await send(method: "PATCH", path: "categories/\(id)", body: AdminCategoryCreateRequest(name: name), as: AdminCategory.self)
        return try requireData(envelope)
    }

    func deleteCategory(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "categories/\(id)")
    }

    func fetchTags(page: Int = 1, limit: Int = 100, reuseLoaded: Bool = false) async throws -> AdminPage<AdminTag> {
        let query = pageQuery(page: page, limit: limit)
        let envelope = try await get(path: "tags", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminTag].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func renameTag(oldTag: String, newTag: String) async throws -> AdminTagMutationResponse {
        let envelope = try await send(
            method: "PATCH",
            path: "tags",
            body: AdminTagRenameRequest(oldTag: oldTag, newTag: newTag),
            as: AdminTagMutationResponse.self
        )
        return try requireData(envelope)
    }

    func deleteTag(tag: String) async throws -> AdminTagMutationResponse {
        let envelope = try await send(
            method: "DELETE",
            path: "tags",
            body: AdminTagDeleteRequest(tag: tag),
            as: AdminTagMutationResponse.self
        )
        return try requireData(envelope)
    }

    func fetchAttachments(page: Int = 1, limit: Int = 50, postID: Int? = nil, reuseLoaded: Bool = true) async throws -> AdminPage<AdminAttachment> {
        var query = pageQuery(page: page, limit: limit)
        if let postID {
            query.append(URLQueryItem(name: "post_id", value: String(postID)))
        }
        let envelope = try await get(path: "attachments", queryItems: query, reuseLoaded: reuseLoaded, as: [AdminAttachment].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func downloadAttachment(path: String) async throws -> URL {
        guard let url = URL(string: path, relativeTo: siteRoot)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw APIError.invalidURL }
        do {
            let (temporaryURL, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw APIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "文件无法下载，请稍后重试")
            }
            return temporaryURL
        } catch {
            if isRequestCancellation(error) || Task.isCancelled { throw CancellationError() }
            if let apiError = error as? APIError { throw apiError }
            throw APIError.transport(Self.userFacingTransportMessage(for: error))
        }
    }

    func deleteAttachment(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "attachments/\(id)")
    }

    func compressAttachment(id: Int, profile: AdminAttachmentCompressionProfile = .balanced) async throws -> AdminAttachmentMaintenanceResult {
        let envelope = try await send(
            method: "POST",
            path: "attachments/\(id)/compress",
            body: AdminAttachmentCompressionRequest(profile: profile.rawValue),
            as: AdminAttachmentMaintenanceResult.self
        )
        return try requireData(envelope)
    }

    func compressUntrackedAttachment(path: String, profile: AdminAttachmentCompressionProfile = .balanced) async throws -> AdminAttachmentMaintenanceResult {
        let envelope = try await send(
            method: "POST",
            path: "attachments/untracked/compress",
            body: AdminUntrackedAttachmentRequest(path: path, profile: profile.rawValue),
            as: AdminAttachmentMaintenanceResult.self
        )
        return try requireData(envelope)
    }

    func cleanupUnusedAttachments() async throws -> AdminAttachmentMaintenanceResult {
        let envelope = try await send(
            method: "POST",
            path: "attachments/cleanup-unused",
            body: AdminConfirmationRequest(confirm: true),
            as: AdminAttachmentMaintenanceResult.self
        )
        return try requireData(envelope)
    }

    func deleteUntrackedAttachment(path: String) async throws -> AdminAttachmentMaintenanceResult {
        let envelope = try await send(
            method: "DELETE",
            path: "attachments/untracked",
            body: AdminUntrackedDeleteRequest(path: path, confirm: true),
            as: AdminAttachmentMaintenanceResult.self
        )
        return try requireData(envelope)
    }

    func cropAttachment(id: Int, x: Int, y: Int, width: Int, height: Int) async throws -> AdminAttachment {
        let body = try JSONEncoder().encode(AdminAttachmentCropRequest(x: x, y: y, width: width, height: height))
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/attachments/\(id)/crop"),
            body: body
        )
        return try decodeDirect(response, as: AdminAttachmentCropResponse.self).attachment
    }

    func fetchSettings(reuseLoaded: Bool = false) async throws -> [String: String] {
        let envelope = try await get(path: "settings", reuseLoaded: reuseLoaded, as: AdminStringMap.self)
        let values = try requireData(envelope).values
        try Task.checkCancellation()
        await siteOverview.apply(settings: values)
        return values
    }

    func updateSettings(_ values: [String: String]) async throws -> [String: String] {
        let envelope = try await send(method: "PATCH", path: "settings", body: values, as: AdminStringMap.self)
        let updated = try requireData(envelope).values
        await siteOverview.apply(settings: updated)
        return updated
    }

    func uploadFile(data: Data, filename: String, mimeType: String, postID: Int? = nil, original: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) async throws -> AdminAttachment {
        guard !data.isEmpty else { throw APIError.emptyData }
        guard data.count <= Self.maxUploadBytes else {
            throw APIError.transport("文件不能超过 25 MB，请压缩后重试")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(name: "original", value: original ? "true" : "false", boundary: boundary)
        if let postID {
            body.appendMultipartField(name: "post_id", value: String(postID), boundary: boundary)
        }
        body.appendMultipartFile(name: "file", filename: filename, mimeType: mimeType, data: data, boundary: boundary)
        body.append(Data("--\(boundary)--\r\n".utf8))

        let response = try await requestData(
            method: "POST",
            url: siteRoot.appendingPathComponent("api/admin/upload"),
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            uploadProgress: progress
        )
        do {
            return try decoder.decode(AdminUploadResponse.self, from: response).attachment
        } catch {
            throw APIError.decoding(decodingFailureMessage(error))
        }
    }

    func searchQQMusic(query: String, type: AdminMusicSearchType) async throws -> AdminMusicSearchResult {
        var components = URLComponents(url: siteRoot.appendingPathComponent("api/admin/qq-music"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "op", value: "search"),
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "q", value: query),
        ]
        guard let url = components?.url else { throw APIError.invalidURL }
        let response = try await requestData(method: "GET", url: url, body: nil)
        do {
            return try decoder.decode(AdminMusicSearchResult.self, from: response)
        } catch {
            throw APIError.decoding(decodingFailureMessage(error))
        }
    }

    /// Resolves a song by its exact QQ Music MID. This is intentionally the
    /// public playback metadata endpoint, not the admin keyword-search
    /// endpoint: searching with a MID may return an unrelated first result.
    func fetchQQMusicTrack(id: String) async throws -> AdminMusicTrack {
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/music/qq", queryItems: [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "type", value: "track"),
            ]),
            body: nil
        )
        return try decodeDirect(response, as: AdminMusicTrack.self)
    }

    /// Song details do not depend on resolving a playable audio URL.
    func fetchQQMusicMetadata(id: String) async throws -> AdminMusicTrack {
        let url = makeSiteURL(path: "api/music/qq", queryItems: [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "type", value: "metadata"),
            ])
        let response = try await readCache.data(for: url, group: "music-metadata", reuseLoaded: true) { [self] in
            let data = try await requestData(method: "GET", url: url, body: nil)
            _ = try decodeDirect(data, as: AdminMusicTrack.self)
            return data
        }
        return try decodeDirect(response, as: AdminMusicTrack.self)
    }

    func fetchLyrics(source: String, reuseLoaded: Bool = true) async throws -> String {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") { return source }
        guard let url = URL(string: source, relativeTo: siteRoot)?.absoluteURL,
              url.scheme == siteRoot.scheme, url.host == siteRoot.host, url.port == siteRoot.port,
              url.path.hasPrefix(siteRoot.path + (siteRoot.path.hasSuffix("/") ? "api/music/" : "/api/music/")) else {
            throw APIError.transport("歌词地址不可用")
        }
        let data = try await readCache.data(for: url, group: "lyrics", reuseLoaded: reuseLoaded) { [self] in
            let data = try await requestData(method: "GET", url: url, body: nil)
            guard data.count <= 512 * 1024, String(data: data, encoding: .utf8) != nil else { throw APIError.transport("歌词格式不可用") }
            return data
        }
        guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { throw APIError.transport("歌词格式不可用") }
        return text
    }

    func articleShortLink(id: Int) async throws -> URL {
        struct ShortLink: Decodable { let code: String; let path: String }
        let url = makeSiteURL(path: "api/posts/\(id)/short-link")
        let data = try await readCache.data(for: url, group: "posts", reuseLoaded: true) { [self] in
            let data = try await requestData(method: "POST", url: url, body: nil)
            let value = try decodeDirect(data, as: ShortLink.self)
            guard value.code.range(of: "^[A-Za-z0-9]{8}$", options: .regularExpression) != nil,
                  value.path == "/" + value.code else { throw APIError.transport("网站返回了无效短链接") }
            return data
        }
        let value = try decodeDirect(data, as: ShortLink.self)
        guard value.code.range(of: "^[A-Za-z0-9]{8}$", options: .regularExpression) != nil,
              value.path == "/" + value.code else { throw APIError.transport("网站返回了无效短链接") }
        return siteRoot.appendingPathComponent(value.code)
    }

    /// Resolves a playlist by its exact ID. The public endpoint returns the
    /// playable tracks and total count, which is enough for a truthful
    /// placeholder even when the playlist title is not part of the response.
    func fetchQQMusicPlaylistTracks(id: String) async throws -> AdminQQMusicPlaylistPlaybackResponse {
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/music/qq", queryItems: [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "type", value: "playlist"),
            ]),
            body: nil
        )
        return try decodeDirect(response, as: AdminQQMusicPlaylistPlaybackResponse.self)
    }

    /// Browse metadata without resolving audio for every row. Older websites return
    /// only their first page; nextOffset stays nil and the UI reports partial data.
    func fetchQQMusicPlaylistMetadata(id: String, offset: Int = 0) async throws -> AdminMusicMetadataPage {
        let url = makeSiteURL(path: "api/music/qq", queryItems: [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "type", value: "playlist-metadata"),
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "50")
        ])
        let response = try await readCache.data(for: url, group: "music-metadata", reuseLoaded: true) { [self] in
            let data = try await requestData(method: "GET", url: url, body: nil)
            _ = try decodeDirect(data, as: AdminMusicMetadataPage.self)
            return data
        }
        return try decodeDirect(response, as: AdminMusicMetadataPage.self)
    }

    func fetchQQMusicStatus() async throws -> AdminQQMusicStatus {
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/admin/qq-music", queryItems: [URLQueryItem(name: "op", value: "status")]),
            body: nil
        )
        return try decodeDirect(response, as: AdminQQMusicStatus.self)
    }

    func fetchQQMusicQR(channel: String = "qq") async throws -> AdminQQMusicQR {
        let operation = channel == "qqmusic" ? "native-qr" : "qr"
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/admin/qq-music", queryItems: [URLQueryItem(name: "op", value: operation)]),
            body: nil
        )
        return try decodeDirect(response, as: AdminQQMusicQR.self)
    }

    func pollQQMusicLogin(qrsig: String, ptqrtoken: String) async throws -> AdminQQMusicPollResult {
        let body = try JSONEncoder().encode(AdminQQMusicPollRequest(op: "poll", qrsig: qrsig, ptqrtoken: ptqrtoken))
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/qq-music"),
            body: body
        )
        return try decodeDirect(response, as: AdminQQMusicPollResult.self)
    }

    func pollNativeQQMusicLogin(key: String) async throws -> AdminQQMusicPollResult {
        let body = try JSONEncoder().encode(AdminQQMusicNativePollRequest(op: "native-poll", key: key))
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/qq-music"),
            body: body
        )
        return try decodeDirect(response, as: AdminQQMusicPollResult.self)
    }

    func cancelNativeQQMusicLogin(key: String) async {
        guard !key.isEmpty else { return }
        let body = try? JSONEncoder().encode(AdminQQMusicNativePollRequest(op: "native-cancel", key: key))
        guard let body else { return }
        _ = try? await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/qq-music"),
            body: body
        )
    }

    func fetchQQMusicPlaylists(reuseLoaded: Bool = false) async throws -> AdminQQMusicPlaylistResponse {
        let url = makeSiteURL(path: "api/admin/qq-music", queryItems: [URLQueryItem(name: "op", value: "playlists")])
        let response = try await readCache.data(for: url, group: "music-playlists", reuseLoaded: reuseLoaded) { [self] in
            try await requestData(method: "GET", url: url, body: nil)
        }
        return try decodeDirect(response, as: AdminQQMusicPlaylistResponse.self)
    }

    func fetchReferenceHistory(query: String = "") async throws -> [AdminReferenceSnapshot] {
        var queryItems: [URLQueryItem] = []
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/admin/article-references/history", queryItems: queryItems),
            body: nil
        )
        return try decodeDirect(response, as: AdminReferenceHistoryResponse.self).references
    }

    func previewReference(url: String, cacheReader: Bool = false, cacheImages: Bool = false) async throws -> AdminReferenceSnapshot {
        let body = try JSONEncoder().encode(AdminReferencePreviewRequest(url: url, cacheReader: cacheReader, cacheImages: cacheImages))
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/article-references/preview"),
            body: body
        )
        return try decodeDirect(response, as: AdminReferencePreviewResponse.self).snapshot
    }

    /// Generates the optional AI summary shown by the web reference manager.
    /// This endpoint is intentionally separate from preview: a missing AI
    /// configuration must not prevent a reference from being inserted.
    func summarizeReference(url: String) async throws -> AdminReferenceSummaryResult {
        let body = try JSONEncoder().encode(AdminReferenceURLRequest(url: url))
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/article-references/summarize"),
            body: body
        )
        let payload = try decodeDirect(response, as: AdminReferenceSummaryPayload.self)
        return payload.data ?? AdminReferenceSummaryResult(
            configured: payload.configured,
            summary: payload.summary,
            keyPoints: payload.keyPoints,
            error: payload.error
        )
    }

    /// Starts or reuses the server-side reader cache job used by the web
    /// admin. The caller can poll fetchReferenceArchiveJob until completion.
    func startReferenceArchive(url: String, cacheImages: Bool = true) async throws -> AdminReferenceArchiveResponse {
        let body = try JSONEncoder().encode(AdminReferenceArchiveRequest(url: url, cacheImages: cacheImages))
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/article-references/archive"),
            body: body
        )
        return try decodeArchiveResponse(response)
    }

    func fetchReferenceArchiveJob(id: String) async throws -> AdminReferenceArchiveResponse {
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/admin/article-references/archive", queryItems: [URLQueryItem(name: "job", value: id)]),
            body: nil
        )
        return try decodeArchiveResponse(response)
    }

    func fetchReferenceLibrary(page: Int = 1, limit: Int = 50, query: String = "", reuseLoaded: Bool = false) async throws -> AdminPage<ReferenceLibraryItem> {
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        let envelope = try await get(path: "references", queryItems: queryItems, reuseLoaded: reuseLoaded, as: [ReferenceLibraryItem].self)
        return try makePage(envelope, page: page, limit: limit)
    }

    func saveReferenceLibrary(snapshot: AdminReferenceSnapshot, category: String = "", tags: String = "") async throws -> ReferenceLibraryItem {
        let envelope = try await send(
            method: "POST",
            path: "references",
            body: AdminReferenceLibraryCreateRequest(snapshot: snapshot, category: category, tags: tags),
            as: ReferenceLibraryItem.self
        )
        return try requireData(envelope)
    }

    func fetchReference(id: Int) async throws -> ReferenceLibraryItem {
        let envelope = try await get(path: "references/\(id)", as: ReferenceLibraryItem.self)
        return try requireData(envelope)
    }

    func fetchReferenceReader(id: Int) async throws -> AdminReferenceReader {
        let envelope = try await get(path: "references/\(id)/reader", as: AdminReferenceReader.self)
        return try requireData(envelope)
    }

    func updateReferenceMetadata(id: Int, category: String, tags: String) async throws -> ReferenceLibraryItem {
        let envelope = try await send(
            method: "PATCH",
            path: "references/\(id)",
            body: AdminReferenceMetadataRequest(category: category, tags: tags),
            as: ReferenceLibraryItem.self
        )
        return try requireData(envelope)
    }

    func deleteReference(id: Int) async throws {
        _ = try await sendWithoutBody(method: "DELETE", path: "references/\(id)")
    }

    func deleteReferences(ids: [Int]) async throws -> AdminReferenceBulkDeleteResult {
        let envelope = try await send(
            method: "POST",
            path: "references/bulk-delete",
            body: AdminReferenceBulkDeleteRequest(ids: ids),
            as: AdminReferenceBulkDeleteResult.self
        )
        return try requireData(envelope)
    }

    func attachReferenceToPost(postID: Int, snapshot: AdminReferenceSnapshot) async throws -> AdminPostDetail {
        let envelope = try await send(
            method: "POST",
            path: "posts/\(postID)/references",
            body: AdminReferenceAttachRequest(snapshot: snapshot),
            as: AdminPostDetail.self
        )
        return try requireData(envelope)
    }

    func fetchDeployStatus() async throws -> AdminDeployStatus {
        let envelope = try await get(path: "deploy/status", as: AdminDeployStatus.self)
        return try requireData(envelope)
    }

    func fetchDeployVersion() async throws -> AdminDeployVersionStatus {
        let envelope = try await get(path: "deploy/version", as: AdminDeployVersionStatus.self)
        return try requireData(envelope)
    }

    /// The release deployer verifies this endpoint before reporting success.
    /// Reading it from the app confirms that the selected domain now serves the
    /// switched release, including direct-process deployments without PM2.
    func fetchDeploymentHealth() async throws -> AdminDeploymentHealth {
        let response = try await requestData(
            method: "GET",
            url: makeSiteURL(path: "api/health/deploy"),
            body: nil
        )
        return try decodeDirect(response, as: AdminDeploymentHealth.self)
    }

    func syncDeployment() async throws -> AdminDeployActionResult {
        let envelope = try await send(method: "POST", path: "deploy/sync", body: AdminEmptyRequest(), as: AdminDeployActionResult.self)
        return try requireData(envelope)
    }

    func fetchTelegramStatus() async throws -> AdminTelegramStatus {
        let response = try await requestData(method: "GET", url: makeSiteURL(path: "api/admin/telegram"), body: nil)
        return try decoder.decode(AdminTelegramStatus.self, from: response)
    }

    func testTelegram() async throws -> AdminTelegramActionResult {
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/telegram"),
            body: try JSONEncoder().encode(AdminTelegramOperation(op: "test"))
        )
        return try decoder.decode(AdminTelegramActionResult.self, from: response)
    }

    func checkTelegram() async throws -> AdminTelegramCheckResult {
        let response = try await requestData(
            method: "POST",
            url: makeSiteURL(path: "api/admin/telegram"),
            body: try JSONEncoder().encode(AdminTelegramOperation(op: "check"))
        )
        return try decoder.decode(AdminTelegramCheckResult.self, from: response)
    }

    private func get<Value: Decodable & Sendable>(path: String, queryItems: [URLQueryItem] = [], reuseLoaded: Bool? = nil, as type: Value.Type) async throws -> AdminEnvelope<Value> {
        let url = makeURL(path: path, queryItems: queryItems)
        guard let reuseLoaded else {
            return try decodeEnvelope(await requestData(method: "GET", url: url, body: nil), as: type)
        }
        let data = try await readCache.data(for: url, group: String(path.split(separator: "/")[0]), reuseLoaded: reuseLoaded) { [self] in
            let data = try await requestData(method: "GET", url: url, body: nil)
            // Failed/invalid responses must remain retryable, rather than becoming snapshots.
            _ = try requireData(decodeEnvelope(data, as: type))
            return data
        }
        return try decodeEnvelope(data, as: type)
    }

    private func invalidateReads(afterWriting url: URL) async {
        let parts = url.pathComponents
        guard let admin = parts.lastIndex(of: "admin"), parts.count > admin + 1 else { return }
        let tail = Array(parts.dropFirst(admin + 1).filter { $0 != "v1" })
        guard let resource = tail.first else { return }
        var groups: Set<String> = [resource]
        switch resource {
        case "posts", "moments", "works", "references": groups.formUnion(["dashboard", "attachments", "categories", "tags", "comments"])
        case "categories", "tags": groups.formUnion(["posts", "moments", "dashboard"])
        case "comments": groups.formUnion(["moments", "dashboard"])
        case "attachments", "upload": groups.formUnion(["attachments", "dashboard"])
        case "settings": groups.insert("attachments")
        case "qq-music": groups.formUnion(["music-metadata", "music-playlists", "lyrics"])
        case "native-backups" where tail.contains("restore"):
            await readCache.invalidate(); return
        default: break
        }
        await readCache.invalidate(groups: groups)
        if groups.contains("dashboard") { await siteOverview.invalidateStatistics() }
    }

    private func send<Value: Decodable & Sendable, Body: Encodable & Sendable>(method: String, path: String, body: Body, as type: Value.Type) async throws -> AdminEnvelope<Value> {
        let data = try JSONEncoder().encode(body)
        let response = try await requestData(method: method, url: makeURL(path: path), body: data)
        return try decodeEnvelope(response, as: type)
    }

    private func sendWithoutBody(method: String, path: String) async throws -> Data {
        try await requestData(method: method, url: makeURL(path: path), body: nil)
    }

    private func decodeEnvelope<Value: Decodable & Sendable>(_ data: Data, as type: Value.Type) throws -> AdminEnvelope<Value> {
        do {
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object.keys.contains("data") {
                return try decoder.decode(AdminEnvelope<Value>.self, from: data)
            }
            return AdminEnvelope(data: try decoder.decode(Value.self, from: data), meta: nil)
        } catch {
            throw APIError.decoding(decodingFailureMessage(error))
        }
    }

    private func decodeDirect<Value: Decodable>(_ data: Data, as type: Value.Type) throws -> Value {
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(decodingFailureMessage(error))
        }
    }

    private func decodeArchiveResponse(_ data: Data) throws -> AdminReferenceArchiveResponse {
        let direct = try decodeDirect(data, as: AdminReferenceArchiveResponse.self)
        if direct.job != nil || direct.reused != nil || direct.error != nil {
            return direct
        }
        if let envelope = try? decodeDirect(data, as: AdminReferenceArchiveEnvelope.self), let nested = envelope.data {
            return nested
        }
        return direct
    }

    private func requireData<Value>(_ envelope: AdminEnvelope<Value>) throws -> Value {
        guard let data = envelope.data else { throw APIError.emptyData }
        return data
    }

    private func makePage<Value>(_ envelope: AdminEnvelope<[Value]>, page: Int, limit: Int) throws -> AdminPage<Value> {
        let items = try requireData(envelope)
        return AdminPage(items: items, meta: envelope.meta ?? AdminPaginationMeta(page: page, limit: limit, total: nil, totalPages: items.count < limit ? page : page + 1))
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var url = siteRoot.appendingPathComponent("api/admin/v1").appendingPathComponent(path)
        if !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        return url
    }

    private func makeSiteURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var url = siteRoot.appendingPathComponent(path)
        if !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        return url
    }

    private func requestData(method: String, url: URL, body: Data?, contentType: String = "application/json", uploadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("YeziAdmin-iOS/1.0", forHTTPHeaderField: "User-Agent")
        applyNativeAdminWriteHeaders(to: &request)
        request.httpBody = body

        do {
            let data: Data
            let response: URLResponse
            if let uploadProgress, let body {
                request.httpBody = nil
                (data, response) = try await session.upload(for: request, from: body, delegate: CreationUploadProgress(report: uploadProgress))
            } else {
                (data, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.transport("服务器响应无效") }
            if http.statusCode == 401 {
                await readCache.invalidate()
                clearLocalSessionCookie()
                unauthorizedHandler?()
            }
            if isHTMLDocument(data) {
                throw APIError.http(status: http.statusCode, message: "后台接口尚未部署或路径不正确（服务器返回了网页 HTML）")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode, message: decodeErrorMessage(data))
            }
            guard !data.isEmpty else { throw APIError.emptyData }
            if !["GET", "HEAD", "OPTIONS"].contains(method) { await invalidateReads(afterWriting: url) }
            return data
        } catch {
            if isRequestCancellation(error) || Task.isCancelled { throw CancellationError() }
            if let apiError = error as? APIError { throw apiError }
            throw APIError.transport(Self.userFacingTransportMessage(for: error))
        }
    }

    private func adminCookie() -> HTTPCookie? {
        cookieStorage.cookies(for: siteRoot)?.first(where: { $0.name == "admin_session" })
    }

    /// The website protects cookie-authenticated writes with a same-origin
    /// check. Native URLSession requests do not create browser Origin/CSRF
    /// headers automatically, so provide the selected site's canonical origin
    /// for every non-read-only admin operation.
    private func applyNativeAdminWriteHeaders(to request: inout URLRequest) {
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard !["GET", "HEAD", "OPTIONS"].contains(method) else { return }
        guard let origin = canonicalSiteOrigin else { return }
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-Yezi-CSRF")
    }

    private var canonicalSiteOrigin: String? {
        guard let scheme = siteRoot.scheme?.lowercased(),
              let host = siteRoot.host?.lowercased() else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = siteRoot.port
        return components.url?.absoluteString
    }

    private func clearLocalSessionCookie() {
        if let cookie = adminCookie() { cookieStorage.deleteCookie(cookie) }
    }

    private func pageQuery(page: Int, limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
    }

    private func decodeErrorMessage(_ data: Data) -> String? {
        if isHTMLDocument(data) {
            return "后台接口尚未部署或路径不正确（服务器返回了网页 HTML）"
        }
        if let payload = try? decoder.decode(AdminErrorPayload.self, from: data) {
            return payload.message
        }
        guard let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if body.count > 300 {
            return String(body.prefix(300)) + "…"
        }
        return body
    }

    private static func userFacingTransportMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
            return "网络连接失败，请检查网络后重试"
        case .timedOut:
            return "网络请求超时，请稍后重试"
        case .cancelled:
            return "请求已取消"
        default:
            return "网络请求失败，请稍后重试"
        }
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        let safeFilename = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeFilename)\"\r\n".utf8))
        append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}

private struct AdminLoginRequest: Encodable, Sendable {
    let password: String
}

struct AdminEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value?
    let meta: AdminPaginationMeta?
}

/// Settings are persisted as strings by the web admin, but older deployments
/// sometimes serialize booleans or numbers as JSON scalars. Normalizing those
/// scalars here keeps the SwiftUI settings controls type-stable.
struct AdminStringMap: Decodable, Sendable {
    let values: [String: String]

    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        let intValue: Int? = nil
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var result: [String: String] = [:]
        for key in container.allKeys {
            // Settings are a dynamic map. The admin decoder uses
            // convertFromSnakeCase for the rest of the API, which can turn
            // keys such as `site_name` into `siteName` before they reach this
            // container. Normalize both spellings back to the web setting
            // names used by the SwiftUI bindings.
            if ["data", "settings", "values"].contains(key.stringValue),
               let nestedDecoder = try? container.superDecoder(forKey: key),
               let nestedValues = try? AdminStringMap(from: nestedDecoder).values {
                result.merge(nestedValues) { _, new in new }
                continue
            }
            let normalizedKey = Self.snakeCase(key.stringValue)
            if let string = try? container.decode(String.self, forKey: key) {
                result[normalizedKey] = string
            } else if let bool = try? container.decode(Bool.self, forKey: key) {
                result[normalizedKey] = bool ? "1" : "0"
            } else if let int = try? container.decode(Int.self, forKey: key) {
                result[normalizedKey] = String(int)
            } else if let double = try? container.decode(Double.self, forKey: key) {
                result[normalizedKey] = String(double)
            }
        }
        values = result
    }

    private static func snakeCase(_ value: String) -> String {
        var result = ""
        for character in value {
            if character.isUppercase {
                if !result.isEmpty { result.append("_") }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}

struct AdminPaginationMeta: Decodable, Sendable {
    let page: Int?
    let limit: Int?
    let total: Int?
    let totalPages: Int?

    init(page: Int?, limit: Int?, total: Int?, totalPages: Int?) {
        self.page = page
        self.limit = limit
        self.total = total
        self.totalPages = totalPages
    }

    private enum CodingKeys: String, CodingKey {
        case page, limit, total, totalPages, count, pages
        case currentPage, currentPageSnake = "current_page"
        case perPage, perPageSnake = "per_page"
        case totalCount, totalCountSnake = "total_count"
        case totalPagesSnake = "total_pages"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(Int.self, forKey: .page)
            ?? container.decodeIfPresent(Int.self, forKey: .currentPage)
            ?? container.decodeIfPresent(Int.self, forKey: .currentPageSnake)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
            ?? container.decodeIfPresent(Int.self, forKey: .perPage)
            ?? container.decodeIfPresent(Int.self, forKey: .perPageSnake)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCount)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCountSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .count)
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
            ?? container.decodeIfPresent(Int.self, forKey: .totalPagesSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .pages)
    }
}

private struct AdminErrorPayload: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey { case error, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let directMessage = try? container.decode(String.self, forKey: .message) {
            message = directMessage
            return
        }
        if let string = try? container.decode(String.self, forKey: .error) {
            message = string
            return
        }
        if let object = try? container.decode(AdminErrorBody.self, forKey: .error) {
            message = object.message
            return
        }
        message = nil
    }
}

private struct AdminErrorBody: Decodable {
    let message: String?
}

struct AdminPage<Item: Sendable>: Sendable {
    let items: [Item]
    let meta: AdminPaginationMeta
}

struct AdminSessionStatus: Decodable, Sendable {
    let authenticated: Bool
    let createdAt: String?
    let expiresAt: Int64?
}

struct AdminDashboard: Decodable, Sendable {
    let posts: AdminPostCounts?
    let comments: AdminCommentCounts?
    let moments: Int?
    let works: Int?
    let attachments: Int?
    let metrics: ContentMetrics?
    let recentPosts: [AdminPostSummary]
    let recentComments: [AdminComment]

    private enum CodingKeys: String, CodingKey {
        case posts, comments, moments, works, attachments, metrics, recentPosts, recentComments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        posts = try container.decodeIfPresent(AdminPostCounts.self, forKey: .posts)
        comments = try container.decodeIfPresent(AdminCommentCounts.self, forKey: .comments)
        moments = try container.decodeIfPresent(Int.self, forKey: .moments)
        works = try container.decodeIfPresent(Int.self, forKey: .works)
        attachments = try container.decodeIfPresent(Int.self, forKey: .attachments)
        metrics = try container.decodeIfPresent(ContentMetrics.self, forKey: .metrics)
        recentPosts = try container.decodeIfPresent([AdminPostSummary].self, forKey: .recentPosts) ?? []
        recentComments = try container.decodeIfPresent([AdminComment].self, forKey: .recentComments) ?? []
    }

    init(posts: AdminPostCounts? = nil, comments: AdminCommentCounts? = nil, moments: Int? = nil, works: Int? = nil, attachments: Int? = nil, metrics: ContentMetrics? = nil, recentPosts: [AdminPostSummary] = [], recentComments: [AdminComment] = []) {
        self.posts = posts
        self.comments = comments
        self.moments = moments
        self.works = works
        self.attachments = attachments
        self.metrics = metrics
        self.recentPosts = recentPosts
        self.recentComments = recentComments
    }
}

struct AdminPostCounts: Decodable, Sendable {
    let total: Int?
    let published: Int?
    let draft: Int?
}

struct AdminCommentCounts: Decodable, Sendable {
    let pending: Int?
}

private final class CreationUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

struct AdminPostSummary: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let slug: String
    let cover: String?
    let category: String
    let tags: [String]
    let status: String
    let createdAt: String?
    let updatedAt: String?
    let metrics: ContentMetrics?
    var excerpt: String? = nil
}

struct AdminPostDetail: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let slug: String
    let content: String
    let cover: String?
    let category: String
    let tags: [String]
    let status: String
    let createdAt: String?
    let updatedAt: String?
    let metrics: ContentMetrics?
    let attachmentIds: [Int]
    let referenceSnapshots: [AdminReferenceSnapshot]

    private enum CodingKeys: String, CodingKey {
        case id, title, slug, content, cover, category, tags, status, metrics
        case createdAt, createdSnake = "created_at"
        case updatedAt, updatedSnake = "updated_at"
        case attachmentIds, attachmentSnake = "attachment_ids"
        case referenceSnapshots, referenceSnake = "reference_snapshots", references
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        guard id > 0 else { throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "无效文章 ID") }
        title = try container.decode(String.self, forKey: .title)
        slug = try container.decode(String.self, forKey: .slug)
        content = try container.decode(String.self, forKey: .content)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        status = try container.decode(String.self, forKey: .status)
        guard ["draft", "published"].contains(status) else { throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "未知文章状态") }
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .createdSnake)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .updatedSnake)
        metrics = try container.decodeIfPresent(ContentMetrics.self, forKey: .metrics)
        attachmentIds = try container.decodeIfPresent([Int].self, forKey: .attachmentIds)
            ?? container.decodeIfPresent([Int].self, forKey: .attachmentSnake)
            ?? []
        let primaryReferences = try container.decodeIfPresent([AdminReferenceSnapshot].self, forKey: .referenceSnapshots) ?? []
        let snakeReferences = try container.decodeIfPresent([AdminReferenceSnapshot].self, forKey: .referenceSnake) ?? []
        let aliasReferences = try container.decodeIfPresent([AdminReferenceSnapshot].self, forKey: .references) ?? []
        referenceSnapshots = primaryReferences.isEmpty ? (snakeReferences.isEmpty ? aliasReferences : snakeReferences) : primaryReferences
    }
}

struct AdminReferenceSnapshot: Codable, Sendable {
    let url: String?
    let canonicalUrl: String?
    let title: String?
    let source: String?
    let author: String?
    let publishedAt: String?
    let cover: String?
    let coverUrl: String?
    let description: String?
    let summary: String?
    let keyPoints: [String]?

    private enum CodingKeys: String, CodingKey {
        case url, link, href, title, name, source, sourceName, site, author
        case canonicalUrl, canonicalURL, canonicalSnake = "canonical_url"
        case publishedAt, publishedSnake = "published_at"
        case cover, image, coverUrl, coverURL, coverSnake = "cover_url", imageUrl, imageURL, imageSnake = "image_url"
        case description, excerpt, summary
        case keyPoints, keyPointsSnake = "key_points"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCanonical = Self.firstString([.canonicalUrl, .canonicalURL, .canonicalSnake], from: container)
        url = Self.firstString([.url, .link, .href], from: container) ?? decodedCanonical
        canonicalUrl = decodedCanonical
        title = Self.firstString([.title, .name], from: container)
        source = Self.firstString([.source, .sourceName, .site], from: container)
        author = Self.firstString([.author], from: container)
        publishedAt = Self.firstString([.publishedAt, .publishedSnake], from: container)
        cover = Self.firstString([.cover, .image], from: container)
        coverUrl = Self.firstString([.coverUrl, .coverURL, .coverSnake, .imageUrl, .imageURL, .imageSnake], from: container)
        description = Self.firstString([.description, .excerpt], from: container)
        summary = Self.firstString([.summary], from: container)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints)
            ?? container.decodeIfPresent([String].self, forKey: .keyPointsSnake)
    }

    private static func firstString(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(canonicalUrl, forKey: .canonicalUrl)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(cover, forKey: .cover)
        try container.encodeIfPresent(coverUrl, forKey: .coverUrl)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(keyPoints, forKey: .keyPoints)
    }
}

struct AdminComment: Decodable, Identifiable, Sendable {
    let id: Int
    let targetType: String
    let targetId: Int
    let targetLabel: String?
    let targetSlug: String?
    let nickname: String
    let email: String?
    let website: String?
    let avatar: String?
    let avatarUrl: String?
    let content: String
    let status: String
    let createdAt: String?
    let adminReply: String?
    let repliedAt: String?

    var displayAvatar: String? { avatar?.trimmedNonEmpty ?? avatarUrl?.trimmedNonEmpty }

    var displayTargetLabel: String? {
        guard let label = targetLabel?.trimmedNonEmpty else { return nil }
        guard targetType == "moment" else { return label }
        var mediaLabel: String?
        for block in MarkdownParser.parse(label) {
            let text: String?
            switch block {
            case .paragraph(let value), .heading(_, let value), .quote(let value): text = value
            case .unorderedList(let items), .orderedList(let items): text = items.joined(separator: " · ")
            case .music(let spec):
                let marker = MarkdownParser.musicMarker(from: spec)
                let names = [marker?.title, marker?.artist].compactMap { $0?.trimmedNonEmpty }
                if mediaLabel == nil { mediaLabel = names.isEmpty ? "音乐絮语" : names.joined(separator: " · ") }
                text = nil
            case .image(_, let alt):
                if mediaLabel == nil { mediaLabel = alt.trimmedNonEmpty ?? "照片絮语" }
                text = nil
            case .video:
                if mediaLabel == nil { mediaLabel = "视频絮语" }
                text = nil
            default: text = nil
            }
            if let text, let plain = String(MarkdownParser.attributed(text).characters).trimmedNonEmpty {
                return plain.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return mediaLabel ?? "絮语"
    }
}

struct AdminAttachment: Decodable, Sendable {
    let id: Int?
    let postId: Int?
    let path: String
    let originalName: String
    let mimeType: String
    let size: Int
    let createdAt: String
    let references: [AdminAttachmentReference]
    let referenced: Bool
    let tracked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, postId, path, originalName, mimeType, size, createdAt, references, referenced, tracked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        postId = try container.decodeIfPresent(Int.self, forKey: .postId)
        path = try container.decode(String.self, forKey: .path)
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName) ?? path.split(separator: "/").last.map(String.init) ?? "附件"
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        references = try container.decodeIfPresent([AdminAttachmentReference].self, forKey: .references) ?? []
        referenced = try container.decodeIfPresent(Bool.self, forKey: .referenced) ?? false
        tracked = try container.decodeIfPresent(Bool.self, forKey: .tracked) ?? (id != nil && id != 0)
    }

    var stableID: String { id.map(String.init) ?? path }
}

struct AdminAttachmentReference: Decodable, Sendable {
    let type: String
    let id: Int
    let label: String
    let slug: String?
    let usage: String?
}

private struct AdminUploadResponse: Decodable {
    let path: String
    let attachment: AdminAttachment
}

private struct AdminAttachmentCropRequest: Encodable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct AdminAttachmentCropResponse: Decodable {
    let attachment: AdminAttachment
}

enum AdminMusicSearchType: String, Sendable {
    case song
    case playlist
}

struct AdminMusicSearchResult: Decodable, Sendable {
    let tracks: [AdminMusicTrack]
    let playlists: [AdminMusicPlaylist]

    init(tracks: [AdminMusicTrack] = [], playlists: [AdminMusicPlaylist] = []) {
        self.tracks = tracks
        self.playlists = playlists
    }

    private enum CodingKeys: String, CodingKey { case tracks, playlists, data }

    private struct Payload: Decodable {
        let tracks: [AdminMusicTrack]?
        let playlists: [AdminMusicPlaylist]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? container.decode(Payload.self, forKey: .data)
        tracks = try container.decodeIfPresent([AdminMusicTrack].self, forKey: .tracks) ?? nested?.tracks ?? []
        playlists = try container.decodeIfPresent([AdminMusicPlaylist].self, forKey: .playlists) ?? nested?.playlists ?? []
    }
}

struct AdminMusicTrack: Decodable, Identifiable, Sendable {
    let mid: String
    let name: String
    let artist: String
    let album: String
    let cover: String
    /// Optional playable URL returned by deployments that expose a preview
    /// stream. QQ search itself normally only returns metadata, so the app
    /// never invents an audio URL when this value is absent.
    let playableURL: String?
    let lyricSource: String?
    var id: String { mid }

    private enum CodingKeys: String, CodingKey {
        case mid, songmid, songMid
        case key
        case id, songid, songId
        case name, songname, songName
        case artist, singer, singerName, singerSnake = "singer_name"
        case album, albumname, albumName
        case cover, coverUrl, coverURL, coverSnake = "cover_url"
        case playableURL, playableUrl, playableSnake = "playable_url"
        case audioURL, audioUrl, audioSnake = "audio_url"
        case playURL, playUrl, playSnake = "play_url"
        case url, lrc, lyric
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let playbackKey = try container.decodeIfPresent(String.self, forKey: .key)
        let keyMID = playbackKey.flatMap { key -> String? in
            guard key.hasPrefix("qqvip:"), !key.dropFirst(6).isEmpty else { return nil }
            let value = String(key.dropFirst(6))
            guard value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }) else { return nil }
            return value
        }
        mid = Self.firstString([.mid, .songmid, .songMid, .id, .songid, .songId], from: container) ?? keyMID ?? ""
        name = Self.firstString([.name, .songname, .songName], from: container) ?? ""
        artist = Self.firstString([.artist, .singer, .singerName, .singerSnake], from: container) ?? ""
        album = Self.firstString([.album, .albumname, .albumName], from: container) ?? ""
        cover = Self.firstString([.cover, .coverUrl, .coverURL, .coverSnake], from: container) ?? ""
        let playableKeys: [CodingKeys] = [
            .playableURL, .playableUrl, .playableSnake, .audioURL, .audioUrl, .audioSnake,
            .playURL, .playUrl, .playSnake, .url,
        ]
        playableURL = Self.firstString(playableKeys, from: container)
        lyricSource = Self.firstString([.lrc, .lyric], from: container)
    }

    private static func firstString(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key), !value.isEmpty {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }
}

struct AdminMusicPlaylist: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let creator: String
    let count: Int?
    let cover: String
    let kind: String?

    private enum CodingKeys: String, CodingKey {
        case id, dissid, dissId, dirId
        case name, dissname, dissName
        case creator, creatorName, nickname
        case count, songnum, songNum
        case cover, coverUrl, coverURL, logo, logoUrl
        case kind, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.firstString([.id, .dissid, .dissId, .dirId], from: container) ?? ""
        name = Self.firstString([.name, .dissname, .dissName], from: container) ?? ""
        creator = Self.firstString([.creator, .creatorName, .nickname], from: container) ?? ""
        count = Self.firstInt([.count, .songnum, .songNum], from: container)
        cover = Self.firstString([.cover, .coverUrl, .coverURL, .logo, .logoUrl], from: container) ?? ""
        kind = Self.firstString([.kind, .type], from: container)
    }

    private static func firstString(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key), !value.isEmpty {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    private static func firstInt(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) { return value }
            if let value = try? container.decode(String.self, forKey: key), let number = Int(value) { return number }
        }
        return nil
    }
}

struct AdminQQMusicPlaylistPlaybackResponse: Decodable, Sendable {
    let tracks: [AdminMusicTrack]
    let total: Int
    let skipped: Int

    private enum CodingKeys: String, CodingKey {
        case tracks, total, skipped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try container.decodeIfPresent([AdminMusicTrack].self, forKey: .tracks) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? tracks.count
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
    }
}

struct AdminMusicMetadataPage: Decodable, Sendable {
    let tracks: [AdminMusicTrack]
    let total: Int
    let availableTotal: Int?
    let nextOffset: Int?
}

struct AdminQQMusicStatus: Decodable, Sendable {
    let available: Bool
    let loggedIn: Bool
    let uin: String?
    var playable: Bool? = nil
    var healthStatus: String? = nil
    var detail: String? = nil

    var playbackWarning: String? {
        guard !loggedIn || !available || playable == false else { return nil }
        if !loggedIn { return "QQ 音乐尚未登录或登录已失效，请到「管理 → 音乐」使用 QQ 音乐 App 重新扫码。" }
        let reason = detail?.trimmedNonEmpty ?? (available ? "音乐服务没有返回播放地址。" : "音乐服务暂时不可用。")
        return "QQ 音乐已登录，但试听服务异常：\(reason) 可到「管理 → 音乐」检查状态或使用 QQ 音乐 App 重新扫码。"
    }

    var displayLabel: String {
        if loggedIn { return playable == false ? "已登录 · 播放异常" : "已登录" }
        return available ? "尚未登录 QQ 音乐" : "QQ 音乐服务不可用"
    }
}

struct AdminQQMusicQR: Decodable, Sendable {
    let channel: String?
    let image: String
    let qrsig: String?
    let ptqrtoken: String?
    let key: String?
    let expiresAt: Double?
    let source: AdminServiceSource?

    var isNativeAppQR: Bool { channel == "qqmusic" }
    var expirationDate: Date? {
        guard let expiresAt else { return nil }
        return Date(timeIntervalSince1970: expiresAt / 1_000)
    }
}

struct AdminQQMusicPollResult: Decodable, Sendable {
    let state: String?
    let uin: String?
    let message: String?
}

struct AdminServiceSource: Decodable, Sendable {
    let label: String?
    let website: String?
}

struct AdminQQMusicPlaylistResponse: Decodable, Sendable {
    let playlists: [AdminMusicPlaylist]
    let counts: AdminQQMusicPlaylistCounts?
    let warning: String?

    private enum CodingKeys: String, CodingKey { case playlists, counts, warning, data }

    private struct Payload: Decodable {
        let playlists: [AdminMusicPlaylist]?
        let counts: AdminQQMusicPlaylistCounts?
        let warning: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? container.decode(Payload.self, forKey: .data)
        playlists = try container.decodeIfPresent([AdminMusicPlaylist].self, forKey: .playlists) ?? nested?.playlists ?? []
        counts = try container.decodeIfPresent(AdminQQMusicPlaylistCounts.self, forKey: .counts) ?? nested?.counts
        warning = try container.decodeIfPresent(String.self, forKey: .warning) ?? nested?.warning
    }
}

struct AdminQQMusicPlaylistCounts: Decodable, Sendable {
    let created: Int?
    let collected: Int?
}

private struct AdminQQMusicPollRequest: Encodable, Sendable {
    let op: String
    let qrsig: String
    let ptqrtoken: String
}

private struct AdminQQMusicNativePollRequest: Encodable, Sendable {
    let op: String
    let key: String
}

private struct AdminReferenceHistoryResponse: Decodable {
    let references: [AdminReferenceSnapshot]

    private enum CodingKeys: String, CodingKey { case references, items, data }

    private struct Payload: Decodable {
        let references: [AdminReferenceSnapshot]?
        let items: [AdminReferenceSnapshot]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent([AdminReferenceSnapshot].self, forKey: .references) {
            references = direct
        } else if let items = try container.decodeIfPresent([AdminReferenceSnapshot].self, forKey: .items) {
            references = items
        } else if let directData = try? container.decode([AdminReferenceSnapshot].self, forKey: .data) {
            references = directData
        } else if let nested = try? container.decode(Payload.self, forKey: .data) {
            references = nested.references ?? nested.items ?? []
        } else {
            references = []
        }
    }
}

private struct AdminReferencePreviewRequest: Encodable, Sendable {
    let url: String
    let cacheReader: Bool
    let cacheImages: Bool
}

private struct AdminReferenceURLRequest: Encodable, Sendable {
    let url: String
}

private struct AdminReferenceArchiveRequest: Encodable, Sendable {
    let url: String
    let cacheImages: Bool
}

struct AdminReferenceSummaryResult: Decodable, Sendable {
    let configured: Bool?
    let summary: String?
    let keyPoints: [String]?
    let error: String?

    init(configured: Bool?, summary: String?, keyPoints: [String]?, error: String?) {
        self.configured = configured
        self.summary = summary
        self.keyPoints = keyPoints
        self.error = error
    }
}

private struct AdminReferenceSummaryPayload: Decodable, Sendable {
    let configured: Bool?
    let summary: String?
    let keyPoints: [String]?
    let error: String?
    let data: AdminReferenceSummaryResult?
}

struct AdminReferenceArchiveResponse: Decodable, Sendable {
    let job: AdminReferenceArchiveJob?
    let reused: Bool?
    let error: String?
}

private struct AdminReferenceArchiveEnvelope: Decodable, Sendable {
    let data: AdminReferenceArchiveResponse?
}

struct AdminReferenceArchiveJob: Decodable, Sendable {
    let id: String?
    let state: String?
    let error: String?
    let archive: AdminReferenceArchiveMetadata?
    let created: Bool?
    let unchanged: Bool?
    let cachedImages: Int?
    let report: AdminReferenceArchiveReport?
    let ai: AdminReferenceArchiveAI?
}

struct AdminReferenceArchiveMetadata: Decodable, Sendable {
    let canonicalUrl: String?
    let title: String?
    let capturedAt: String?
    let updatedAt: String?
}

struct AdminReferenceArchiveReport: Decodable, Sendable {
    let keptBlocks: Int?
    let removedBlocks: Int?
    let cachedImages: Int?
    let reusedImages: Int?
    let textCharacters: Int?
    let quality: String?
}

struct AdminReferenceArchiveAI: Decodable, Sendable {
    let applied: Bool?
    let summaryGenerated: Bool?
    let error: String?
}

struct AdminReferenceReader: Decodable, Sendable {
    let id: Int?
    let title: String?
    let sourceName: String?
    let author: String?
    let publishedAt: String?
    let summary: String?
    let keyPoints: [String]?
    let markdown: String
    let capturedAt: String?
    let updatedAt: String?
    let report: AdminReferenceArchiveReport?
    let originalSnapshotPath: String?
}

private struct AdminReferencePreviewResponse: Decodable {
    let snapshot: AdminReferenceSnapshot

    private enum CodingKeys: String, CodingKey { case snapshot, data }

    private struct Payload: Decodable {
        let snapshot: AdminReferenceSnapshot?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(AdminReferenceSnapshot.self, forKey: .snapshot), value.url != nil {
            snapshot = value
        } else if let value = try container.decodeIfPresent(AdminReferenceSnapshot.self, forKey: .data), value.url != nil {
            snapshot = value
        } else if let nested = try? container.decode(Payload.self, forKey: .data), let value = nested.snapshot, value.url != nil {
            snapshot = value
        } else {
            let value = try AdminReferenceSnapshot(from: decoder)
            guard value.url != nil else { throw DecodingError.dataCorruptedError(forKey: .snapshot, in: container, debugDescription: "reference snapshot is missing a URL") }
            snapshot = value
        }
    }
}

struct AdminBackup: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let size: Int64
    let createdAt: String
    var title: String { kind == "complete" ? "完整加密备份" : "数据库备份" }
}
struct AdminBackupJob: Decodable, Sendable {
    let id: String
    let action: String
    let kind: String
    let status: String
    let message: String?
    let resultId: String?
    var isRunning: Bool { !["succeeded", "failed"].contains(status) }
}
struct AdminBackupOverview: Decodable, Sendable {
    let backups: [AdminBackup]
    let job: AdminBackupJob?
    let completeEnabled: Bool
    let restoreEnabled: Bool
}
private struct AdminBackupOperation: Encodable, Sendable {
    let action: String
    let kind: String
    let backupId: String?
    let confirmation: String?
}

struct AdminMoment: Decodable, Identifiable, Sendable {
    let id: Int
    let content: String
    let images: [String]
    let createdAt: String?
    let updatedAt: String?
    let metrics: ContentMetrics?
    var location: String? = nil
    var commentCount: Int? = nil
    var tags: [String]? = nil
}

struct AdminWork: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let description: String
    let cover: String?
    let link: String?
    let sortOrder: Int
    let createdAt: String?
}

struct AdminCategory: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let slug: String
    let createdAt: String?
    let postsCount: Int?
}

struct AdminTag: Decodable, Identifiable, Sendable {
    let tag: String
    let count: Int
    var id: String { tag }
}

enum AdminPostFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, published, draft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .published: return "已发布"
        case .draft: return "草稿"
        }
    }
}

enum AdminCommentFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, pending, approved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .pending: return "待审核"
        case .approved: return "已通过"
        }
    }
}

enum AdminCommentAction: String, Sendable {
    case approve, hide, reply
}

struct AdminCommentActionRequest: Encodable, Sendable {
    let action: String
    let reply: String?
}

struct AdminPostWriteRequest: Encodable, Sendable {
    let title: String
    let slug: String
    let content: String
    let cover: String?
    let category: String
    let tags: String
    let attachmentIds: [Int]
    let referenceSnapshots: [AdminReferenceSnapshot]?
    let status: String
}

struct AdminMomentWriteRequest: Encodable, Sendable {
    let content: String
    let images: [String]
}

struct AdminWorkWriteRequest: Encodable, Sendable {
    let title: String
    let description: String
    let cover: String?
    let link: String
    let sortOrder: Int
}

private struct AdminEmptyRequest: Encodable, Sendable {}

private struct AdminCategoryCreateRequest: Encodable, Sendable {
    let name: String
}

private struct AdminTagRenameRequest: Encodable, Sendable {
    let oldTag: String
    let newTag: String

    private enum CodingKeys: String, CodingKey {
        case oldTag = "old_tag"
        case newTag = "new_tag"
    }
}

private struct AdminTagDeleteRequest: Encodable, Sendable {
    let tag: String
}

struct AdminTagMutationResponse: Decodable, Sendable {
    let tag: String
    let tags: [AdminTag]
}

enum AdminAttachmentCompressionProfile: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case quality
    case small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "均衡"
        case .quality: return "高质量"
        case .small: return "小体积"
        }
    }
}

private struct AdminAttachmentCompressionRequest: Encodable, Sendable {
    let profile: String
}

private struct AdminUntrackedAttachmentRequest: Encodable, Sendable {
    let path: String
    let profile: String
}

private struct AdminConfirmationRequest: Encodable, Sendable {
    let confirm: Bool
}

private struct AdminUntrackedDeleteRequest: Encodable, Sendable {
    let path: String
    let confirm: Bool
}

struct AdminAttachmentMaintenanceResult: Decodable, Sendable {
    let path: String?
    let originalSize: Int?
    let compressedSize: Int?
    let savedPercent: Int?
    let changed: Bool?
    let deletedCount: Int?
    let skippedCount: Int?
}

private struct AdminReferenceLibraryCreateRequest: Encodable, Sendable {
    let snapshot: AdminReferenceSnapshot
    let category: String
    let tags: String
}

private struct AdminReferenceMetadataRequest: Encodable, Sendable {
    let category: String
    let tags: String
}

private struct AdminReferenceBulkDeleteRequest: Encodable, Sendable {
    let ids: [Int]
}

struct AdminReferenceBulkDeleteResult: Decodable, Sendable {
    let deletedCount: Int?
}

private struct AdminReferenceAttachRequest: Encodable, Sendable {
    let snapshot: AdminReferenceSnapshot
}

struct AdminDeployStatus: Decodable, Sendable {
    let status: String
    let updatedAt: String?
    let error: String?
}

struct AdminDeployVersionStatus: Decodable, Sendable {
    let status: String
    let localCommit: String?
    let remoteCommit: String?
    let error: String?
}

struct AdminDeploymentHealth: Decodable, Sendable {
    let status: String
    let commit: String?
    let schemaVersion: Int?
    let supportedSchemaVersion: Int?
    let reason: String?
}

struct AdminDeployActionResult: Decodable, Sendable {
    let status: String?
    let message: String?
}

struct AdminTelegramHealthStatus: Decodable, Sendable {
    let status: String?
    let label: String?
    let lastCheckedAt: String?
    let lastDetail: String?
    let lastNotifiedAt: String?
}

struct AdminTelegramStatus: Decodable, Sendable {
    let configured: Bool
    let qqMusic: AdminTelegramHealthStatus
}

private struct AdminTelegramOperation: Encodable, Sendable {
    let op: String
}

struct AdminTelegramActionResult: Decodable, Sendable {
    let message: String?
    let error: String?
}

struct AdminTelegramCheckResult: Decodable, Sendable {
    let status: String?
    let label: String?
    let detail: String?
    let checkedAt: String?
    let notified: Bool?
}
