import SwiftUI

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: SearchViewModel(repository: container.repository))
    }

    var body: some View {
        Group {
            if model.isLoading {
                LoadingStateView(message: "正在搜索")
            } else if let error = model.errorMessage {
                ErrorStateView(message: error, retry: model.submit)
            } else if !model.hasSearched {
                EmptyStateView(title: "搜索 Yezi", message: "输入关键词，查找文章和想法。")
            } else if model.results.isEmpty {
                EmptyStateView(title: "没有找到结果", message: "试试更短或不同的关键词。")
            } else {
                List(model.results, id: \.identity) { result in
                    SearchResultRow(result: result, container: container)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文章和想法")
        .onSubmit(of: .search) { model.submit() }
        .toolbar {
            if model.hasSearched {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除", action: model.clear)
                }
            }
        }
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    let container: AppContainer

    var body: some View {
        switch result {
        case .post(let post):
            if let slug = post.slug?.trimmedNonEmpty {
                NavigationLink {
                    PostDetailView(container: container, slug: slug)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("文章", systemImage: "doc.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(YeziPalette.accent)
                        Text(post.displayTitle).font(.headline)
                        if let content = post.content?.trimmedNonEmpty {
                            Text(content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Text(post.displayTitle)
            }
        case .moment(let moment):
            VStack(alignment: .leading, spacing: 6) {
                Label("想法", systemImage: "bubble.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(YeziPalette.accent)
                Text(moment.content?.trimmedNonEmpty ?? "暂无内容")
                    .font(.body)
                    .lineLimit(5)
                MetadataLine(date: moment.createdAt, comments: moment.commentsCount, metrics: moment.metrics)
            }
            .padding(.vertical, 8)
        }
    }
}

