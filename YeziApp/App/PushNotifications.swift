import SwiftUI
import UIKit
@preconcurrency import UserNotifications

struct YeziPushRoute: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case comment, musicExpired = "music_expired", test }
    let id: String
    let kind: Kind
    let siteRoot: URL
    let commentID: Int?

    init?(userInfo: [AnyHashable: Any]) {
        guard let body = userInfo["yezi"] as? [String: Any], body["version"] as? Int == 1,
              let id = body["event_id"] as? String, !id.isEmpty, id.count <= 200,
              let rawKind = body["kind"] as? String, let kind = Kind(rawValue: rawKind),
              let rawSite = body["site_root"] as? String, let site = URLComponents(string: rawSite),
              site.scheme == "https", site.host != nil, site.user == nil, site.password == nil,
              site.query == nil, site.fragment == nil, ["", "/"].contains(site.path),
              let root = site.url else { return nil }
        let commentID = body["comment_id"] as? Int
        if kind == .comment && (commentID == nil || commentID! <= 0) { return nil }
        self.id = id; self.kind = kind; self.siteRoot = root; self.commentID = commentID
    }

    func matches(_ site: URL) -> Bool {
        site.scheme?.lowercased() == siteRoot.scheme?.lowercased() && site.host?.lowercased() == siteRoot.host?.lowercased() && site.port == siteRoot.port
    }
}

struct YeziPushPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var comments = true
    var music = true
}
struct YeziPushRegistration: Encodable, Sendable {
    let installation_id: String
    let token: String
    let environment: String
    let site_root: String
    let comments: Bool
    let music: Bool
}
struct YeziPushDeviceID: Encodable, Sendable { let installation_id: String }
struct YeziPushStatus: Decodable, Sendable { let configured: Bool }
struct YeziPushAck: Decodable, Sendable { let registered: Bool?; let queued: Bool? }

@MainActor
final class YeziNotifications: ObservableObject {
    static let shared = YeziNotifications()
    @Published private(set) var preferences = YeziPushPreferences()
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var registered = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var route: YeziPushRoute?
    private var api: AdminAPIClient?
    private var token: String?
    private var revision = 0
    private var syncTask: Task<Void, Never>?
    private var lastBinding: String?
    private var handledEvents: [String] = []
    private let defaults = UserDefaults.standard
    private var installationID: String {
        // A restored preferences backup must not replace another physical device's binding.
        if let id = UIDevice.current.identifierForVendor { return id.uuidString.lowercased() }
        if let id = defaults.string(forKey: "yezi.push.installation") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "yezi.push.installation")
        return id
    }
    private func preferencesKey(_ site: URL) -> String { "yezi.push.preferences.\(site.absoluteString)" }
    private func boundKey(_ site: URL) -> String { "yezi.push.bound.\(site.absoluteString)" }

    func attach(_ api: AdminAPIClient?) async {
        guard !CreationPreview.isEnabled else { return }
        if self.api !== api {
            self.api = api; lastBinding = nil; registered = false; message = nil; revision += 1
            if let api, let data = defaults.data(forKey: preferencesKey(api.siteRoot)), let value = try? JSONDecoder().decode(YeziPushPreferences.self, from: data) { preferences = value }
            else { preferences = YeziPushPreferences() }
        }
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        guard !CreationPreview.isEnabled else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if preferences.enabled && isAuthorized && api != nil { UIApplication.shared.registerForRemoteNotifications() }
        else if !isAuthorized { registered = false; lastBinding = nil }
        scheduleSync()
    }
    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional || authorization == .ephemeral }
    var statusText: String {
        if CreationPreview.isEnabled { return "预览模式 · 尚未连接 Apple 推送" }
        if authorization == .denied { return "系统通知已关闭" }
        if !preferences.enabled { return "尚未开启" }
        if registered { return "此设备已连接" }
        return isAuthorized ? "正在连接通知服务" : "等待通知权限"
    }
    func enable() async {
        guard !CreationPreview.isEnabled else { message = "预览模式不申请系统权限，也不发送推送。"; return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { await refreshAuthorization(); return }
            setPreferences(YeziPushPreferences(enabled: true, comments: preferences.comments, music: preferences.music))
            await refreshAuthorization()
        } catch { message = error.localizedDescription }
    }
    func setPreferences(_ value: YeziPushPreferences) {
        preferences = value; revision += 1; message = nil; lastBinding = nil
        if let api, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: preferencesKey(api.siteRoot)) }
        scheduleSync()
    }
    func receivedToken(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        revision += 1; scheduleSync()
    }
    func registrationFailed(_ detail: String) { registered = false; message = "Apple 推送注册失败：\(detail)" }
    func receive(_ route: YeziPushRoute) {
        guard !handledEvents.contains(route.id) else { return }
        handledEvents.append(route.id); handledEvents = Array(handledEvents.suffix(32))
        self.route = route
    }
    func canPresent(_ route: YeziPushRoute?) -> Bool { route.map { route in api.map { route.matches($0.siteRoot) } ?? false } ?? false }

    private func scheduleSync() {
        guard syncTask == nil, !CreationPreview.isEnabled, api != nil else { return }
        syncTask = Task {
            busy = true
            defer { busy = false; syncTask = nil }
            while let api = self.api {
                let current = revision
                await synchronize(api)
                if revision == current { break }
            }
        }
    }
    private func synchronize(_ api: AdminAPIClient) async {
        guard self.api === api else { return }
        do {
            if !preferences.enabled || !isAuthorized {
                if defaults.bool(forKey: boundKey(api.siteRoot)) {
                    try await api.unregisterPushDevice(installationID)
                    defaults.removeObject(forKey: boundKey(api.siteRoot))
                }
                if self.api === api { registered = false; lastBinding = nil }
                return
            }
            guard let token else { return }
#if DEBUG
            let environment = "development"
#else
            let environment = "production"
#endif
            let binding = "\(api.siteRoot)|\(token)|\(preferences.comments)|\(preferences.music)"
            guard lastBinding != binding else { return }
            let value = YeziPushRegistration(installation_id: installationID, token: token, environment: environment,
                site_root: api.siteRoot.absoluteString, comments: preferences.comments, music: preferences.music)
            try await api.registerPushDevice(value)
            defaults.set(true, forKey: boundKey(api.siteRoot))
            if self.api === api { registered = true; lastBinding = binding; message = nil }
        } catch {
            if self.api === api { registered = false; message = error.localizedDescription }
        }
    }
    func disconnect() async {
        let old = api
        api = nil; revision += 1
        await syncTask?.value
        if let old, defaults.bool(forKey: boundKey(old.siteRoot)) {
            try? await old.unregisterPushDevice(installationID)
            defaults.removeObject(forKey: boundKey(old.siteRoot))
        }
        registered = false; lastBinding = nil; route = nil
    }
    func sendTest() async {
        guard let api, registered else { return }
        busy = true; defer { busy = false }
        do { try await api.testPushDevice(installationID); message = "测试通知已加入发送队列，请留意系统通知。" }
        catch { message = error.localizedDescription }
    }
}

final class YeziAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        YeziNotifications.shared.receivedToken(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        YeziNotifications.shared.registrationFailed(error.localizedDescription)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let route = YeziPushRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { YeziNotifications.shared.receive(route) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let route = YeziPushRoute(userInfo: notification.request.content.userInfo)
        return await MainActor.run { YeziNotifications.shared.canPresent(route) ? [.banner, .sound, .list] : [] }
    }
}

struct AdminNotificationSettingsView: View {
    @ObservedObject private var notifications = YeziNotifications.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Form {
            Section {
                Label(notifications.statusText, systemImage: notifications.registered ? "bell.badge" : "bell")
                if notifications.authorization == .denied {
                    Button("前往系统设置开启通知") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                } else if !notifications.preferences.enabled {
                    Button("开启通知") { Task { await notifications.enable() } }.accessibilityIdentifier("notifications.enable")
                } else {
                    Toggle("接收通知", isOn: preference(\.enabled))
                }
            } footer: { Text("通知由网站服务器发送，无需 App 在后台刷新。通知仅绑定当前登录的站点与此设备。") }
                .listRowBackground(CreationDesign.surface)
            Section("通知内容") {
                Toggle("新评论", isOn: preference(\.comments))
                Toggle("QQ 音乐登录失效", isOn: preference(\.music))
            }.listRowBackground(CreationDesign.surface)
            Section {
                Button("发送测试通知") { Task { await notifications.sendTest() } }.disabled(!notifications.registered || notifications.busy)
                if let message = notifications.message { Text(message).foregroundStyle(.secondary) }
            } footer: { Text("QQ 音乐提醒使用网站现有的定时健康检查。网络临时异常不会被当成登录失效。") }
                .listRowBackground(CreationDesign.surface)
        }.scrollContentBackground(.hidden).background(CreationDesign.canvas)
            .font(CreationDesign.interface()).navigationTitle("通知").navigationBarTitleDisplayMode(.inline)
            .tint(CreationDesign.accent).task { await notifications.refreshAuthorization() }
            .onChange(of: phase) { _, value in if value == .active { Task { await notifications.refreshAuthorization() } } }
    }
    private func preference(_ key: WritableKeyPath<YeziPushPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { notifications.preferences[keyPath: key] }, set: { value in
            var next = notifications.preferences; next[keyPath: key] = value; notifications.setPreferences(next)
        })
    }
}
