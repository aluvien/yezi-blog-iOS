import Foundation
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {
    let apiClient: APIClient
    let repository: ContentRepository
    let imageLoader: ImageLoader
    let visitorIdentity: VisitorIdentity
    let cacheCoordinator: CacheCoordinator
    let urlResolver: SiteURLResolver
    let networkMonitor: NetworkMonitor

    init() {
        let responseCache = ResponseCache()
        let apiURLCache = URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 30 * 1024 * 1024, diskPath: "YeziAPICache")
        let imageURLCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024, diskPath: "YeziImageCache")
        let imageLoader = ImageLoader(urlCache: imageURLCache)
        let apiClient = APIClient(urlCache: apiURLCache, responseCache: responseCache)

        self.apiClient = apiClient
        self.repository = ContentRepository(api: apiClient)
        self.imageLoader = imageLoader
        self.visitorIdentity = VisitorIdentity(store: KeychainStore())
        self.cacheCoordinator = CacheCoordinator(responseCache: responseCache, apiURLCache: apiClient.urlCache, imageLoader: imageLoader)
        self.urlResolver = SiteURLResolver()
        self.networkMonitor = NetworkMonitor()

        // Generate the installation-scoped visitor UUID on first launch so it
        // is already persisted before the first interaction is sent.
        _ = self.visitorIdentity.id
    }
}
