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

private actor CreationAudioSession {
    static let shared = CreationAudioSession()
    private var token: UUID?
    func activate(token: UUID) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        self.token = token
    }
    func deactivate(token: UUID) {
        guard self.token == token else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.token = nil
    }
}

@MainActor
final class CreationAudioPlayer: ObservableObject {
    static let shared = CreationAudioPlayer()
    @Published private(set) var playingID: String?
    @Published var message: String?
    private var player: AVPlayer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var completionObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    func stop() {
        let previousToken = generation
        generation = UUID()
        task?.cancel()
        task = nil
        player?.pause()
        player = nil
        playingID = nil
        statusObservation = nil
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        completionObserver = nil
        failureObserver = nil
        Task { await CreationAudioSession.shared.deactivate(token: previousToken) }
    }

    func preview(_ music: CreationMusic, api: AdminAPIClient) {
        if playingID == music.spec { stop(); return }
        stop()
        message = nil
        guard let marker = music.marker else { message = "暂不能试听"; return }
        let token = generation
        playingID = music.spec
        task = Task { [weak self] in
            do {
                let track: AdminMusicTrack?
                if marker.type == "playlist" {
                    let playlist = try await api.fetchQQMusicPlaylistTracks(id: marker.id)
                    track = marker.shuffle ? playlist.tracks.randomElement() : playlist.tracks.first
                } else { track = try await api.fetchQQMusicTrack(id: marker.id) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                guard let track,
                      let url = CreationPlaybackURL.resolve(track: track, expectedMID: marker.type == "playlist" ? nil : marker.id, siteRoot: api.siteRoot), !CreationPreview.isEnabled else {
                    self.playingID = nil
                    self.message = "暂不能试听，仍可添加音乐"
                    return
                }
                try await CreationAudioSession.shared.activate(token: token)
                guard self.generation == token, !Task.isCancelled else { await CreationAudioSession.shared.deactivate(token: token); return }
                let item = AVPlayerItem(url: url)
                self.player = AVPlayer(playerItem: item)
                self.completionObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in guard let self, self.generation == token else { return }; self.stop() }
                }
                self.failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in guard let self, self.generation == token else { return }; self.stop(); self.message = "暂不能试听，仍可添加音乐" }
                }
                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .failed { Task { @MainActor in guard let self, self.generation == token else { return }; self.stop(); self.message = "暂不能试听，仍可添加音乐" } }
                }
                self.player?.play()
            } catch {
                guard let self, self.generation == token else { return }
                self.playingID = nil
                self.message = "暂不能试听，仍可添加音乐"
            }
        }
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
    var replace: (() -> Void)?
    var remove: (() -> Void)?
    @StateObject private var audio = CreationAudioPlayer.shared
    @State private var resolvedSong: AdminMusicTrack?
    @State private var resolvedPlaylist: AdminMusicPlaylist?
    @Environment(\.scenePhase) private var scenePhase

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
            ?? "音乐信息暂不可用"
    }

    private var cover: String? {
        music.marker?.cover?.trimmedNonEmpty
            ?? resolvedSong?.cover.trimmedNonEmpty
            ?? resolvedPlaylist?.cover.trimmedNonEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CreationRemoteImage(path: cover, site: api.siteRoot)
                    .frame(width: compact ? 38 : 56, height: compact ? 38 : 56)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold)).lineLimit(1)
                    Text(artist).font(compact ? .caption : .subheadline).foregroundStyle(CreationDesign.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { audio.preview(music, api: api) } label: {
                    Image(systemName: audio.playingID == music.spec ? "stop.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(audio.playingID == music.spec ? "停止试听" : "试听\(title)")
                if replace != nil || remove != nil {
                    Menu {
                        if let replace { Button("替换音乐") { audio.stop(); replace() } }
                        if let remove { Button("移除音乐", role: .destructive) { audio.stop(); remove() } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("音乐操作")
                }
            }
            if let message = audio.message { Text(message).font(.caption).foregroundStyle(CreationDesign.secondary) }
        }.padding(compact ? 8 : 12).background(CreationDesign.soft, in: RoundedRectangle(cornerRadius: compact ? 11 : 16))
            .task(id: music.spec) { await resolveDetails() }
            .onDisappear { if audio.playingID == music.spec { audio.stop() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active && audio.playingID == music.spec { audio.stop() } }
    }

    private func resolveDetails() async {
        resolvedSong = nil
        resolvedPlaylist = nil
        guard let marker = music.marker,
              marker.title?.trimmedNonEmpty == nil || marker.artist?.trimmedNonEmpty == nil || marker.cover?.trimmedNonEmpty == nil else { return }
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
        } catch { /* Preserve the marker when QQ metadata is unavailable. */ }
    }
}

struct MusicPickerView: View {
    @StateObject private var model: MusicPickerModel
    @StateObject private var audio = CreationAudioPlayer.shared
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
                    if let message = audio.message { CreationNotice(text: message) }
                    Text(model.query.isEmpty ? "最近添加" : "搜索结果").font(.headline)
                    let items = model.query.isEmpty ? model.recent : model.results
                    if items.isEmpty && !model.isLoading && model.error == nil {
                        Text(model.query.isEmpty ? "添加的音乐会保存在当前站点的最近记录中。" : "没找到这首音乐，试试歌曲名或歌手").foregroundStyle(CreationDesign.secondary)
                    }
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Button { model.select(item); audio.stop() } label: {
                                HStack(spacing: 12) {
                                    CreationRemoteImage(path: item.cover, site: model.api.siteRoot).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.body.weight(.medium)); Text(item.artist).font(.subheadline).foregroundStyle(CreationDesign.secondary) }
                                    Spacer(minLength: 4)
                                    Image(systemName: model.selected?.spec == item.spec ? "checkmark.circle.fill" : "circle").foregroundStyle(CreationDesign.accent)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { audio.preview(item, api: model.api) } label: { Image(systemName: audio.playingID == item.spec ? "stop.fill" : "play.fill").frame(width: 44, height: 44) }.accessibilityLabel("试听\(item.title)")
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
            .task { await model.loadRecent() }
            .onDisappear { model.cancel(); audio.stop() }
            .onChange(of: model.type) { _, _ in audio.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audio.stop() } }
    }
}
