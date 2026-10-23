import SwiftUI
import AVFoundation
import MediaPlayer

/// Keep potentially blocking audio-session activation off the UI actor.
private actor CreationAudioSession {
    static let shared = CreationAudioSession()
    private var owner: UUID?
    func activate(_ token: UUID) throws {
        try Task.checkCancellation()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        owner = token
    }
    func deactivate(_ token: UUID) {
        guard owner == token else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        owner = nil
    }
}

extension CreationMusic {
    var playbackKey: String { marker.map { "\($0.type):\($0.id)" } ?? spec }
    init(track: AdminMusicTrack) {
        self.init(spec: MarkdownParser.makeMusicSpec(id: track.mid, type: "song", title: track.name, artist: track.artist, cover: track.cover))
    }
}

enum CreationPlaybackMode: String, CaseIterable {
    case ordered = "顺序播放", shuffle = "随机播放", repeatOne = "单曲循环"
    var symbol: String { switch self { case .ordered: "list.bullet"; case .shuffle: "shuffle"; case .repeatOne: "repeat.1" } }
}

/// Queue navigation is independent of audio/network state and can be tested deterministically.
struct CreationPlaybackQueue {
    var items: [CreationMusic] = []
    var index = 0
    var mode: CreationPlaybackMode = .ordered { didSet { remaining = []; history = [] } }
    private var remaining: [Int] = []
    private var history: [Int] = []
    var current: CreationMusic? { items.indices.contains(index) ? items[index] : nil }
    mutating func set(_ songs: [CreationMusic], selected: CreationMusic) {
        var seen = Set<String>()
        items = songs.filter { seen.insert($0.playbackKey).inserted }
        if !items.contains(where: { $0.playbackKey == selected.playbackKey }) { items.append(selected) }
        index = items.firstIndex { $0.playbackKey == selected.playbackKey } ?? 0
        remaining = []; history = []
    }
    mutating func advance(automatic: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        if automatic && mode == .repeatOne { return true }
        if mode == .shuffle {
            if remaining.isEmpty { remaining = items.indices.filter { $0 != index }.shuffled() }
            history.append(index)
            if let next = remaining.popLast() { index = next }
            return true
        }
        guard index + 1 < items.count else {
            if automatic { return false }
            index = 0; return true
        }
        index += 1; return true
    }
    mutating func previous() {
        guard !items.isEmpty else { return }
        if mode == .shuffle, let last = history.popLast() { remaining.append(index); index = last }
        else { index = max(0, index - 1) }
    }
}

@MainActor
final class CreationAudioPlayer: ObservableObject {
    static let shared = CreationAudioPlayer()
    static let audition = CreationAudioPlayer(isAudition: true)
    @Published private(set) var queue = CreationPlaybackQueue()
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var message: String?
    @Published private(set) var messageID: String?
    var current: CreationMusic? { queue.current }
    var playingID: String? { (isPlaying || isLoading) ? current?.spec : nil }
    var mode: CreationPlaybackMode {
        get { queue.mode }
        set { queue.mode = newValue }
    }
    private let isAudition: Bool
    private var api: AdminAPIClient?
    private var player: AVPlayer?
    private var task: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var generation = UUID()
    private var periodicObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var statusObservation: NSKeyValueObservation?
    private var resumeAfterInterruption = false
    private var auditionWasPlaying = false
    private var auditionKey: String?
    private var playlistID: String?
    private var nextOffset: Int?
    private var sessionToken: UUID?

    init(isAudition: Bool = false) {
        self.isAudition = isAudition
        observeSystemAudio()
    }
    isolated deinit {
        task?.cancel(); artworkTask?.cancel()
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        (itemObservers + systemObservers).forEach { NotificationCenter.default.removeObserver($0) }
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }

    private func releaseItem() {
        generation = UUID(); task?.cancel(); task = nil
        artworkTask?.cancel(); artworkTask = nil; artwork = nil
        player?.pause()
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        periodicObserver = nil; player = nil; statusObservation = nil
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }; itemObservers = []
        isLoading = false; isPlaying = false; elapsed = 0; duration = 0
    }

    func stop() {
        releaseItem(); queue = CreationPlaybackQueue(); message = nil; messageID = nil
        playlistID = nil; nextOffset = nil
        auditionWasPlaying = false; auditionKey = nil; resumeAfterInterruption = false
        if let token = sessionToken { Task { await CreationAudioSession.shared.deactivate(token) } }
        sessionToken = nil
        if !isAudition {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            remoteTargets.forEach { $0.0.removeTarget($0.1) }; remoteTargets = []
        }
    }

    static func stopAll() { audition.stop(); shared.stop() }

    func suspendForAudition() {
        auditionWasPlaying = isPlaying || isLoading
        auditionKey = current?.playbackKey
        pause()
    }
    func restoreAfterAudition() {
        let resume = auditionWasPlaying && auditionKey == current?.playbackKey
        auditionWasPlaying = false; auditionKey = nil
        if resume { resumePlayback() }
        else { updateNowPlaying() }
    }

    func preview(_ music: CreationMusic, api: AdminAPIClient) { play(music, in: [music], api: api) }

    func play(_ music: CreationMusic, in songs: [CreationMusic], api: AdminAPIClient, playlistID: String? = nil, nextOffset: Int? = nil) {
        if self.api?.siteRoot == api.siteRoot, current?.playbackKey == music.playbackKey {
            toggle(); return
        }
        self.api = api
        self.playlistID = playlistID; self.nextOffset = nextOffset
        queue.set(songs, selected: music)
        loadCurrent()
    }

    func selectQueueItem(_ music: CreationMusic) {
        guard let api else { return }
        play(music, in: queue.items, api: api, playlistID: playlistID, nextOffset: nextOffset)
    }

    func pause() {
        player?.pause(); isPlaying = false
        task?.cancel()
        if isLoading && player == nil { generation = UUID(); task?.cancel(); task = nil }
        isLoading = false
        updateNowPlaying()
    }
    func toggle() { if isPlaying || isLoading { pause() } else { resumePlayback() } }
    func resumePlayback() {
        guard current != nil else { return }
        if player != nil && message == nil {
            let token = generation
            let activationToken = UUID()
            task?.cancel()
            isLoading = true
            task = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    try await CreationAudioSession.shared.activate(activationToken)
                    guard let self, self.generation == token, !Task.isCancelled else {
                        await CreationAudioSession.shared.deactivate(activationToken); return
                    }
                    self.sessionToken = activationToken; self.isLoading = false
                    if self.duration > 0 && self.elapsed >= self.duration - 0.25 { self.seek(to: 0) }
                    self.isPlaying = true; self.player?.play(); self.updateNowPlaying()
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.fail(error.localizedDescription)
                }
            }
        } else { loadCurrent() }
    }
    func next(automatic: Bool = false) {
        if queue.index == queue.items.count - 1, let playlistID, let offset = nextOffset, let api,
           !(automatic && queue.mode == .repeatOne) {
            releaseItem(); isLoading = true; message = nil
            let token = generation
            task = Task { [weak self] in
                do {
                    let page = try await api.fetchQQMusicPlaylistMetadata(id: playlistID, offset: offset)
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    var known = Set(self.queue.items.map(\.playbackKey))
                    let added = page.tracks.filter { !$0.mid.isEmpty }.map(CreationMusic.init(track:)).filter { known.insert($0.playbackKey).inserted }
                    guard !added.isEmpty else { self.nextOffset = nil; self.fail("网站没有返回更多歌曲，请重新打开歌单刷新。"); return }
                    self.queue.items += added
                    self.nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                    self.isLoading = false
                    if self.queue.advance(automatic: automatic) { self.loadCurrent() }
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.fail("下一页歌曲加载失败，请再次点击下一首。")
                }
            }
            return
        }
        guard queue.advance(automatic: automatic) else { pause(); return }
        loadCurrent()
    }
    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        queue.previous(); loadCurrent()
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0, player != nil else { return }
        elapsed = min(duration, max(0, seconds))
        player?.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    private func loadCurrent() {
        releaseItem(); message = nil
        guard let music = current, let marker = music.marker, let api else { return }
        let token = generation
        messageID = music.spec; isLoading = true
        if !isAudition { installRemoteCommands(); updateNowPlaying() }
        task = Task { [weak self] in
            do {
                if marker.type == "playlist" {
                    let response = try await api.fetchQQMusicPlaylistMetadata(id: marker.id)
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    let songs = response.tracks.filter { !$0.mid.isEmpty }.map(CreationMusic.init(track:))
                    guard let first = marker.shuffle ? songs.randomElement() : songs.first else { self.fail("歌单暂未返回歌曲，请稍后重试。"); return }
                    self.queue.set(songs, selected: first)
                    self.queue.mode = marker.shuffle ? .shuffle : .ordered
                    self.playlistID = marker.id; self.nextOffset = response.nextOffset
                    self.loadCurrent(); return
                }
                let track = try await api.fetchQQMusicTrack(id: marker.id)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                guard let url = CreationPreview.musicPlaybackURL ?? CreationPlaybackURL.resolve(track: track, expectedMID: marker.id, siteRoot: api.siteRoot) else {
                    self.reportFailure("这首歌暂时没有可用的播放地址。请重试或选择其他歌曲。", api: api, checkService: true); return
                }
                self.queue.items[self.queue.index] = CreationMusic(spec: MarkdownParser.makeMusicSpec(id: marker.id, type: "song", title: track.name.trimmedNonEmpty ?? marker.title, artist: track.artist.trimmedNonEmpty ?? marker.artist, cover: track.cover.trimmedNonEmpty ?? marker.cover))
                self.messageID = self.current?.spec
                try await CreationAudioSession.shared.activate(token)
                guard self.generation == token, !Task.isCancelled else { await CreationAudioSession.shared.deactivate(token); return }
                self.sessionToken = token
                let item = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: item)
                self.player = player
                self.itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if self.isAudition { self.pause(); self.seek(to: 0) }
                        else { self.next(automatic: true) }
                    }
                })
                self.itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in guard let self, self.generation == token else { return }; self.fail("播放中断，请重试。") }
                })
                self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    let seconds = item.duration.seconds
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if status == .readyToPlay {
                            self.isLoading = false
                            self.duration = seconds.isFinite ? max(0, seconds) : 0
                            self.updateNowPlaying()
                        } else if status == .failed { self.fail("音频无法播放，请重试。") }
                    }
                }
                self.periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
                    let seconds = time.seconds
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.elapsed = seconds.isFinite ? max(0, seconds) : 0
                        let length = self.player?.currentItem?.duration.seconds ?? 0
                        self.duration = length.isFinite ? max(0, length) : 0
                        self.updateNowPlaying()
                    }
                }
                self.isPlaying = true; player.play(); self.updateNowPlaying()
                self.loadArtwork(track.cover, site: api.siteRoot, token: token)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if isRequestCancellation(error) { self.releaseItem(); return }
                let checkService: Bool
                if case APIError.http(let status, _) = error { checkService = [502, 503, 504].contains(status) } else { checkService = false }
                self.reportFailure(error.localizedDescription, api: api, checkService: checkService)
            }
        }
    }

    private func fail(_ text: String) {
        releaseItem(); message = text; messageID = current?.spec; updateNowPlaying()
    }
    private func reportFailure(_ text: String, api: AdminAPIClient, checkService: Bool) {
        fail(text)
        guard checkService else { return }
        let token = generation
        task = Task { [weak self] in
            guard let status = try? await api.fetchQQMusicStatus(), let self,
                  self.generation == token, !Task.isCancelled, let warning = status.playbackWarning else { return }
            self.message = "\(text)\n\(warning)"
        }
    }
    private func loadArtwork(_ path: String, site: URL, token: UUID) {
        guard !isAudition, !path.isEmpty, let url = URL(string: path, relativeTo: site)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        artworkTask = Task { [weak self] in
            guard let cg = try? await ImageLoader.shared.image(for: url, maxPixelSize: 384), !Task.isCancelled,
                  let self, self.generation == token else { return }
            let image = UIImage(cgImage: cg)
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
    }
    private func updateNowPlaying() {
        guard !isAudition, let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: duration]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func installRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor () -> Void)] = [
            (center.playCommand, { [weak self] in self?.resumePlayback() }),
            (center.pauseCommand, { [weak self] in self?.pause() }),
            (center.togglePlayPauseCommand, { [weak self] in self?.toggle() }),
            (center.nextTrackCommand, { [weak self] in self?.next() }),
            (center.previousTrackCommand, { [weak self] in self?.previous() })]
        for (command, action) in actions {
            command.isEnabled = true
            remoteTargets.append((command, command.addTarget { _ in Task { @MainActor in action() }; return .success }))
        }
        center.changePlaybackPositionCommand.isEnabled = true
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.seek(to: seconds) }; return .success
        }))
    }
    private func observeSystemAudio() {
        systemObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.resumeAfterInterruption = self.isPlaying || self.isLoading; self.pause() }
                else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    let resume = self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.resumeAfterInterruption = false
                    if resume { self.resumePlayback() }
                }
            }
        })
        systemObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
    }
}
