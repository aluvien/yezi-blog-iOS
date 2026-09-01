import Combine
import Foundation
import Network
import OSLog
import Security
import SwiftUI
import UIKit

// MARK: - URL handling

struct SiteURLResolver: Sendable {
    let siteRoot: URL

    init(siteRoot: URL = URL(string: "https://yezi.me")!) {
        self.siteRoot = siteRoot
    }

    /// Resolves `/uploads/...`, `images/...`, protocol-relative URLs and full
    /// http(s) URLs without allowing arbitrary non-web schemes into the UI.
    func absoluteURL(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("//") {
            return URL(string: "https:\(value)")
        }

        if let direct = URL(string: value), let scheme = direct.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return direct
            }
            return nil
        }

        guard !value.contains("://") else { return nil }
        return URL(string: value, relativeTo: siteRoot)?.absoluteURL
    }

    func path(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Diagnostics

struct DiagnosticEvent: Identifiable, Sendable {
    let id = UUID()
    let date = Date()
    let message: String
}

actor DiagnosticsCenter {
    private(set) var events: [DiagnosticEvent] = []
    private let logger = Logger(subsystem: "me.yezi.YeziApp", category: "Diagnostics")

    func record(_ message: String) {
        events.append(DiagnosticEvent(message: message))
        if events.count > 50 { events.removeFirst(events.count - 50) }
        logger.error("\(message, privacy: .public)")
    }

    func clear() {
        events.removeAll()
    }

    func snapshot() -> [DiagnosticEvent] {
        events
    }
}

// MARK: - Connectivity

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    @Published private(set) var isExpensive = false

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "me.yezi.YeziApp.network-monitor")

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.isConnected = connected
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

// MARK: - Lightweight public response cache

actor ResponseCache {
    private let directory: URL
    private var memory: [String: Data] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("YeziAPICache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func data(for key: String) -> Data? {
        if let value = memory[key] { return value }
        let file = fileURL(for: key)
        guard let value = try? Data(contentsOf: file) else { return nil }
        memory[key] = value
        return value
    }

    func store(_ data: Data, for key: String) {
        memory[key] = data
        try? data.write(to: fileURL(for: key), options: [.atomic])
    }

    func removeAll() {
        memory.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(for key: String) -> URL {
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(encoded).appendingPathExtension("json")
    }
}

// MARK: - Keychain visitor identity

protocol SecureValueStore: Sendable {
    func value(for key: String) -> String?
    @discardableResult func set(_ value: String, for key: String) -> Bool
    @discardableResult func deleteValue(for key: String) -> Bool
}

final class KeychainStore: SecureValueStore, @unchecked Sendable {
    private let service: String

    init(service: String = "me.yezi.YeziApp") {
        self.service = service
    }

    func value(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    func deleteValue(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class InMemorySecureValueStore: SecureValueStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func value(for key: String) -> String? { values[key] }

    @discardableResult
    func set(_ value: String, for key: String) -> Bool {
        values[key] = value
        return true
    }

    @discardableResult
    func deleteValue(for key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}

final class VisitorIdentity: @unchecked Sendable {
    private let store: any SecureValueStore
    private let key: String
    private var cachedValue: String?

    init(store: any SecureValueStore, key: String = "visitor-id") {
        self.store = store
        self.key = key
    }

    /// A random installation-scoped UUID. It is never derived from an account,
    /// device identifier or advertising identifier.
    var id: String {
        if let cachedValue { return cachedValue }
        if let saved = store.value(for: key), UUID(uuidString: saved) != nil {
            cachedValue = saved.lowercased()
            return cachedValue!
        }
        let generated = UUID().uuidString.lowercased()
        _ = store.set(generated, for: key)
        cachedValue = generated
        return generated
    }
}

// MARK: - Image loading

actor ImageLoader {
    private var memory: [URL: Data] = [:]
    private let session: URLSession

    init(urlCache: URLCache? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache ?? URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024, diskPath: "YeziImageCache")
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)
    }

    func data(for url: URL, forceReload: Bool = false) async throws -> Data {
        if !forceReload, let cached = memory[url] { return cached }
        var request = URLRequest(url: url)
        request.cachePolicy = forceReload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        memory[url] = data
        return data
    }

    func removeAll() {
        memory.removeAll()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}

@MainActor
final class RemoteImageModel: ObservableObject {
    @Published private(set) var data: Data?
    @Published private(set) var isLoading = false
    @Published private(set) var didFail = false

    private let loader: ImageLoader
    private var url: URL?
    private var loadTask: Task<Void, Never>?

    init(url: URL?, loader: ImageLoader) {
        self.url = url
        self.loader = loader
    }

    func update(url: URL?) {
        guard self.url != url else { return }
        loadTask?.cancel()
        self.url = url
        data = nil
        didFail = false
        load()
    }

    func load(forceReload: Bool = false) {
        loadTask?.cancel()
        guard let url else {
            didFail = true
            return
        }
        isLoading = true
        didFail = false
        let loader = loader
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await loader.data(for: url, forceReload: forceReload)
                guard !Task.isCancelled else { return }
                self.data = data
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.data = nil
                self.didFail = true
                self.isLoading = false
            }
        }
    }

    deinit {
        loadTask?.cancel()
    }
}

struct RemoteImageView<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let loader: ImageLoader
    @ViewBuilder let placeholder: () -> Placeholder
    @StateObject private var model: RemoteImageModel

    init(url: URL?, loader: ImageLoader, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.loader = loader
        self.contentMode = contentMode
        self.placeholder = placeholder
        _model = StateObject(wrappedValue: RemoteImageModel(url: url, loader: loader))
    }

    var body: some View {
        Group {
            if let data = model.data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if model.isLoading {
                ZStack {
                    placeholder()
                    ProgressView()
                        .controlSize(.small)
                }
            } else if model.didFail {
                ZStack {
                    placeholder()
                    Button {
                        model.load(forceReload: true)
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                placeholder()
            }
        }
        .clipped()
        .task(id: url) {
            model.update(url: url)
            if model.data == nil && !model.isLoading && !model.didFail { model.load() }
        }
    }
}

// MARK: - Cache clearing

final class CacheCoordinator: @unchecked Sendable {
    let responseCache: ResponseCache
    let apiURLCache: URLCache
    let imageLoader: ImageLoader

    init(responseCache: ResponseCache, apiURLCache: URLCache, imageLoader: ImageLoader) {
        self.responseCache = responseCache
        self.apiURLCache = apiURLCache
        self.imageLoader = imageLoader
    }

    func clearAll() async {
        await responseCache.removeAll()
        apiURLCache.removeAllCachedResponses()
        await imageLoader.removeAll()
    }
}
