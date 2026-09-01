import SwiftUI

struct PostDetailView: View {
    @StateObject private var model: PostDetailViewModel
    let container: AppContainer

    init(container: AppContainer, slug: String) {
        self.container = container
        _model = StateObject(wrappedValue: PostDetailViewModel(repository: container.repository, visitorIdentity: container.visitorIdentity, slug: slug))
    }

    var body: some View {
        Group {
            if model.isLoading && model.post == nil {
                LoadingStateView(message: "正在加载文章")
            } else if let error = model.errorMessage, model.post == nil {
                ErrorStateView(message: error, retry: model.retry)
            } else if let post = model.post {
                article(post)
            } else {
                EmptyStateView(title: "文章不可用", message: "这篇文章可能已经下线。")
            }
        }
        .navigationTitle(model.post?.displayTitle ?? "文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.post != nil {
                if let slug = model.post?.slug?.trimmedNonEmpty,
                   let shareURL = container.urlResolver.absoluteURL("/posts/\(slug)") {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: shareURL) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.toggleLike()
                    } label: {
                        Label(model.liked ? "已赞" : "点赞", systemImage: model.liked ? "heart.fill" : "heart")
                    }
                    .disabled(model.isLiking)
                }
            }
        }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private func article(_ post: PostDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let cover = container.urlResolver.absoluteURL(post.cover) {
                    RemoteImageView(url: cover, loader: container.imageLoader) {
                        RoundedRectangle(cornerRadius: 16).fill(YeziPalette.soft)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let category = post.category?.trimmedNonEmpty {
                        Text(category)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(YeziPalette.accent)
                    }
                    Text(post.displayTitle)
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    MetadataLine(date: post.createdAt, comments: post.commentsCount, metrics: post.metrics)
                    if let tags = post.tags, !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.caption)
                                        .foregroundStyle(YeziPalette.accent)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(YeziPalette.accent.opacity(0.10), in: Capsule())
                                }
                            }
                        }
                    }
                }

                Divider()

                MarkdownView(content: post.content ?? "", references: post.references ?? [], container: container)

                if let comments = post.comments, !comments.isEmpty {
                    CommentsView(comments: comments)
                }

                if let error = model.errorMessage {
                    ErrorBanner(message: error, retry: model.retry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemBackground))
        .refreshable { await model.refresh() }
    }
}

struct CommentsView: View {
    let comments: [Comment]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("评论（\(comments.count)）")
                .font(.title3.weight(.bold))
            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(comment.nickname?.trimmedNonEmpty ?? "访客")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        DateText(value: comment.createdAt)
                    }
                    Text(comment.content?.trimmedNonEmpty ?? "")
                        .font(.subheadline)
                    if let reply = comment.adminReply?.trimmedNonEmpty {
                        Text("作者回复：\(reply)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(9)
                            .background(YeziPalette.soft, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.top, 10)
    }
}
