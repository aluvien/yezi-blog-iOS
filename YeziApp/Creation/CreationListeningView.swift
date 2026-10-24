import SwiftUI
import UIKit

enum CreationMiniPlayerSizing {
    static func scrollOffset(distance: CGFloat, elapsed: TimeInterval) -> CGFloat {
        guard distance > 0, elapsed.isFinite else { return 0 }
        let travel = Double(distance) / 20
        let dwell = 1.2
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 2 * (travel + dwell))
        if phase <= dwell { return 0 }
        if phase <= dwell + travel { return -CGFloat(phase - dwell) * 20 }
        if phase <= 2 * dwell + travel { return -distance }
        return -distance + CGFloat(phase - 2 * dwell - travel) * 20
    }

    static func textWidth(lyrics: [CreationLyricLine], title: String, artist: String, lyricSize: CGFloat, titleSize: CGFloat) -> CGFloat {
        let lyricFont = UIFont(name: "LXGWWenKai-Regular", size: lyricSize) ?? .systemFont(ofSize: lyricSize)
        func measure(_ text: String, font: UIFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let widths = lyrics.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { measure($0, font: lyricFont) }.sorted(by: >)
        if !widths.isEmpty { return widths.count >= 3 ? widths[2] : widths[0] }
        let titleFont = UIFont(name: "LXGWWenKai-Regular", size: titleSize) ?? .systemFont(ofSize: titleSize)
        return max(measure(title, font: titleFont), measure(artist, font: lyricFont))
    }
}

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
                        if let error = feed.error { Text(error).font(CreationDesign.interface(.footnote)); Button("重试") { Task { await feed.load(reset: feed.moments.isEmpty) } } }
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
                                            Text(playlist.name).font(CreationDesign.interface(.body).weight(.medium)).lineLimit(1)
                                            Text([playlist.creator.trimmedNonEmpty, playlist.count.map { "\($0) 首" }].compactMap { $0 }.joined(separator: " · "))
                                                .font(CreationDesign.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.padding(.vertical, 2)
                                }.accessibilityIdentifier("listening.playlist.\(playlist.id)")
                                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
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
                    .refreshable {
                        await api.discardLoadedData(for: ["music-metadata", "music-playlists"])
                        if source == 0 { await feed.load(reset: true) }
                        else if source == 1 { await loadPlaylists() }
                    }
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
            let result = try await api.fetchQQMusicPlaylists(reuseLoaded: true).playlists
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
                        Text(playlist.name).font(CreationDesign.interface(.headline))
                        if let creator = playlist.creator.trimmedNonEmpty { Text(creator).font(CreationDesign.interface(.subheadline)).foregroundStyle(.secondary) }
                        Text(model.total == 0 ? (playlist.count.map { "共 \($0) 首" } ?? "加载歌曲资料…") : model.countLabel)
                            .font(CreationDesign.interface(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("playlist.count")
                    }
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                ForEach(Array(model.songs.enumerated()), id: \.element.playbackKey) { index, song in
                    CreationMusicQueueRow(music: song, api: api, number: index + 1) {
                        audio.play(song, in: model.songs, api: api, playlistID: playlist.id, nextOffset: model.nextOffset)
                    }
                }
                if model.loading { ProgressView("加载歌曲资料…") }
                if let error = model.error { Text(error).font(CreationDesign.interface(.footnote)); Button("重试") { Task { await load() } } }
                if model.nextOffset != nil && !model.loading { Button("加载更多歌曲") { Task { await load() } }.accessibilityIdentifier("playlist.loadMore") }
                if let message = model.incompleteMessage { Text(message).font(CreationDesign.interface(.footnote)).foregroundStyle(.secondary) }
                if !model.loading && model.error == nil && model.total == 0 { ContentUnavailableView("歌单暂无歌曲", systemImage: "music.note") }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await api.discardLoadedData(for: ["music-metadata"]); await load() }
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
                        else { Image(systemName: selected && audio.isPlaying ? "waveform" : "music.note").opacity(selected && audio.isPlaying ? 1 : 0) }
                    }.frame(width: 16).overlay { if !selected || (!audio.isPlaying && !audio.isLoading) { Text("\(number)").font(CreationDesign.interface(.caption)).foregroundStyle(.tertiary) } }
                    CreationRemoteImage(path: song.cover, site: api.siteRoot).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(song.title).font(CreationDesign.interface(.subheadline, weight: selected && audio.isPlaying ? .semibold : .regular))
                        .foregroundStyle(CreationDesign.foreground).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    Text(loading ? "加载中…" : failed ? "资料加载失败" : song.artist)
                        .font(CreationDesign.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 110, alignment: .trailing)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("listening.song.\(music.marker?.id ?? music.spec)")
                .accessibilityLabel("\(song.title)，\(song.artist)")
                .accessibilityValue(selected ? (audio.isLoading ? "加载中" : audio.isPlaying ? "正在播放" : "已暂停") : "未播放")
            if failed { Button { retry += 1 } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("重试歌曲资料") }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(selected && audio.isPlaying ? CreationDesign.accentSoft : Color.clear)
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
    @State private var showLyrics = false
    @State private var scrubbing = false
    @State private var position = 0.0
    var body: some View {
        if let song = audio.current {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    CreationRemoteImage(path: song.cover, site: api.siteRoot).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(audio.isLoading ? "正在加载" : audio.isPlaying ? "正在播放" : "已暂停").font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.accent)
                        Text(song.title).font(CreationDesign.interface(.headline)).lineLimit(2)
                        Text(song.artist).font(CreationDesign.interface(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    transportControls
                }
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { scrubbing ? position : audio.elapsed }, set: { position = $0 }), in: 0...max(audio.duration, 1), onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { audio.seek(to: position) }
                    }).disabled(audio.duration <= 0 || audio.isLoading).accessibilityLabel("播放进度")
                    HStack { Text(time(scrubbing ? position : audio.elapsed)); Spacer(); Text(time(audio.duration)) }.font(CreationDesign.time(.caption2)).foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    if !showLyrics {
                        Button { withAnimation(.easeInOut(duration: 0.2)) { showLyrics = true } } label: {
                            HStack {
                                Text(audio.currentLyric ?? (audio.lyricsLoading ? "歌词加载中…" : audio.lyricsError ?? (audio.lyrics.isEmpty ? "暂无歌词" : "查看歌词")))
                                    .font(CreationDesign.copy(15, relativeTo: .subheadline)).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.down")
                            }.frame(minHeight: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("player.lyrics.toggle")
                    }
                    if let error = audio.lyricsError {
                        Button("\(error)，重试") { audio.loadLyrics(retry: true) }.font(CreationDesign.interface(.caption))
                    }
                    if showLyrics {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 14) {
                                    if audio.lyrics.isEmpty {
                                        Text(audio.lyricsLoading ? "歌词加载中…" : audio.lyricsError ?? "暂无歌词")
                                            .font(CreationDesign.copy(15, relativeTo: .subheadline)).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    ForEach(audio.lyrics) { line in
                                        Text(line.text).font(CreationDesign.copy())
                                            .foregroundStyle(line.id == audio.lyricIndex ? CreationDesign.accent : CreationDesign.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                                    }
                                }.padding(.vertical, 12).padding(.trailing, 44)
                            }.frame(height: 150).accessibilityIdentifier("player.lyrics")
                                .onAppear { if let index = audio.lyricIndex { proxy.scrollTo(index, anchor: .center) } }
                                .onChange(of: audio.lyricIndex) { _, index in
                                    // While paused the index changes only on an explicit seek.
                                    if let index { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) } }
                                }
                                .overlay(alignment: .topTrailing) {
                                    Button { withAnimation(.easeInOut(duration: 0.2)) { showLyrics = false } } label: {
                                        Image(systemName: "chevron.up").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("收起歌词").accessibilityIdentifier("player.lyrics.toggle")
                                }
                        }
                    }
                }
                if let message = audio.message {
                    HStack { Text(message).font(CreationDesign.interface(.caption)).foregroundStyle(.secondary); Button("重试") { audio.resumePlayback() } }.accessibilityIdentifier("player.error")
                }
            }.toolbar { ToolbarItem(placement: .topBarLeading) { modeMenu } }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list").font(CreationDesign.interface(.title2)).foregroundStyle(CreationDesign.accent).frame(width: 48, height: 48).background(CreationDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) { Text("听点喜欢的").font(CreationDesign.interface(.headline)); Text("选一首歌，让日常慢下来").font(CreationDesign.interface(.subheadline)).foregroundStyle(.secondary) }
                Spacer()
            }.padding(.vertical, 8)
        }
    }
    private var transportControls: some View {
        HStack(spacing: 0) {
            Button { audio.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 13)).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("上一首")
            Button { audio.toggle() } label: {
                Group {
                    if audio.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17)) }
                }.frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel(audio.isPlaying || audio.isLoading ? "暂停播放" : "继续播放").accessibilityIdentifier("player.toggle")
            Button { audio.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 13)).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("下一首")
        }.buttonStyle(.plain)
    }
    private var modeMenu: some View {
        Menu {
            Picker("播放模式", selection: Binding(get: { audio.mode }, set: { audio.mode = $0 })) {
                ForEach(CreationPlaybackMode.allCases, id: \.self) { mode in Label(mode.rawValue, systemImage: mode.symbol).tag(mode) }
            }
            Button("停止播放", systemImage: "stop.circle", role: .destructive) { audio.stop() }
        } label: { Image(systemName: audio.mode.symbol).frame(width: 32, height: 32) }.accessibilityLabel("播放模式")
    }
    private func time(_ value: Double) -> String { let seconds = value.isFinite ? max(0, Int(value)) : 0; return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

private struct CreationMiniPlayerModifier: ViewModifier {
    let api: AdminAPIClient
    var visible = true
    @ObservedObject private var audio = CreationAudioPlayer.shared
    @Environment(\.creationParentPresented) private var parentPresented
    @State private var expanded = false
    @State private var resting = true
    @State private var suppressed = false
    @State private var composeWidth: CGFloat = 0
    @State private var referenceTextWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .caption) private var lyricSize: CGFloat = 12
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    func body(content: Content) -> some View {
        content
            .onAppear { updateReferenceWidth() }
            .onChange(of: audio.current) { _, _ in updateReferenceWidth() }
            .onChange(of: audio.lyrics) { _, _ in updateReferenceWidth() }
            .onChange(of: lyricSize) { _, _ in updateReferenceWidth() }
            .onChange(of: titleSize) { _, _ in updateReferenceWidth() }
            .modifier(CreationScrollActionVisibility(visible: $resting))
            .onPreferenceChange(CreationMiniPlayerHiddenKey.self) { suppressed = $0 }
            .onPreferenceChange(CreationComposeWidthKey.self) { composeWidth = $0 }
            .overlay(alignment: .bottomLeading) {
                GeometryReader { proxy in
                    VStack {
                        Spacer()
                        HStack {
                            if let song = audio.current {
                                Group {
                                    if #available(iOS 26.0, *) {
                                        coverButton(song, width: width(in: proxy.size.width)).buttonStyle(.glass).buttonBorderShape(.capsule)
                                    } else {
                                        coverButton(song, width: width(in: proxy.size.width)).buttonStyle(.bordered).background(.regularMaterial, in: Capsule())
                                    }
                                }
                                .modifier(CreationComposeVisibility(visible: visible && resting && !suppressed && !expanded && !parentPresented))
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }
            }.sheet(isPresented: $expanded) { CreationListeningView(api: api, moments: []) }
    }
    private func width(in available: CGFloat) -> CGFloat {
        min(240, max(100, available - 40 - (composeWidth > 0 ? composeWidth + 12 : 0)))
    }
    private func updateReferenceWidth() {
        guard let song = audio.current else { referenceTextWidth = 0; return }
        referenceTextWidth = CreationMiniPlayerSizing.textWidth(lyrics: audio.lyrics, title: song.title, artist: song.artist, lyricSize: lyricSize, titleSize: titleSize)
    }
    private func coverButton(_ song: CreationMusic, width: CGFloat) -> some View {
        Button { expanded = true } label: {
            HStack(spacing: 8) {
                CreationRotatingCover(path: song.cover, site: api.siteRoot, playing: audio.isPlaying && !expanded)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    CreationMiniPlayerScrollingText(text: song.title, size: titleSize, playing: audio.isPlaying && !expanded)
                    CreationMiniPlayerScrollingText(text: audio.playingLyric ?? song.artist, size: lyricSize, playing: audio.isPlaying && !expanded)
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: min(max(60, width - 28), 36 + 8 + referenceTextWidth), alignment: .leading)
            .frame(height: 44)
        }.accessibilityLabel("展开播放器")
            .accessibilityValue("\(song.title)，\(audio.playingLyric ?? song.artist)，\(audio.isPlaying ? "正在播放" : "已暂停")")
            .accessibilityIdentifier("player.mini")
    }
}

/// Animate only overflowing text; the capsule's measured width stays unchanged.
private struct CreationMiniPlayerScrollingText: View {
    let text: String
    let size: CGFloat
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var measured = CGSize.zero
    @State private var elapsed: TimeInterval = 0
    @State private var started: Date?
    private var running: Bool { playing && visible && !reduceMotion && scenePhase == .active }
    private func time(at date: Date) -> TimeInterval { elapsed + (started.map { date.timeIntervalSince($0) } ?? 0) }
    var body: some View {
        GeometryReader { proxy in
            let distance = max(0, measured.width - proxy.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running || distance <= 0)) { context in
                Text(text)
                    .font(.custom("LXGWWenKai-Regular", fixedSize: size))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                    .offset(x: reduceMotion ? 0 : CreationMiniPlayerSizing.scrollOffset(distance: distance, elapsed: time(at: context.date)))
            }
            .clipped()
            .onChange(of: proxy.size.width) { _, _ in reset() }
        }
        .frame(height: max(size, measured.height))
        .onAppear { visible = true; measure() }
        .onDisappear { visible = false; updateMotion() }
        .onChange(of: text) { _, _ in measure() }
        .onChange(of: size) { _, _ in measure() }
        .onChange(of: running) { _, _ in updateMotion() }
    }
    private func measure() {
        let font = UIFont(name: "LXGWWenKai-Regular", size: size) ?? .systemFont(ofSize: size)
        measured = CGSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width), height: ceil(font.lineHeight))
        reset()
    }
    private func reset() {
        elapsed = 0
        started = running ? Date() : nil
    }
    private func updateMotion() {
        let now = Date()
        elapsed = time(at: now)
        started = running ? now : nil
    }
}

/// Only the small artwork redraws while playing; no timer publishes into the feed.
private struct CreationRotatingCover: View {
    let path: String?
    let site: URL
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var angle: Double = 0
    @State private var started: Date?
    private var running: Bool { playing && visible && scenePhase == .active && !reduceMotion }
    private func rotation(at date: Date) -> Double { angle + (started.map { date.timeIntervalSince($0) * 30 } ?? 0) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
            CreationRemoteImage(path: path, site: site)
                .clipShape(Circle()).rotationEffect(.degrees(rotation(at: context.date)))
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
        }.onAppear { visible = true; updateMotion() }
            .onDisappear { visible = false; updateMotion() }
            .onChange(of: running) { _, _ in updateMotion() }
    }
    private func updateMotion() {
        let now = Date()
        angle = rotation(at: now).truncatingRemainder(dividingBy: 360)
        started = running ? now : nil
    }
}

extension View {
    func creationMiniPlayer(api: AdminAPIClient, visible: Bool = true) -> some View { modifier(CreationMiniPlayerModifier(api: api, visible: visible)) }
}
