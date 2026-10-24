import SwiftUI
import PhotosUI
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum CreationIntent { case text, photos, music }
private enum CreationSheet: String, Identifiable { case music, settings, reference, attachment, cover, video, preview, camera, imageOptions, aiImage; var id: String { rawValue } }

private struct CreationPickedVideo: Transferable, Sendable {
    let data: Data
    let mime: String
    let filename: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let values = try received.file.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            guard let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
                throw APIError.transport("视频需小于 20 MB，请在相册裁剪后重试。")
            }
            let ext = received.file.pathExtension.lowercased()
            guard ["mov", "mp4", "m4v"].contains(ext) else { throw APIError.transport("请选择 MP4 或 MOV 视频。") }
            return CreationPickedVideo(data: try Data(contentsOf: received.file), mime: ext == "mov" ? "video/quicktime" : "video/mp4", filename: "video-\(UUID().uuidString).\(ext == "mov" ? "mov" : "mp4")")
        }
    }
}

private struct CreationVideoInsertSheet: View {
    let api: AdminAPIClient
    let onInsert: (String, AdminAttachment?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var video: CreationPickedVideo?
    @State private var link = ""
    @State private var chosenLink: String?
    @State private var busy = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var uploadTask: Task<Void, Never>?
    private var validLink: String? {
        let values = CreationVideoInput.candidates(link)
        if let chosenLink, values.contains(chosenLink) { return chosenLink }
        return values.count == 1 ? values[0] : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    PhotosPicker(selection: $selection, matching: .videos) { Label("从相册选择视频", systemImage: "video") }.disabled(busy)
                } footer: { Text("支持 MP4、MOV，最大 20 MB。较长视频可使用链接插入。") }
                if busy { Section {
                    if video == nil && validLink != nil { ProgressView("正在识别视频链接…") }
                    else { ProgressView(value: progress) { Text(progress >= 1 ? "服务器正在处理…" : "正在读取或上传视频…") } }
                } }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if video != nil { Button("重试上传") { startUpload() }.disabled(busy) }
                    }
                }
                Section("链接、分享文字或 BV 号") {
                    TextField("粘贴分享内容，或输入 BV 号", text: $link, axis: .vertical).lineLimit(2...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("video.input")
                    ForEach(CreationVideoInput.candidates(link), id: \.self) { value in
                        Button { chosenLink = value } label: {
                            HStack {
                                Label(value, systemImage: value.hasPrefix("youtube:") ? "play.rectangle" : "video").lineLimit(2)
                                Spacer()
                                if validLink == value { Image(systemName: "checkmark") }
                            }
                        }.buttonStyle(.plain)
                    }
                    Button("确认插入") {
                        guard let validLink else { return }
                        busy = true; error = nil
                        uploadTask = Task {
                            do {
                                let value = try await CreationVideoInput.resolve(validLink)
                                guard !Task.isCancelled else { return }
                                onInsert(value, nil); busy = false; dismiss()
                            } catch { if !isRequestCancellation(error) { self.error = "视频识别失败，请检查链接后重试" }; busy = false }
                        }
                    }.disabled(validLink == nil || busy)
                    if !link.isEmpty && CreationVideoInput.candidates(link).isEmpty { Text("未识别到视频，请粘贴 Bilibili、YouTube 链接或完整 BV 号。").foregroundStyle(.secondary) }
                }
                }.listRowBackground(CreationDesign.surface)
            }.scrollContentBackground(.hidden).background(CreationDesign.canvas)
                .navigationTitle("插入视频").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { uploadTask?.cancel(); dismiss() } } }
                .interactiveDismissDisabled(busy)
                .task(id: selection) {
                    guard let selection else { return }
                    busy = true; error = nil; video = nil; progress = 0
                    do {
                        guard let picked = try await selection.loadTransferable(type: CreationPickedVideo.self) else { throw APIError.emptyData }
                        guard !Task.isCancelled else { return }
                        video = picked; startUpload()
                    } catch { busy = false; if !isRequestCancellation(error) { self.error = error.localizedDescription } }
                }
                .onDisappear { uploadTask?.cancel() }
        }
    }
    private func startUpload() {
        guard let video else { return }
        uploadTask?.cancel(); busy = true; error = nil; progress = 0
        uploadTask = Task {
            defer { busy = false }
            do {
                let attachment = try await api.uploadFile(data: video.data, filename: video.filename, mimeType: video.mime) { value in
                    Task { @MainActor in progress = value }
                }
                guard !Task.isCancelled else { return }
                onInsert(attachment.path, attachment); dismiss()
            } catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}

struct CreationComposerView: View {
    @StateObject private var model: CreationComposerModel
    let intent: CreationIntent
    let onPublished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var focused = false
    @StateObject private var writing = MarkdownWritingController()
    @State private var sheet: CreationSheet?
    @State private var resumeWritingAfterSheet = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsPhotosAfterSheet = false
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
    private var title: String { article ? (model.draft.serverID == nil ? "写随笔" : "编辑随笔") : (model.draft.serverID == nil ? "写絮语" : "编辑絮语") }

    var body: some View {
        editorLayout.background(CreationDesign.canvas).foregroundStyle(CreationDesign.foreground).tint(CreationDesign.accent)
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
            .fullScreenCover(item: $previewMedia) { media in CreationImagePreview(selection: CreationImageSelection(items: model.draft.media, index: model.draft.media.firstIndex(where: { $0.id == media.id }) ?? 0), api: model.api, site: model.draft.site) }
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
        case .video: CreationVideoInsertSheet(api: model.api) { url, attachment in
            insertVideo(url)
            if let attachment { model.registerGeneratedImage(attachment, asCover: false) }
        }
        case .preview: AdminMarkdownPreviewSheet(content: model.previewContent, api: model.api, siteRoot: model.api.siteRoot, references: model.draft.references)
        case .camera: CreationCameraView(onFinish: finishCamera).ignoresSafeArea()
        case .imageOptions: imageOptions.presentationDetents([.height(390)]).presentationDragIndicator(.visible).presentationBackground(.regularMaterial)
        case .aiImage:
            AIImageComposerView(allowsCover: article, service: CreationPreview.makeAIImageService() ?? AIImageService(),
                                settings: CreationPreview.aiImageSettings, onInsert: insertGeneratedImage).presentationDetents([.large])
        }
    }

    private func finishMusic(_ music: CreationMusic) {
        let replacing = replacingMusic
        replacingMusic = nil
        resumeWritingAfterSheet = true
        Task { await model.addMusic(music, replacing: replacing) }
    }

    private func resumeWriting() {
        if showsPhotosAfterSheet { showsPhotosAfterSheet = false; showsPhotos = true }
        guard resumeWritingAfterSheet else { return }
        resumeWritingAfterSheet = false
        guard model.canEdit, !model.isSaving else { return }
        focused = true
    }

    private func finishCamera(_ data: Data?) {
        sheet = nil
        guard let data, let id = model.reserveImages(count: 1).first else { return }
        Task { await model.prepareImage(id: id, data: data) }
    }

    private func insertVideo(_ url: String) {
        let snippet = "\n\n!video \(url)\n"
        if !writing.insert(snippet) { model.edit { $0.text += snippet } }
        resumeWritingAfterSheet = true
    }

    private var imageOptions: some View {
        VStack(spacing: 0) {
            Text("添加图片").font(CreationDesign.interface(.headline)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
            imageOption("AI 生图", detail: "描述画面，生成配图", symbol: "sparkle", accent: true) { sheet = .aiImage }
            Divider().overlay(CreationDesign.border)
            imageOption("拍照", detail: "用相机记录这一刻", symbol: "camera") { openCamera() }.disabled(model.draft.media.count >= 9)
            Divider().overlay(CreationDesign.border)
            imageOption("插入图片", detail: "从相册选择", symbol: "photo") { showsPhotosAfterSheet = true; sheet = nil }.disabled(model.draft.media.count >= 9)
            Divider().overlay(CreationDesign.border)
            Button("取消") { sheet = nil }.frame(maxWidth: .infinity, minHeight: 48)
        }.padding(.horizontal, 20).foregroundStyle(CreationDesign.foreground)
    }

    private func imageOption(_ title: String, detail: String, symbol: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: symbol).font(CreationDesign.interface(size: 25)).foregroundStyle(accent ? CreationDesign.accent : CreationDesign.foreground).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(CreationDesign.interface(.body)); Text(detail).font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary) }
                Spacer()
                Image(systemName: "chevron.right").font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary)
            }.frame(maxWidth: .infinity, minHeight: 76).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("image-option.\(title)")
    }

    private func insertGeneratedImage(_ data: Data, asCover: Bool) async throws {
        guard model.canEdit, !model.isSaving else { throw AIImageError.message("当前内容暂不能编辑。") }
        let prepared = try await CreationImageProcessor.prepare(data)
        let attachment = try await model.api.uploadFile(data: prepared.data, filename: "ai-\(UUID().uuidString).\(prepared.extensionName)", mimeType: prepared.mimeType)
        let snippet = "\n\n![AI 配图](\(attachment.path))\n\n"
        if !writing.insert(snippet) { model.edit { $0.text += snippet } }
        model.registerGeneratedImage(attachment, asCover: asCover)
        resumeWritingAfterSheet = true
    }

    private var editorLayout: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    saveStatus
                    recoveryControls
                    writingCanvas
                    attachments
                    if let blocker = model.submitBlocker { Text(blocker).font(CreationDesign.interface(.subheadline)).foregroundStyle(CreationDesign.secondary).accessibilityLabel("暂不能发布：\(blocker)") }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
            if article { articleToolbar } else { mediaBar }
        }
    }

    private var saveStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: model.savedRevision >= model.draft.revision ? "checkmark.circle" : "internaldrive")
            Text(model.localStatus)
            Spacer(minLength: 0)
            if !article { Text("\(model.draft.serializedContent.utf16.count)/20,000").monospacedDigit() }
        }.font(CreationDesign.interface(.caption)).foregroundStyle(model.storageError == nil ? CreationDesign.secondary : CreationDesign.danger).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recoveryControls: some View {
        if let error = model.errorMessage { CreationNotice(text: error, isError: true) }
        if model.storageError != nil { Button("重试保存到本机") { Task { await model.flush() } }.buttonStyle(.bordered) }
        if model.isLoading { ProgressView("正在加载文章…") }
        if !model.canEdit && !model.isLoading { Button("重新加载文章") { Task { await model.load() } }.buttonStyle(.bordered) }
        if model.draft.submission == .uncertain {
            Button("保留草稿，查看列表") { closeForReview() }.buttonStyle(.bordered)
            Button("我已核对列表，确认未发布") { showsUncertainConfirmation = true }.font(CreationDesign.interface(.subheadline))
        }
    }

    private func closeForReview() {
        Task { let closed = await model.close(); if closed { dismiss() } }
    }

    @ViewBuilder private var writingCanvas: some View {
        if article {
            TextField("文章标题", text: model.binding(\.title), axis: .vertical)
                .font(CreationDesign.contentTitle(32, relativeTo: .title, bold: true)).padding(.vertical, 12).disabled(model.isSaving || !model.canEdit)
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
        ZStack {
            if article {
                Menu { articleOptions } label: {
                    HStack(spacing: 5) {
                        Text(title).font(CreationDesign.interface(.headline))
                        Image(systemName: "chevron.down").font(CreationDesign.interface(size: 9, weight: .medium)).foregroundStyle(CreationDesign.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("文章选项").accessibilityIdentifier("article.options")
                    .disabled(model.isSaving || !model.canEdit)
            } else { Text(title).font(CreationDesign.interface(.headline)) }
            HStack {
            Button { focused = false; Task { if await model.close() { dismiss() } } } label: {
                Text("取消").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("关闭编辑器").disabled(model.isSaving)
            Spacer()
            Button(model.isSaving ? "提交中…" : (article ? (model.draft.status == "published" ? "更新文章" : "发布") : (model.draft.serverID == nil ? "发布" : "保存修改"))) {
                focused = false
                Task {
                    if await model.submit(), model.didPublish { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onPublished(); dismiss() }
                }
            }.foregroundStyle(CreationDesign.accent).frame(minWidth: 44, minHeight: 44)
                .disabled(model.submitBlocker != nil).opacity(model.submitBlocker == nil ? 1 : 0.5)
            }.font(CreationDesign.interface(.subheadline))
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4).background(CreationDesign.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }
    }

    @ViewBuilder private var articleOptions: some View {
        Section {
            Button("撤销", systemImage: "arrow.uturn.backward") { writing.undo() }.disabled(!writing.canUndo)
            Button("重做", systemImage: "arrow.uturn.forward") { writing.redo() }.disabled(!writing.canRedo)
            Menu("更多格式", systemImage: "textformat") {
                ForEach([MarkdownAction.italic, .quote, .numbered, .task, .code, .codeBlock, .divider], id: \.self) { action in
                    Button(action.title, systemImage: action.symbol) { writing.apply(action) }
                }
            }
        }
        Section {
            Button("发布设置", systemImage: "slider.horizontal.3") { focused = false; sheet = .settings }
            Button("插入视频", systemImage: "video") { focused = false; sheet = .video }
            Button("引用文章", systemImage: "quote.opening") { focused = false; sheet = .reference }
            Button("选择已有附件", systemImage: "paperclip") { focused = false; sheet = .attachment }
        }
        Section("\(model.draft.text.count) 字") {
            Button("舍弃草稿", role: .destructive) { showsDiscard = true }
        }
    }

    private var articleToolbar: some View {
        CreationEditorialToolbar(controller: writing,
            image: { focused = false; sheet = .imageOptions },
            video: { focused = false; sheet = .video },
            music: { focused = false; replacingMusic = model.draft.music.first?.id; sheet = .music },
            preview: { focused = false; sheet = .preview })
            .disabled(model.isSaving || !model.canEdit)
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
            Button { focused = false; sheet = .imageOptions } label: { CreationToolLabel(title: "图片", symbol: "photo") }
            Button { focused = false; sheet = .video } label: { CreationToolLabel(title: "视频", symbol: "video") }
            Button { focused = false; replacingMusic = model.draft.music.first?.id; sheet = .music } label: { CreationToolLabel(title: "音乐", symbol: "music.note") }
            Menu {
                if article {
                    Button("发布设置") { focused = false; sheet = .settings }
                }
                Button("Markdown 预览") { focused = false; sheet = .preview }
                Button("引用文章") { focused = false; sheet = .reference }
                Button("选择已有附件") { focused = false; sheet = .attachment }
                Button("舍弃草稿", role: .destructive) { showsDiscard = true }
            } label: { CreationToolLabel(title: "更多", symbol: "ellipsis") }
        }.font(CreationDesign.interface(.subheadline).weight(.medium)).foregroundStyle(CreationDesign.foreground).padding(.horizontal, 8).background(CreationDesign.canvas)
            .overlay(alignment: .top) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }.disabled(model.isSaving || !model.canEdit)
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
                        Text("显式保存到站点；自动保存仅写入本机。").font(CreationDesign.interface(.subheadline)).foregroundStyle(CreationDesign.secondary)
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
                        Button { model.removeImage(media.id) } label: { Image(systemName: "xmark.circle.fill").font(CreationDesign.interface(.title3)).foregroundStyle(.white, .black.opacity(0.65)).frame(width: 44, height: 44) }.accessibilityLabel("移除第 \(index + 1) 张图片")
                    }
                    HStack(spacing: 4) {
                        if [.preparing, .waiting, .uploading].contains(media.state) { ProgressView().controlSize(.mini) }
                        Text(status(media)).font(CreationDesign.interface(.caption)).foregroundStyle(media.state == .failed ? CreationDesign.danger : CreationDesign.secondary)
                        Spacer(minLength: 0)
                        Menu {
                            if media.state == .failed { Button("重试第 \(index + 1) 张图片") { model.retryImage(media.id) } }
                            if index > 0 { Button("向前移动") { model.moveImage(media.id, offset: -1) } }
                            if index + 1 < model.draft.media.count { Button("向后移动") { model.moveImage(media.id, offset: 1) } }
                            Button("移除", role: .destructive) { model.removeImage(media.id) }
                        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("第 \(index + 1) 张图片操作")
                    }
                    if media.state == .failed { Button("点按重试") { model.retryImage(media.id) }.font(CreationDesign.interface(.caption)).accessibilityLabel("重试第 \(index + 1) 张图片"); Text(media.error ?? "上传失败").font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.danger) }
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

struct CreationImageSelection: Identifiable {
    let id = UUID()
    let items: [CreationMedia]
    let index: Int
}

struct CreationImagePreview: View {
    let selection: CreationImageSelection
    let api: AdminAPIClient
    let site: String
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var reload = 0
    init(selection: CreationImageSelection, api: AdminAPIClient, site: String) {
        self.selection = selection; self.api = api; self.site = site
        _index = State(initialValue: min(max(selection.index, 0), max(selection.items.count - 1, 0)))
    }
    var body: some View {
        NavigationStack {
            CreationImagePager(selection: selection, site: site, siteRoot: api.siteRoot, index: $index, reload: reload, onDismiss: { dismiss() })
            .background(.black)
            .navigationTitle(selection.items.count > 1 ? "\(index + 1) / \(selection.items.count)" : "图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("重新加载图片", systemImage: "arrow.clockwise") { reload += 1 } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }.preferredColorScheme(.dark)
    }
}

/// UIKit owns interactive movement; SwiftUI only receives committed page changes.
private struct CreationImagePager: UIViewControllerRepresentable {
    let selection: CreationImageSelection
    let site: String
    let siteRoot: URL
    @Binding var index: Int
    let reload: Int
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.view.backgroundColor = .black
        pager.view.accessibilityIdentifier = "image.gallery"
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        let down = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dragDown(_:)))
        down.maximumNumberOfTouches = 1
        down.delegate = context.coordinator
        pager.view.addGestureRecognizer(down)
        context.coordinator.pager = pager
        context.coordinator.downGesture = down
        for gesture in pager.gestureRecognizers where gesture is UIPanGestureRecognizer && gesture !== down {
            gesture.require(toFail: down)
        }
        if let page = context.coordinator.page(index) {
            pager.setViewControllers([page], direction: .forward, animated: false)
            context.coordinator.retainNeighbors(around: index)
        }
        return pager
    }
    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.reload != reload {
            context.coordinator.reload = reload
            (pager.viewControllers?.first as? CreationGalleryPage)?.load(force: true)
        }
    }
    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        pager.dataSource = nil; pager.delegate = nil
        if let gesture = coordinator.downGesture { pager.view.removeGestureRecognizer(gesture) }
        coordinator.resetDrag(animated: false)
        coordinator.pages.values.forEach { $0.cancel() }
        coordinator.pages.removeAll()
    }
    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: CreationImagePager
        var pages: [Int: CreationGalleryPage] = [:]
        var reload: Int
        weak var pager: UIPageViewController?
        weak var downGesture: UIPanGestureRecognizer?
        private weak var draggedView: UIView?
        private var changingPage = false
        private var dismissing = false
        init(_ parent: CreationImagePager) { self.parent = parent; reload = parent.reload }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, !changingPage, !dismissing else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.2
        }
        @objc func dragDown(_ pan: UIPanGestureRecognizer) {
            guard let pager else { return }
            switch pan.state {
            case .began:
                draggedView = pager.viewControllers?.first?.view
            case .changed:
                let translation = pan.translation(in: pager.view)
                let distance = max(0, translation.y)
                let fraction = min(distance / max(pager.view.bounds.height, 1), 1)
                let scale = UIAccessibility.isReduceMotionEnabled ? 1 : 1 - fraction * 0.12
                draggedView?.transform = CGAffineTransform(translationX: translation.x * 0.12, y: distance).scaledBy(x: scale, y: scale)
            case .ended:
                let distance = max(0, pan.translation(in: pager.view).y)
                if distance > max(90, pager.view.bounds.height * 0.15) || (distance > 30 && pan.velocity(in: pager.view).y > 800) {
                    dismissing = true
                    parent.onDismiss()
                } else { resetDrag(animated: true) }
            case .cancelled, .failed: resetDrag(animated: true)
            default: break
            }
        }
        func resetDrag(animated: Bool) {
            guard let view = draggedView else { return }
            draggedView = nil
            if animated {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { view.transform = .identity }
            } else { view.transform = .identity }
        }
        func page(_ index: Int) -> CreationGalleryPage? {
            guard parent.selection.items.indices.contains(index) else { return nil }
            if let page = pages[index] { return page }
            let page = CreationGalleryPage(index: index, media: parent.selection.items[index], site: parent.site, siteRoot: parent.siteRoot)
            pages[index] = page
            page.loadViewIfNeeded() // Prefetch and decode before the swipe reaches this page.
            return page
        }
        func retainNeighbors(around index: Int) {
            for key in Array(pages.keys) where abs(key - index) > 1 { pages.removeValue(forKey: key)?.cancel() }
            _ = page(index - 1); _ = page(index + 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? CreationGalleryPage else { return nil }
            return self.page(page.index - 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? CreationGalleryPage else { return nil }
            return self.page(page.index + 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { changingPage = true }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            changingPage = false
            guard let page = pageViewController.viewControllers?.first as? CreationGalleryPage else { return }
            if completed { parent.index = page.index }
            retainNeighbors(around: page.index)
        }
    }
}

@MainActor
final class CreationGalleryPage: UIViewController {
    let index: Int
    private let media: CreationMedia
    private let site: String
    private let siteRoot: URL
    private let loader: ImageLoader
    private let photo = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var loading: Task<Void, Never>?
    private var generation = 0
    init(index: Int, media: CreationMedia, site: String, siteRoot: URL, loader: ImageLoader = .shared) {
        self.index = index; self.media = media; self.site = site; self.siteRoot = siteRoot; self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        photo.contentMode = .scaleAspectFit
        photo.accessibilityIdentifier = "gallery.photo.\(index)"
        photo.isAccessibilityElement = true
        photo.accessibilityLabel = "第 \(index + 1) 张图片"
        spinner.color = .white
        retryButton.setTitle("图片加载失败，点此重试", for: .normal)
        retryButton.tintColor = .white
        retryButton.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        for child in [photo, spinner, retryButton] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            photo.leadingAnchor.constraint(equalTo: view.leadingAnchor), photo.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            photo.topAnchor.constraint(equalTo: view.topAnchor), photo.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor), retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        load()
    }
    @objc private func retryImage() { load(force: true) }
    func cancel() { generation += 1; loading?.cancel(); loading = nil }
    func load(force: Bool = false) {
        cancel()
        let token = generation
        retryButton.isHidden = true
        if photo.image == nil { spinner.startAnimating() }
        loading = Task { [weak self, media, site, siteRoot, loader] in
            do {
                let image: UIImage
                let localURL = if let filename = media.filename { try? await CreationDraftStore.shared.imageURL(site: site, filename: filename) } else { URL?.none }
                let localImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        guard let url = localURL else { return nil }
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
                        return image
                    }.value
                try Task.checkCancellation()
                if let localImage {
                    image = UIImage(cgImage: localImage)
                } else if CreationPreview.isEnabled, let preview = UIImage(named: media.remotePath?.contains("/preview-1.") == true ? "BrandCat" : "EditorialPreview") {
                    image = await preview.byPreparingForDisplay() ?? preview
                } else if let path = media.remotePath, let url = URL(string: path, relativeTo: siteRoot)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    image = UIImage(cgImage: try await loader.image(for: url, maxPixelSize: 2048, forceReload: force))
                } else { throw URLError(.badURL) }
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.photo.image = image
                self.photo.accessibilityValue = "已加载"
                self.spinner.stopAnimating()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.spinner.stopAnimating(); self.retryButton.isHidden = false
            }
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
