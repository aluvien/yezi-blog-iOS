import Foundation
import XCTest
@testable import YeziApp

final class YeziAppTests: XCTestCase {
    func testAPIURLJoinsBasePathAndPercentEncodesQuery() {
        let client = APIClient(baseURL: URL(string: "https://yezi.me/api/v1")!)
        let url = client.makeURL(path: "/posts", queryItems: [
            URLQueryItem(name: "view", value: "summary"),
            URLQueryItem(name: "q", value: "Swift 中文"),
        ])

        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "yezi.me")
        XCTAssertEqual(url?.path, "/api/v1/posts")
        XCTAssertTrue(url?.absoluteString.contains("view=summary") == true)
        XCTAssertTrue(url?.absoluteString.contains("q=Swift%20%E4%B8%AD%E6%96%87") == true)
    }

    func testSiteURLResolverMakesRelativeImageURLsAbsolute() {
        let resolver = SiteURLResolver()

        XCTAssertEqual(resolver.absoluteURL("/uploads/cover.jpg")?.absoluteString, "https://yezi.me/uploads/cover.jpg")
        XCTAssertEqual(resolver.absoluteURL("images/cover.jpg")?.absoluteString, "https://yezi.me/images/cover.jpg")
        XCTAssertNil(resolver.absoluteURL("javascript:alert(1)"))
    }

    func testSummaryCodableToleratesNullsAndUnknownFields() throws {
        let data = #"""
        {
          "data": [{
            "id": 7,
            "title": "移动端文章",
            "slug": "native-app",
            "excerpt": "摘要",
            "cover": null,
            "category": null,
            "tags": null,
            "created_at": "2026-08-18T00:00:00.000Z",
            "updated_at": null,
            "comments_count": null,
            "metrics": {"views": 2, "likes": null, "new_field": true},
            "future_field": {"anything": "ignored"}
          }],
          "meta": {"page": 1, "limit": 20, "total": 1, "total_pages": 1},
          "new_top_level_field": true
        }
        """#.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(APIEnvelope<[PostSummary]>.self, from: data)
        XCTAssertEqual(envelope.data?.first?.id, 7)
        XCTAssertNil(envelope.data?.first?.cover)
        XCTAssertNil(envelope.data?.first?.tags)
        XCTAssertEqual(envelope.meta?.totalPages, 1)
    }

    func testPaginationStateAdvancesAndStopsAtTotalPages() {
        var state = PaginationState()
        XCTAssertEqual(state.begin(), 1)
        state.finish(meta: PaginationMeta(page: 1, limit: 20, total: 21, totalPages: 2))
        XCTAssertTrue(state.canLoadMore)
        XCTAssertEqual(state.begin(), 2)
        state.finish(meta: PaginationMeta(page: 2, limit: 20, total: 21, totalPages: 2))
        XCTAssertFalse(state.canLoadMore)
        XCTAssertNil(state.begin())
    }

    func testPaginationRefreshDoesNotResetAnInFlightRequest() {
        var state = PaginationState()
        XCTAssertEqual(state.begin(), 1)
        XCTAssertNil(state.begin(reset: true))
        XCTAssertTrue(state.isLoading)
        state.fail()
        XCTAssertEqual(state.begin(reset: true), 1)
    }

    func testMarkdownParserResolvesYeziReferenceToken() {
        let reference = ArticleReferenceSnapshot(
            url: "https://example.com/article",
            canonicalURL: "https://example.com/article",
            title: "公开引用",
            source: "Example",
            author: "作者",
            publishedAt: "2026-08-18",
            cover: "/uploads/reference.png",
            coverURL: "/api/article-references/image?url=x",
            description: "描述",
            summary: "摘要",
            keyPoints: ["要点"]
        )
        let marker = "!reference:\(MarkdownParser.referenceToken(for: reference))"
        let blocks = MarkdownParser.parse("# 标题\n\n**正文**\n\n\(marker)", references: [reference])

        XCTAssertTrue(blocks.contains { block in
            if case .reference(let value) = block { return value.title == "公开引用" }
            return false
        })
    }

    func testMarkdownParserSupportsTildeCodeFences() {
        let blocks = MarkdownParser.parse("~~~swift\nlet answer = 42\n~~~")
        XCTAssertTrue(blocks.contains { block in
            if case .code(let language, let text) = block {
                return language == "swift" && text.contains("answer = 42")
            }
            return false
        })
    }

    func testMarkdownParserRendersMusicMarkersAndFencedMusicAsMusicBlocks() {
        let blocks = MarkdownParser.parse("!music qqvip:9750959088:playlist:random\n\n```music\nqqvip:002eDlpu4U223F:song\nqqvip:002eDlpu4U223F:song:random\n```\n\n~~~qqvip\nqqvip:002eDlpu4U223F:song\n~~~")
        let specs = blocks.compactMap { block -> String? in
            if case .music(let spec) = block { return spec }
            return nil
        }

        XCTAssertEqual(specs, [
            "qqvip:9750959088:playlist:random",
            "qqvip:002eDlpu4U223F:song",
            "qqvip:002eDlpu4U223F:song:random",
            "qqvip:002eDlpu4U223F:song",
        ])
    }

    func testMusicSpecRoundTripsSearchMetadata() {
        let spec = MarkdownParser.makeMusicSpec(
            id: "002eDlpu4U223F",
            type: "song",
            title: "测试歌曲",
            artist: "测试歌手",
            cover: "https://y.gtimg.cn/music/photo.jpg"
        )
        let marker = MarkdownParser.musicMarker(from: spec)

        XCTAssertEqual(marker?.id, "002eDlpu4U223F")
        XCTAssertEqual(marker?.type, "song")
        XCTAssertEqual(marker?.title, "测试歌曲")
        XCTAssertEqual(marker?.artist, "测试歌手")
        XCTAssertEqual(marker?.cover, "https://y.gtimg.cn/music/photo.jpg")
    }

    func testMusicParserAcceptsWrappedMarkersAndPlaylistMetadata() {
        let playlistSpec = MarkdownParser.makeMusicSpec(
            id: "9750959088",
            type: "playlist",
            shuffle: true,
            title: "我的歌单",
            artist: "创建者",
            cover: "/playlist.jpg"
        )
        let blocks = MarkdownParser.parse("`!MUSIC:qqvip:002eDlpu4U223F:song`\n\n\(playlistSpec)")

        XCTAssertTrue(blocks.contains { block in
            if case .music(let spec) = block {
                return MarkdownParser.musicMarker(from: spec)?.id == "002eDlpu4U223F"
            }
            return false
        })
        let marker = MarkdownParser.musicMarker(from: playlistSpec)
        XCTAssertEqual(marker?.type, "playlist")
        XCTAssertEqual(marker?.title, "我的歌单")
        XCTAssertEqual(marker?.artist, "创建者")
        XCTAssertTrue(marker?.shuffle == true)
    }

    func testMusicFoldMarkerMatchesWebsiteFormat() {
        let song = MarkdownParser.makeMusicSpec(id: "ABC123", type: "song", folded: true, title: "晴天", artist: "周杰伦")
        XCTAssertTrue(song.hasPrefix("qqvip:ABC123:song:fold:meta-"))
        XCTAssertEqual(MarkdownParser.musicMarker(from: song)?.title, "晴天")
        XCTAssertEqual(MarkdownParser.musicMarker(from: song)?.artist, "周杰伦")
        XCTAssertEqual(MarkdownParser.musicMarker(from: song)?.folded, true)

        let playlist = MarkdownParser.makeMusicSpec(id: "9750959088", type: "playlist", shuffle: true, folded: true, title: "歌单")
        XCTAssertEqual(playlist, "qqvip:9750959088:playlist:random:fold")
        XCTAssertEqual(MarkdownParser.musicMarker(from: playlist)?.shuffle, true)
        XCTAssertEqual(MarkdownParser.musicMarker(from: playlist)?.folded, true)
        XCTAssertEqual(MarkdownParser.musicMarker(from: "qqvip:ABC123:song:collapsed")?.folded, true)
        XCTAssertNil(MarkdownParser.musicMarker(from: "qqvip:ABC123:song:random:fold:meta-extra"))
    }

    func testMarkdownParserRendersNativeVideoMarkers() {
        let blocks = MarkdownParser.parse("!video:https://cdn.example.com/demo.mp4\n\n```video\nhttps://cdn.example.com/demo.m3u8\n```")
        let urls = blocks.compactMap { block -> String? in
            if case .video(let url) = block { return url }
            return nil
        }

        XCTAssertEqual(urls, [
            "https://cdn.example.com/demo.mp4",
            "https://cdn.example.com/demo.m3u8",
        ])
    }

    func testMarkdownParserRendersProviderVideoSpecsAsPlaceholderURLs() {
        let blocks = MarkdownParser.parse("```video\nbilibili:BV13JMi6yE4p\nbilibili:av123456:2\nyoutube:dQw4w9WgXcQ\n```")
        let urls = blocks.compactMap { block -> String? in
            if case .video(let url) = block { return url }
            return nil
        }

        XCTAssertEqual(urls, [
            "https://www.bilibili.com/video/BV13JMi6yE4p",
            "https://www.bilibili.com/video/av123456?p=2",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        ])
    }

    func testReferenceParserDecodesAliasesAndURLFallback() {
        let json = #"{"link":"https://example.com/story","name":"引用文章","site":"Example","image_url":"/cover.jpg","excerpt":"摘要"}"#
        let encoded = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let blocks = MarkdownParser.parse("!reference:\(encoded)\n\n!reference:https://example.com/old")
        let references = blocks.compactMap { block -> ArticleReferenceSnapshot? in
            if case .reference(let reference) = block { return reference }
            return nil
        }

        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(references[0].url, "https://example.com/story")
        XCTAssertEqual(references[0].displayTitle, "引用文章")
        XCTAssertEqual(references[0].resolvedCoverValue, "/cover.jpg")
        XCTAssertEqual(references[1].url, "https://example.com/old")
    }

    func testMarkdownParserKeepsReferenceSnapshotCoverURLAndShortToken() {
        let reference = ArticleReferenceSnapshot(
            url: "https://example.com/article",
            canonicalURL: "https://example.com/article",
            title: "引用文章",
            source: "Example",
            author: nil,
            publishedAt: nil,
            cover: "/legacy.jpg",
            coverURL: "/api/article-references/image?url=encoded",
            description: nil,
            summary: "摘要",
            keyPoints: nil
        )
        let marker = "!reference:\(MarkdownParser.referenceToken(for: reference))"
        let blocks = MarkdownParser.parse(marker, references: [reference])

        XCTAssertTrue(blocks.contains { block in
            if case .reference(let value) = block {
                return value.resolvedCoverValue == "/api/article-references/image?url=encoded"
            }
            return false
        })
    }

    func testReferenceCoverURLTakesPriorityOverLegacyCover() throws {
        let data = #"{"url":"https://example.com","cover":"/legacy.jpg","cover_url":"/proxy.jpg"}"#.data(using: .utf8)!
        let reference = try JSONDecoder().decode(ArticleReferenceSnapshot.self, from: data)
        XCTAssertEqual(reference.resolvedCoverValue, "/proxy.jpg")
    }

    func testAdminMusicTrackDecodesOptionalPlayableURLAliases() throws {
        let data = #"{"mid":"song-1","name":"歌曲","artist":"歌手","album":"专辑","cover":"/cover.jpg","audio_url":"/preview.mp3"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let track = try decoder.decode(AdminMusicTrack.self, from: data)
        XCTAssertEqual(track.mid, "song-1")
        XCTAssertEqual(track.playableURL, "/preview.mp3")
    }

    func testAdminMusicTrackDecodesPublicExactPlaybackMetadata() throws {
        let data = #"{"name":"准确歌曲","artist":"准确歌手","cover":"https://example.com/cover.jpg","key":"qqvip:song-1","url":"https://example.com/song.mp3"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let track = try decoder.decode(AdminMusicTrack.self, from: data)

        XCTAssertEqual(track.name, "准确歌曲")
        XCTAssertEqual(track.artist, "准确歌手")
        XCTAssertEqual(track.cover, "https://example.com/cover.jpg")
        XCTAssertEqual(track.playableURL, "https://example.com/song.mp3")
    }

    func testAdminQQMusicPlaylistPlaybackResponseDecodesCount() throws {
        let data = #"{"tracks":[],"total":12,"skipped":3}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(AdminQQMusicPlaylistPlaybackResponse.self, from: data)

        XCTAssertEqual(response.total, 12)
        XCTAssertEqual(response.skipped, 3)
        XCTAssertTrue(response.tracks.isEmpty)
    }

    func testAdminPostDetailDecodesReferenceSnapshotAliases() throws {
        let data = #"""
        {
          "id": 9,
          "title": "文章",
          "slug": "post",
          "content": "正文",
          "category": "默认",
          "tags": [],
          "status": "draft",
          "attachment_ids": [3],
          "reference_snapshots": [{
            "canonical_url": "https://example.com/reference",
            "name": "引用标题",
            "site": "Example",
            "image_url": "/cover.jpg"
          }]
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let post = try decoder.decode(AdminPostDetail.self, from: data)

        XCTAssertEqual(post.referenceSnapshots.count, 1)
        XCTAssertEqual(post.referenceSnapshots[0].url, "https://example.com/reference")
        XCTAssertEqual(post.referenceSnapshots[0].title, "引用标题")
        XCTAssertEqual(post.referenceSnapshots[0].coverUrl, "/cover.jpg")
    }

    func testAdminReferenceLibraryDecodesSnakeCaseMetadataAndLinkedTitles() throws {
        let data = #"""
        {
          "id": 12,
          "url": "https://example.com/reference",
          "canonical_url": "https://example.com/reference",
          "title": "资料库引用",
          "source_name": "Example",
          "published_at": "2026-08-21",
          "cover_url": "/cover.jpg",
          "key_points": ["要点一"],
          "category": "阅读",
          "tags": ["iOS", "API"],
          "archive_captured_at": "2026-08-21T08:00:00.000Z",
          "archive_updated_at": "2026-08-21T08:01:00.000Z",
          "archive_cache_report": {"quality": "good", "cachedImages": 2},
          "linked_post_count": 2,
          "linked_post_titles": ["文章一", "文章二"]
        }
        """#.data(using: .utf8)!

        let item = try JSONDecoder().decode(ReferenceLibraryItem.self, from: data)
        XCTAssertEqual(item.id, 12)
        XCTAssertEqual(item.canonicalURL, "https://example.com/reference")
        XCTAssertEqual(item.sourceName, "Example")
        XCTAssertEqual(item.keyPoints, ["要点一"])
        XCTAssertEqual(item.linkedPostCount, 2)
        XCTAssertEqual(item.linkedPostTitles, "文章一、文章二")
        XCTAssertEqual(item.archiveCacheReport?.quality, "good")
        XCTAssertEqual(item.archiveCacheReport?.cachedImages, 2)
    }

    func testPublicPostDetailAcceptsReferenceSnapshotsAlias() throws {
        let data = #"{"id":1,"reference_snapshots":[{"url":"https://example.com/reference","title":"引用"}]}"#.data(using: .utf8)!
        let post = try JSONDecoder().decode(PostDetail.self, from: data)
        XCTAssertEqual(post.references?.first?.displayTitle, "引用")
    }

    func testAdminPaginationAcceptsCommonSnakeCaseAliases() throws {
        let data = #"{"current_page":2,"per_page":20,"total_count":41,"pages":3}"#.data(using: .utf8)!
        let meta = try JSONDecoder().decode(AdminPaginationMeta.self, from: data)
        XCTAssertEqual(meta.page, 2)
        XCTAssertEqual(meta.limit, 20)
        XCTAssertEqual(meta.total, 41)
        XCTAssertEqual(meta.totalPages, 3)
    }

    func testAdminSettingsNormalizeScalarValues() throws {
        let data = #"{"enabled":true,"interval":6,"name":"Yezi","ratio":1.5}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AdminStringMap.self, from: data).values
        XCTAssertEqual(settings["enabled"], "1")
        XCTAssertEqual(settings["interval"], "6")
        XCTAssertEqual(settings["name"], "Yezi")
        XCTAssertEqual(settings["ratio"], "1.5")
    }

    func testPublicResponseCacheRoundTripsAndClears() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YeziAppTests-\(UUID().uuidString)", isDirectory: true)
        let cache = ResponseCache(directory: directory)
        let key = "https://yezi.me/api/v1/posts?page=1"
        let payload = Data(#"{"data":[]}"#.utf8)

        await cache.store(payload, for: key)
        let cached = await cache.data(for: key)
        XCTAssertEqual(cached, payload)
        await cache.removeAll()
        let removed = await cache.data(for: key)
        XCTAssertNil(removed)
    }

    func testVisitorIdentityIsRandomUUIDAndPersistsInSecureStore() {
        let store = InMemorySecureValueStore()
        let first = VisitorIdentity(store: store).id
        let second = VisitorIdentity(store: store).id

        XCTAssertNotEqual(first, "")
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.value(for: "visitor-id"), first)
    }
}
