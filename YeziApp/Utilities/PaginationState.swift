import Foundation

struct PaginationState: Equatable, Sendable {
    private(set) var lastLoadedPage = 0
    private(set) var totalPages: Int?
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    var canLoadMore: Bool {
        guard !isLoading else { return false }
        guard hasLoaded else { return true }
        guard let totalPages else { return true }
        return lastLoadedPage < totalPages
    }

    mutating func begin(reset: Bool = false) -> Int? {
        // A refresh must not invalidate an in-flight page request. The caller
        // can simply refresh again after that request finishes.
        guard !isLoading else { return nil }
        if reset {
            lastLoadedPage = 0
            totalPages = nil
            hasLoaded = false
        }
        guard canLoadMore else { return nil }
        isLoading = true
        return lastLoadedPage + 1
    }

    mutating func finish(meta: PaginationMeta) {
        lastLoadedPage = max(meta.page ?? lastLoadedPage + 1, 1)
        totalPages = meta.totalPages
        hasLoaded = true
        isLoading = false
    }

    mutating func fail() {
        isLoading = false
    }

    mutating func reset() {
        lastLoadedPage = 0
        totalPages = nil
        isLoading = false
        hasLoaded = false
    }
}
