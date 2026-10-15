import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedCreationImage: Sendable {
    let data: Data
    let extensionName: String
    let mimeType: String
}

enum CreationImageProcessor {
    static func prepare(_ data: Data) async throws -> PreparedCreationImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { throw APIError.transport("无法读取图片，请选择 JPEG、HEIC 或 PNG 图片") }
            let alpha = image.alphaInfo
            let transparent = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, (transparent ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else { throw APIError.emptyData }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length < 25 * 1024 * 1024 else { throw APIError.transport("处理后的图片超过 25 MB，请选择较小的图片") }
            return PreparedCreationImage(data: output as Data, extensionName: transparent ? "png" : "jpg", mimeType: transparent ? "image/png" : "image/jpeg")
        }.value
    }
}

@MainActor
final class MediaUploadQueue {
    typealias Upload = @Sendable (Data, String, String) async throws -> AdminAttachment
    var onChange: ((CreationMedia) -> Void)?
    private let store: CreationDraftStore
    private let site: String
    private let upload: Upload
    private var items: [UUID: CreationMedia] = [:]
    private var order: [UUID] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(store: CreationDraftStore, site: String, upload: @escaping Upload) {
        self.store = store
        self.site = site
        self.upload = upload
    }

    func restore(_ media: [CreationMedia]) {
        for item in media { items[item.id] = item; order.append(item.id) }
        pump()
    }

    func prepare(id: UUID, data: Data) async {
        guard let item = items[id], item.state == .preparing else { return }
        do {
            let prepared = try await CreationImageProcessor.prepare(data)
            guard items[id] != nil else { return }
            let filename = try await store.writeImage(prepared.data, site: site, id: id, extensionName: prepared.extensionName)
            guard var current = items[id] else { try? await store.removeImage(site: site, mediaID: id, filename: filename); return }
            current.filename = filename
            current.mimeType = prepared.mimeType
            current.state = .waiting
            update(current)
            pump()
        } catch { fail(id, error: error.localizedDescription) }
    }

    func add(_ item: CreationMedia) { items[item.id] = item; order.append(item.id) }
    func failedPreparation(_ id: UUID, message: String) { fail(id, error: message) }

    func remove(_ id: UUID) {
        let filename = items[id]?.filename
        items[id] = nil
        order.removeAll { $0 == id }
        tasks[id]?.cancel()
        pump()
        if let filename { Task { [store, site] in try? await store.removeImage(site: site, mediaID: id, filename: filename) } }
    }

    func retry(_ id: UUID) {
        guard var item = items[id], item.state == .failed, item.filename != nil else { return }
        item.state = .waiting
        item.error = nil
        update(item)
        pump()
    }

    func suspend() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        items.removeAll()
        order.removeAll()
    }

    private func update(_ item: CreationMedia) { items[item.id] = item; onChange?(item) }
    private func fail(_ id: UUID, error: String) {
        guard var item = items[id] else { return }
        item.state = .failed
        item.error = error
        update(item)
    }

    private func pump() {
        for id in order where tasks.count < 2 {
            guard var item = items[id], item.state == .waiting, let filename = item.filename else { continue }
            item.state = .uploading
            update(item)
            let mime = item.mimeType
            tasks[id] = Task { [weak self, store, site, upload] in
                defer { self?.tasks[id] = nil; self?.pump() }
                do {
                    let data = try await store.imageData(site: site, filename: filename)
                    let attachment = try await upload(data, filename, mime)
                    guard let self, !Task.isCancelled, var current = self.items[id] else { return }
                    guard !attachment.path.isEmpty else { throw APIError.emptyData }
                    current.remotePath = attachment.path
                    current.attachmentID = attachment.id
                    current.state = .uploaded
                    current.error = nil
                    self.update(current)
                } catch {
                    if !Task.isCancelled { self?.fail(id, error: error.localizedDescription) }
                }
            }
        }
    }
}
