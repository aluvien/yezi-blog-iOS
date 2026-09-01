import Foundation

// MARK: - Common API envelopes

struct APIEnvelope<Value: Decodable>: Decodable, Sendable where Value: Sendable {
    let data: Value?
    let meta: PaginationMeta?
    let query: String?
}

struct PaginationMeta: Decodable, Equatable, Sendable {
    let page: Int?
    let limit: Int?
    let total: Int?
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case page
        case limit
        case total
        case totalPages = "total_pages"
    }
}

struct PageResult<Item: Sendable>: Sendable {
    let items: [Item]
    let meta: PaginationMeta
}

// MARK: - Public site data

struct SiteInfo: Decodable, Sendable {
    let name: String?
    let subtitle: String?
    let description: String?
    let logo: String?
    let author: SiteAuthor?
    let aboutContent: String?
    let socialLinks: [SocialLink]?
    let navigation: [NavigationItem]?

    enum CodingKeys: String, CodingKey {
        case name
        case subtitle
        case description
        case logo
        case author
        case aboutContent = "about_content"
        case socialLinks = "social_links"
        case navigation
    }
}

struct SiteAuthor: Decodable, Sendable {
    let name: String?
    let avatar: String?
    let avatarNoBorder: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case avatar
        case avatarNoBorder = "avatar_no_border"
    }
}

struct SocialLink: Decodable, Hashable, Sendable {
    let label: String?
    let url: String?
}

struct NavigationItem: Decodable, Hashable, Sendable {
    let href: String?
    let label: String?
}

// MARK: - Posts, moments and works

struct PostSummary: Decodable, Hashable, Sendable {
    let id: Int?
    let title: String?
    let slug: String?
    let excerpt: String?
    let cover: String?
    let category: String?
    let tags: [String]?
    let createdAt: String?
    let updatedAt: String?
    let commentsCount: Int?
    let metrics: ContentMetrics?

    enum CodingKeys: String, CodingKey {
        case id, title, slug, excerpt, cover, category, tags
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case commentsCount = "comments_count"
        case metrics
    }

    var identity: String { slug ?? "post-\(id ?? 0)" }
    var displayTitle: String { title?.trimmedNonEmpty ?? "未命名文章" }
}

struct PostDetail: Decodable, Hashable, Sendable {
    let id: Int?
    let title: String?
    let slug: String?
    let content: String?
    let cover: String?
    let category: String?
    let tags: [String]?
    let createdAt: String?
    let updatedAt: String?
    let commentsCount: Int?
    let comments: [Comment]?
    let metrics: ContentMetrics?
    let references: [ArticleReferenceSnapshot]?

    enum CodingKeys: String, CodingKey {
        case id, title, slug, content, cover, category, tags, comments, metrics, references
        case referenceSnapshots = "reference_snapshots"
        case referenceSnapshotsCamel = "referenceSnapshots"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case commentsCount = "comments_count"
    }

    init(
        id: Int?,
        title: String?,
        slug: String?,
        content: String?,
        cover: String?,
        category: String?,
        tags: [String]?,
        createdAt: String?,
        updatedAt: String?,
        commentsCount: Int?,
        comments: [Comment]?,
        metrics: ContentMetrics?,
        references: [ArticleReferenceSnapshot]?
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.content = content
        self.cover = cover
        self.category = category
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.commentsCount = commentsCount
        self.comments = comments
        self.metrics = metrics
        self.references = references
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        commentsCount = try container.decodeIfPresent(Int.self, forKey: .commentsCount)
        comments = try container.decodeIfPresent([Comment].self, forKey: .comments)
        metrics = try container.decodeIfPresent(ContentMetrics.self, forKey: .metrics)
        let primaryReferences = try container.decodeIfPresent([ArticleReferenceSnapshot].self, forKey: .references) ?? []
        let snakeReferences = try container.decodeIfPresent([ArticleReferenceSnapshot].self, forKey: .referenceSnapshots) ?? []
        let camelReferences = try container.decodeIfPresent([ArticleReferenceSnapshot].self, forKey: .referenceSnapshotsCamel) ?? []
        references = primaryReferences.isEmpty ? (snakeReferences.isEmpty ? camelReferences : snakeReferences) : primaryReferences
    }

    var displayTitle: String { title?.trimmedNonEmpty ?? "未命名文章" }
    var identity: String { slug ?? "post-\(id ?? 0)" }
}

struct Comment: Decodable, Hashable, Sendable {
    let id: Int?
    let nickname: String?
    let content: String?
    let createdAt: String?
    let adminReply: String?
    let repliedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, nickname, content
        case createdAt = "created_at"
        case adminReply = "admin_reply"
        case repliedAt = "replied_at"
    }
}

struct ContentMetrics: Decodable, Hashable, Sendable {
    let views: Int?
    let likes: Int?
    let liked: Bool?
}

struct Moment: Decodable, Hashable, Sendable {
    let id: Int?
    let content: String?
    let images: [String]?
    let createdAt: String?
    let updatedAt: String?
    let commentsCount: Int?
    let metrics: ContentMetrics?

    enum CodingKeys: String, CodingKey {
        case id, content, images, metrics
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case commentsCount = "comments_count"
    }

    var identity: String { "moment-\(id ?? 0)" }
}

struct Work: Decodable, Hashable, Sendable {
    let id: Int?
    let title: String?
    let description: String?
    let cover: String?
    let link: String?
    let sortOrder: Int?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, cover, link
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    var identity: String { "work-\(id ?? 0)" }
}

// MARK: - Taxonomy and references

struct Category: Decodable, Hashable, Sendable {
    let id: Int?
    let name: String?
    let slug: String?
    let createdAt: String?
    let postsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case createdAt = "created_at"
        case postsCount = "posts_count"
    }

    var identity: String { slug ?? name ?? "category-\(id ?? 0)" }
}

struct Tag: Decodable, Hashable, Sendable {
    let tag: String?
    let count: Int?

    var identity: String { tag ?? "tag-\(count ?? 0)" }
}

/// A reference embedded in an article. The article-detail endpoint spreads the
/// server's camelCase snapshot and adds `cover_url`; decoding also accepts the
/// snake_case form so a future API serializer change remains non-fatal.
struct ArticleReferenceSnapshot: Decodable, Hashable, Sendable {
    let url: String?
    let canonicalURL: String?
    let title: String?
    let source: String?
    let author: String?
    let publishedAt: String?
    let cover: String?
    let coverURL: String?
    let description: String?
    let summary: String?
    let keyPoints: [String]?

    enum CodingKeys: String, CodingKey {
        case url, title, source, author, cover, description, summary
        case canonicalURL = "canonicalUrl"
        case canonicalSnake = "canonical_url"
        case publishedAt = "publishedAt"
        case publishedSnake = "published_at"
        case coverURL = "cover_url"
        case keyPoints = "keyPoints"
        case keyPointsSnake = "key_points"
    }

    init(
        url: String?,
        canonicalURL: String?,
        title: String?,
        source: String?,
        author: String?,
        publishedAt: String?,
        cover: String?,
        coverURL: String?,
        description: String?,
        summary: String?,
        keyPoints: [String]?
    ) {
        self.url = url
        self.canonicalURL = canonicalURL
        self.title = title
        self.source = source
        self.author = author
        self.publishedAt = publishedAt
        self.cover = cover
        self.coverURL = coverURL
        self.description = description
        self.summary = summary
        self.keyPoints = keyPoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        canonicalURL = try container.decodeIfPresent(String.self, forKey: .canonicalURL)
            ?? container.decodeIfPresent(String.self, forKey: .canonicalSnake)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
            ?? container.decodeIfPresent(String.self, forKey: .publishedSnake)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints)
            ?? container.decodeIfPresent([String].self, forKey: .keyPointsSnake)
    }

    var resolvedCoverValue: String? { coverURL?.trimmedNonEmpty ?? cover?.trimmedNonEmpty }
    var displayTitle: String { title?.trimmedNonEmpty ?? "引用文章" }
    var displaySource: String { source?.trimmedNonEmpty ?? "网页文章" }
}

struct ReferenceArchiveCacheReport: Decodable, Hashable, Sendable {
    let textCharacters: Int?
    let keptBlocks: Int?
    let removedBlocks: Int?
    let cachedImages: Int?
    let reusedImages: Int?
    let quality: String?

    private enum CodingKeys: String, CodingKey {
        case textCharacters, textCharactersSnake = "text_characters"
        case keptBlocks, keptBlocksSnake = "kept_blocks"
        case removedBlocks, removedBlocksSnake = "removed_blocks"
        case cachedImages, cachedImagesSnake = "cached_images"
        case reusedImages, reusedImagesSnake = "reused_images"
        case quality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textCharacters = Self.firstInt([.textCharacters, .textCharactersSnake], from: container)
        keptBlocks = Self.firstInt([.keptBlocks, .keptBlocksSnake], from: container)
        removedBlocks = Self.firstInt([.removedBlocks, .removedBlocksSnake], from: container)
        cachedImages = Self.firstInt([.cachedImages, .cachedImagesSnake], from: container)
        reusedImages = Self.firstInt([.reusedImages, .reusedImagesSnake], from: container)
        quality = try container.decodeIfPresent(String.self, forKey: .quality)
    }

    private static func firstInt(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) { return value }
        }
        return nil
    }
}

struct ReferenceLibraryItem: Decodable, Hashable, Sendable {
    let id: Int?
    let url: String?
    let canonicalURL: String?
    let title: String?
    let sourceName: String?
    let author: String?
    let publishedAt: String?
    let coverURL: String?
    let description: String?
    let summary: String?
    let keyPoints: [String]?
    let category: String?
    let tags: [String]?
    let createdAt: String?
    let updatedAt: String?
    /// Admin-only fields returned by the web reference-management query. The
    /// public references API omits these, so they remain optional for the
    /// shared model used by both endpoints.
    let archiveCapturedAt: String?
    let archiveUpdatedAt: String?
    let archiveCacheReport: ReferenceArchiveCacheReport?
    let linkedPostCount: Int?
    let linkedPostTitles: String?

    private enum CodingKeys: String, CodingKey {
        case id, url, title, author, description, summary, category, tags
        case canonicalURL, canonicalSnake = "canonical_url"
        case sourceName, sourceSnake = "source_name"
        case publishedAt, publishedSnake = "published_at"
        case coverURL, coverSnake = "cover_url"
        case keyPoints, keyPointsSnake = "key_points"
        case createdAt, createdSnake = "created_at"
        case updatedAt, updatedSnake = "updated_at"
        case archiveCapturedAt, archiveCapturedSnake = "archive_captured_at"
        case archiveUpdatedAt, archiveUpdatedSnake = "archive_updated_at"
        case archiveCacheReport, archiveCacheReportSnake = "archive_cache_report"
        case linkedPostCount, linkedPostCountSnake = "linked_post_count"
        case linkedPostTitles, linkedPostTitlesSnake = "linked_post_titles"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        canonicalURL = Self.firstString([.canonicalURL, .canonicalSnake], from: container)
        sourceName = Self.firstString([.sourceName, .sourceSnake], from: container)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        publishedAt = Self.firstString([.publishedAt, .publishedSnake], from: container)
        coverURL = Self.firstString([.coverURL, .coverSnake], from: container)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        keyPoints = Self.firstValue([.keyPoints, .keyPointsSnake], from: container)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        createdAt = Self.firstString([.createdAt, .createdSnake], from: container)
        updatedAt = Self.firstString([.updatedAt, .updatedSnake], from: container)
        archiveCapturedAt = Self.firstString([.archiveCapturedAt, .archiveCapturedSnake], from: container)
        archiveUpdatedAt = Self.firstString([.archiveUpdatedAt, .archiveUpdatedSnake], from: container)
        archiveCacheReport = Self.firstValue([.archiveCacheReport, .archiveCacheReportSnake], from: container)
        linkedPostCount = Self.firstValue([.linkedPostCount, .linkedPostCountSnake], from: container)
        linkedPostTitles = Self.firstString([.linkedPostTitles, .linkedPostTitlesSnake], from: container)
            ?? Self.firstStringArray([.linkedPostTitles, .linkedPostTitlesSnake], from: container)?.joined(separator: "、")
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

    private static func firstStringArray(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [String]? {
        for key in keys {
            if let value = try? container.decode([String].self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func firstValue<Value: Decodable>(
        _ keys: [CodingKeys],
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Value? {
        for key in keys {
            if let value = try? container.decode(Value.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    var identity: String {
        let stableURL = url ?? ""
        return "reference-\(id ?? 0)-\(stableURL)"
    }
    var displayTitle: String { title?.trimmedNonEmpty ?? "引用文章" }
}

// MARK: - Search

enum SearchResult: Decodable, Hashable, Sendable {
    case post(PostDetail)
    case moment(Moment)

    enum CodingKeys: String, CodingKey { case type, item }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)?.lowercased()
        if type == "moment" {
            self = .moment(try container.decodeIfPresent(Moment.self, forKey: .item) ?? Moment(id: nil, content: nil, images: nil, createdAt: nil, updatedAt: nil, commentsCount: nil, metrics: nil))
        } else {
            self = .post(try container.decodeIfPresent(PostDetail.self, forKey: .item) ?? PostDetail(id: nil, title: nil, slug: nil, content: nil, cover: nil, category: nil, tags: nil, createdAt: nil, updatedAt: nil, commentsCount: nil, comments: nil, metrics: nil, references: nil))
        }
    }

    var identity: String {
        switch self {
        case .post(let post): return "search-post-\(post.identity)"
        case .moment(let moment): return "search-moment-\(moment.identity)"
        }
    }
}

struct InteractionRequest: Encodable, Sendable {
    let targetType: String
    let targetID: Int
    let kind: String

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetID = "target_id"
        case kind
    }
}

// MARK: - Small decoding conveniences

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
