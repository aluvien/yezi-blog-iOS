import SwiftUI

struct AboutView: View {
    @StateObject private var model: AboutViewModel
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _model = StateObject(wrappedValue: AboutViewModel(repository: container.repository))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.isLoading && model.site == nil {
                    LoadingStateView(message: "正在加载站点信息")
                } else if let error = model.errorMessage, model.site == nil {
                    ErrorStateView(message: error, retry: model.retry)
                } else if let site = model.site {
                    siteContent(site)
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, retry: model.retry)
                    }
                } else {
                    EmptyStateView(title: "暂无站点信息", message: "稍后再试。")
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(container: container)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private func siteContent(_ site: SiteInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if let avatar = container.urlResolver.absoluteURL(site.author?.avatar) {
                    RemoteImageView(url: avatar, loader: container.imageLoader) {
                        Circle().fill(YeziPalette.soft)
                    }
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(YeziPalette.accent.opacity(0.14))
                        .overlay(Text(String((site.author?.name ?? "叶").prefix(1))).font(.title2.weight(.bold)).foregroundStyle(YeziPalette.accent))
                        .frame(width: 68, height: 68)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(site.name?.trimmedNonEmpty ?? "Yezi's Blog")
                        .font(.title2.weight(.bold))
                    Text(site.subtitle?.trimmedNonEmpty ?? "文章 · 想法 · 作品")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let author = site.author?.name?.trimmedNonEmpty {
                        Text("作者：\(author)")
                            .font(.caption)
                            .foregroundStyle(YeziPalette.accent)
                    }
                }
            }
            if let description = site.description?.trimmedNonEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }

        if let about = site.aboutContent?.trimmedNonEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("关于我")
                    .font(.title3.weight(.bold))
                MarkdownView(content: about, references: [], container: container)
            }
        }

        if let links = site.socialLinks, !links.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("社交链接")
                    .font(.title3.weight(.bold))
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    if let rawURL = link.url, let url = container.urlResolver.absoluteURL(rawURL) {
                        Link(destination: url) {
                            Label(link.label ?? "打开链接", systemImage: "arrow.up.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .tint(YeziPalette.accent)
                    }
                }
            }
        }

        if let navigation = site.navigation, !navigation.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("站内导航")
                    .font(.title3.weight(.bold))
                ForEach(Array(navigation.enumerated()), id: \.offset) { _, item in
                    if let rawURL = item.href, let url = container.urlResolver.absoluteURL(rawURL) {
                        Link(destination: url) {
                            Label(item.label?.trimmedNonEmpty ?? "打开页面", systemImage: "arrow.up.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .tint(YeziPalette.accent)
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    let container: AppContainer
    @StateObject private var model = SettingsViewModel()

    var body: some View {
        List {
            Section("显示") {
                Label("深色模式跟随系统", systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
            }
            Section("应用") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("接口", value: "Yezi API v1")
            }
            Section("数据") {
                Button {
                    model.clearCache(using: container.cacheCoordinator)
                } label: {
                    HStack {
                        Label("清除图片/接口缓存", systemImage: "trash")
                        Spacer()
                        if model.isClearing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(model.isClearing)
            }
            Section {
                Text("YeziApp 使用公开 API 与本地 Keychain 访客标识。不会记录或上传账户、设备序列号或 IDFA。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("缓存已清除", isPresented: $model.showClearedAlert) {
            Button("好的", role: .cancel) {}
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
