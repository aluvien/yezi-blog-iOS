import SwiftUI

struct YeziPalette {
    static let accent = Color(red: 0.26, green: 0.36, blue: 0.80)
    static let soft = Color.secondary.opacity(0.10)
}

struct OfflineStatusBanner: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        if !monitor.isConnected {
            Label("当前为离线模式，显示已缓存的公开内容", systemImage: "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.yellow.opacity(0.18))
                .accessibilityElement(children: .combine)
        }
    }
}

struct ScreenContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

struct LoadingStateView: View {
    var message = "加载中…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(YeziPalette.accent)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(YeziPalette.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(20)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(20)
        .accessibilityElement(children: .combine)
    }
}

struct PostRowView: View {
    let post: PostSummary
    let container: AppContainer

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let category = post.category?.trimmedNonEmpty {
                    Text(category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(YeziPalette.accent)
                }
                Text(post.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let excerpt = post.excerpt?.trimmedNonEmpty {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                MetadataLine(date: post.createdAt, comments: post.commentsCount, metrics: post.metrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let cover = container.urlResolver.absoluteURL(post.cover) {
                RemoteImageView(url: cover, loader: container.imageLoader) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(YeziPalette.soft)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
                .frame(width: 104, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(post.displayTitle)
    }
}

struct PostNavigationRow: View {
    let post: PostSummary
    let container: AppContainer

    var body: some View {
        if let slug = post.slug?.trimmedNonEmpty {
            NavigationLink {
                PostDetailView(container: container, slug: slug)
            } label: {
                PostRowView(post: post, container: container)
            }
            .buttonStyle(.plain)
        } else {
            PostRowView(post: post, container: container)
        }
    }
}

struct MetadataLine: View {
    let date: String?
    let comments: Int?
    let metrics: ContentMetrics?

    var body: some View {
        HStack(spacing: 10) {
            if let date = date?.trimmedNonEmpty {
                Label(date.yeziDateText, systemImage: "calendar")
            }
            if let comments, comments > 0 {
                Label(String(comments), systemImage: "bubble.left")
            }
            if let views = metrics?.views, views > 0 {
                Label(String(views), systemImage: "eye")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

struct MarkdownView: View {
    let content: String
    let references: [ArticleReferenceSnapshot]
    let container: AppContainer

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(content, references: references)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, container: container)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let container: AppContainer

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text: text)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.bold) : .headline.weight(.semibold))
                .padding(.top, level == 1 ? 8 : 4)
        case .paragraph(let text):
            InlineMarkdownText(text: text)
                .font(.body)
                .lineSpacing(4)
        case .unorderedList(let items):
            ListBlock(items: items, ordered: false)
        case .orderedList(let items):
            ListBlock(items: items, ordered: true)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(YeziPalette.accent)
                    .frame(width: 3)
                InlineMarkdownText(text: text)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .music(let spec):
            PublicMusicBlockView(spec: spec, container: container)
        case .video(let url):
            MarkdownVideoView(rawURL: url, container: container)
        case .code(let language, let text):
            if language?.lowercased() == "music" || language?.lowercased() == "qqvip" {
                PublicMusicBlockView(spec: text, container: container)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let language, language != "text" {
                        Text(language)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        case .image(let url, let alt):
            MarkdownImageView(url: url, alt: alt, container: container)
        case .divider:
            Divider()
        case .reference(let reference):
            ReferenceCardView(reference: reference, container: container)
        case .unresolvedReference:
            Label("引用内容暂不可用", systemImage: "link.badge.plus")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(YeziPalette.soft, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ListBlock: View {
    let items: [String]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .fontWeight(.semibold)
                        .foregroundStyle(YeziPalette.accent)
                        .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
                    InlineMarkdownText(text: item)
                        .font(.body)
                        .lineSpacing(3)
                }
            }
        }
    }
}

struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        Text(MarkdownParser.attributed(text))
            .tint(YeziPalette.accent)
            .textSelection(.enabled)
    }
}

/// A native representation of the site's `qqvip:id:type` marker. When the
/// editor saved a metadata snapshot, it is rendered immediately and does not
/// flash the raw marker while the public player is unavailable.
struct PublicMusicBlockView: View {
    let spec: String
    let container: AppContainer
    @State private var resolvedSong: AdminMusicTrack?

    private var marker: MusicMarker? { MarkdownParser.musicMarker(from: spec) }
    private var title: String { marker?.title?.trimmedNonEmpty ?? resolvedSong?.name.trimmedNonEmpty ?? (marker?.type == "playlist" ? "QQ 音乐歌单" : "QQ 音乐歌曲") }
    private var artist: String? { marker?.artist?.trimmedNonEmpty ?? resolvedSong?.artist.trimmedNonEmpty }
    private var cover: String? { marker?.cover?.trimmedNonEmpty ?? resolvedSong?.cover.trimmedNonEmpty }

    private var qqURL: URL? {
        guard let marker else { return nil }
        switch marker.type {
        case "song":
            return URL(string: "https://y.qq.com/n/ryqq/songDetail/\(marker.id)")
        case "playlist":
            return URL(string: "https://y.qq.com/n/ryqq/playlist/\(marker.id)")
        default:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if marker != nil,
               let cover = cover.flatMap({ container.urlResolver.absoluteURL($0) }) {
                RemoteImageView(url: cover, loader: container.imageLoader) {
                    RoundedRectangle(cornerRadius: 11).fill(YeziPalette.accent.opacity(0.12))
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            } else {
                Image(systemName: marker?.type == "playlist" ? "music.note.list" : "music.note")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YeziPalette.accent)
                    .frame(width: 42, height: 42)
                    .background(YeziPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(marker.map { "ID：\($0.id)" } ?? "音乐标记格式不可识别")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if marker?.shuffle == true {
                    Text("随机播放")
                        .font(.caption2)
                        .foregroundStyle(YeziPalette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let qqURL {
                Link(destination: qqURL) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("在 QQ 音乐中打开")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .task(id: spec) {
            resolvedSong = nil
            guard let marker, marker.type == "song",
                  marker.title?.trimmedNonEmpty == nil || marker.artist?.trimmedNonEmpty == nil || marker.cover?.trimmedNonEmpty == nil else { return }
            let api = AdminAPIClient(siteRoot: container.urlResolver.siteRoot)
            guard let track = try? await api.fetchQQMusicMetadata(id: marker.id),
                  !Task.isCancelled, track.mid == marker.id else { return }
            resolvedSong = track
        }
    }
}

struct MarkdownImageView: View {
    let url: String
    let alt: String
    let container: AppContainer

    var body: some View {
        if let resolved = container.urlResolver.absoluteURL(url) {
            RemoteImageView(url: resolved, loader: container.imageLoader, contentMode: .fit) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(YeziPalette.soft)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                            if !alt.isEmpty { Text(alt).font(.caption) }
                        }
                        .foregroundStyle(.secondary)
                    }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(alt)
        }
    }
}

/// Native Markdown video rendering. The app deliberately shows a placeholder
/// for every video source: direct media and third-party web pages are not
/// played inside Markdown preview or public content views.
struct MarkdownVideoView: View {
    let rawURL: String
    let container: AppContainer

    init(rawURL: String, container: AppContainer) {
        self.rawURL = rawURL
        self.container = container
    }

    private var resolvedURL: URL? {
        container.urlResolver.absoluteURL(rawURL)
    }

    private var isWebPageEmbed: Bool {
        guard let host = resolvedURL?.host?.lowercased() else { return false }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return ["youtube.com", "youtu.be", "bilibili.com", "b23.tv", "vimeo.com", "tiktok.com"].contains {
            normalizedHost == $0 || normalizedHost.hasSuffix(".\($0)")
        }
    }

    private var sourceLabel: String {
        guard let host = resolvedURL?.host?.lowercased() else { return "视频" }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if normalizedHost == "bilibili.com" || normalizedHost.hasSuffix(".bilibili.com") || normalizedHost == "b23.tv" {
            return "Bilibili 视频"
        }
        if normalizedHost == "youtube.com" || normalizedHost == "youtu.be" || normalizedHost.hasSuffix(".youtube.com") {
            return "YouTube 视频"
        }
        return "视频"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if resolvedURL != nil {
                HStack(spacing: 12) {
                    Image(systemName: isWebPageEmbed ? "play.rectangle.fill" : "video.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(YeziPalette.accent)
                        .frame(width: 48, height: 48)
                        .background(YeziPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(sourceLabel)占位卡片")
                            .font(.subheadline.weight(.semibold))
                        Text("Markdown 预览不播放视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(rawURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Label("视频地址不可用", systemImage: "video.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 84)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ReferenceCardView: View {
    let reference: ArticleReferenceSnapshot
    let container: AppContainer

    private var sourceLine: String {
        var parts = [reference.displaySource]
        if let author = reference.author?.trimmedNonEmpty { parts.append(author) }
        if let date = reference.publishedAt?.trimmedNonEmpty { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let cover = container.urlResolver.absoluteURL(reference.resolvedCoverValue) {
                    RemoteImageView(url: cover, loader: container.imageLoader) {
                        RoundedRectangle(cornerRadius: 10).fill(YeziPalette.soft)
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(YeziPalette.accent.opacity(0.12))
                        .overlay(Text("引").font(.title2.weight(.semibold)).foregroundStyle(YeziPalette.accent))
                        .frame(width: 76, height: 76)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(sourceLine)
                        .font(.caption)
                        .foregroundStyle(YeziPalette.accent)
                    Text(reference.displayTitle)
                        .font(.headline)
                        .lineLimit(3)
                }
            }

            if let summary = reference.summary?.trimmedNonEmpty ?? reference.description?.trimmedNonEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let points = reference.keyPoints, !points.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(points.prefix(6).enumerated()), id: \.offset) { _, point in
                        Label(point, systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let url = container.urlResolver.absoluteURL(reference.url ?? reference.canonicalURL) {
                Link(destination: url) {
                    Label("阅读原文", systemImage: "arrow.up.right")
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

struct DateText: View {
    let value: String?

    var body: some View {
        Text(value?.yeziDateText ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension String {
    var yeziDateText: String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return Self.displayDateFormatter.string(from: date)
        }
        return String(value.prefix(10))
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
