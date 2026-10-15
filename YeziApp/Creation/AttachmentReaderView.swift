import SwiftUI
import QuickLook
import UniformTypeIdentifiers

enum LibraryFileKind: String, CaseIterable {
    case all = "全部", image = "图片", document = "文档", audio = "音频", video = "视频", other = "其他"
    static func kind(mime: String, name: String) -> Self {
        let fileType = UTType(filenameExtension: (name as NSString).pathExtension)
        if mime.hasPrefix("image/") || fileType?.conforms(to: .image) == true { return .image }
        if mime.hasPrefix("audio/") || fileType?.conforms(to: .audio) == true { return .audio }
        if mime.hasPrefix("video/") || fileType?.conforms(to: .movie) == true { return .video }
        let ext = (name as NSString).pathExtension.lowercased()
        if mime.hasPrefix("text/") || ["pdf", "md", "markdown", "txt", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "epub"].contains(ext) { return .document }
        return .other
    }
    var symbol: String {
        switch self {
        case .all: "folder"
        case .image: "photo"
        case .document: "doc.text"
        case .audio: "waveform"
        case .video: "play.rectangle"
        case .other: "doc.zipper"
        }
    }
}

struct AttachmentReaderRoute: Identifiable {
    let attachment: AdminAttachment
    var id: String { attachment.stableID }
}

struct AttachmentReaderView: View {
    let attachment: AdminAttachment
    let api: AdminAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var markdown: String?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if let markdown {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(MarkdownParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                                AdminPreviewMarkdownBlock(block: block, api: api, siteRoot: api.siteRoot)
                            }
                        }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                    }
                } else if let localURL, QLPreviewController.canPreview(localURL as NSURL) {
                    AttachmentQuickLook(url: localURL)
                } else if let error {
                    VStack(spacing: 18) {
                        ContentUnavailableView("暂时无法打开文件", systemImage: "doc.badge.ellipsis", description: Text(error))
                        Button("重新加载") { Task { await load() } }.buttonStyle(CreationPrimaryButtonStyle())
                    }
                } else if localURL != nil {
                    ContentUnavailableView("此格式暂不支持预览", systemImage: "doc", description: Text("使用右上角的分享按钮保存文件，或在其他 App 中打开。"))
                } else { ProgressView("正在打开文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.background(CreationDesign.surface).foregroundStyle(CreationDesign.foreground)
                .navigationTitle(attachment.originalName).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        if let localURL { ShareLink(item: localURL) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享或保存文件") }
                    }
                }.task { await load() }
        }.tint(CreationDesign.accent)
    }

    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YeziReader-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (attachment.originalName as NSString).lastPathComponent
            let destination = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "file" : name)
            do {
#if DEBUG
                if CreationPreview.isEnabled {
                    try CreationPreview.fileData(for: attachment).write(to: destination)
                } else {
                    let downloaded = try await api.downloadAttachment(path: attachment.path)
                    try FileManager.default.moveItem(at: downloaded, to: destination)
                }
#else
                let downloaded = try await api.downloadAttachment(path: attachment.path)
                try FileManager.default.moveItem(at: downloaded, to: destination)
#endif
                try Task.checkCancellation()
                if ["md", "markdown"].contains(destination.pathExtension.lowercased()) {
                    markdown = try String(contentsOf: destination, encoding: .utf8)
                }
                localURL = destination
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        } catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
}

private struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
