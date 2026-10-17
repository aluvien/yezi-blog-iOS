import SwiftUI
import PhotosUI
import UIKit
import AVFoundation
import ImageIO

enum CreationIntent { case text, photos, music }
private enum CreationSheet: String, Identifiable { case music, settings, reference, attachment, cover, video, preview, camera; var id: String { rawValue } }

struct CreationComposerView: View {
    @StateObject private var model: CreationComposerModel
    let intent: CreationIntent
    let onPublished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var focused = false
    @State private var previewing = false
    @StateObject private var writing = MarkdownWritingController()
    @State private var sheet: CreationSheet?
    @State private var resumeWritingAfterSheet = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsDiscard = false
    @State private var showsUncertainConfirmation = false
    @State private var replacingMusic: UUID?
    @State private var previewMedia: CreationMedia?

    init(api: AdminAPIClient, draft: CreationDraft, intent: CreationIntent = .text, onPublished: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: CreationComposerModel(api: api, draft: draft))
        self.intent = intent
        self.onPublished = onPublished
    }

    private var article: Bool { model.draft.kind == .post }
    private var title: String { article ? (model.draft.serverID == nil ? "写文章" : "编辑文章") : (model.draft.serverID == nil ? "写絮语" : "编辑絮语") }

    var body: some View {
        editorLayout.background(CreationDesign.surface).foregroundStyle(CreationDesign.foreground).tint(CreationDesign.accent)
            .interactiveDismissDisabled()
            .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos, maxSelectionCount: max(1, 9 - model.draft.media.count), selectionBehavior: .ordered, matching: .images)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                let ids = model.reserveImages(count: items.count)
                selectedPhotos = []
                for (id, item) in zip(ids, items) {
                    Task {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw APIError.emptyData }
                            await model.prepareImage(id: id, data: data)
                        } catch { model.failedImage(id: id, message: error.localizedDescription) }
                    }
                }
            }
            .sheet(item: $sheet, onDismiss: resumeWriting) { value in sheetContent(value) }
            .sheet(item: $previewMedia) { media in CreationImagePreview(media: media, api: model.api, site: model.draft.site) }
            .confirmationDialog("舍弃本机草稿？", isPresented: $showsDiscard, titleVisibility: .visible) {
                Button("舍弃草稿", role: .destructive) { Task { if await model.discard() { dismiss() } } }
            } message: { Text("仅删除此草稿与它的本地图片，不会删除已上传的服务器附件。") }
            .alert("确认没有发布成功？", isPresented: $showsUncertainConfirmation) {
                Button("已核对，继续编辑", role: .destructive) { Task { await model.confirmNotPublished() } }
                Button("取消", role: .cancel) {}
            } message: { Text("请先在列表核对是否存在这条内容，重复发布会创建重复记录。") }
            .task {
                await model.load()
                guard model.canEdit else { return }
                if intent == .photos { showsPhotos = true }
                else if intent == .music { sheet = .music }
                else if CreationPreview.isEnabled && CreationPreview.screen == "settings" { sheet = .settings }
                else if !CreationPreview.isEnabled || CreationPreview.showsKeyboard {
                    try? await Task.sleep(for: .milliseconds(450))
                    focused = true
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await model.flush() } } }
            .onDisappear { Task { await model.flush() } }
    }

    @ViewBuilder private func sheetContent(_ value: CreationSheet) -> some View {
        switch value {
        case .music:
            MusicPickerView(api: model.api, allowFolded: !article,
                            initialFolded: model.draft.music.first(where: { $0.id == replacingMusic })?.marker?.folded ?? false,
                            onAdd: finishMusic).presentationDetents([.large])
        case .settings: settings
        case .reference: AdminReferencePickerSheet(api: model.api, onSelect: model.insertReference)
        case .attachment: AdminAttachmentPickerSheet(api: model.api, postID: model.draft.serverID, selectedIDs: model.draft.attachmentIDs, onSelect: model.insertAttachment)
        case .cover: AdminAttachmentPickerSheet(api: model.api, postID: model.draft.serverID, selectedIDs: model.draft.attachmentIDs, onSelect: model.selectCover)
        case .video: AdminVideoInsertSheet(onInsert: insertVideo)
        case .preview: AdminMarkdownPreviewSheet(content: model.previewContent, api: model.api, siteRoot: model.api.siteRoot, references: model.draft.references)
        case .camera: CreationCameraView(onFinish: finishCamera).ignoresSafeArea()
        }
    }

    private func finishMusic(_ music: CreationMusic) {
        let replacing = replacingMusic
        replacingMusic = nil
        resumeWritingAfterSheet = true
        Task { await model.addMusic(music, replacing: replacing) }
    }

    private func resumeWriting() {
        guard resumeWritingAfterSheet else { return }
        resumeWritingAfterSheet = false
        guard model.canEdit, !model.isSaving, !previewing else { return }
        focused = true
    }

    private func finishCamera(_ data: Data?) {
        sheet = nil
        guard let data, let id = model.reserveImages(count: 1).first else { return }
        Task { await model.prepareImage(id: id, data: data) }
    }

    private func insertVideo(_ url: String) { model.edit { $0.text += "\n\n!video:\(url)\n" } }

    private var editorLayout: some View {
        VStack(spacing: 0) {
            header
            if article {
                HStack(spacing: 16) {
                    Text("Markdown").font(.caption.weight(.medium)).foregroundStyle(CreationDesign.secondary)
                    Picker("写作模式", selection: $previewing) {
                        Text("编辑").tag(false)
                        Text("预览").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 190)
                    Spacer(minLength: 0)
                    Text("\(model.draft.text.count) 字").font(.caption).foregroundStyle(CreationDesign.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 10)
                .onChange(of: previewing) { _, value in if value { focused = false } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    saveStatus
                    recoveryControls
                    if previewing {
                        Text(model.draft.title.isEmpty ? "未命名文章" : model.draft.title).font(.system(.title, design: .serif, weight: .bold))
                        ForEach(Array(creationMarkdownBlocks(model.previewContent, references: model.draft.references).enumerated()), id: \.offset) { _, block in
                            AdminPreviewMarkdownBlock(block: block, api: model.api, siteRoot: model.api.siteRoot)
                        }
                    } else {
                        writingCanvas
                        attachments
                    }
                    if article {
                        Button { focused = false; sheet = .settings } label: { Label("发布设置 · 分类、封面与引用", systemImage: "slider.horizontal.3").frame(minHeight: 44) }.disabled(model.isSaving || !model.canEdit)
                    }
                    if let blocker = model.submitBlocker { Text(blocker).font(.subheadline).foregroundStyle(CreationDesign.secondary).accessibilityLabel("暂不能发布：\(blocker)") }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
            if article && !previewing { MarkdownFormatBar(controller: writing).disabled(model.isSaving || !model.canEdit) }
            mediaBar
        }
    }

    private var saveStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: model.savedRevision >= model.draft.revision ? "checkmark.circle" : "internaldrive")
            Text(model.localStatus)
            Spacer(minLength: 0)
            if !article { Text("\(model.draft.serializedContent.utf16.count)/20,000").monospacedDigit() }
        }.font(.caption).foregroundStyle(model.storageError == nil ? CreationDesign.secondary : CreationDesign.danger).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recoveryControls: some View {
        if let error = model.errorMessage { CreationNotice(text: error, isError: true) }
        if model.storageError != nil { Button("重试保存到本机") { Task { await model.flush() } }.buttonStyle(.bordered) }
        if model.isLoading { ProgressView("正在加载文章…") }
        if !model.canEdit && !model.isLoading { Button("重新加载文章") { Task { await model.load() } }.buttonStyle(.bordered) }
        if model.draft.submission == .uncertain {
            Button("保留草稿，查看列表") { closeForReview() }.buttonStyle(.bordered)
            Button("我已核对列表，确认未发布") { showsUncertainConfirmation = true }.font(.subheadline)
        }
    }

    private func closeForReview() {
        Task { let closed = await model.close(); if closed { dismiss() } }
    }

    @ViewBuilder private var writingCanvas: some View {
        if article {
            TextField("文章标题", text: model.binding(\.title), axis: .vertical)
                .font(.title.weight(.semibold)).padding(.vertical, 8).disabled(model.isSaving || !model.canEdit)
        }
        ZStack(alignment: .topLeading) {
            if model.draft.text.isEmpty { Text(article ? "从这里开始写作…" : "这一刻，想说点什么…").foregroundStyle(CreationDesign.secondary).padding(.top, 12).padding(.leading, 5).allowsHitTesting(false) }
            MarkdownWritingView(text: model.binding(\.text), focused: $focused, controller: writing,
                                editable: !model.isSaving && model.canEdit, label: article ? "文章正文" : "絮语正文",
                                minimumHeight: article ? 330 : (model.draft.media.isEmpty && model.draft.music.isEmpty ? 280 : 180))
        }
    }

    @ViewBuilder private var attachments: some View {
        if !model.draft.media.isEmpty { CreationMediaGrid(model: model) { previewMedia = $0 }.disabled(model.isSaving || !model.canEdit) }
        ForEach(model.draft.music) { music in
            musicCard(music)
            if !article {
                Toggle("折叠显示到絮语标题旁", isOn: Binding(
                    get: { model.draft.music.first(where: { $0.id == music.id })?.marker?.folded ?? false },
                    set: { model.setMusicFolded(music.id, folded: $0) }
                )).disabled(model.isSaving || !model.canEdit)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { focused = false; Task { if await model.close() { dismiss() } } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭编辑器").disabled(model.isSaving)
            Spacer(minLength: 0)
            Text(title).font(.headline)
            Spacer(minLength: 0)
            Button(model.isSaving ? "提交中…" : (article ? (model.draft.status == "published" ? "更新文章" : "发布") : (model.draft.serverID == nil ? "发布" : "保存修改"))) {
                focused = false
                Task {
                    if await model.submit(), model.didPublish { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onPublished(); dismiss() }
                }
            }.buttonStyle(CreationPrimaryButtonStyle()).disabled(model.submitBlocker != nil).opacity(model.submitBlocker == nil ? 1 : 0.5)
        }.padding(.horizontal, 12).padding(.vertical, 6).background(CreationDesign.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(CreationDesign.border).frame(height: 1) }
    }

    private func musicCard(_ music: CreationMusic) -> some View {
        CreationMusicCard(music: music, api: model.api, replace: {
            focused = false
            replacingMusic = music.id
            sheet = .music
        }, remove: { model.removeMusic(music.id) }).disabled(model.isSaving || !model.canEdit)
    }

    private var mediaBar: some View {
        HStack(spacing: 0) {
            Button { focused = false; showsPhotos = true } label: { CreationToolLabel(title: "照片", symbol: "photo") }.disabled(model.draft.media.count >= 9)
            if !article {
                Button { focused = false; openCamera() } label: { CreationToolLabel(title: "拍照", symbol: "camera") }.disabled(model.draft.media.count >= 9)
            }
            Button { focused = false; replacingMusic = model.draft.music.first?.id; sheet = .music } label: { CreationToolLabel(title: "音乐", symbol: "music.note") }
            Menu {
                if article {
                    Button("发布设置") { focused = false; sheet = .settings }
                }
                Button("Markdown 预览") { focused = false; sheet = .preview }
                Button("插入视频") { focused = false; sheet = .video }
                Button("引用文章") { focused = false; sheet = .reference }
                Button("选择已有附件") { focused = false; sheet = .attachment }
                Button("舍弃草稿", role: .destructive) { showsDiscard = true }
            } label: { CreationToolLabel(title: "更多", symbol: "ellipsis") }
        }.font(.subheadline.weight(.medium)).padding(.horizontal, 8).background(CreationDesign.soft).disabled(model.isSaving || !model.canEdit)
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { model.errorMessage = "此设备没有可用相机，请使用照片选择器添加图片。"; return }
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed { sheet = .camera }
            else { model.errorMessage = "相机权限未开启，请在系统设置中允许叶子使用相机。" }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("发布信息") {
                    LabeledContent("文章地址") { TextField("留空自动生成 Slug", text: model.binding(\.slug)).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    LabeledContent("分类") { TextField("未分类", text: model.binding(\.category)) }
                    LabeledContent("标签") { TextField("用逗号分隔", text: model.binding(\.tags)) }
                    LabeledContent("封面地址") { TextField("可选图片地址", text: model.binding(\.cover)).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    ForEach(model.draft.media.filter { $0.state == .uploaded }) { media in
                        Button("设第 \((model.draft.media.firstIndex(where: { $0.id == media.id }) ?? 0) + 1) 张照片为封面") { model.edit { $0.cover = media.remotePath ?? "" } }
                    }
                    Button("选择已有封面附件") { sheet = nil; Task { await Task.yield(); sheet = .cover } }
                }
                Section("关联附件") {
                    Text("\(model.draft.attachmentIDs.count) 个已有附件，\(model.draft.media.count) 张新图片")
                    ForEach(model.draft.attachmentIDs, id: \.self) { id in
                        HStack { Text("附件 #\(id)"); Spacer(); Button("解除关联", role: .destructive) { model.edit { $0.attachmentIDs.removeAll { $0 == id } } } }
                    }
                    Button("管理关联附件") { sheet = nil; Task { await Task.yield(); sheet = .attachment } }
                }
                Section("引用信息") {
                    ForEach(Array(model.draft.references.enumerated()), id: \.offset) { _, reference in Text(reference.title ?? reference.url ?? "文章引用") }
                    Button("添加引用文章") { sheet = nil; Task { await Task.yield(); sheet = .reference } }
                }
                Section("服务器草稿") {
                    if model.draft.status == "published" { Text("已发布文章不会因本机保存而转为草稿。").foregroundStyle(CreationDesign.secondary) }
                    else {
                        Button("保存服务器草稿") { Task { if await model.submit(serverDraft: true) { onPublished() } } }.disabled(model.isSaving || model.draft.submission == .uncertain)
                        Text("显式保存到站点；自动保存仅写入本机。").font(.subheadline).foregroundStyle(CreationDesign.secondary)
                    }
                }
                if let error = model.errorMessage { Section { CreationNotice(text: error, isError: true) } }
            }.navigationTitle("发布设置").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
        }.tint(CreationDesign.accent)
    }
}

struct CreationMediaGrid: View {
    @ObservedObject var model: CreationComposerModel
    let onPreview: (CreationMedia) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var columnCount: Int { model.draft.media.count == 1 ? 1 : (dynamicTypeSize.isAccessibilitySize || model.draft.media.count == 2 || model.draft.media.count == 4 ? 2 : 3) }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount), spacing: 12) {
            ForEach(Array(model.draft.media.enumerated()), id: \.element.id) { index, media in
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topTrailing) {
                        Button { onPreview(media) } label: { CreationLocalImage(media: media, site: model.draft.site, api: model.api).frame(height: model.draft.media.count == 1 ? 190 : 105).clipped().clipShape(RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).accessibilityLabel("查看第 \(index + 1) 张图片")
                        Button { model.removeImage(media.id) } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.65)).frame(width: 44, height: 44) }.accessibilityLabel("移除第 \(index + 1) 张图片")
                    }
                    HStack(spacing: 4) {
                        if [.preparing, .waiting, .uploading].contains(media.state) { ProgressView().controlSize(.mini) }
                        Text(status(media)).font(.caption).foregroundStyle(media.state == .failed ? CreationDesign.danger : CreationDesign.secondary)
                        Spacer(minLength: 0)
                        Menu {
                            if media.state == .failed { Button("重试第 \(index + 1) 张图片") { model.retryImage(media.id) } }
                            if index > 0 { Button("向前移动") { model.moveImage(media.id, offset: -1) } }
                            if index + 1 < model.draft.media.count { Button("向后移动") { model.moveImage(media.id, offset: 1) } }
                            Button("移除", role: .destructive) { model.removeImage(media.id) }
                        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("第 \(index + 1) 张图片操作")
                    }
                    if media.state == .failed { Button("点按重试") { model.retryImage(media.id) }.font(.caption).accessibilityLabel("重试第 \(index + 1) 张图片"); Text(media.error ?? "上传失败").font(.caption).foregroundStyle(CreationDesign.danger) }
                }
            }
        }
    }
    private func status(_ media: CreationMedia) -> String {
        switch media.state { case .preparing: "准备中"; case .waiting: "待上传"; case .uploading: "上传中"; case .uploaded: "已上传"; case .failed: "上传失败" }
    }
}

struct CreationLocalImage: View {
    let media: CreationMedia
    let site: String
    let api: AdminAPIClient
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            content.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: media.filename) { await loadImage() }
    }
    private var content: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode) }
            else if let path = media.remotePath { CreationRemoteImage(path: path, site: api.siteRoot, contentMode: contentMode) }
            else { CreationDesign.soft.overlay { Image(systemName: "photo").foregroundStyle(CreationDesign.secondary) } }
        }
    }
    private func loadImage() async {
            guard let filename = media.filename, let url = try? await CreationDraftStore.shared.imageURL(site: site, filename: filename) else { return }
            let data = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return Data?.none }
                return UIImage(cgImage: thumb).pngData()
            }.value
            if let data { image = UIImage(data: data) }
    }
}

struct CreationImagePreview: View {
    let media: CreationMedia
    let api: AdminAPIClient
    let site: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in CreationLocalImage(media: media, site: site, api: api, contentMode: .fit).frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                .background(.black).navigationTitle("图片预览").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct CreationCameraView: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.imageURL] as? URL {
                Task { let data = await Task.detached { try? Data(contentsOf: url) }.value; onFinish(data) }
                return
            }
            guard let image = info[.originalImage] as? UIImage, let pixels = image.cgImage else { onFinish(nil); return }
            let orientations: [UIImage.Orientation: Int] = [.up: 1, .down: 3, .left: 8, .right: 6, .upMirrored: 2, .downMirrored: 4, .leftMirrored: 5, .rightMirrored: 7]
            let snapshot = CreationCameraSnapshot(image: pixels, orientation: orientations[image.imageOrientation] ?? 1)
            Task { let data = await Task.detached { snapshot.encoded() }.value; onFinish(data) }
        }
    }
}

private struct CreationCameraSnapshot: @unchecked Sendable {
    let image: CGImage
    let orientation: Int
    func encoded() -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
