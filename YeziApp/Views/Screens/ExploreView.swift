import SwiftUI

struct ExploreView: View {
    @StateObject private var model: BrowseViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: BrowseViewModel(repository: container.repository))
    }

    var body: some View {
        List {
            if model.isLoading && model.categories.isEmpty && model.tags.isEmpty {
                Section { LoadingStateView() }
            } else if let error = model.errorMessage, model.categories.isEmpty && model.tags.isEmpty {
                Section { ErrorStateView(message: error, retry: model.retry) }
            }

            if let error = model.errorMessage, !model.categories.isEmpty || !model.tags.isEmpty {
                Section { ErrorBanner(message: error, retry: model.retry) }
            }

            if !model.categories.isEmpty {
                Section("分类") {
                    ForEach(model.categories, id: \.identity) { category in
                        NavigationLink {
                            PostsListView(container: container, category: category.name, title: category.name ?? "分类")
                        } label: {
                            HStack {
                                Text(category.name ?? "未命名分类")
                                Spacer()
                                if let count = category.postsCount { Text(String(count)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("标签") {
                    ForEach(model.tags, id: \.identity) { tag in
                        NavigationLink {
                            PostsListView(container: container, tag: tag.tag, title: "#\(tag.tag ?? "标签")")
                        } label: {
                            HStack {
                                Text("#\(tag.tag ?? "未命名")")
                                Spacer()
                                if let count = tag.count { Text(String(count)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            Section("内容") {
                NavigationLink("想法", destination: MomentsView(container: container))
                NavigationLink("作品", destination: WorksView(container: container))
                NavigationLink("引用库", destination: ReferencesView(container: container))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("浏览")
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}
