import SwiftUI

@MainActor
final class CreationPlaylistModel: ObservableObject {
    @Published private(set) var songs: [CreationMusic] = []
    @Published private(set) var total = 0
    @Published private(set) var availableTotal: Int?
    @Published private(set) var nextOffset: Int?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var didLoad = false
    func load(api: AdminAPIClient, id: String) async {
        guard !loading, !didLoad || nextOffset != nil else { return }
        loading = true; error = nil
        defer { loading = false }
        let offset = nextOffset ?? 0
        do {
            let response = try await api.fetchQQMusicPlaylistMetadata(id: id, offset: offset)
            guard !Task.isCancelled else { return }
            var existing = Set(songs.map(\.playbackKey))
            songs += response.tracks.filter { !$0.mid.isEmpty }.map(CreationMusic.init(track:)).filter { existing.insert($0.playbackKey).inserted }
            total = max(response.total, songs.count); availableTotal = response.availableTotal
            nextOffset = response.nextOffset.flatMap { $0 > offset ? $0 : nil }
            didLoad = true
        } catch { if !isRequestCancellation(error) { self.error = error.localizedDescription } }
    }
    var countLabel: String {
        total > songs.count ? "共 \(total) 首 · 已加载 \(songs.count) 首" : "\(total) 首歌曲"
    }
    var incompleteMessage: String? {
        guard didLoad, nextOffset == nil, songs.count < total else { return nil }
        return availableTotal == nil ? "网站目前只返回部分歌曲，更新网站接口后可继续加载完整歌单。" : "有 \(total - songs.count) 首歌曲未返回有效资料，已保留歌单总数。"
    }
}

struct CreationListeningView: View {
    let api: AdminAPIClient
    let moments: [AdminMoment]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var feed: CreationFeedModel
    @ObservedObject private var audio = CreationAudioPlayer.shared
    @State private var source = 0
    @State private var playlists: [AdminMusicPlaylist] = []
    @State private var loadingPlaylists = false
    @State private var loadedPlaylists = false
    @State private var playlistError: String?
    @State private var showQueue = true
    init(api: AdminAPIClient, moments: [AdminMoment]) {
        self.api = api; self.moments = moments
        _feed = StateObject(wrappedValue: CreationFeedModel(api: api))
    }
    private var music: [CreationMusic] {
        var seen = Set<String>()
        return (feed.moments.isEmpty ? moments : feed.moments).flatMap { CreationMusic.split($0.content).music }
            .filter { seen.insert($0.playbackKey).inserted }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CreationNowPlayingView(api: api)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                Picker("音乐来源", selection: $source) {
                    Text("絮语音乐").tag(0); Text("网站歌单").tag(1); Text("待播放").tag(2)
                }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 8)
                List {
                    if source == 0 {
                        Section {
                            ForEach(Array(music.enumerated()), id: \.element.playbackKey) { index, song in
                                CreationMusicQueueRow(music: song, api: api, number: index + 1) { audio.play(song, in: music, api: api) }
                            }
                        } header: { Text("絮语里的音乐 · \(music.count)") }
                        if let error = feed.error { Text(error).font(.footnote); Button("重试") { Task { await feed.load(reset: feed.moments.isEmpty) } } }
                        if feed.isLoading { ProgressView("加载音乐…") }
                        else if feed.hasMore { Button("加载更多絮语音乐") { Task { await feed.load() } } }
                        if music.isEmpty && !feed.isLoading && feed.error == nil { ContentUnavailableView("还没有音乐", systemImage: "music.note", description: Text("写絮语时添加喜欢的歌曲。")) }
                    } else if source == 1 {
                        Section {
                            ForEach(playlists) { playlist in
                                NavigationLink { CreationPlaylistView(api: api, playlist: playlist) } label: {
                                    HStack(spacing: 12) {
                                        CreationRemoteImage(path: playlist.cover, site: api.siteRoot)
                                            .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(playlist.name).font(.body.weight(.medium)).lineLimit(1)
                                            Text([playlist.creator.trimmedNonEmpty, playlist.count.map { "\($0) 首" }].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.padding(.vertical, 2)
                                }.accessibilityIdentifier("listening.playlist.\(playlist.id)")
                            }
                        } header: { Text(loadedPlaylists ? "网站歌单 · \(playlists.count)" : "网站歌单") }
                        if loadingPlaylists { ProgressView("加载歌单…") }
                        if let playlistError { Text(playlistError); Button("重试") { Task { await loadPlaylists() } } }
                        if loadedPlaylists && playlists.isEmpty && playlistError == nil { ContentUnavailableView("暂无网站歌单", systemImage: "music.note.list") }
                    } else {
                        Section {
                            if showQueue {
                                ForEach(Array(audio.queue.items.enumerated()), id: \.element.playbackKey) { index, song in
                                    CreationMusicQueueRow(music: song, api: api, number: index + 1) { audio.selectQueueItem(song) }
                                }
                            }
                        } header: {
                            Button { withAnimation { showQueue.toggle() } } label: {
                                Label("待播放 · \(audio.queue.items.count)", systemImage: showQueue ? "chevron.down" : "chevron.right")
                            }.accessibilityLabel(showQueue ? "收起待播放列表" : "展开待播放列表")
                        }
                        if audio.queue.items.isEmpty { ContentUnavailableView("还没有待播放歌曲", systemImage: "music.note.list") }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }.background(CreationDesign.canvas)
                .navigationTitle("听音乐").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("收起") { dismiss() }.accessibilityIdentifier("listening.dismiss") } }
                .task { await feed.loadIfNeeded() }
                .task(id: source) { if source == 1 && !loadedPlaylists { await loadPlaylists() } }
        }.tint(CreationDesign.accent)
    }
    private func loadPlaylists() async {
        guard !loadingPlaylists else { return }
        loadingPlaylists = true; playlistError = nil
        defer { loadingPlaylists = false }
        do {
            let result = try await api.fetchQQMusicPlaylists().playlists
            guard !Task.isCancelled else { return }
            playlists = result; loadedPlaylists = true
        } catch { if !isRequestCancellation(error) { playlistError = error.localizedDescription } }
    }
}

private struct CreationPlaylistView: View {
    let api: AdminAPIClient
    let playlist: AdminMusicPlaylist
    @StateObject private var model = CreationPlaylistModel()
    @ObservedObject private var audio = CreationAudioPlayer.shared
    var body: some View {
        VStack(spacing: 0) {
            if audio.current != nil { CreationNowPlayingView(api: api).padding(.horizontal, 20).padding(.vertical, 8) }
            List {
                HStack(spacing: 14) {
                    CreationRemoteImage(path: playlist.cover, site: api.siteRoot).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(playlist.name).font(.headline)
                        if let creator = playlist.creator.trimmedNonEmpty { Text(creator).font(.subheadline).foregroundStyle(.secondary) }
                        Text(model.total == 0 ? (playlist.count.map { "共 \($0) 首" } ?? "加载歌曲资料…") : model.countLabel)
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("playlist.count")
                    }
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                ForEach(Array(model.songs.enumerated()), id: \.element.playbackKey) { index, song in
                    CreationMusicQueueRow(music: song, api: api, number: index + 1) {
                        audio.play(song, in: model.songs, api: api, playlistID: playlist.id, nextOffset: model.nextOffset)
                    }
                }
                if model.loading { ProgressView("加载歌曲资料…") }
                if let error = model.error { Text(error).font(.footnote); Button("重试") { Task { await load() } } }
                if model.nextOffset != nil && !model.loading { Button("加载更多歌曲") { Task { await load() } }.accessibilityIdentifier("playlist.loadMore") }
                if let message = model.incompleteMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if !model.loading && model.error == nil && model.total == 0 { ContentUnavailableView("歌单暂无歌曲", systemImage: "music.note") }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }.background(CreationDesign.canvas).navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
            .task { if model.songs.isEmpty { await load() } }
    }
    private func load() async { await model.load(api: api, id: playlist.id) }
}

struct CreationMusicQueueRow: View {
    let music: CreationMusic
    let api: AdminAPIClient
    let number: Int
    let action: () -> Void
    @ObservedObject private var audio = CreationAudioPlayer.shared
    @State private var resolved: CreationMusic?
    @State private var loading = false
    @State private var failed = false
    @State private var retry = 0
    private var song: CreationMusic { resolved ?? music }
    private var selected: Bool { audio.current?.playbackKey == music.playbackKey }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Group {
                        if selected && audio.isLoading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: selected ? (audio.isPlaying ? "waveform" : "pause.fill") : "music.note").opacity(selected ? 1 : 0) }
                    }.frame(width: 16).overlay { if !selected { Text("\(number)").font(.caption).foregroundStyle(.tertiary) } }
                    CreationRemoteImage(path: song.cover, site: api.siteRoot).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.subheadline.weight(selected ? .semibold : .medium)).foregroundStyle(CreationDesign.foreground).lineLimit(1)
                        Text(loading ? "加载歌曲资料…" : failed ? "资料加载失败，可重试" : song.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected && audio.isPlaying ? "pause.fill" : "play.fill").font(.caption)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("listening.song.\(music.marker?.id ?? music.spec)")
                .accessibilityLabel("\(song.title)，\(song.artist)")
                .accessibilityValue(selected ? (audio.isLoading ? "加载中" : audio.isPlaying ? "正在播放" : "已暂停") : "未播放")
            if failed { Button { retry += 1 } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("重试歌曲资料") }
        }
        .listRowBackground(selected ? CreationDesign.accentSoft : Color.clear)
        .overlay(alignment: .leading) { if selected { Capsule().fill(CreationDesign.accent).frame(width: 3, height: 28).offset(x: -10) } }
        .task(id: "\(music.playbackKey)-\(retry)") {
            guard resolved == nil, let marker = music.marker, marker.type == "song", marker.title?.trimmedNonEmpty == nil || marker.artist?.trimmedNonEmpty == nil else { return }
            loading = true; failed = false
            defer { loading = false }
            do {
                let track = try await api.fetchQQMusicMetadata(id: marker.id)
                guard !Task.isCancelled else { return }
                resolved = CreationMusic(track: track)
            } catch { if !isRequestCancellation(error) { failed = true } }
        }
    }
}

struct CreationNowPlayingView: View {
    let api: AdminAPIClient
    @ObservedObject private var audio = CreationAudioPlayer.shared
    @State private var scrubbing = false
    @State private var position = 0.0
    var body: some View {
        if let song = audio.current {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    CreationRemoteImage(path: song.cover, site: api.siteRoot).frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(audio.isLoading ? "正在加载" : audio.isPlaying ? "正在播放" : "已暂停").font(.caption).foregroundStyle(CreationDesign.accent)
                        Text(song.title).font(.headline).lineLimit(2)
                        Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Picker("播放模式", selection: Binding(get: { audio.mode }, set: { audio.mode = $0 })) {
                            ForEach(CreationPlaybackMode.allCases, id: \.self) { mode in Label(mode.rawValue, systemImage: mode.symbol).tag(mode) }
                        }
                        Button("停止播放", systemImage: "stop.circle", role: .destructive) { audio.stop() }
                    } label: { Image(systemName: audio.mode.symbol).frame(width: 44, height: 44) }.accessibilityLabel("播放模式")
                }
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { scrubbing ? position : audio.elapsed }, set: { position = $0 }), in: 0...max(audio.duration, 1), onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { audio.seek(to: position) }
                    }).disabled(audio.duration <= 0 || audio.isLoading).accessibilityLabel("播放进度")
                    HStack { Text(time(scrubbing ? position : audio.elapsed)); Spacer(); Text(time(audio.duration)) }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 34) {
                    Button { audio.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("上一首")
                    Button { audio.toggle() } label: {
                        Group { if audio.isLoading { ProgressView() } else { Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title2) } }.frame(width: 52, height: 44)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel(audio.isPlaying || audio.isLoading ? "暂停播放" : "继续播放").accessibilityIdentifier("player.toggle")
                    Button { audio.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("下一首")
                }.buttonStyle(.plain)
                if let message = audio.message {
                    HStack { Text(message).font(.caption).foregroundStyle(.secondary); Button("重试") { audio.resumePlayback() } }.accessibilityIdentifier("player.error")
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list").font(.title2).foregroundStyle(CreationDesign.accent).frame(width: 48, height: 48).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) { Text("听点喜欢的").font(.headline); Text("选一首歌，让日常慢下来").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
            }.padding(.vertical, 8)
        }
    }
    private func time(_ value: Double) -> String { let seconds = value.isFinite ? max(0, Int(value)) : 0; return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

private struct CreationMiniPlayerModifier: ViewModifier {
    let api: AdminAPIClient
    @ObservedObject private var audio = CreationAudioPlayer.shared
    @State private var expanded = false
    @State private var height: CGFloat = 60
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let song = audio.current {
                HStack(spacing: 4) {
                    Button { expanded = true } label: {
                        HStack(spacing: 10) {
                            CreationRemoteImage(path: song.cover, site: api.siteRoot).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) { Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1); Text(audio.message == nil ? song.artist : "播放失败，点此重试").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(minLength: 0)
                        }.frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("展开播放器").accessibilityIdentifier("player.mini")
                    Button { audio.toggle() } label: { Image(systemName: audio.isPlaying || audio.isLoading ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(audio.isPlaying || audio.isLoading ? "暂停播放" : "继续播放")
                }.padding(.horizontal, 12).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 16).padding(.bottom, 4).tint(CreationDesign.accent)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
        }.environment(\.creationMiniPlayerHeight, audio.current == nil ? 0 : height)
            .sheet(isPresented: $expanded) { CreationListeningView(api: api, moments: []) }
    }
}

private struct CreationMiniPlayerHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var creationMiniPlayerHeight: CGFloat {
        get { self[CreationMiniPlayerHeightKey.self] }
        set { self[CreationMiniPlayerHeightKey.self] = newValue }
    }
}

extension View {
    func creationMiniPlayer(api: AdminAPIClient) -> some View { modifier(CreationMiniPlayerModifier(api: api)) }
}
