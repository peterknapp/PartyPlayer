import Foundation
import Combine
import MusicKit
import MediaPlayer

@MainActor
final class HostPlaybackController: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentArtworkURL: URL?

    private var tickTask: Task<Void, Never>?

    private let systemPlayer = SystemMusicPlayer.shared
    private let appPlayer = ApplicationMusicPlayer.shared

    // Remote command & Now Playing metadata
    private var remoteCommandsSetup = false
    private var nowPlayingTitle: String? = nil
    private var nowPlayingArtist: String? = nil
    private var nowPlayingDuration: TimeInterval? = nil

    private var isRunningOnMac: Bool {
        #if os(macOS)
        return true
        #else
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return true }
            if ProcessInfo.processInfo.isMacCatalystApp { return true }
        }
        return false
        #endif
    }

    private var playbackStatus: MusicKit.MusicPlayer.PlaybackStatus {
        isRunningOnMac ? appPlayer.state.playbackStatus : systemPlayer.state.playbackStatus
    }

    private var playbackTime: TimeInterval {
        isRunningOnMac ? appPlayer.playbackTime : systemPlayer.playbackTime
    }

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        isAuthorized = (status == .authorized)
        DebugLog.shared.add("MUSIC", "authorization status=\(status)")
        DebugLog.shared.add("MUSIC", "authorization currentStatus=\(MusicAuthorization.currentStatus)")
    }

    func searchCatalogSongs(for terms: [String]) async throws -> [Song] {
        var result: [Song] = []
        result.reserveCapacity(terms.count)

        for term in terms {
            DebugLog.shared.add("MUSIC", "search term='\(term)'")

            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 1

            let response = try await request.response()

            guard let song = response.songs.first else {
                DebugLog.shared.add("MUSIC", "no result for '\(term)'")
                continue
            }

            DebugLog.shared.add("MUSIC", "found '\(song.title)' – '\(song.artistName)' id=\(song.id.rawValue)")
            result.append(song)
        }

        if result.isEmpty {
            throw NSError(
                domain: "HostPlaybackController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Keine Songs gefunden (Suche leer)."]
            )
        }

        return result
    }

    /// Queue direkt aus Songs setzen (Songs sind PlayableMusicItem)
    func setQueue(withSongs songs: [Song]) async throws {
        guard !songs.isEmpty else { return }
        if isRunningOnMac {
            appPlayer.queue = ApplicationMusicPlayer.Queue(for: songs)
        } else {
            systemPlayer.queue = MusicKit.MusicPlayer.Queue(for: songs)
        }
        try await prepareActivePlayerToPlay()
        updateArtwork(from: songs)
        self.updateNowPlayingInfo(position: self.playbackTime, isPlaying: self.isPlaying)
        DebugLog.shared.add("MUSIC", "queue set: \(songs.count) songs")
        diagnoseEnvironment()
    }

    /// Setzt das Artwork anhand der ersten Song-Artwork-URL (Fallback für initiale Anzeige im Public Tab)
    private func updateArtwork(from songs: [Song]) {
        guard let first = songs.first, let artwork = first.artwork else { return }
        // Wähle eine mittlere Größe, damit es zügig lädt
        if let url = artwork.url(width: 600, height: 600) {
            self.currentArtworkURL = url
            DebugLog.shared.add("MUSIC", "artwork preset from first song: \(url.absoluteString)")
            self.nowPlayingTitle = first.title
            self.nowPlayingArtist = first.artistName
            self.nowPlayingDuration = first.duration
            self.updateNowPlayingInfo(position: self.playbackTime, isPlaying: self.isPlaying)
        }
    }

    /// Bereitet den aktiven Player nach dem Setzen der Queue vor, damit der erste Eintrag korrekt als Now Playing initialisiert ist.
    private func prepareActivePlayerToPlay() async throws {
        if isRunningOnMac {
            try await appPlayer.prepareToPlay()
        } else {
            try await systemPlayer.prepareToPlay()
        }
        diagnoseEnvironment(prefix: "MUSIC-PREPARE")
    }

    func diagnoseEnvironment(prefix: String = "MUSIC") {
        let status = MusicAuthorization.currentStatus
        let playbackStatus = self.playbackStatus
        let time = self.playbackTime
        DebugLog.shared.add(prefix, "diag authStatus=\(status) playbackStatus=\(playbackStatus) time=\(time)")
    }

    // Expose current playback time for state restoration during queue rebuilds
    var currentTime: TimeInterval { playbackTime }
    
    // Expose current song ID from the active player's queue (if available)
    var currentSongID: String? {
        if isRunningOnMac {
            if let song = appPlayer.queue.currentEntry?.item as? Song {
                return song.id.rawValue
            }
        } else {
            if let song = systemPlayer.queue.currentEntry?.item as? Song {
                return song.id.rawValue
            }
        }
        return nil
    }

    // Seek to a specific playback position on the active player
    func seek(to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        if isRunningOnMac {
            appPlayer.playbackTime = clamped
        } else {
            systemPlayer.playbackTime = clamped
        }
        DebugLog.shared.add("MUSIC", String(format: "seek(to: %.2f)", clamped))
        self.updateNowPlayingInfo(position: clamped, isPlaying: self.isPlaying)
    }

    // MARK: - Queue

    /// catalogSongIDs = Apple Music Song IDs als String, z.B. "203709340"
    func setQueue(withCatalogSongIDs catalogSongIDs: [String]) async throws {
        guard !catalogSongIDs.isEmpty else { return }

        let ids = catalogSongIDs.map { MusicItemID($0) }

        let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids)
        let response = try await request.response()

        // Map fetched songs by ID and preserve the original order of requested IDs
        let fetchedSongs = Array(response.items)
        let songByID: [MusicItemID: Song] = Dictionary(uniqueKeysWithValues: fetchedSongs.map { ($0.id, $0) })
        let songs = ids.compactMap { songByID[$0] }

        guard !songs.isEmpty else {
            throw NSError(domain: "HostPlaybackController", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Keine Songs zu den IDs gefunden."
            ])
        }

        if isRunningOnMac {
            appPlayer.queue = ApplicationMusicPlayer.Queue(for: songs)
        } else {
            systemPlayer.queue = MusicKit.MusicPlayer.Queue(for: songs)
        }
        try await prepareActivePlayerToPlay()
        updateArtwork(from: songs)
        self.nowPlayingTitle = songs.first?.title
        self.nowPlayingArtist = songs.first?.artistName
        self.nowPlayingDuration = songs.first?.duration
        self.updateNowPlayingInfo(position: self.playbackTime, isPlaying: self.isPlaying)
        DebugLog.shared.add("MUSIC", "queue set: \(songs.count) songs")
    }

    // MARK: - Playback

    func play() async throws {
        DebugLog.shared.add("MUSIC", "play() auth=\(MusicAuthorization.currentStatus) isAuthorized=\(isAuthorized)")
        guard isAuthorized else {
            throw NSError(
                domain: "HostPlaybackController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Music-Autorisierung fehlt. Bitte in der Musik-App anmelden und Zugriff erlauben."]
            )
        }
        if isRunningOnMac {
            try await appPlayer.play()
        } else {
            try await systemPlayer.play()
        }
        isPlaying = true
        self.updateNowPlayingInfo(position: self.playbackTime, isPlaying: true)
    }

    func pause() {
        DebugLog.shared.add("MUSIC", "pause()")
        if isRunningOnMac {
            appPlayer.pause()
        } else {
            systemPlayer.pause()
        }
        isPlaying = false
        self.updateNowPlayingInfo(position: self.playbackTime, isPlaying: false)
    }

    func skipToNext() async throws {
        DebugLog.shared.add("MUSIC", "skipToNextEntry()")
        if isRunningOnMac {
            try await appPlayer.skipToNextEntry()
        } else {
            try await systemPlayer.skipToNextEntry()
        }
        diagnoseEnvironment()
    }

    func setupRemoteCommands() {
        guard !remoteCommandsSetup else { return }
        remoteCommandsSetup = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { try? await self.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { try? await self.skipToNext() }
            return .success
        }
    }

    // MARK: - Polling (simple + robust)

    func startTick(
        every seconds: Double = 1.0,
        onTick: @escaping (_ isPlaying: Bool, _ position: Double, _ currentSongID: String?) -> Void
    ) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let pos = self.playbackTime
                let playing = (self.playbackStatus == .playing)
                // Determine current song ID from active player's queue currentEntry
                let currentSongID: String? = {
                    if self.isRunningOnMac {
                        if let song = self.appPlayer.queue.currentEntry?.item as? Song {
                            return song.id.rawValue
                        }
                    } else {
                        if let song = self.systemPlayer.queue.currentEntry?.item as? Song {
                            return song.id.rawValue
                        }
                    }
                    return nil
                }()
                await MainActor.run { self.isPlaying = playing }
                onTick(playing, pos, currentSongID)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func updateNowPlayingInfo(position: Double? = nil, isPlaying: Bool? = nil) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let title = nowPlayingTitle { info[MPMediaItemPropertyTitle] = title }
        if let artist = nowPlayingArtist { info[MPMediaItemPropertyArtist] = artist }
        if let dur = nowPlayingDuration { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if let pos = position ?? Optional(playbackTime) { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos }
        let playing = isPlaying ?? self.isPlaying
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

