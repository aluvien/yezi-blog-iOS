import SwiftUI
import AVFoundation

enum CreationPlaybackURL {
    static func resolve(track: AdminMusicTrack, expectedMID: String?, siteRoot: URL) -> URL? {
        guard expectedMID == nil || track.mid == expectedMID,
              let raw = track.playableURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw, relativeTo: siteRoot)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

@MainActor
final class MusicPickerModel: ObservableObject {
    let api: AdminAPIClient
    let store: CreationDraftStore
    let allowsFolded: Bool
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var type: AdminMusicSearchType = .song { didSet { selected = nil; scheduleSearch() } }
    @Published private(set) var results: [CreationMusic] = []
    @Published private(set) var recent: [CreationMusic] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var selected: CreationMusic?
    @Published var shuffle = false
    @Published var folded: Bool
    private var generation = UUID()
    private var searchTask: Task<Void, Never>?

    init(api: AdminAPIClient, store: CreationDraftStore = .shared, allowsFolded: Bool = false, initialFolded: Bool = false) {
        self.api = api
        self.store = store
        self.allowsFolded = allowsFolded
        folded = allowsFolded && initialFolded
    }

    func select(_ music: CreationMusic) {
        selected = music
        shuffle = music.marker?.shuffle ?? false
        folded = allowsFolded && (music.marker?.folded ?? false)
    }

    func loadRecent() async {
        do { recent = try await store.recent(site: CreationDraftStore.canonicalSite(api.siteRoot)) }
        catch { self.error = error.localizedDescription }
    }

    func cancel() { generation = UUID(); searchTask?.cancel(); isLoading = false }

    func scheduleSearch() {
        cancel()
        results = []
        selected = nil
        error = nil
        guard let text = query.trimmedNonEmpty else { return }
        let token = generation
        let kind = type
        isLoading = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let response = try await self.api.searchQQMusic(query: text, type: kind)
                guard self.generation == token, !Task.isCancelled else { return }
                if kind == .song {
                    self.results = response.tracks.filter { !$0.mid.isEmpty }.map {
                        CreationMusic(spec: MarkdownParser.makeMusicSpec(id: $0.mid, type: "song", title: $0.name, artist: $0.artist, cover: $0.cover))
                    }
                } else {
                    self.results = response.playlists.filter { !$0.id.isEmpty }.map {
                        CreationMusic(spec: MarkdownParser.makeMusicSpec(id: $0.id, type: "playlist", title: $0.name, artist: $0.creator, cover: $0.cover))
                    }
                }
                self.isLoading = false
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.isLoading = false
                self.error = "音乐服务暂不可用 · \(error.localizedDescription)"
            }
        }
    }

    func selectManual(_ raw: String) {
        var spec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = MarkdownParser.musicPayload(in: spec) { spec = payload }
        if MarkdownParser.musicMarker(from: spec) == nil,
           let components = URLComponents(string: spec), components.scheme == "https",
           ["y.qq.com", "i.y.qq.com"].contains(components.host?.lowercased() ?? "") {
            let query = components.queryItems ?? []
            if let mid = query.first(where: { $0.name == "songmid" })?.value {
                spec = "qqvip:\(mid):song"
            } else if let id = query.first(where: { ["id", "disstid"].contains($0.name) })?.value, components.path.contains("playlist") {
                spec = "qqvip:\(id):playlist"
            } else if let range = components.path.range(of: "/songDetail/") {
                let mid = String(components.path[range.upperBound...]).split(separator: "/").first.map(String.init) ?? ""
                spec = "qqvip:\(mid):song"
            }
        }
        guard MarkdownParser.musicMarker(from: spec) != nil else { error = "请输入 !music qqvip:003OUlho2HcRHC:song 或 QQ 音乐完整歌曲链接；短链接无法识别"; return }
        select(CreationMusic(spec: spec))
        error = nil
    }

    var selection: CreationMusic? {
        guard let selected, let marker = selected.marker else { return nil }
        return CreationMusic(spec: MarkdownParser.makeMusicSpec(
            id: marker.id, type: marker.type,
            shuffle: marker.type == "playlist" && shuffle,
            folded: allowsFolded && folded,
            title: marker.title, artist: marker.artist, cover: marker.cover
        ))
    }
}

struct CreationMusicCard: View {
    let music: CreationMusic
    let api: AdminAPIClient
    var compact = false
    var inline = false
    var listRow = false
    var replace: (() -> Void)?
    var remove: (() -> Void)?
    @StateObject private var audio = CreationAudioPlayer.shared
    @State private var resolvedSong: AdminMusicTrack?
    @State private var resolvedPlaylist: AdminMusicPlaylist?
    @State private var loadingDetails = false
    @State private var detailsFailed = false
    private var isCurrent: Bool { audio.current?.playbackKey == music.playbackKey }
    private var active: Bool { isCurrent && (audio.isPlaying || audio.isLoading) }

    private var title: String {
        music.marker?.title?.trimmedNonEmpty
            ?? resolvedSong?.name.trimmedNonEmpty
            ?? resolvedPlaylist?.name.trimmedNonEmpty
            ?? (music.marker?.type == "playlist" ? "QQ 音乐歌单" : "QQ 音乐歌曲")
    }

    private var artist: String {
        music.marker?.artist?.trimmedNonEmpty
            ?? resolvedSong?.artist.trimmedNonEmpty
            ?? resolvedPlaylist?.creator.trimmedNonEmpty
            ?? (loadingDetails ? "加载歌曲资料…" : detailsFailed ? "歌曲资料加载失败" : "歌曲资料待加载")
    }

    private var cover: String? {
        music.marker?.cover?.trimmedNonEmpty
            ?? resolvedSong?.cover.trimmedNonEmpty
            ?? resolvedPlaylist?.cover.trimmedNonEmpty
    }

    var body: some View {
        Group {
        if inline {
            Button { audio.preview(music, api: api) } label: {
                HStack(spacing: 5) {
                    Image(systemName: active ? "pause.fill" : "music.note")
                    Text("\(title) · \(artist)").lineLimit(1)
                    if active && audio.isLoading { ProgressView().controlSize(.mini) }
                }.font(.subheadline).frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("播放\(title)，\(artist)")
        } else {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { audio.preview(music, api: api) } label: {
                HStack(spacing: 12) {
                CreationRemoteImage(path: cover, site: api.siteRoot)
                    .frame(width: compact ? 38 : 56, height: compact ? 38 : 56)
                    .clipShape(RoundedRectangle(cornerRadius: listRow ? 10 : 3))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold)).lineLimit(1)
                    Text(artist).font(compact ? .caption : .subheadline).foregroundStyle(CreationDesign.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if active && audio.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: active ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }.frame(width: 44, height: 44)
                }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(active ? "暂停播放" : "试听\(title)")
                    .accessibilityValue(active ? (audio.isLoading ? "正在加载" : "正在播放") : "未播放")
                if replace != nil || remove != nil {
                    Menu {
                        if let replace { Button("替换音乐") { replace() } }
                        if let remove { Button("移除音乐", role: .destructive) { if isCurrent { audio.stop() }; remove() } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("音乐操作")
                }
            }
            if let message = audio.message, isCurrent { Text(message).font(.caption).foregroundStyle(CreationDesign.secondary) }
        }.padding(listRow ? 0 : (compact ? 8 : 12))
            .padding(.vertical, listRow ? 6 : 0)
            .background(listRow ? Color.clear : CreationDesign.soft, in: RoundedRectangle(cornerRadius: 12))
        }
        }
            .task(id: music.spec) { await resolveDetails() }
            .alert("音乐暂时无法播放", isPresented: Binding(get: { inline && isCurrent && audio.message != nil }, set: { if !$0 { audio.message = nil } })) {
                Button("好") { audio.message = nil }
            } message: { Text(audio.message ?? "") }
    }

    private func resolveDetails() async {
        resolvedSong = nil
        resolvedPlaylist = nil
        guard let marker = music.marker,
              marker.title?.trimmedNonEmpty == nil || marker.artist?.trimmedNonEmpty == nil || marker.cover?.trimmedNonEmpty == nil else { return }
        loadingDetails = true; detailsFailed = false
        defer { loadingDetails = false }
        do {
            if marker.type == "song" {
                let track = try await api.fetchQQMusicMetadata(id: marker.id)
                guard !Task.isCancelled, track.mid == marker.id else { return }
                resolvedSong = track
            } else {
                let playlists = try await api.fetchQQMusicPlaylists().playlists
                guard !Task.isCancelled else { return }
                resolvedPlaylist = playlists.first { $0.id == marker.id }
            }
        } catch { if !isRequestCancellation(error) { detailsFailed = true } }
    }
}

struct MusicPickerView: View {
    @StateObject private var model: MusicPickerModel
    @StateObject private var audio = CreationAudioPlayer.audition
    @State private var auditionStarted = false
    @State private var manual = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onAdd: (CreationMusic) -> Void
    let allowFolded: Bool

    init(api: AdminAPIClient, allowFolded: Bool = false, initialFolded: Bool = false, onAdd: @escaping (CreationMusic) -> Void) {
        _model = StateObject(wrappedValue: MusicPickerModel(api: api, allowsFolded: allowFolded, initialFolded: initialFolded))
        self.allowFolded = allowFolded
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("搜索类型", selection: $model.type) { Text("歌曲").tag(AdminMusicSearchType.song); Text("歌单").tag(AdminMusicSearchType.playlist) }.pickerStyle(.segmented)
                    HStack {
                        Image(systemName: "magnifyingglass")
                        TextField("搜索歌曲名或歌手", text: $model.query).submitLabel(.search).onSubmit { model.scheduleSearch() }
                        if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("清空搜索") }
                    }.padding(.horizontal, 12).frame(minHeight: 48).background(CreationDesign.soft, in: RoundedRectangle(cornerRadius: 12))
                    if model.isLoading { ProgressView("正在搜索…") }
                    if let error = model.error { CreationNotice(text: error, isError: true); Button("重试搜索") { model.scheduleSearch() } }
                    if let message = audio.message { CreationNotice(text: message, isError: true) }
                    Text(model.query.isEmpty ? "最近添加" : "搜索结果").font(.headline)
                    let items = model.query.isEmpty ? model.recent : model.results
                    if items.isEmpty && !model.isLoading && model.error == nil {
                        Text(model.query.isEmpty ? "添加的音乐会保存在当前站点的最近记录中。" : "没找到这首音乐，试试歌曲名或歌手").foregroundStyle(CreationDesign.secondary)
                    }
                    ForEach(items) { item in
                        let previewing = audio.current?.playbackKey == item.playbackKey && (audio.isPlaying || audio.isLoading)
                        HStack(spacing: 10) {
                            Button { model.select(item); audio.stop() } label: {
                                HStack(spacing: 12) {
                                    CreationRemoteImage(path: item.cover, site: model.api.siteRoot).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.body.weight(.medium)); Text(item.artist).font(.subheadline).foregroundStyle(CreationDesign.secondary) }
                                    Spacer(minLength: 4)
                                    Image(systemName: model.selected?.spec == item.spec ? "checkmark.circle.fill" : "circle").foregroundStyle(CreationDesign.accent)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier("music-picker.select.\(item.marker?.id ?? item.spec)")
                            Button { audio.preview(item, api: model.api) } label: {
                                Group {
                                    if previewing && audio.isLoading { ProgressView() }
                                    else { Image(systemName: previewing ? "pause.fill" : "play.fill") }
                                }.frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(previewing ? "暂停试听\(item.title)" : "试听\(item.title)")
                                .accessibilityIdentifier("music-picker.preview.\(item.marker?.id ?? item.spec)")
                                .accessibilityValue(previewing ? (audio.isLoading ? "正在获取播放地址" : "正在试听") : "")
                        }.padding(12).background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    DisclosureGroup("粘贴链接或手动输入") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("!music qqvip:歌曲MID:song", text: $manual).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                            Button("识别并选择") { model.selectManual(manual) }.buttonStyle(.bordered)
                        }.padding(.top, 12)
                    }
                    if model.selected?.marker?.type == "playlist" { Toggle("随机播放歌单", isOn: $model.shuffle) }
                    if allowFolded { Toggle("折叠显示到絮语标题旁", isOn: $model.folded) }
                }.padding(20)
            }.background(CreationDesign.canvas)
                .navigationTitle("添加音乐").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button(model.selected?.marker?.type == "playlist" ? "添加这个歌单" : "添加这首音乐") {
                        guard let selection = model.selection else { return }
                        audio.stop(); onAdd(selection); dismiss()
                    }.buttonStyle(CreationPrimaryButtonStyle()).disabled(model.selection == nil).opacity(model.selection == nil ? 0.5 : 1).padding(16).frame(maxWidth: .infinity).background(CreationDesign.surface)
                }
        }.tint(CreationDesign.accent)
            .task {
                if !auditionStarted { CreationAudioPlayer.shared.suspendForAudition(); auditionStarted = true }
                await model.loadRecent()
            }
            .onDisappear {
                model.cancel(); audio.stop()
                if auditionStarted { CreationAudioPlayer.shared.restoreAfterAudition(); auditionStarted = false }
            }
            .onChange(of: model.type) { _, _ in audio.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audio.stop() } }
    }
}
