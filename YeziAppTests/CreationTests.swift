import XCTest
import Foundation
import UIKit
import SwiftUI
@testable import YeziApp

private struct FixtureReply: Sendable {
    var status = 200
    var body: Data
    var delay: TimeInterval = 0
    var failure: URLError.Code?
    var rawCancellation = false
    init(_ json: String, status: Int = 200, delay: TimeInterval = 0, failure: URLError.Code? = nil, rawCancellation: Bool = false) {
        body = Data(json.utf8); self.status = status; self.delay = delay; self.failure = failure; self.rawCancellation = rawCancellation
    }
}

private final class CreationFixtureServer: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) -> FixtureReply
    let host = "\(UUID().uuidString.lowercased()).invalid"
    init(handler: @escaping @Sendable (URLRequest) -> FixtureReply) { self.handler = handler; CreationFixtureProtocol.register(self) }
    func response(_ request: URLRequest) -> FixtureReply { lock.withLock { requests.append(request) }; return handler(request) }
    var recorded: [URLRequest] { lock.withLock { requests } }
    var api: AdminAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreationFixtureProtocol.self]
        configuration.httpCookieStorage = nil
        return AdminAPIClient(siteRoot: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }
}

private final class CreationFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: CreationFixtureServer] = [:]
    static func register(_ server: CreationFixtureServer) { lock.withLock { servers[server.host] = server } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.host ?? ""] }) else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            captured.httpBody = data
        }
        let reply = server.response(captured)
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        if reply.rawCancellation { client?.urlProtocol(self, didFailWithError: CancellationError()); return }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor UploadAudit {
    var active = 0
    var maximum = 0
    var filenames: [String] = []
    var failedOnce: Set<String> = []
    func start(_ filename: String) { active += 1; maximum = max(active, maximum); filenames.append(filename) }
    func finish() { active -= 1 }
    func shouldFail(_ filename: String) -> Bool { if failedOnce.contains(filename) { return false }; failedOnce.insert(filename); return true }
}

private final class FixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

final class CreationTests: XCTestCase {
    private func store() -> CreationDraftStore {
        CreationDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CreationTests-\(UUID())"))
    }
    private let site = "https://example.com"
    private static let post = #"{"id":42,"title":"文章","slug":"post-42","content":"正文","category":"随笔","tags":[],"status":"draft","attachmentIds":[],"referenceSnapshots":[]}"#
    private static let moment = #"{"id":9,"content":"内容","images":[]}"#

    @MainActor func testFailedCommentReplyAndDeletePreserveContentAndAllowRetry() async throws {
        let commentJSON = #"{"id":4,"targetType":"post","targetId":42,"nickname":"读者","content":"访客原文","status":"pending"}"#
        let repliedJSON = #"{"id":4,"targetType":"post","targetId":42,"nickname":"读者","content":"访客原文","status":"pending","adminReply":"谢谢你"}"#
        let counter = FixtureCounter()
        let server = CreationFixtureServer { request in
            if request.httpMethod == "DELETE" { return FixtureReply(#"{"error":"暂时无法删除"}"#, status: 500) }
            if counter.increment() == 1 { return FixtureReply(#"{"error":"暂时无法保存"}"#, status: 500) }
            return FixtureReply("{\"data\":\(repliedJSON)}")
        }
        let comment = try JSONDecoder().decode(AdminComment.self, from: Data(commentJSON.utf8))
        let model = AdminCommentsModel(api: server.api)
        model.items = [comment]
        let failedReply = await model.update(comment, action: .reply, reply: "谢谢你")
        XCTAssertFalse(failedReply)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.items.first?.content, "访客原文")
        XCTAssertNil(model.items.first?.adminReply)
        XCTAssertFalse(model.isMutating)
        let retry = await model.update(comment, action: .reply, reply: "谢谢你")
        XCTAssertTrue(retry)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.first?.adminReply, "谢谢你")
        let failedDelete = await model.delete(comment)
        XCTAssertFalse(failedDelete)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.adminReply, "谢谢你")
    }

    @MainActor func testCommentMutationRejectsDuplicateRequestsWhileSaving() async throws {
        let json = #"{"id":4,"targetType":"post","targetId":42,"nickname":"读者","content":"原文","status":"approved"}"#
        let server = CreationFixtureServer { _ in FixtureReply("{\"data\":\(json)}", delay: 0.15) }
        let comment = try JSONDecoder().decode(AdminComment.self, from: Data(json.utf8))
        let model = AdminCommentsModel(api: server.api)
        model.items = [comment]
        let first = Task { await model.update(comment, action: .approve) }
        await Task.yield()
        XCTAssertTrue(model.isMutating)
        let duplicate = await model.update(comment, action: .approve)
        XCTAssertFalse(duplicate)
        let result = await first.value
        XCTAssertTrue(result)
        XCTAssertEqual(server.recorded.count, 1)
        XCTAssertFalse(model.isMutating)
    }

    func testAttachmentDownloadPreservesOriginalFileBytes() async throws {
        let content = "# 阅读笔记\n\n中文与 emoji 🌿"
        let server = CreationFixtureServer { _ in FixtureReply(content) }
        let url = try await server.api.downloadAttachment(path: "/uploads/notes.md")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data(content.utf8))
        XCTAssertEqual(server.recorded.first?.url?.path, "/uploads/notes.md")
    }

    func testAttachmentDownloadRejectsErrorsAndPreservesCancellation() async throws {
        let missing = CreationFixtureServer { _ in FixtureReply("missing", status: 404) }
        do { _ = try await missing.api.downloadAttachment(path: "/missing.pdf"); XCTFail("404 must not become a readable file") }
        catch APIError.http(let status, _) { XCTAssertEqual(status, 404) }
        let cancelled = CreationFixtureServer { _ in FixtureReply("", failure: .cancelled) }
        do { _ = try await cancelled.api.downloadAttachment(path: "/cancelled.pdf"); XCTFail("must cancel") }
        catch { XCTAssertTrue(isRequestCancellation(error)) }
    }

    func testMarkdownFormattingReplacesSelectionAndPreservesSurroundingText() {
        let original = "你好 🎵 世界"
        let edit = MarkdownAction.bold.edit(text: original, selection: NSRange(location: 3, length: 2))
        XCTAssertEqual((original as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "你好 **🎵** 世界")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 2))
    }

    func testMarkdownToolbarInsertsAtCursorRatherThanDocumentEnd() {
        let original = "前面 后面"
        let edit = MarkdownAction.link.edit(text: original, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual((original as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "前面 [链接文字](https://)后面")
        XCTAssertEqual(edit.selection, NSRange(location: 4, length: 4))
    }

    func testMarkdownListFormatsWholeSelectedLinesWithoutTouchingNeighbors() {
        let original = "前言\n第一行\n第二行\n结语"
        let edit = MarkdownAction.numbered.edit(text: original, selection: NSRange(location: 3, length: 7))
        XCTAssertEqual((original as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "前言\n1. 第一行\n2. 第二行\n结语")
    }

    func testMarkdownHeadingKeepsCursorInsideCurrentLine() {
        let original = "开头\n正在写作\n末尾"
        let edit = MarkdownAction.heading.edit(text: original, selection: NSRange(location: 5, length: 0))
        XCTAssertEqual((original as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "开头\n## 正在写作\n末尾")
        XCTAssertEqual(edit.selection, NSRange(location: 8, length: 0))
    }

    func testFileLibraryClassifiesDocumentsMediaAndUnknownFiles() {
        XCTAssertEqual(LibraryFileKind.kind(mime: "application/octet-stream", name: "记录.MD"), .document)
        XCTAssertEqual(LibraryFileKind.kind(mime: "application/pdf", name: "计划.pdf"), .document)
        XCTAssertEqual(LibraryFileKind.kind(mime: "application/octet-stream", name: "照片.png"), .image)
        XCTAssertEqual(LibraryFileKind.kind(mime: "audio/mpeg", name: "音乐.mp3"), .audio)
        XCTAssertEqual(LibraryFileKind.kind(mime: "video/mp4", name: "视频.mp4"), .video)
        XCTAssertEqual(LibraryFileKind.kind(mime: "application/zip", name: "归档.zip"), .other)
    }

    func testCanonicalOriginAndSiteIsolation() async throws {
        XCTAssertEqual(CreationDraftStore.canonicalSite(URL(string: "HTTPS://EXAMPLE.COM:443/something")!), site)
        XCTAssertNotEqual(CreationDraftStore.canonicalSite(URL(string: "https://example.com:8443")!), site)
        let store = store()
        var draft = CreationDraft(site: site, kind: .moment); draft.text = "A"
        try await store.save(draft)
        let other = try await store.list(site: "https://other.example")
        XCTAssertTrue(other.isEmpty)
        let music = CreationMusic(spec: "qqvip:ABC123:song")
        try await store.remember(music, site: site)
        let recentOther = try await store.recent(site: "https://other.example")
        XCTAssertTrue(recentOther.isEmpty)
    }

    func testDraftRoundTripAfterStoreRecreationAndMissingFile() async throws {
        let original = store()
        let directory = await original.directory
        var draft = CreationDraft(site: site, kind: .moment)
        draft.text = "文字"; draft.music = [CreationMusic(spec: "qqvip:ABC123:song")]
        let id = UUID()
        let name = try await original.writeImage(Data([1, 2, 3]), site: site, id: id, extensionName: "jpg")
        draft.media = [CreationMedia(id: id, filename: name, remotePath: "/a.jpg", state: .uploaded)]
        try await original.save(draft)
        let restored = CreationDraftStore(directory: directory)
        let value = try await restored.list(site: site).first!
        XCTAssertEqual(value.text, "文字"); XCTAssertEqual(value.music.first?.spec, "qqvip:ABC123:song")
        XCTAssertEqual(value.media.first?.state, .uploaded)
        let url = try await restored.imageURL(site: site, filename: name)
        try FileManager.default.removeItem(at: url)
        let missing = try await restored.list(site: site).first!
        XCTAssertEqual(missing.media.first?.state, .failed)
        XCTAssertTrue(missing.media.first?.error?.contains("缺失") == true)
    }

    func testOldRevisionCannotOverwriteNew() async throws {
        let store = store()
        var newer = CreationDraft(site: site, kind: .moment); newer.text = "最新"; newer.revision = 5
        var older = newer; older.text = "旧"; older.revision = 2
        try await store.save(newer); try await store.save(older)
        let value = try await store.list(site: site).first
        XCTAssertEqual(value?.text, "最新")
    }

    func testMalformedNeighborPreservesHealthyDraftAndWarning() async throws {
        let store = store()
        var draft = CreationDraft(site: site, kind: .moment); draft.text = "健康草稿"
        try await store.save(draft)
        let marker = try await store.writeImage(Data([1]), site: site, id: UUID(), extensionName: "jpg")
        let folder = try await store.imageURL(site: site, filename: marker).deletingLastPathComponent()
        let malformed = folder.appendingPathComponent("broken.json")
        try Data("invalid json".utf8).write(to: malformed)
        let scan = try await store.scan(site: site)
        XCTAssertEqual(scan.drafts.count, 1); XCTAssertEqual(scan.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
    }

    func testControlledImagePathsRejectTraversal() async throws {
        let store = store()
        do { _ = try await store.imageURL(site: site, filename: "../secret"); XCTFail("must reject") } catch {}
    }

    func testDeleteDoesNotRecreateFromLateSaveAndKeepsOtherDraftImages() async throws {
        let store = store()
        var first = CreationDraft(site: site, kind: .moment); first.text = "first"
        var other = CreationDraft(site: site, kind: .moment); other.text = "other"
        let name = try await store.writeImage(Data([1]), site: site, id: UUID(), extensionName: "jpg")
        other.media = [CreationMedia(filename: name, remotePath: "/b.jpg", state: .uploaded)]
        try await store.save(first); try await store.save(other)
        try await store.remove(first); try await store.save(first)
        let values = try await store.list(site: site)
        XCTAssertEqual(values.map(\.id), [other.id])
        let otherData = try await store.imageData(site: site, filename: name)
        XCTAssertEqual(otherData, Data([1]))
    }

    func testCleanupRejectsRecentAndOtherDraftFilenamesAndDeletesOwnedOrphans() async throws {
        let store = store()
        let music = CreationMusic(spec: "qqvip:ABC123:song")
        try await store.remember(music, site: site)
        let ownedID = UUID()
        let filename = try await store.writeImage(Data([9]), site: site, id: ownedID, extensionName: "jpg")
        var other = CreationDraft(site: site, kind: .moment, text: "other")
        other.media = [CreationMedia(id: ownedID, filename: filename, remotePath: "/image.jpg", state: .uploaded)]
        try await store.save(other)
        let malicious = CreationDraft(site: site, kind: .moment, text: "delete", media: [CreationMedia(filename: "recent.json"), CreationMedia(filename: filename)])
        try await store.save(malicious); try await store.remove(malicious)
        let recent = try await store.recent(site: site)
        XCTAssertEqual(recent.count, 1)
        let retained = try await store.imageData(site: site, filename: filename)
        XCTAssertEqual(retained, Data([9]))
        let orphanID = UUID()
        let orphan = try await store.writeImage(Data([8]), site: site, id: orphanID, extensionName: "png")
        try await store.removeImage(site: site, mediaID: orphanID, filename: orphan)
        let url = try await store.imageURL(site: site, filename: orphan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testMusicReplaceRemoveAndBackgroundStop() async {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment), store: store())
        let first = CreationMusic(spec: "qqvip:ABC123:song")
        let second = CreationMusic(spec: "qqvip:DEF123:song")
        await model.addMusic(first)
        await model.addMusic(second, replacing: first.id)
        XCTAssertEqual(model.draft.music.count, 1)
        XCTAssertFalse(model.draft.serializedContent.contains("qqvip:ABC"))
        XCTAssertTrue(model.draft.serializedContent.contains("qqvip:DEF"))
        model.removeMusic(second.id)
        XCTAssertFalse(model.draft.serializedContent.contains("qqvip:"))
        XCTAssertTrue(CreationAudioPlayer.shared === CreationAudioPlayer.shared)
        CreationAudioPlayer.shared.stop()
        XCTAssertNil(CreationAudioPlayer.shared.playingID)
    }

    func testSendingRestoresAsUncertain() async throws {
        let store = store()
        var draft = CreationDraft(site: site, kind: .moment); draft.text = "pending"; draft.submission = .sending
        try await store.save(draft)
        let restored = try await store.list(site: site).first!
        XCTAssertEqual(restored.submission, .uncertain)
    }

    func testStrictArticleRequiredFields() throws {
        let original = try JSONSerialization.jsonObject(with: Data(Self.post.utf8)) as! [String: Any]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        for key in ["id", "title", "slug", "content", "status"] {
            var invalid = original; invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try decoder.decode(AdminPostDetail.self, from: JSONSerialization.data(withJSONObject: invalid)), key)
        }
    }

    func testAPIAcceptsDirectAndWrappedArticleObjects() async throws {
        for wrapped in [false, true] {
            let server = CreationFixtureServer { _ in FixtureReply(wrapped ? "{\"data\":\(Self.post)}" : Self.post) }
            let post = try await server.api.fetchPost(id: 42)
            XCTAssertEqual(post.content, "正文"); XCTAssertEqual(post.id, 42)
        }
    }

    func testRealDecoderPaginationAliasesAdvancePage() async throws {
        let server = CreationFixtureServer { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
            return FixtureReply("{\"data\":[],\"meta\":{\"current_page\":\(page),\"per_page\":20,\"total_count\":41,\"total_pages\":3}}")
        }
        let first = try await server.api.fetchMoments(page: 1)
        let second = try await server.api.fetchMoments(page: 2)
        XCTAssertEqual(first.meta.page, 1); XCTAssertEqual(second.meta.page, 2)
        XCTAssertEqual(second.meta.limit, 20); XCTAssertEqual(second.meta.total, 41); XCTAssertEqual(second.meta.totalPages, 3)
    }

    @MainActor func testCancelledFeedLoadsStaySilentAndRefreshCanRecover() async {
        let counter = FixtureCounter()
        let server = CreationFixtureServer { _ in
            let attempt = counter.increment()
            if attempt == 1 { return FixtureReply("", rawCancellation: true) }
            if attempt == 3 { return FixtureReply("", failure: .cancelled) }
            let content = attempt == 2 ? "旧内容" : "新内容"
            return FixtureReply("{\"data\":[{\"id\":9,\"content\":\"\(content)\",\"images\":[]}],\"meta\":{\"page\":1,\"limit\":20,\"total\":1,\"totalPages\":1}}")
        }
        let model = CreationFeedModel(api: server.api)
        await model.load(reset: true)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
        await model.load(reset: true)
        XCTAssertEqual(model.moments.first?.content, "旧内容")
        await model.load(reset: true)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.moments.first?.content, "旧内容")
        await model.load(reset: true)
        XCTAssertEqual(model.moments.first?.content, "新内容")
        XCTAssertNil(model.error)
    }

    @MainActor func testLatestFeedRefreshWinsOverSlowEarlierResponse() async throws {
        let counter = FixtureCounter()
        let server = CreationFixtureServer { _ in
            let first = counter.increment() == 1
            let content = first ? "过期内容" : "最新内容"
            return FixtureReply("{\"data\":[{\"id\":9,\"content\":\"\(content)\",\"images\":[]}],\"meta\":{\"page\":1,\"limit\":20,\"total\":1,\"totalPages\":1}}", delay: first ? 0.1 : 0)
        }
        let model = CreationFeedModel(api: server.api)
        let earlier = Task { await model.load(reset: true) }
        for _ in 0..<50 {
            if !server.recorded.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await model.load(reset: true)
        await earlier.value
        XCTAssertEqual(model.moments.first?.content, "最新内容")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testSongMetadataLoadsWithoutPlayableAudio() async throws {
        let server = CreationFixtureServer { request in
            let type = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "type" })?.value
            if type == "metadata" {
                return FixtureReply(#"{"key":"qqvip:ABC123","name":"实际歌曲","artist":"实际歌手","cover":"https://example.com/cover.jpg"}"#)
            }
            return FixtureReply(#"{"error":"播放地址不可用"}"#, status: 502)
        }
        let track = try await server.api.fetchQQMusicMetadata(id: "ABC123")
        XCTAssertEqual(track.mid, "ABC123")
        XCTAssertEqual(track.name, "实际歌曲")
        XCTAssertEqual(track.artist, "实际歌手")
        XCTAssertEqual(server.recorded.first?.url?.path, "/api/music/qq")
        XCTAssertEqual(URLComponents(url: server.recorded.first!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "type" })?.value, "metadata")
        do { _ = try await server.api.fetchQQMusicTrack(id: "ABC123"); XCTFail("播放接口应返回错误") }
        catch { XCTAssertEqual(server.recorded.count, 2) }
    }

    func testMusicSplitPreservesMultipleAndUnknownMarkdown() {
        let content = "文字\n!reference:abc\n\n```music\nqqvip:ABC123:song\n```\n\n```music\nqqvip:DEF123:playlist\n```\n\n```music\nunknown-platform\n```"
        let split = CreationMusic.split(content)
        XCTAssertEqual(split.music.count, 2)
        XCTAssertTrue(split.text.contains("!reference:abc")); XCTAssertTrue(split.text.contains("unknown-platform"))
        let draft = CreationDraft(site: site, kind: .moment, text: split.text, music: split.music)
        XCTAssertEqual(MarkdownParser.parse(draft.serializedContent).filter { if case .music = $0 { true } else { false } }.count, 2)
    }

    func testMomentMusicMarkersRoundTripWithMetadataAndShuffle() {
        let song = MarkdownParser.makeMusicSpec(id: "ABC123", type: "song", title: "歌曲", artist: "歌手", cover: "https://example.com/cover.jpg")
        let playlist = "qqvip:9750959088:playlist:random"
        let draft = CreationDraft(site: site, kind: .moment, text: "分享音乐", music: [CreationMusic(spec: song), CreationMusic(spec: "!music \(playlist)")])
        XCTAssertEqual(draft.serializedContent, "分享音乐\n\n!music \(song)\n\n!music \(playlist)")
        let split = CreationMusic.split(draft.serializedContent)
        XCTAssertEqual(split.text.trimmingCharacters(in: .whitespacesAndNewlines), "分享音乐")
        XCTAssertEqual(split.music.map(\.spec), [song, playlist])
        XCTAssertEqual(split.music.first?.marker?.title, "歌曲")
        XCTAssertEqual(split.music.first?.marker?.artist, "歌手")
        XCTAssertEqual(split.music.first?.marker?.cover, "https://example.com/cover.jpg")
        XCTAssertEqual(split.music.last?.marker?.shuffle, true)
        let article = CreationDraft(site: site, kind: .post, music: [CreationMusic(spec: song)])
        XCTAssertEqual(article.serializedContent, "```music\n\(song)\n```")
    }

    func testMusicSplitPreservesCodeExamplesAndUnknownMarkers() {
        let untouched = "文字 🎵\n!reference:abc\n!music unknown-platform\n```text\n!music qqvip:CODE123:song\n```\n```music\nunknown-platform\n```\n```music\nqqvip:MIXED123:song\nunknown-platform\n```"
        let content = untouched + "\n!music qqvip:ABC123:song\n~~~qqvip\nqqvip:DEF123:playlist:random\n~~~\n```music\nqqvip:THIRD123:song\n```"
        let split = CreationMusic.split(content)
        XCTAssertEqual(split.text, untouched)
        XCTAssertEqual(split.music.map(\.spec), ["qqvip:ABC123:song", "qqvip:DEF123:playlist:random", "qqvip:THIRD123:song"])
        let unclosed = "```text\n!music qqvip:CODE123:song"
        XCTAssertEqual(CreationMusic.split(unclosed).text, unclosed)
        XCTAssertTrue(CreationMusic.split(unclosed).music.isEmpty)
    }

    @MainActor func testEditingMomentMusicReplacesAndRemovesLineMarkersInPayload() async throws {
        let split = CreationMusic.split("正文\n!music qqvip:ABC123:song\n!music qqvip:DEF123:playlist:random")
        XCTAssertEqual(split.music.count, 2)
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let draft = CreationDraft(site: site, kind: .moment, serverID: 9, text: split.text, music: split.music)
        let model = CreationComposerModel(api: server.api, draft: draft, store: store())
        let first = try XCTUnwrap(split.music.first)
        let last = try XCTUnwrap(split.music.last)
        await model.addMusic(CreationMusic(spec: "qqvip:NEW123:song"), replacing: first.id)
        model.removeMusic(last.id)
        let submitted = await model.submit()
        XCTAssertTrue(submitted)
        let request = try XCTUnwrap(server.recorded.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/admin/v1/moments/9")
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(payload["content"] as? String, "正文\n\n!music qqvip:NEW123:song")
    }

    @MainActor func testMomentMusicFoldChoiceIsPublishedAndCanBeChanged() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let original = CreationMusic(spec: MarkdownParser.makeMusicSpec(id: "ABC123", type: "song", title: "歌曲", artist: "歌手"))
        let draft = CreationDraft(site: site, kind: .moment, text: "正文", music: [original])
        let model = CreationComposerModel(api: server.api, draft: draft, store: store())
        model.setMusicFolded(original.id, folded: true)
        XCTAssertEqual(model.draft.music.first?.marker?.folded, true)
        XCTAssertTrue(model.draft.serializedContent.contains("qqvip:ABC123:song:fold:meta-"))
        let result = await model.submit()
        XCTAssertTrue(result)
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(server.recorded.first?.httpBody)) as! [String: Any]
        let content = try XCTUnwrap(payload["content"] as? String)
        XCTAssertTrue(content.contains("!music qqvip:ABC123:song:fold:meta-"))
        let split = CreationMusic.split(content)
        XCTAssertEqual(split.music.first?.marker?.folded, true)

        let edited = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: split.text, music: split.music), store: store())
        let foldedID = try XCTUnwrap(split.music.first?.id)
        edited.setMusicFolded(foldedID, folded: false)
        XCTAssertEqual(edited.draft.music.first?.marker?.folded, false)
        XCTAssertFalse(edited.draft.serializedContent.contains(":fold"))
    }

    @MainActor func testMusicPickerFoldIsOnlyAvailableForMoments() {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let moment = MusicPickerModel(api: server.api, allowsFolded: true)
        moment.selectManual("!music qqvip:ABC123:song:fold")
        XCTAssertEqual(moment.selection?.marker?.folded, true)
        let article = MusicPickerModel(api: server.api)
        article.selectManual("!music qqvip:ABC123:song:fold")
        XCTAssertEqual(article.selection?.marker?.folded, false)
    }

    func testExactPlaybackKeyExtractsMIDButRejectsWrongPlatformAndMalformedKey() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let exact = try decoder.decode(AdminMusicTrack.self, from: Data(#"{"key":"qqvip:song-1","url":"https://example.com/a.mp3"}"#.utf8))
        XCTAssertEqual(exact.mid, "song-1")
        for key in ["netease:song-1", "qqvip:", "qqvip:song-1:song", "qqvip:../foo"] {
            let json = try JSONSerialization.data(withJSONObject: ["key": key])
            XCTAssertEqual(try decoder.decode(AdminMusicTrack.self, from: json).mid, "")
        }
    }

    func testPlaybackURLResolvesCachedRelativePathAndRequiresExactMIDAndHTTP() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let siteRoot = URL(string: "https://example.com")!
        func track(_ raw: String, key: String = "qqvip:song-1") throws -> AdminMusicTrack {
            try decoder.decode(AdminMusicTrack.self, from: JSONSerialization.data(withJSONObject: ["key": key, "url": raw]))
        }
        XCTAssertEqual(CreationPlaybackURL.resolve(track: try track("/api/music/qq?mid=song-1"), expectedMID: "song-1", siteRoot: siteRoot)?.absoluteString, "https://example.com/api/music/qq?mid=song-1")
        XCTAssertEqual(CreationPlaybackURL.resolve(track: try track("https://cdn.example.com/song.mp3"), expectedMID: "song-1", siteRoot: siteRoot)?.host, "cdn.example.com")
        XCTAssertNotNil(CreationPlaybackURL.resolve(track: try track("http://cdn.example.com/song.mp3"), expectedMID: "song-1", siteRoot: siteRoot))
        XCTAssertNil(CreationPlaybackURL.resolve(track: try track("/api/music/qq?mid=other", key: "qqvip:other"), expectedMID: "song-1", siteRoot: siteRoot))
        XCTAssertNil(CreationPlaybackURL.resolve(track: try track("/api/music/qq", key: "netease:song-1"), expectedMID: "song-1", siteRoot: siteRoot))
        for raw in ["", " ", "file:///song.mp3", "data:audio/mp3;base64,AAAA", "ftp://example.com/song.mp3", "https://user:password@example.com/song.mp3"] {
            XCTAssertNil(CreationPlaybackURL.resolve(track: try track(raw), expectedMID: "song-1", siteRoot: siteRoot))
        }
    }

    @MainActor func testClearingSavedDraftDoesNotRestoreStaleText() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let store = store()
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment), store: store)
        model.edit { $0.text = "要清空的文字" }; await model.flush()
        model.edit { $0.text = "" }; await model.flush()
        let drafts = try await store.list(site: site)
        XCTAssertTrue(drafts.isEmpty)
        model.edit { $0.text = "重新输入" }; await model.flush()
        let retyped = try await store.list(site: site).first
        XCTAssertEqual(retyped?.text, "重新输入")
    }

    @MainActor func testDoubleSubmitAndTerminalAutosaveNeverResurrectDraft() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment, delay: 0.05) }
        let store = store()
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: "正文"), store: store)
        async let first = model.submit()
        async let second = model.submit()
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1); XCTAssertEqual(server.recorded.count, 1)
        XCTAssertTrue(model.didPublish)
        model.edit { $0.text = "late edit" }; await model.flush()
        try await Task.sleep(for: .milliseconds(500))
        let drafts = try await store.list(site: site)
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertEqual(server.recorded.first?.value(forHTTPHeaderField: "Origin"), "https://\(server.host)")
        XCTAssertEqual(server.recorded.first?.value(forHTTPHeaderField: "X-Yezi-CSRF"), "1")
    }

    @MainActor func testDiscardCancelsAutosaveAndRetainedModelCannotRestore() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let store = store()
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: "草稿"), store: store)
        model.edit { $0.text = "最新" }
        let discarded = await model.discard(); XCTAssertTrue(discarded)
        model.edit { $0.text = "late" }; await model.flush()
        try await Task.sleep(for: .milliseconds(500))
        let drafts = try await store.list(site: site); XCTAssertTrue(drafts.isEmpty)
    }

    @MainActor func testTimedOutCreationIsNotRetriedAndDraftRemains() async throws {
        let server = CreationFixtureServer { _ in FixtureReply("", failure: .timedOut) }
        let store = store()
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: "待确认"), store: store)
        let first = await model.submit(); let second = await model.submit()
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(server.recorded.count, 1)
        XCTAssertEqual(model.draft.submission, .uncertain)
        let saved = try await store.list(site: site).first
        XCTAssertEqual(saved?.text, "待确认"); XCTAssertEqual(saved?.submission, .uncertain)
    }

    @MainActor func testDefinitiveFailureKeepsEditorAndAllowsManualRetry() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(#"{"message":"invalid"}"#, status: 400) }
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: "保存"), store: store())
        let result = await model.submit()
        XCTAssertFalse(result); XCTAssertFalse(model.didPublish); XCTAssertEqual(model.draft.text, "保存")
        XCTAssertEqual(model.draft.submission, .idle)
    }

    @MainActor func testFourMomentPayloadCombinationsAndOrder() async throws {
        for mode in 0..<4 {
            let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
            var draft = CreationDraft(site: site, kind: .moment)
            if mode == 0 { draft.text = "纯文字" }
            if mode == 1 || mode == 3 { draft.media = [CreationMedia(remotePath: "/b.jpg", state: .uploaded), CreationMedia(remotePath: "/a.jpg", state: .uploaded)] }
            if mode == 2 || mode == 3 { draft.music = [CreationMusic(spec: "qqvip:ABC123:song")] }
            let model = CreationComposerModel(api: server.api, draft: draft, store: store())
            let result = await model.submit(); XCTAssertTrue(result)
            let payload = try JSONSerialization.jsonObject(with: server.recorded.first!.httpBody!) as! [String: Any]
            if mode == 1 { XCTAssertEqual(payload["content"] as? String, "") }
            if mode == 1 || mode == 3 { XCTAssertEqual(payload["images"] as? [String], ["/b.jpg", "/a.jpg"]) }
            if mode == 2 || mode == 3 { XCTAssertEqual(payload["content"] as? String, "!music qqvip:ABC123:song") }
        }
    }

    @MainActor func testPendingFailedImagesAndLimitBlockPublishing() async {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: "test"), store: store())
        let ids = model.reserveImages(count: 12)
        XCTAssertEqual(ids.count, 9); XCTAssertTrue(model.reserveImages(count: 2).isEmpty)
        XCTAssertTrue(model.submitBlocker?.contains("9") == true)
        model.failedImage(id: ids[0], message: "失败")
        for id in ids.dropFirst() { model.removeImage(id) }
        XCTAssertTrue(model.submitBlocker?.contains("失败") == true)
        let result = await model.submit(); XCTAssertFalse(result); XCTAssertTrue(server.recorded.isEmpty)
    }

    @MainActor func testNewArticleServerDraftPOSTThenPATCHAndPreservesLatestEdits() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post, delay: 0.05) }
        let store = store()
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, text: "正文", title: "文章"), store: store)
        let task = Task { await model.submit(serverDraft: true) }
        try await Task.sleep(for: .milliseconds(20))
        model.edit { $0.text = "保存期间的新输入" }
        let first = await task.value
        XCTAssertTrue(first); XCTAssertEqual(model.draft.serverID, 42); XCTAssertEqual(model.draft.text, "保存期间的新输入")
        let second = await model.submit(serverDraft: true)
        XCTAssertTrue(second); XCTAssertEqual(server.recorded.map(\.httpMethod), ["POST", "PATCH"])
        XCTAssertEqual(server.recorded.last?.url?.path, "/api/admin/v1/posts/42")
        let saved = try await store.list(site: site).first
        XCTAssertEqual(saved?.text, "保存期间的新输入")
    }

    @MainActor func testPublishedArticleOnlyLocalAutosaveAndNoImplicitDraft() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post.replacingOccurrences(of: "\"draft\"", with: "\"published\"")) }
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, serverID: 42), store: store())
        await model.load(); model.edit { $0.text += "最新" }; await model.flush()
        let result = await model.submit(serverDraft: true)
        XCTAssertFalse(result); XCTAssertEqual(model.draft.status, "published"); XCTAssertEqual(server.recorded.map(\.httpMethod), ["GET"])
    }

    @MainActor func testOpeningExistingContentDoesNotCreateLocalDraftUntilEdited() async throws {
        let postServer = CreationFixtureServer { _ in FixtureReply(Self.post.replacingOccurrences(of: "\"draft\"", with: "\"published\"")) }
        let postStore = store()
        let postSite = CreationDraftStore.canonicalSite(postServer.api.siteRoot)
        let post = CreationComposerModel(api: postServer.api, draft: CreationDraft(site: postSite, kind: .post, serverID: 42), store: postStore)
        await post.load()
        XCTAssertEqual(post.draft.text, "正文")
        let closedPost = await post.close()
        XCTAssertTrue(closedPost)
        let unopenedPostDrafts = try await postStore.list(site: postSite)
        XCTAssertTrue(unopenedPostDrafts.isEmpty)
        post.edit { $0.text += "修改" }
        let savedPost = await post.flush()
        XCTAssertTrue(savedPost)
        let editedPosts = try await postStore.list(site: postSite)
        XCTAssertEqual(editedPosts.first?.text, "正文修改")

        let momentStore = store()
        let moment = CreationComposerModel(api: postServer.api, draft: CreationDraft(site: postSite, kind: .moment, serverID: 9, text: "已有想法"), store: momentStore)
        await moment.load()
        let closedMoment = await moment.close()
        XCTAssertTrue(closedMoment)
        let unopenedMomentDrafts = try await momentStore.list(site: postSite)
        XCTAssertTrue(unopenedMomentDrafts.isEmpty)
        moment.edit { $0.text += "更新" }
        let savedMoment = await moment.flush()
        XCTAssertTrue(savedMoment)
        let editedMoments = try await momentStore.list(site: postSite)
        XCTAssertEqual(editedMoments.first?.text, "已有想法更新")
    }

    @MainActor func testUnchangedEditorCallbacksDoNotCreateDraft() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post) }
        let storage = store()
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, serverID: 42), store: storage)
        await model.load()
        let controller = MarkdownWritingController()
        let editor = MarkdownWritingView(text: model.binding(\.text), focused: .constant(false), controller: controller)
        let coordinator = editor.makeCoordinator()
        let textView = UITextView()
        textView.text = model.draft.text
        coordinator.textViewDidChange(textView)
        coordinator.textViewDidEndEditing(textView)
        model.binding(\.title).wrappedValue = model.draft.title
        await model.flush()
        XCTAssertEqual(model.draft.revision, 0)
        let drafts = try await storage.list(site: site)
        XCTAssertTrue(drafts.isEmpty)
    }

    @MainActor func testMarkdownControllerUpdatesOnceAndSupportsUndoRedo() {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let original = "你好 🌿 世界"
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: original), store: store())
        let controller = MarkdownWritingController()
        let editor = MarkdownWritingView(text: model.binding(\.text), focused: .constant(false), controller: controller)
        let coordinator = editor.makeCoordinator()
        let textView = UITextView()
        textView.text = original
        textView.delegate = coordinator
        controller.textView = textView
        textView.selectedRange = (original as NSString).range(of: "🌿 世界")
        textView.undoManager?.beginUndoGrouping()
        controller.apply(.bold)
        textView.undoManager?.endUndoGrouping()
        XCTAssertEqual(model.draft.text, "你好 **🌿 世界**")
        XCTAssertEqual(model.draft.revision, 1)
        XCTAssertEqual((textView.text as NSString).substring(with: textView.selectedRange), "🌿 世界")
        XCTAssertTrue(controller.canUndo)
        controller.undo()
        XCTAssertEqual(model.draft.text, original)
        XCTAssertTrue(controller.canRedo)
        controller.redo()
        XCTAssertEqual(model.draft.text, "你好 **🌿 世界**")
    }

    @MainActor func testMediaInsertionUsesSavedUTF16SelectionAndSupportsUndo() {
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let original = "前文 🌿 后文"
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment, text: original), store: store())
        let controller = MarkdownWritingController()
        let editor = MarkdownWritingView(text: model.binding(\.text), focused: .constant(false), controller: controller)
        let coordinator = editor.makeCoordinator()
        let textView = UITextView()
        textView.text = original
        textView.delegate = coordinator
        controller.textView = textView
        textView.selectedRange = (original as NSString).range(of: "🌿")
        textView.undoManager?.beginUndoGrouping()
        XCTAssertTrue(controller.insert("!music qqvip:ABC:song"))
        textView.undoManager?.endUndoGrouping()
        XCTAssertEqual(model.draft.text, "前文 !music qqvip:ABC:song 后文")
        XCTAssertEqual(model.draft.revision, 1)
        controller.undo()
        XCTAssertEqual(model.draft.text, original)
        textView.isEditable = false
        XCTAssertFalse(controller.insert("不应插入"))
        XCTAssertEqual(model.draft.text, original)
    }

    @MainActor func testOpeningSavedArticleDraftDoesNotRewriteIt() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post.replacingOccurrences(of: "\"draft\"", with: "\"published\"")) }
        let store = store()
        let site = CreationDraftStore.canonicalSite(server.api.siteRoot)
        var saved = CreationDraft(site: site, kind: .post, serverID: 42, text: "未发布的修改", title: "文章")
        saved.revision = 3
        try await store.save(saved)
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, serverID: 42), store: store)
        await model.load()
        XCTAssertEqual(model.draft.text, saved.text)
        let closed = await model.close()
        XCTAssertTrue(closed)
        let persisted = try await store.list(site: site)
        let unchanged = try XCTUnwrap(persisted.first)
        XCTAssertEqual(unchanged.revision, 3)
        XCTAssertEqual(unchanged.updatedAt, saved.updatedAt)
    }

    @MainActor func testRemotePublishedStatusOverridesLocalDraftWithoutLosingLocalText() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post.replacingOccurrences(of: "\"draft\"", with: "\"published\"")) }
        let store = store()
        let canonicalSite = CreationDraftStore.canonicalSite(server.api.siteRoot)
        var local = CreationDraft(site: canonicalSite, kind: .post, serverID: 42, text: "本机最新输入", title: "本机标题", status: "draft")
        local.revision = 4
        try await store.save(local)
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: canonicalSite, kind: .post, serverID: 42), store: store)
        await model.load()
        XCTAssertEqual(model.draft.text, "本机最新输入"); XCTAssertEqual(model.draft.status, "published")
        let result = await model.submit(serverDraft: true)
        XCTAssertFalse(result); XCTAssertEqual(server.recorded.map(\.httpMethod), ["GET"])
    }

    @MainActor func testArticleFailureRetryLoadsAndCannotSubmitEmptyResponse() async {
        let server = CreationFixtureServer { _ in FixtureReply(#"{"id":42,"title":"坏响应","slug":"post","status":"draft"}"#) }
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, serverID: 42), store: store())
        await model.load(); XCTAssertFalse(model.canEdit)
        let result = await model.submit(); XCTAssertFalse(result)
        await model.load(); XCTAssertEqual(server.recorded.count, 2)
        XCTAssertTrue(server.recorded.allSatisfy { $0.httpMethod == "GET" })
    }

    @MainActor func testMomentReferenceInlineAndArticleCompactSerialization() throws {
        let reference = try JSONDecoder().decode(AdminReferenceSnapshot.self, from: Data(#"{"url":"https://source.example/a","title":"完整引用","summary":"摘要"}"#.utf8))
        let server = CreationFixtureServer { _ in FixtureReply(Self.moment) }
        let moment = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .moment), store: store())
        moment.insertReference(reference)
        let blocks = MarkdownParser.parse(moment.draft.serializedContent)
        guard case .reference(let snapshot) = blocks.first else { return XCTFail("moment reference must resolve without snapshots") }
        XCTAssertEqual(snapshot.title, "完整引用"); XCTAssertEqual(snapshot.url, "https://source.example/a")
        let article = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post), store: store())
        article.insertReference(reference)
        XCTAssertEqual(article.draft.references.count, 1)
        XCTAssertNotEqual(article.draft.text, moment.draft.text)
    }

    @MainActor func testCoverSelectionActuallySetsCoverWithoutInsertingBody() throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post) }
        let attachment = try JSONDecoder().decode(AdminAttachment.self, from: Data(#"{"id":7,"path":"/cover.jpg","mimeType":"image/jpeg"}"#.utf8))
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, text: "正文"), store: store())
        model.selectCover(attachment)
        XCTAssertEqual(model.draft.cover, "/cover.jpg"); XCTAssertEqual(model.draft.attachmentIDs, [7]); XCTAssertEqual(model.draft.text, "正文")
    }

    @MainActor func testArticlePreviewAndPayloadShareImageContentWithoutDuplication() async throws {
        let server = CreationFixtureServer { _ in FixtureReply(Self.post) }
        let draft = CreationDraft(site: site, kind: .post, text: "正文", title: "文章", media: [CreationMedia(remotePath: "/one.jpg", state: .uploaded), CreationMedia(remotePath: "/two.jpg", state: .uploaded)])
        let model = CreationComposerModel(api: server.api, draft: draft, store: store())
        let preview = model.previewContent
        XCTAssertEqual(preview.components(separatedBy: "/one.jpg").count, 2)
        let first = await model.submit(serverDraft: true); XCTAssertTrue(first)
        let second = await model.submit(serverDraft: true); XCTAssertTrue(second)
        for request in server.recorded {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(payload["content"] as? String, preview)
        }
        XCTAssertEqual(model.draft.text, "正文")
        XCTAssertEqual(model.previewContent, preview)
    }

    @MainActor func testArticleRetrySuccessClearsOldError() async {
        let counter = FixtureCounter()
        let server = CreationFixtureServer { _ in
            counter.increment() == 1 ? FixtureReply("{}") : FixtureReply(Self.post)
        }
        let model = CreationComposerModel(api: server.api, draft: CreationDraft(site: site, kind: .post, serverID: 42), store: store())
        await model.load(); XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.canEdit)
        await model.load(); XCTAssertNil(model.errorMessage); XCTAssertTrue(model.canEdit)
        XCTAssertEqual(model.draft.text, "正文")
    }

    @MainActor func testMusicQueryGenerationRejectsOldResultsAndManualLinks() async throws {
        let server = CreationFixtureServer { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            return FixtureReply("{\"tracks\":[{\"mid\":\"\(query)\",\"name\":\"\(query)\"}],\"playlists\":[]}", delay: query == "oldsong" ? 0.4 : 0)
        }
        let model = MusicPickerModel(api: server.api, store: store())
        model.query = "oldsong"; try await Task.sleep(for: .milliseconds(350)); model.query = "newsong"
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.results.first?.marker?.id, "newsong")
        model.query = ""; XCTAssertTrue(model.results.isEmpty)
        model.selectManual("https://y.qq.com/n/ryqq/songDetail/ABC123"); XCTAssertEqual(model.selection?.marker?.id, "ABC123")
        model.selectManual("!music qqvip:DEF123:song"); XCTAssertEqual(model.selection?.spec, "qqvip:DEF123:song")
        model.selectManual("https://short.example/ABC"); XCTAssertNotNil(model.error)
        model.cancel()
    }

    @MainActor func testQueueConcurrencyRetryOnlyFailedAndRemovedLateCallback() async throws {
        let store = store()
        let audit = UploadAudit()
        var media: [CreationMedia] = []
        for _ in 0..<9 {
            let id = UUID()
            let filename = try await store.writeImage(Data([1]), site: site, id: id, extensionName: "jpg")
            media.append(CreationMedia(id: id, filename: filename, state: .waiting))
        }
        let failureFilename = media[1].filename!
        let queue = MediaUploadQueue(store: store, site: site) { _, filename, _ in
            await audit.start(filename)
            await Task.detached { try? await Task.sleep(for: .milliseconds(70)) }.value
            await audit.finish()
            if filename == failureFilename, await audit.shouldFail(filename) { throw APIError.transport("fixture failure") }
            return try JSONDecoder().decode(AdminAttachment.self, from: Data("{\"path\":\"/\(filename)\"}".utf8))
        }
        var changed: [CreationMedia] = []
        queue.onChange = { changed.append($0) }
        queue.restore(media)
        for _ in 0..<100 {
            if await audit.active == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await audit.active
        XCTAssertEqual(started, 2)
        let removedID = media[0].id
        queue.remove(removedID)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(changed.contains { $0.id == removedID && $0.state == .uploaded })
        XCTAssertTrue(changed.contains { $0.id == media[1].id && $0.state == .failed })
        XCTAssertEqual(changed.filter { $0.state == .uploaded }.count, 7)
        queue.retry(media[1].id)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(changed.contains { $0.id == media[1].id && $0.state == .uploaded })
        XCTAssertEqual(changed.filter { $0.state == .uploaded }.count, 8)
        let filenames = await audit.filenames
        XCTAssertEqual(filenames.filter { $0 == failureFilename }.count, 2)
        for item in media.dropFirst(2) { XCTAssertEqual(filenames.filter { $0 == item.filename }.count, 1) }
        let maximum = await audit.maximum
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    @MainActor func testImageProcessorDownsamplesAndPreservesTransparency() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1200))
        let input = renderer.image { context in UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1500, height: 1200)) }.pngData()!
        let prepared = try await CreationImageProcessor.prepare(input)
        XCTAssertEqual(prepared.mimeType, "image/png")
        let output = UIImage(data: prepared.data)!
        XCTAssertLessThanOrEqual(max(output.size.width, output.size.height), 2048)
        XCTAssertLessThan(prepared.data.count, 25 * 1024 * 1024)
    }
}
