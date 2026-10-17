import Combine
import Foundation
import ImageIO
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
    static let shared = ImageLoader()

    private struct Key: Hashable, Sendable {
        let url: URL
        let pixels: Int
        var cacheKey: NSString { "\(pixels):\(url.absoluteString)" as NSString }
    }
    private struct Flight {
        let id: UUID
        let task: Task<CGImage, Error>
        var consumers: Set<UUID>
    }
    private struct Waiting {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    // Cache decoded thumbnails by their actual memory cost; never retain an
    // unbounded dictionary of original image bytes.
    private let images = NSCache<NSString, CGImage>()
    private let session: URLSession
    private let maximumConcurrentLoads: Int
    private var flights: [Key: Flight] = [:]
    private var activeLoads = 0
    private var waiting: [Waiting] = []

    init(urlCache: URLCache? = nil, session: URLSession? = nil, maximumConcurrentLoads: Int = 4) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = urlCache ?? URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024, diskPath: "YeziImageCache")
            configuration.requestCachePolicy = .useProtocolCachePolicy
            self.session = URLSession(configuration: configuration)
        }
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 96
    }

    func image(for url: URL, maxPixelSize: Int = 1200, forceReload: Bool = false) async throws -> CGImage {
        try Task.checkCancellation()
        // Small geometry changes reuse the same size bucket.
        let pixels = min(2048, max(64, ((maxPixelSize + 63) / 64) * 64))
        let key = Key(url: url, pixels: pixels)
        if !forceReload, let image = images.object(forKey: key.cacheKey) { return image }
        let consumer = UUID()
        let flight: Flight
        if var existing = flights[key] {
            existing.consumers.insert(consumer)
            flights[key] = existing
            flight = existing
        } else {
            let id = UUID()
            let task = Task { try await self.download(key, id: id, forceReload: forceReload) }
            flight = Flight(id: id, task: task, consumers: [consumer])
            flights[key] = flight
        }
        return try await withTaskCancellationHandler {
            defer { releaseConsumer(consumer, key: key, flightID: flight.id) }
            let image = try await flight.task.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await self.releaseConsumer(consumer, key: key, flightID: flight.id) }
        }
    }

    private func download(_ key: Key, id: UUID, forceReload: Bool) async throws -> CGImage {
        try await acquireSlot(id: id)
        defer { releaseSlot() }
        try Task.checkCancellation()
        var request = URLRequest(url: key.url)
        request.cachePolicy = forceReload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        // ImageIO downsamples and decodes on this actor, outside the main
        // actor. No full-resolution UIImage is constructed for a small card.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: key.pixels,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        guard flights[key]?.id == id else { throw CancellationError() }
        images.setObject(image, forKey: key.cacheKey, cost: image.bytesPerRow * image.height)
        return image
    }

    private func releaseConsumer(_ consumer: UUID, key: Key, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            flight.task.cancel()
            flights.removeValue(forKey: key)
        } else { flights[key] = flight }
    }

    private func acquireSlot(id: UUID) async throws {
        try Task.checkCancellation()
        if activeLoads < maximumConcurrentLoads { activeLoads += 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiting(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiting(id: id) }
        }
    }

    private func cancelWaiting(id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseSlot() {
        if waiting.isEmpty { activeLoads -= 1 }
        else { waiting.removeFirst().continuation.resume() }
    }

    func removeAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        images.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}

@MainActor
final class RemoteImageModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false
    @Published private(set) var didFail = false

    private let loader: ImageLoader
    private var url: URL?
    private var generation = 0

    init(loader: ImageLoader) {
        self.loader = loader
    }

    func unload() {
        generation += 1
        image = nil
        isLoading = false
    }

    func load(url: URL?, maxPixelSize: Int, forceReload: Bool = false) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let token = generation
        if self.url != url { image = nil }
        self.url = url
        didFail = false
        guard let url else {
            didFail = true
            isLoading = false
            return
        }
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let decoded = try await loader.image(for: url, maxPixelSize: maxPixelSize, forceReload: forceReload)
            guard token == generation, !Task.isCancelled else { return }
            image = UIImage(cgImage: decoded)
        } catch {
            guard token == generation, !Task.isCancelled, !isRequestCancellation(error) else { return }
            image = nil
            didFail = true
        }
    }
}

struct RemoteImageView<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let loader: ImageLoader
    let maxPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @StateObject private var model: RemoteImageModel
    @State private var retry = 0

    private struct Request: Hashable {
        let url: URL?
        let pixels: Int
        let retry: Int
    }

    init(url: URL?, loader: ImageLoader, contentMode: ContentMode = .fill, maxPixelSize: Int = 1200, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.loader = loader
        self.contentMode = contentMode
        self.maxPixelSize = min(2048, max(64, ((maxPixelSize + 63) / 64) * 64))
        self.placeholder = placeholder
        _model = StateObject(wrappedValue: RemoteImageModel(loader: loader))
    }

    var body: some View {
        Group {
            if let image = model.image {
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
                        retry += 1
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
        .task(id: Request(url: url, pixels: maxPixelSize, retry: retry)) {
            await model.load(url: url, maxPixelSize: maxPixelSize, forceReload: retry > 0)
        }
        .onDisappear { model.unload() }
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
