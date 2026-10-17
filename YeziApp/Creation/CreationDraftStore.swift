import Foundation
import CryptoKit

enum CreationKind: String, Codable, Sendable { case moment, post }
enum CreationSubmission: String, Codable, Sendable { case idle, sending, uncertain }
enum CreationMediaState: String, Codable, Sendable { case preparing, waiting, uploading, uploaded, failed }

struct CreationMedia: Codable, Identifiable, Sendable {
    var id = UUID()
    var filename: String?
    var remotePath: String?
    var attachmentID: Int?
    var mimeType = "image/jpeg"
    var state: CreationMediaState = .preparing
    var error: String?
}

struct CreationMusic: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var spec: String
    var title: String
    var artist: String
    var cover: String?
    var marker: MusicMarker? { MarkdownParser.musicMarker(from: spec) }

    init(spec: String) {
        self.spec = spec
        let marker = MarkdownParser.musicMarker(from: spec)
        title = marker?.title ?? (marker?.type == "playlist" ? "QQ 音乐歌单" : "QQ 音乐")
        artist = marker?.artist ?? "QQ 音乐"
        cover = marker?.cover
    }

    static func split(_ content: String) -> (text: String, music: [CreationMusic]) {
        let lines = content.components(separatedBy: "\n")
        var text: [String] = []
        var music: [CreationMusic] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep ordinary code blocks intact, including examples of !music.
            if let marker = line.first, marker == "`" || marker == "~" {
                let fenceLength = line.prefix(while: { $0 == marker }).count
                if fenceLength >= 3 {
                    let language = line.dropFirst(fenceLength).trimmingCharacters(in: .whitespaces).lowercased()
                    var end = index + 1
                    while end < lines.count {
                        let closing = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
                        if closing.count >= fenceLength && closing.allSatisfy({ $0 == marker }) { break }
                        end += 1
                    }
                    let specs = lines[(index + 1)..<end]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if end < lines.count, language == "music" || language == "qqvip",
                       !specs.isEmpty, specs.allSatisfy({ MarkdownParser.musicMarker(from: $0) != nil }) {
                        music.append(contentsOf: specs.map { CreationMusic(spec: MarkdownParser.musicPayload(in: $0) ?? $0) })
                    } else {
                        text.append(contentsOf: lines[index..<min(end + 1, lines.count)])
                    }
                    index = min(end + 1, lines.count)
                    continue
                }
            }
            if let spec = MarkdownParser.musicPayload(in: line), MarkdownParser.musicMarker(from: spec) != nil {
                music.append(CreationMusic(spec: spec))
            } else {
                text.append(lines[index])
            }
            index += 1
        }
        return (text.joined(separator: "\n"), music)
    }
}

struct CreationDraft: Codable, Identifiable, Sendable {
    var id = UUID()
    var site: String
    var kind: CreationKind
    var serverID: Int?
    var createdAt = Date()
    var updatedAt = Date()
    var revision = 0
    var text = ""
    var title = ""
    var slug = ""
    var cover = ""
    var category = ""
    var tags = ""
    var status = "draft"
    var attachmentIDs: [Int] = []
    var references: [AdminReferenceSnapshot] = []
    var media: [CreationMedia] = []
    var music: [CreationMusic] = []
    var submission: CreationSubmission = .idle

    var serializedContent: String {
        let markers = music.map { item in
            let spec = MarkdownParser.musicPayload(in: item.spec) ?? item.spec.trimmingCharacters(in: .whitespacesAndNewlines)
            return kind == .moment ? "!music \(spec)" : "```music\n\(spec)\n```"
        }
        return ([text] + markers).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var articleSubmissionContent: String {
        let images = media.compactMap { item in item.remotePath.map { "![照片](\($0))" } }.joined(separator: "\n\n")
        return [serializedContent, images].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var hasContent: Bool { text.trimmedNonEmpty != nil || title.trimmedNonEmpty != nil || !media.isEmpty || !music.isEmpty }
    var summary: String { title.trimmedNonEmpty ?? text.trimmedNonEmpty.map { String($0.prefix(65)) } ?? music.first?.title ?? "\(media.count) 张照片" }
}

struct CreationDraftScan: Sendable {
    let drafts: [CreationDraft]
    let warnings: [String]
}

actor CreationDraftStore {
    static let shared: CreationDraftStore = {
#if DEBUG
        if CreationPreview.isEnabled && ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return CreationDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CreationUITests-\(UUID())", isDirectory: true))
        }
#endif
        return CreationDraftStore()
    }()
    let directory: URL
    private var removed: Set<String> = []

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CreationDrafts", isDirectory: true)
    }

    nonisolated static func canonicalSite(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host?.lowercased()
        if let port = url.port, !(port == 443 && components.scheme == "https"), !(port == 80 && components.scheme == "http") { components.port = port }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func siteDirectory(_ site: String) -> URL {
        let hash = SHA256.hash(data: Data(site.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash, isDirectory: true)
    }

    private func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = url
        try folder.setResourceValues(values)
    }

    func save(_ draft: CreationDraft) throws {
        guard !removed.contains("\(draft.site)/\(draft.id)") else { return }
        let folder = siteDirectory(draft.site)
        try prepare(folder)
        let path = folder.appendingPathComponent("\(draft.id).json")
        let existing = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(CreationDraft.self, from: $0) }
        if let existing, existing.revision > draft.revision { return }
        try JSONEncoder().encode(draft).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let retained = Set(draft.media.compactMap(\.filename))
        for media in existing?.media ?? [] {
            if let filename = media.filename, !retained.contains(filename) { try removeImage(site: draft.site, mediaID: media.id, filename: filename) }
        }
    }

    func list(site: String) throws -> [CreationDraft] { try scan(site: site).drafts }

    func scan(site: String) throws -> CreationDraftScan {
        let folder = siteDirectory(site)
        guard FileManager.default.fileExists(atPath: folder.path) else { return CreationDraftScan(drafts: [], warnings: []) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" && $0.lastPathComponent != "recent.json" }
        var drafts: [CreationDraft] = []
        var warnings: [String] = []
        for file in files {
            do {
                var draft = try JSONDecoder().decode(CreationDraft.self, from: Data(contentsOf: file))
                guard draft.site == site else { continue }
                if draft.submission == .sending { draft.submission = .uncertain }
                for index in draft.media.indices {
                    if let filename = draft.media[index].filename {
                        if !ownedImage(filename, id: draft.media[index].id) || !FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) {
                            draft.media[index].state = .failed
                            draft.media[index].error = "本地图片文件缺失，请移除后重新选择"
                        } else if [.preparing, .uploading].contains(draft.media[index].state) {
                            draft.media[index].state = .waiting
                        }
                    } else if draft.media[index].remotePath == nil {
                        draft.media[index].state = .failed
                        draft.media[index].error = "图片未准备完成，请重新选择"
                    }
                }
                if draft.hasContent || draft.serverID != nil || draft.submission != .idle { drafts.append(draft) }
            } catch {
                warnings.append("本机草稿损坏（\(file.lastPathComponent)），原文件已保留，可导出恢复")
            }
        }
        return CreationDraftScan(drafts: drafts.sorted { $0.updatedAt > $1.updatedAt }, warnings: warnings)
    }

    private func validFilename(_ name: String) -> Bool {
        name == URL(fileURLWithPath: name).lastPathComponent && !name.contains("..") && !name.contains("/")
    }

    private func ownedImage(_ filename: String, id: UUID) -> Bool {
        validFilename(filename) && ["\(id).jpg", "\(id).png"].contains(filename)
    }

    func removeImage(site: String, mediaID: UUID, filename: String) throws {
        guard ownedImage(filename, id: mediaID) else { return }
        let folder = siteDirectory(site)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "recent.json" {
            if let data = try? Data(contentsOf: file), let draft = try? JSONDecoder().decode(CreationDraft.self, from: data), draft.media.contains(where: { $0.filename == filename }) { return }
        }
        let url = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func writeImage(_ data: Data, site: String, id: UUID, extensionName: String) throws -> String {
        guard ["jpg", "png"].contains(extensionName) else { throw APIError.invalidURL }
        let folder = siteDirectory(site)
        try prepare(folder)
        let name = "\(id).\(extensionName)"
        try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    func imageURL(site: String, filename: String) throws -> URL {
        guard validFilename(filename) else { throw APIError.invalidURL }
        return siteDirectory(site).appendingPathComponent(filename)
    }

    func imageData(site: String, filename: String) throws -> Data {
        try Data(contentsOf: imageURL(site: site, filename: filename))
    }

    func remove(_ draft: CreationDraft) throws {
        let folder = siteDirectory(draft.site)
        let json = folder.appendingPathComponent("\(draft.id).json")
        let persisted = (try? Data(contentsOf: json)).flatMap { try? JSONDecoder().decode(CreationDraft.self, from: $0) }
        if FileManager.default.fileExists(atPath: json.path) { try FileManager.default.removeItem(at: json) }
        removed.insert("\(draft.site)/\(draft.id)")
        for media in draft.media + (persisted?.media ?? []) {
            if let name = media.filename { try removeImage(site: draft.site, mediaID: media.id, filename: name) }
        }
    }

    func recent(site: String) throws -> [CreationMusic] {
        let url = siteDirectory(site).appendingPathComponent("recent.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CreationMusic].self, from: Data(contentsOf: url))
    }

    func remember(_ music: CreationMusic, site: String) throws {
        let folder = siteDirectory(site)
        try prepare(folder)
        var items = try recent(site: site)
        items.removeAll { $0.marker?.id == music.marker?.id && $0.marker?.type == music.marker?.type }
        items.insert(music, at: 0)
        try JSONEncoder().encode(Array(items.prefix(10))).write(to: folder.appendingPathComponent("recent.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
