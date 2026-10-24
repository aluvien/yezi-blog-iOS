import SwiftUI
import UIKit

@MainActor
final class AIImageComposerModel: ObservableObject {
    @Published var settings: AIImageSettings
    @Published var prompt = ""
    @Published var size = "1024x1024"
    @Published private(set) var image: GeneratedAIImage?
    @Published private(set) var preview: UIImage?
    @Published private(set) var isGenerating = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private let service: AIImageService

    init(service: AIImageService = AIImageService(), settings: AIImageSettings? = nil) {
        self.service = service
        self.settings = settings ?? AIImageSettingsStore().load()
    }
    func generate() {
        guard !isGenerating else { return }
        error = nil
        do { try settings.validate() } catch { self.error = error.localizedDescription; return }
        let configuration = settings
        let description = prompt
        let dimensions = size
        isGenerating = true
        task = Task {
            defer { isGenerating = false }
            do {
                let result = try await service.generate(settings: configuration, prompt: description, size: dimensions)
                let prepared = try await CreationImageProcessor.prepare(result.data)
                try Task.checkCancellation()
                guard let thumbnail = UIImage(data: prepared.data) else { throw AIImageError.message("图片预览失败，请重新生成。") }
                image = GeneratedAIImage(data: prepared.data)
                preview = thumbnail
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func cancel() { task?.cancel() }
}

struct AIImageComposerView: View {
    @StateObject private var model: AIImageComposerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsSettings = false
    @State private var useAsCover = false
    @State private var isInserting = false
    @FocusState private var promptFocused: Bool
    let allowsCover: Bool
    let onInsert: (Data, Bool) async throws -> Void

    init(allowsCover: Bool, service: AIImageService = AIImageService(), settings: AIImageSettings? = nil, onInsert: @escaping (Data, Bool) async throws -> Void) {
        self.allowsCover = allowsCover
        self.onInsert = onInsert
        _model = StateObject(wrappedValue: AIImageComposerModel(service: service, settings: settings))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(model.preview == nil ? "用文字，描绘一幅画" : "配图预览").font(CreationDesign.editorial(30, relativeTo: .largeTitle, bold: true))
                    if let image = model.preview {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("AI 生成图片")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("画面描述").font(CreationDesign.interface(.subheadline))
                        TextField("例如：山间晨雾，胶片摄影，柔和的日出光线", text: $model.prompt, axis: .vertical)
                            .lineLimit(4...8).focused($promptFocused).padding(14)
                            .background(CreationDesign.surface).overlay { RoundedRectangle(cornerRadius: 6).stroke(CreationDesign.border, lineWidth: 0.5) }
                            .accessibilityIdentifier("ai-image.prompt").disabled(model.isGenerating)
                    }
                    Picker("图片尺寸", selection: $model.size) {
                        Text("方形 1:1").tag("1024x1024")
                        Text("横向 3:2").tag("1536x1024")
                        Text("竖向 2:3").tag("1024x1536")
                    }.pickerStyle(.menu).tint(CreationDesign.foreground).disabled(model.isGenerating)
                    if allowsCover { Toggle("同时设为文章封面", isOn: $useAsCover).font(CreationDesign.interface(.subheadline)) }
                }.padding(20).disabled(isInserting)
            }.scrollDismissesKeyboard(.interactively)
                .background(CreationDesign.canvas)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if model.isGenerating {
                            HStack { ProgressView(); Text("正在生成，请稍候…"); Spacer(); Button("取消生成") { model.cancel() } }.font(CreationDesign.interface(.subheadline)).padding(20)
                        }
                        if let error = model.error { CreationNotice(text: error, isError: true).padding(.horizontal, 20).padding(.top, 12) }
                        actions
                    }.background(CreationDesign.canvas)
                }
                .navigationTitle("AI 生图").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(isInserting) }
                    ToolbarItem(placement: .primaryAction) { Button("服务设置", systemImage: "slider.horizontal.3") { showsSettings = true }.disabled(model.isGenerating || isInserting) }
                }
        }.foregroundStyle(CreationDesign.foreground).tint(CreationDesign.accent)
            .interactiveDismissDisabled(isInserting)
            .sheet(isPresented: $showsSettings) { AIImageSettingsView(settings: $model.settings) }
            .onDisappear { model.cancel() }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                promptFocused = false
                if (try? model.settings.validate()) == nil { showsSettings = true }
                else { model.generate() }
            } label: {
                Text(model.preview == nil ? "生成配图" : "重新生成").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).overlay { RoundedRectangle(cornerRadius: 6).stroke(CreationDesign.border) }
                .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating || isInserting)
                .accessibilityIdentifier("ai-image.generate")
            Button {
                guard let image = model.image, !isInserting else { return }
                promptFocused = false
                isInserting = true
                model.error = nil
                Task {
                    defer { isInserting = false }
                    do { try await onInsert(image.data, useAsCover); dismiss() }
                    catch { model.error = "插入失败，图片已保留，可重试。\(error.localizedDescription)" }
                }
            } label: {
                Text(isInserting ? "正在插入…" : "插入正文").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(CreationPrimaryButtonStyle())
                .disabled(model.image == nil || model.isGenerating || isInserting).accessibilityIdentifier("ai-image.insert")
        }.font(CreationDesign.interface(.subheadline)).padding(20).background(CreationDesign.canvas)
            .overlay(alignment: .top) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }
    }
}

private struct AIImageSettingsView: View {
    @Binding var settings: AIImageSettings
    @State private var edited: AIImageSettings
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(settings: Binding<AIImageSettings>) { _settings = settings; _edited = State(initialValue: settings.wrappedValue) }
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section("CPA · OpenAI 兼容服务") {
                    TextField("服务地址（HTTPS）", text: $edited.address).keyboardType(.URL).accessibilityIdentifier("ai-image.address")
                    TextField("生图模型名称", text: $edited.model).accessibilityIdentifier("ai-image.model")
                    SecureField("API 密钥", text: $edited.apiKey).accessibilityIdentifier("ai-image.key")
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Section { Text("地址支持填写服务根地址、以 /v1 结尾的地址，或完整的 /images/generations 地址。模型名称请与 CPA 中配置的一致。密钥只保存在此设备的系统钥匙串中。").font(CreationDesign.interface(.footnote)) }
                if let error { Section { Text(error).foregroundStyle(CreationDesign.danger) } }
                }.listRowBackground(CreationDesign.surface)
            }.scrollContentBackground(.hidden).background(CreationDesign.canvas)
                .navigationTitle("生图服务").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { try AIImageSettingsStore().save(edited); settings = edited; dismiss() }
                        catch { self.error = error.localizedDescription }
                    } }
                }
        }.tint(CreationDesign.accent)
    }
}
