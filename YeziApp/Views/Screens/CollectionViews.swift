import SwiftUI

struct MomentsView: View {
    @StateObject private var model: MomentsViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: MomentsViewModel(repository: container.repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if model.isLoading && model.moments.isEmpty {
                    LoadingStateView()
                } else if let error = model.errorMessage, model.moments.isEmpty {
                    ErrorStateView(message: error, retry: model.retry)
                } else if model.moments.isEmpty {
                    EmptyStateView(title: "还没有想法", message: "新的片段会出现在这里。")
                } else {
                    ForEach(model.moments, id: \.identity) { moment in
                        MomentCard(moment: moment, container: container)
                            .onAppear {
                                if moment.identity == model.moments.last?.identity { model.loadMore() }
                            }
                    }
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, retry: model.retry)
                    } else if model.isLoading {
                        ProgressView().padding()
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("想法")
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}

struct MomentCard: View {
    let moment: Moment
    let container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(moment.content?.trimmedNonEmpty ?? "暂无内容")
                .font(.body)
                .lineSpacing(4)
            if let images = moment.images, !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.prefix(6).enumerated()), id: \.offset) { _, image in
                            if let url = container.urlResolver.absoluteURL(image) {
                                RemoteImageView(url: url, loader: container.imageLoader) {
                                    RoundedRectangle(cornerRadius: 10).fill(YeziPalette.soft)
                                }
                                .frame(width: 150, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            MetadataLine(date: moment.createdAt, comments: moment.commentsCount, metrics: moment.metrics)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct WorksView: View {
    @StateObject private var model: WorksViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: WorksViewModel(repository: container.repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if model.isLoading && model.works.isEmpty {
                    LoadingStateView()
                } else if let error = model.errorMessage, model.works.isEmpty {
                    ErrorStateView(message: error, retry: model.retry)
                } else if model.works.isEmpty {
                    EmptyStateView(title: "还没有作品", message: "作品信息会展示在这里。")
                } else {
                    ForEach(model.works, id: \.identity) { work in
                        WorkCard(work: work, container: container)
                            .onAppear {
                                if work.identity == model.works.last?.identity { model.loadMore() }
                            }
                    }
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, retry: model.retry)
                    } else if model.isLoading {
                        ProgressView().padding()
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("作品")
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}

struct WorkCard: View {
    let work: Work
    let container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cover = container.urlResolver.absoluteURL(work.cover) {
                RemoteImageView(url: cover, loader: container.imageLoader) {
                    RoundedRectangle(cornerRadius: 14).fill(YeziPalette.soft)
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 230)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(work.title?.trimmedNonEmpty ?? "未命名作品")
                .font(.title3.weight(.bold))
            if let description = work.description?.trimmedNonEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
            if let rawLink = work.link, let link = container.urlResolver.absoluteURL(rawLink) {
                Link(destination: link) {
                    Label("查看作品", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(YeziPalette.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ReferencesView: View {
    @StateObject private var model: ReferencesViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: ReferencesViewModel(repository: container.repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if model.isLoading && model.references.isEmpty {
                    LoadingStateView()
                } else if let error = model.errorMessage, model.references.isEmpty {
                    ErrorStateView(message: error, retry: model.retry)
                } else if model.references.isEmpty {
                    EmptyStateView(title: "引用库为空", message: "公开收藏会出现在这里。")
                } else {
                    ForEach(model.references, id: \.identity) { reference in
                        PublicReferenceCard(reference: reference, container: container)
                            .onAppear {
                                if reference.identity == model.references.last?.identity { model.loadMore() }
                            }
                    }
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, retry: model.retry)
                    } else if model.isLoading {
                        ProgressView().padding()
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("引用库")
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }
}

struct PublicReferenceCard: View {
    let reference: ReferenceLibraryItem
    let container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let cover = container.urlResolver.absoluteURL(reference.coverURL) {
                    RemoteImageView(url: cover, loader: container.imageLoader) {
                        RoundedRectangle(cornerRadius: 10).fill(YeziPalette.soft)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(YeziPalette.accent.opacity(0.12))
                        .overlay(Text("引").font(.title2.weight(.semibold)).foregroundStyle(YeziPalette.accent))
                        .frame(width: 84, height: 84)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(reference.sourceName?.trimmedNonEmpty ?? "网页文章")
                        .font(.caption)
                        .foregroundStyle(YeziPalette.accent)
                    Text(reference.displayTitle)
                        .font(.headline)
                        .lineLimit(3)
                    if let author = reference.author?.trimmedNonEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let summary = reference.description?.trimmedNonEmpty ?? reference.summary?.trimmedNonEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack {
                if let category = reference.category?.trimmedNonEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(YeziPalette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(YeziPalette.accent.opacity(0.10), in: Capsule())
                }
                Spacer()
                if let url = container.urlResolver.absoluteURL(reference.url) {
                    Link("阅读原文 ↗", destination: url)
                        .font(.caption.weight(.semibold))
                        .tint(YeziPalette.accent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

