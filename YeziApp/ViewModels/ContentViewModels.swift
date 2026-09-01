import Foundation
import Observation
import SwiftUI

@MainActor
final class PostListViewModel: ObservableObject {
    let category: String?
    let tag: String?
    let title: String

    @Published private(set) var posts: [PostSummary] = []
    @Published private(set) var errorMessage: String?
    private(set) var pagination = PaginationState()

    private let repository: ContentRepository
    private let limit = 20
    private var lastRequestWasReset = true

    init(repository: ContentRepository, category: String? = nil, tag: String? = nil, title: String = "文章") {
        self.repository = repository
        self.category = category
        self.tag = tag
        self.title = title
    }

    var isLoading: Bool { pagination.isLoading }
    var hasMore: Bool { pagination.canLoadMore }

    func loadIfNeeded() async {
        guard !pagination.hasLoaded else { return }
        await loadPage(reset: true)
    }

    func refresh() async {
        await loadPage(reset: true)
    }

    func loadMore() {
        guard !pagination.isLoading, pagination.canLoadMore else { return }
        Task { await loadPage(reset: false) }
    }

    func retry() {
        Task { await loadPage(reset: lastRequestWasReset) }
    }

    private func loadPage(reset: Bool) async {
        guard let page = pagination.begin(reset: reset) else { return }
        lastRequestWasReset = reset
        if reset { errorMessage = nil }

        do {
            let result = try await repository.fetchPosts(page: page, limit: limit, category: category, tag: tag)
            if reset {
                posts = result.items
            } else {
                appendUnique(result.items)
            }
            pagination.finish(meta: result.meta)
            errorMessage = nil
        } catch {
            pagination.fail()
            errorMessage = error.localizedDescription
        }
    }

    private func appendUnique(_ newItems: [PostSummary]) {
        let existing = Set(posts.map(\.identity))
        posts.append(contentsOf: newItems.filter { !existing.contains($0.identity) })
    }
}

@MainActor
final class BrowseViewModel: ObservableObject {
    @Published private(set) var categories: [Category] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let repository: ContentRepository

    init(repository: ContentRepository) {
        self.repository = repository
    }

    func loadIfNeeded() async {
        guard categories.isEmpty && tags.isEmpty && !isLoading else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    func retry() {
        Task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let loadedCategories = repository.fetchCategories()
            async let loadedTags = repository.fetchTags()
            let (categories, tags) = try await (loadedCategories, loadedTags)
            self.categories = categories
            self.tags = tags
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasSearched = false

    private let repository: ContentRepository
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(repository: ContentRepository) {
        self.repository = repository
    }

    func submit() {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()

        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            isLoading = false
            results = []
            errorMessage = nil
            hasSearched = false
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.search(value: value, generation: generation)
        }
    }

    func clear() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        isLoading = false
        query = ""
        results = []
        errorMessage = nil
        hasSearched = false
    }

    private func search(value: String, generation: Int) async {
        isLoading = true
        errorMessage = nil
        hasSearched = true
        defer {
            if generation == searchGeneration {
                isLoading = false
                searchTask = nil
            }
        }

        do {
            let loaded = try await repository.search(query: value).items
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = loaded
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    deinit {
        searchTask?.cancel()
    }
}

@MainActor
final class PostDetailViewModel: ObservableObject {
    @Published private(set) var post: PostDetail?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLiking = false
    @Published private(set) var liked = false

    private let repository: ContentRepository
    private let visitorIdentity: VisitorIdentity
    private let slug: String
    private var didReportView = false

    init(repository: ContentRepository, visitorIdentity: VisitorIdentity, slug: String) {
        self.repository = repository
        self.visitorIdentity = visitorIdentity
        self.slug = slug
    }

    func loadIfNeeded() async {
        guard post == nil, !isLoading else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    func retry() {
        Task { await load() }
    }

    func reportViewIfNeeded() {
        guard !didReportView, let id = post?.id else { return }
        didReportView = true
        Task {
            do {
                let metrics = try await repository.sendInteraction(targetType: "post", targetID: id, kind: "view", visitorID: visitorIdentity.id)
                guard let post else { return }
                self.post = replacingMetrics(in: post, with: metrics)
                if let liked = metrics.liked { self.liked = liked }
            } catch {
                // Reading analytics is best-effort; a transient failure must not
                // prevent the article from being read.
            }
        }
    }

    func toggleLike() {
        guard !isLiking, let id = post?.id else { return }
        isLiking = true
        Task {
            do {
                let metrics = try await repository.sendInteraction(targetType: "post", targetID: id, kind: "like", visitorID: visitorIdentity.id)
                if let post { self.post = replacingMetrics(in: post, with: metrics) }
                liked = metrics.liked ?? !liked
            } catch {
                errorMessage = error.localizedDescription
            }
            isLiking = false
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loadedPost = try await repository.fetchPost(slug: slug)
            post = loadedPost
            liked = loadedPost.metrics?.liked ?? false
            reportViewIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func replacingMetrics(in post: PostDetail, with metrics: ContentMetrics) -> PostDetail {
        PostDetail(id: post.id, title: post.title, slug: post.slug, content: post.content, cover: post.cover, category: post.category, tags: post.tags, createdAt: post.createdAt, updatedAt: post.updatedAt, commentsCount: post.commentsCount, comments: post.comments, metrics: metrics, references: post.references)
    }
}

@MainActor
final class MomentsViewModel: ObservableObject {
    @Published private(set) var moments: [Moment] = []
    @Published private(set) var errorMessage: String?
    private(set) var pagination = PaginationState()
    private let repository: ContentRepository
    private var lastRequestWasReset = true

    init(repository: ContentRepository) { self.repository = repository }

    var isLoading: Bool { pagination.isLoading }
    var hasMore: Bool { pagination.canLoadMore }

    func loadIfNeeded() async { guard !pagination.hasLoaded else { return }; await loadPage(reset: true) }
    func refresh() async { await loadPage(reset: true) }
    func loadMore() { guard !pagination.isLoading, pagination.canLoadMore else { return }; Task { await loadPage(reset: false) } }
    func retry() { Task { await loadPage(reset: lastRequestWasReset) } }

    private func loadPage(reset: Bool) async {
        guard let page = pagination.begin(reset: reset) else { return }
        lastRequestWasReset = reset
        do {
            let result = try await repository.fetchMoments(page: page)
            if reset { moments = result.items } else { appendUnique(result.items) }
            pagination.finish(meta: result.meta)
            errorMessage = nil
        } catch {
            pagination.fail()
            errorMessage = error.localizedDescription
        }
    }

    private func appendUnique(_ newItems: [Moment]) {
        let existing = Set(moments.map(\.identity))
        moments.append(contentsOf: newItems.filter { !existing.contains($0.identity) })
    }
}

@MainActor
final class WorksViewModel: ObservableObject {
    @Published private(set) var works: [Work] = []
    @Published private(set) var errorMessage: String?
    private(set) var pagination = PaginationState()
    private let repository: ContentRepository
    private var lastRequestWasReset = true

    init(repository: ContentRepository) { self.repository = repository }

    var isLoading: Bool { pagination.isLoading }
    var hasMore: Bool { pagination.canLoadMore }

    func loadIfNeeded() async { guard !pagination.hasLoaded else { return }; await loadPage(reset: true) }
    func refresh() async { await loadPage(reset: true) }
    func loadMore() { guard !pagination.isLoading, pagination.canLoadMore else { return }; Task { await loadPage(reset: false) } }
    func retry() { Task { await loadPage(reset: lastRequestWasReset) } }

    private func loadPage(reset: Bool) async {
        guard let page = pagination.begin(reset: reset) else { return }
        lastRequestWasReset = reset
        do {
            let result = try await repository.fetchWorks(page: page)
            if reset { works = result.items } else { appendUnique(result.items) }
            pagination.finish(meta: result.meta)
            errorMessage = nil
        } catch {
            pagination.fail()
            errorMessage = error.localizedDescription
        }
    }

    private func appendUnique(_ newItems: [Work]) {
        let existing = Set(works.map(\.identity))
        works.append(contentsOf: newItems.filter { !existing.contains($0.identity) })
    }
}

@MainActor
final class ReferencesViewModel: ObservableObject {
    @Published private(set) var references: [ReferenceLibraryItem] = []
    @Published private(set) var errorMessage: String?
    private(set) var pagination = PaginationState()
    private let repository: ContentRepository
    private var lastRequestWasReset = true

    init(repository: ContentRepository) { self.repository = repository }

    var isLoading: Bool { pagination.isLoading }
    var hasMore: Bool { pagination.canLoadMore }

    func loadIfNeeded() async { guard !pagination.hasLoaded else { return }; await loadPage(reset: true) }
    func refresh() async { await loadPage(reset: true) }
    func loadMore() { guard !pagination.isLoading, pagination.canLoadMore else { return }; Task { await loadPage(reset: false) } }
    func retry() { Task { await loadPage(reset: lastRequestWasReset) } }

    private func loadPage(reset: Bool) async {
        guard let page = pagination.begin(reset: reset) else { return }
        lastRequestWasReset = reset
        do {
            let result = try await repository.fetchReferences(page: page)
            if reset { references = result.items } else { appendUnique(result.items) }
            pagination.finish(meta: result.meta)
            errorMessage = nil
        } catch {
            pagination.fail()
            errorMessage = error.localizedDescription
        }
    }

    private func appendUnique(_ newItems: [ReferenceLibraryItem]) {
        let existing = Set(references.map(\.identity))
        references.append(contentsOf: newItems.filter { !existing.contains($0.identity) })
    }
}

@MainActor
final class AboutViewModel: ObservableObject {
    @Published private(set) var site: SiteInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let repository: ContentRepository

    init(repository: ContentRepository) { self.repository = repository }

    func loadIfNeeded() async {
        guard site == nil, !isLoading else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            site = try await repository.fetchSite()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func retry() {
        Task { await load() }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var isClearing = false
    @Published var showClearedAlert = false

    func clearCache(using coordinator: CacheCoordinator) {
        guard !isClearing else { return }
        isClearing = true
        Task {
            await coordinator.clearAll()
            isClearing = false
            showClearedAlert = true
        }
    }
}
