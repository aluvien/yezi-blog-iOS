import SwiftUI

struct HomeView: View {
    @StateObject private var model: PostListViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: PostListViewModel(repository: container.repository, title: "首页"))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.isLoading && model.posts.isEmpty {
                    LoadingStateView(message: "正在加载文章")
                } else if let error = model.errorMessage, model.posts.isEmpty {
                    ErrorStateView(message: error, retry: model.retry)
                } else if model.posts.isEmpty {
                    EmptyStateView(title: "还没有文章", message: "稍后再来看看吧。")
                } else {
                    ForEach(model.posts, id: \.identity) { post in
                        PostNavigationRow(post: post, container: container)
                        .onAppear {
                            if post.identity == model.posts.last?.identity { model.loadMore() }
                        }
                        Divider()
                    }
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, retry: model.retry)
                    } else if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Yezi")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).font(.caption).lineLimit(2)
            Spacer(minLength: 4)
            Button("重试", action: retry).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .background(YeziPalette.soft, in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct PostsListView: View {
    @StateObject private var model: PostListViewModel
    let container: AppContainer

    init(container: AppContainer, category: String? = nil, tag: String? = nil, title: String) {
        self.container = container
        _model = StateObject(wrappedValue: PostListViewModel(repository: container.repository, category: category, tag: tag, title: title))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.isLoading && model.posts.isEmpty {
                    LoadingStateView()
                } else if let error = model.errorMessage, model.posts.isEmpty {
                    ErrorStateView(message: error, retry: model.retry)
                } else if model.posts.isEmpty {
                    EmptyStateView(title: "没有匹配文章", message: "换一个分类或标签试试。")
                } else {
                    ForEach(model.posts, id: \.identity) { post in
                        PostNavigationRow(post: post, container: container)
                        .onAppear {
                            if post.identity == model.posts.last?.identity { model.loadMore() }
                        }
                        Divider()
                    }
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, retry: model.retry)
                    } else if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}
