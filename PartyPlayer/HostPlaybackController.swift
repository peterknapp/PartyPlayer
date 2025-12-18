import Foundation
import Combine
import MusicKit

@MainActor
final class HostPlaybackController: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isPlaying = false

    private let player = SystemMusicPlayer.shared
    private var tickTask: Task<Void, Never>?

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        isAuthorized = (status == .authorized)
        DebugLog.shared.add("MUSIC", "authorization status=\(status)")
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
        player.queue = MusicPlayer.Queue(for: songs)
        DebugLog.shared.add("MUSIC", "queue set: \(songs.count) songs")
    }

    // MARK: - Search helper (needed by PartyHostController.loadDemoAndPlay)

    /// Sucht pro Term genau 1 Song und gibt dessen Catalog-Song-ID als String zurück.
    /// Beispiel-Term: "Daft Punk One More Time"
    func searchCatalogSongIDs(for terms: [String]) async throws -> [String] {
        var result: [String] = []
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

            // Song.id ist MusicItemID -> String extrahieren
            let idString = song.id.rawValue

            DebugLog.shared.add("MUSIC", "found '\(song.title)' – '\(song.artistName)' id=\(idString)")
            result.append(idString)
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

    // MARK: - Queue

    /// catalogSongIDs = Apple Music Song IDs als String, z.B. "203709340"
    func setQueue(withCatalogSongIDs catalogSongIDs: [String]) async throws {
        guard !catalogSongIDs.isEmpty else { return }

        let ids = catalogSongIDs.map { MusicItemID($0) }

        let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids)
        let response = try await request.response()
        let songs = Array(response.items)

        guard !songs.isEmpty else {
            throw NSError(domain: "HostPlaybackController", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Keine Songs zu den IDs gefunden."
            ])
        }

        player.queue = MusicPlayer.Queue(for: songs)
        DebugLog.shared.add("MUSIC", "queue set: \(songs.count) songs")
    }

    // MARK: - Playback

    func play() async throws {
        DebugLog.shared.add("MUSIC", "play()")
        try await player.play()
        isPlaying = true
    }

    func pause() {
        DebugLog.shared.add("MUSIC", "pause()")
        player.pause()
        isPlaying = false
    }

    func skipToNext() async throws {
        DebugLog.shared.add("MUSIC", "skipToNextEntry()")
        try await player.skipToNextEntry()
    }

    // MARK: - Polling (simple + robust)

    func startTick(
        every seconds: Double = 1.0,
        onTick: @escaping (_ isPlaying: Bool, _ position: Double) -> Void
    ) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let pos = self.player.playbackTime
                let playing = (self.player.state.playbackStatus == .playing)
                await MainActor.run { self.isPlaying = playing }
                onTick(playing, pos)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }
}
