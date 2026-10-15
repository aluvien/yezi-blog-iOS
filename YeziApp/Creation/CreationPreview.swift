import Foundation
import UIKit

enum CreationPreview {
    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--creation-preview")
#else
        false
#endif
    }

    static var screen: String {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if isEnabled, let index = args.firstIndex(of: "--preview-screen"), args.indices.contains(index + 1) { return args[index + 1] }
#endif
        return "feed"
    }

    static var showsKeyboard: Bool {
#if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains("--preview-keyboard")
#else
        false
#endif
    }

#if DEBUG
    @MainActor static func fileData(for attachment: AdminAttachment) throws -> Data {
        let text = "# 旅行的备忘录\n\n把值得留下的细节，慢慢收集起来。\n\n## 出发之前\n\n- 带上相机和一本书\n- 留一点时间给散步\n\n> 生活的美好，藏在认真看见的瞬间。"
        let ext = (attachment.originalName as NSString).pathExtension.lowercased()
        if ["md", "markdown", "txt"].contains(ext) { return Data(text.utf8) }
        if ext == "pdf" {
            return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
                context.beginPage()
                ("十月阅读清单" as NSString).draw(at: CGPoint(x: 48, y: 70), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .bold)])
                ("留出一段安静的时间，读完手边的书。\n\n01  每天读二十页\n\n02  摘录喜欢的句子\n\n03  写下一点自己的想法" as NSString).draw(in: CGRect(x: 48, y: 140, width: 499, height: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        if ["jpg", "jpeg", "png"].contains(ext) {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000)).image { context in
                UIColor(red: 0.84, green: 0.87, blue: 0.77, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
                UIColor(red: 0.96, green: 0.89, blue: 0.66, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 420, y: 100, width: 220, height: 220)).fill()
                UIColor(red: 0.29, green: 0.48, blue: 0.37, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: -180, y: 500, width: 1100, height: 900)).fill()
            }
            if let data = ext == "png" ? image.pngData() : image.jpegData(compressionQuality: 0.85) { return data }
        }
        throw APIError.transport("离线演示未提供此文件，请使用 Markdown、PDF 或图片示例。")
    }
#endif

    static func makeAPI() -> AdminAPIClient? {
#if DEBUG
        guard isEnabled else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreationPreviewURLProtocol.self]
        configuration.httpCookieStorage = nil
        return AdminAPIClient(siteRoot: URL(string: "https://creation-preview.invalid")!, session: URLSession(configuration: configuration))
#else
        return nil
#endif
    }

    @MainActor
    static func seed() async {
#if DEBUG
        guard isEnabled else { return }
        let site = "https://creation-preview.invalid"
        let store = CreationDraftStore.shared
        guard (try? await store.list(site: site).isEmpty) == true else { return }
        var moment = CreationDraft(site: site, kind: .moment)
        moment.text = "傍晚的风终于凉下来。\n走得慢一点，就会发现路边的小小风景。"
        let music = CreationMusic(spec: MarkdownParser.makeMusicSpec(id: "003OUlho2HcRHC", type: "song", title: "晴天", artist: "周杰伦 · 叶惠美", cover: "/cover.jpg"))
        moment.music = [music]
        for index in 0..<3 {
            let id = UUID()
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 460))
            let image = renderer.image { context in
                let colors: [UIColor] = [UIColor(red: 0.62, green: 0.73, blue: 0.66, alpha: 1), UIColor(red: 0.72, green: 0.77, blue: 0.60, alpha: 1), UIColor(red: 0.62, green: 0.73, blue: 0.77, alpha: 1)]
                colors[index].setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 460))
                UIColor(red: 0.32, green: 0.49, blue: 0.37, alpha: 1).setFill()
                let hill = UIBezierPath(); hill.move(to: CGPoint(x: 0, y: 340)); hill.addCurve(to: CGPoint(x: 640, y: 300), controlPoint1: CGPoint(x: 180, y: 150), controlPoint2: CGPoint(x: 400, y: 480)); hill.addLine(to: CGPoint(x: 640, y: 460)); hill.addLine(to: CGPoint(x: 0, y: 460)); hill.close(); hill.fill()
                UIColor(red: 0.95, green: 0.91, blue: 0.70, alpha: 1).setFill(); UIBezierPath(ovalIn: CGRect(x: 430, y: 60, width: 90, height: 90)).fill()
            }
            if let data = image.jpegData(compressionQuality: 0.85), let filename = try? await store.writeImage(data, site: site, id: id, extensionName: "jpg") {
                moment.media.append(CreationMedia(id: id, filename: filename, remotePath: "/uploads/preview-\(index).jpg", state: .uploaded))
            }
        }
        try? await store.save(moment)
        try? await store.remember(music, site: site)
        for (id, title, artist) in [("002J4UUk29y8BY", "稻香", "周杰伦"), ("004Z8Ihr0JIu5s", "旅行的意义", "陈绮贞")] {
            try? await store.remember(CreationMusic(spec: MarkdownParser.makeMusicSpec(id: id, type: "song", title: title, artist: artist, cover: "/cover.jpg")), site: site)
        }
        var article = CreationDraft(site: site, kind: .post)
        article.title = "在日常里，找一点风景"
        article.text = "不必走得很远，日常也有值得留下的瞬间。\n\n## 走慢一点\n\n每天经过的小路，今天有了不一样的光。树影落在墙上，像一封写给傍晚的信。\n\n我们总是急着抵达，却忘了路上的风景。"
        article.category = "随笔"
        try? await store.save(article)
#endif
    }
}

#if DEBUG
final class CreationPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let data: Data
        let date = "2026-10-03T08:30:00.000Z"
        let music = MarkdownParser.makeMusicSpec(id: "003OUlho2HcRHC", type: "song", title: "晴天", artist: "周杰伦", cover: "/cover.jpg")
        let moments: [[String: Any]] = [
            ["id": 101, "content": "天气很好，路过一家小花店。\n买了一束没有名字的花，放在窗边。", "images": ["/uploads/preview-0.jpg"], "createdAt": date],
            ["id": 102, "content": "今天的循环播放。\n\n!music \(music)", "images": [], "createdAt": date],
            ["id": 103, "content": "", "images": ["/uploads/preview-0.jpg", "/uploads/preview-1.jpg"], "createdAt": date],
        ]
        let comments: [[String: Any]] = [
            ["id": 401, "targetType": "post", "targetId": 201, "targetLabel": "在日常里，找一点风景", "nickname": "小满", "content": "很喜欢这句话。慢下来以后，好像真的能看见更多原来被忽略的小事。谢谢你的分享！", "status": "pending", "createdAt": "2026-10-15T08:20:00Z"],
            ["id": 402, "targetType": "moment", "targetId": 101, "targetLabel": "路过的小花店", "nickname": "山间来信", "content": "给平凡的一天添一点颜色，真好。", "status": "pending", "createdAt": "2026-10-14T09:20:00Z"],
            ["id": 403, "targetType": "post", "targetId": 201, "targetLabel": "在日常里，找一点风景", "nickname": "木木", "content": "看完也想带着相机去散散步。", "status": "approved", "createdAt": date, "adminReply": "一起去找找秋天的光吧。"]
        ]
        let works: [[String: Any]] = [
            ["id": 601, "title": "慢慢生活 · 摄影手记", "description": "用影像记录散步、植物和日常里的光。", "cover": "/uploads/preview-0.jpg", "link": "https://creation-preview.invalid", "sortOrder": 0, "createdAt": date],
            ["id": 602, "title": "一间小站", "description": "为文字、音乐和生活碎片，留一处安静的地方。", "sortOrder": 1, "createdAt": date]
        ]
        let references: [[String: Any]] = [
            ["id": 701, "url": "https://example.com/slow-design", "title": "在快节奏的生活里，重新发现慢设计", "sourceName": "生活与设计", "author": "林间", "summary": "让设计回到人的日常：多留一点空白，照顾细小的感受，创造可以长久陪伴的事物。", "keyPoints": ["留白让信息更清楚", "为真实的日常设计"], "category": "设计与生活", "tags": ["设计", "阅读", "生活观察"], "updatedAt": date, "archiveCapturedAt": date, "archiveCacheReport": ["textCharacters": 3280, "cachedImages": 6], "linkedPostCount": 2, "linkedPostTitles": "在日常里，找一点风景"],
            ["id": 702, "url": "https://example.com/reading", "title": "给自己留一段安静阅读的时间", "sourceName": "阅读笔记", "author": "远山", "summary": "从每天的二十页开始，让阅读成为生活里可以期待的一段时间。", "updatedAt": date, "tags": ["阅读"]]
        ]
        var post: [String: Any] = ["id": 201, "title": "在日常里，找一点风景", "slug": "everyday-landscape", "content": "不必走得很远，日常也有值得留下的瞬间。\n\n## 走慢一点\n\n每天经过的小路，今天有了不一样的光。树影落在墙上，像一封写给傍晚的信。\n\n> 我们总是急着抵达，却忘了路上的风景。", "category": "随笔", "tags": ["日常"], "status": "published", "cover": "/uploads/preview-0.jpg", "createdAt": date, "attachmentIds": [], "referenceSnapshots": []]
        let object: Any
        if path == "/api/admin/v1/comments" {
            let status = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "status" })?.value ?? "all"
            let filtered = comments.filter { status == "all" || $0["status"] as? String == status }
            object = ["data": filtered, "meta": ["page": 1, "limit": 20, "total": filtered.count, "totalPages": 1]]
        } else if path.hasPrefix("/api/admin/v1/comments/") {
            var value = comments.first { String($0["id"] as? Int ?? 0) == path.components(separatedBy: "/").last } ?? comments[0]
            if let body = request.httpBody, let update = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if update["action"] as? String == "reply" { value["adminReply"] = update["reply"] }
                else { value["status"] = update["action"] as? String == "approve" ? "approved" : "spam" }
            }
            object = ["data": value]
        } else if path == "/api/admin/v1/works" { object = ["data": works, "meta": ["page": 1, "total": works.count, "totalPages": 1]] }
        else if path == "/api/admin/v1/categories" { object = ["data": [["id": 1, "name": "随笔", "slug": "notes", "postsCount": 12], ["id": 2, "name": "阅读与生活", "slug": "reading", "postsCount": 8]], "meta": ["page": 1, "totalPages": 1]] }
        else if path == "/api/admin/v1/tags" { object = ["data": [["tag": "日常", "count": 16], ["tag": "阅读", "count": 8], ["tag": "摄影", "count": 5]], "meta": ["page": 1, "totalPages": 1]] }
        else if path == "/api/admin/v1/references" { object = ["data": references, "meta": ["page": 1, "total": references.count, "totalPages": 1]] }
        else if path.hasPrefix("/api/admin/v1/references/") && path.hasSuffix("/reader") { object = ["data": ["id": 701, "title": "在快节奏的生活里，重新发现慢设计", "sourceName": "生活与设计", "author": "林间", "summary": "让设计回到人的日常，多留一点空白，照顾细小的感受。", "markdown": "## 把时间还给生活\n\n好的设计，不需要我们不停地追赶。它让日常的动作变得自然，让平凡的物件有了陪伴的温度。\n\n## 从细节开始\n\n- 给阅读留出空白\n- 让常用操作触手可及\n- 保留属于自己的节奏\n\n> 慢一点，往往能看得更清楚。", "capturedAt": date, "report": ["textCharacters": 3280, "cachedImages": 6]]] }
        else if path == "/api/admin/v1/dashboard" { object = ["data": ["posts": ["total": 20, "published": 18, "draft": 2], "comments": ["pending": 2], "moments": 32, "works": 2, "attachments": 4, "recentPosts": [], "recentComments": comments]] }
        else if path == "/api/admin/v1/moments" && method == "GET" { object = ["data": moments, "meta": ["current_page": 1, "per_page": 20, "total_count": 3, "pages": 1]] }
        else if path.contains("/moments") && ["POST", "PATCH"].contains(method) {
            var value = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            value["id"] = 301; value["createdAt"] = date; object = ["data": value]
        } else if path == "/api/admin/v1/posts" && method == "GET" { var draft = post; draft["id"] = 202; draft["title"] = "十月的阅读与写作清单"; draft["status"] = "draft"; draft["cover"] = ""; object = ["data": [post, draft], "meta": ["page": 1, "limit": 20, "total": 1, "totalPages": 1]] }
        else if path.contains("/posts") {
            if let body = request.httpBody, let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { post.merge(value) { _, new in new } }
            object = ["data": post]
        } else if path == "/api/admin/qq-music" {
            let operation = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "op" })?.value
            if operation == "status" { object = ["available": true, "loggedIn": true, "uin": "100001"] }
            else { object = ["tracks": [["mid": "003OUlho2HcRHC", "name": "晴天", "artist": "周杰伦", "album": "叶惠美", "cover": "/cover.jpg"], ["mid": "002J4UUk29y8BY", "name": "稻香", "artist": "周杰伦", "album": "魔杰座", "cover": "/cover.jpg"]], "playlists": [["id": "123456", "name": "散步的时候听", "creator": "叶子", "count": 12, "cover": "/cover.jpg"]]] }
        } else if path == "/api/music/qq" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.first(where: { $0.name == "type" })?.value == "playlist" { object = ["tracks": [], "total": 12, "skipped": 12] }
            else { object = ["mid": query.first(where: { $0.name == "id" })?.value ?? "", "name": "晴天", "artist": "周杰伦", "album": "叶惠美", "cover": "/cover.jpg"] }
        } else if path == "/api/admin/upload" { object = ["attachment": ["id": 801, "path": "/uploads/local-preview.jpg", "originalName": "照片.jpg", "mimeType": "image/jpeg", "size": 1000, "createdAt": date]] }
        else if path == "/api/admin/v1/attachments" {
            let files: [[String: Any]] = [
                ["id": 901, "path": "/uploads/travel.md", "originalName": "旅行的备忘录.md", "mimeType": "text/markdown", "size": 2400, "createdAt": "2026-10-15T09:00:00Z", "referenced": false],
                ["id": 902, "path": "/uploads/autumn.jpg", "originalName": "窗边的秋日光影.jpg", "mimeType": "image/jpeg", "size": 480000, "createdAt": "2026-10-14T09:00:00Z", "referenced": true],
                ["id": 903, "path": "/uploads/reading.pdf", "originalName": "十月阅读清单.pdf", "mimeType": "application/pdf", "size": 1250000, "createdAt": "2026-10-12T09:00:00Z", "referenced": false],
                ["id": 904, "path": "/uploads/wind.mp3", "originalName": "山间的风.mp3", "mimeType": "audio/mpeg", "size": 4600000, "createdAt": "2026-10-10T09:00:00Z", "referenced": false]
            ]
            object = ["data": files, "meta": ["page": 1, "totalPages": 1]]
        } else if path == "/api/admin/v1/settings" {
            object = ["data": ["site_name": "叶子的小站", "site_description": "记录生活，分享喜欢的事物。", "author_name": "叶子", "site_url": "https://creation-preview.invalid", "about_content": "## 你好，我是叶子\n\n这里是我的一间小站，收藏日常里的风景、音乐和一些慢慢生长的想法。\n\n## 我喜欢的事\n\n- 散步，和路边的植物打招呼\n- 阅读，把喜欢的句子记下来\n- 拍照，留下平凡生活里的光\n\n> 希望来到这里的你，也能收获一点安静和温暖。"]]
        } else if path == "/api/admin/v1/deploy/status" { object = ["data": ["status": "success", "updatedAt": date]] }
        else if path == "/api/admin/v1/deploy/version" { object = ["data": ["status": "up-to-date", "localCommit": "a12bc34", "remoteCommit": "a12bc34"]] }
        else if path == "/api/health/deploy" { object = ["status": "ok", "commit": "a12bc34", "schemaVersion": 1, "supportedSchemaVersion": 1] }
        else if path == "/api/admin/telegram" { object = ["configured": false, "qqMusic": ["status": "ok", "label": "服务正常"]] }
        else if path.contains("session") { object = ["authenticated": true] }
        else { object = ["data": [], "meta": ["page": 1, "totalPages": 1]] }
        data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
