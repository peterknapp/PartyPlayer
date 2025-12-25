import Foundation
import Combine
import CoreLocation
import MultipeerConnectivity
import MusicKit

@MainActor
final class PartyHostController: ObservableObject {
    @Published private(set) var state: PartyState
    @Published var joinCode: String
    @Published private(set) var nowPlaying: PartyMessage.NowPlayingPayload? = nil
    @Published private(set) var pendingSkipRequests: [PendingSkipRequest] = []
    @Published var votingEngineEnabled: Bool = true
    @Published var voteThresholdPercent: Int = 50
    @Published var processDownOutcomes: Bool = true
    @Published var processUpOutcomes: Bool = true
    @Published var processSendToEndOutcomes: Bool = true
    @Published private(set) var removedItems: [QueueItem] = []

    private let mpc: MPCService
    // Concurrent action slots per member (e.g., 3). Each spent when a vote is accepted and restored when the per-item cooldown elapses.
    @Published var maxConcurrentActions: Int = 3
    private var activeActions: [MemberID: Int] = [:]

    private var perItemLimiter = PerItemVoteLimiter()
    @Published var perItemCooldownMinutes: Int = 1 { didSet { perItemLimiter.setCooldown(minutes: perItemCooldownMinutes) } }
    private let locationService: LocationService
    private let playback = HostPlaybackController()
    private let playlist = PlaylistEngine()

    enum VotingMode: String, Codable { case automatic, hostApproval }
    @Published var votingMode: VotingMode = .automatic

    /// Pending outcomes awaiting host approval
    struct PendingVoteOutcome: Identifiable, Equatable {
        enum Kind: Equatable { case promoteNext, removeFromQueue, sendToEnd }
        let id: UUID
        let itemID: UUID
        let kind: Kind
        let threshold: Int
        let createdAt: Date
    }
    @Published private(set) var pendingVoteOutcomes: [PendingVoteOutcome] = []

    private var nowPlayingBroadcastTask: Task<Void, Never>?
    private var isNowPlayingBroadcasting = false
    private var lastPlaybackPosition: Double? = nil
    private var lastManualSkipAt: Date? = nil
    private var lastAutoSkipAt: Date? = nil
    private var blockedSongCounts: [String: Int] = [:]

    private var lastObservedSongID: String? = nil
    private var pendingSkipNextSongID: String? = nil
    private var lastBoundaryAt: Date? = nil
    private var didAutoAdvanceForCurrentItem: Bool = false

    // MARK: - Debug logging

    private func logCurrentPlaylist(_ reason: String) {
        let nowID = state.nowPlayingItemID
        var lines: [String] = []
        lines.append("reason=\(reason) count=\(state.queue.count)")
        for (i, item) in state.queue.enumerated() {
            let mark = (item.id == nowID) ? "▶︎" : " "
            let idShort = String(item.id.uuidString.prefix(6))
            let songShort = String(item.songID.prefix(8))
            lines.append("\(i). \(mark) \(item.title) – \(item.artist) [\(idShort)] (\(songShort)) up:\(item.upVotes.count) down:\(item.downVotes.count)")
        }
        DebugLog.shared.add("QUEUE", lines.joined(separator: "\n"))
    }

    private func logUpcomingExpected(_ reason: String, limit: Int = 3) {
        guard let nowID = state.nowPlayingItemID,
              let nowIdx = state.queue.firstIndex(where: { $0.id == nowID }) else {
            let startSummary = state.queue.prefix(limit).map { "\($0.title) (\($0.songID))" }.joined(separator: ", ")
            DebugLog.shared.add("QUEUE-NEXT", "reason=\(reason) no nowPlaying; upcoming from start: \(startSummary)")
            return
        }
        let start = nowIdx + 1
        let slice = state.queue.indices.contains(start) ? Array(state.queue[start...].prefix(limit)) : []
        let summary = slice.enumerated().map { off, item in
            let idx = start + off
            return "#\(idx)=\(item.title) (\(item.songID))"
        }.joined(separator: ", ")
        DebugLog.shared.add("QUEUE-NEXT", "reason=\(reason) nowIdx=\(nowIdx) upcoming(\(min(limit, slice.count))): \(summary)")
    }

    private var peerToMember: [MCPeerID: MemberID] = [:]
    private let hostMemberID: MemberID = DeviceIdentity.memberID()

    // Pro Item: pro Member genau 1 Entscheidung (bis Item entfernt wird)
    private var memberDecisions: [UUID: [MemberID: PartyMessage.VoteDirection]] = [:]
    private var lastMemberItemVoteAt: [MemberID: [UUID: Date]] = [:]

    // Helper to check played tracks (index < nowPlaying index)
    private func isPlayed(itemID: UUID) -> Bool {
        guard let nowID = state.nowPlayingItemID,
              let nowIdx = state.queue.firstIndex(where: { $0.id == nowID }),
              let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return false }
        return idx < nowIdx
    }

    // Helpers for concurrent action slots
    private func remainingSlots(for member: MemberID) -> Int {
        let used = activeActions[member] ?? 0
        return max(0, maxConcurrentActions - used)
    }

    private func trySpendSlot(for member: MemberID) -> Bool {
        let used = activeActions[member] ?? 0
        guard used < maxConcurrentActions else { return false }
        activeActions[member] = used + 1
        return true
    }

    private func restoreSlot(for member: MemberID) {
        let used = activeActions[member] ?? 0
        activeActions[member] = max(0, used - 1)
    }

    init(hostName: String, locationService: LocationService) {
        self.locationService = locationService
        self.state = PartyState(
            sessionID: String(UUID().uuidString.prefix(6)).uppercased(),
            hostName: hostName,
            createdAt: Date()
        )
        self.joinCode = String(UUID().uuidString.prefix(6)).uppercased()

        self.mpc = MPCService(displayName: "HOST-\(hostName)")
        self.mpc.onData = { [weak self] data, peer in
            Task { await self?.handleIncoming(data: data, from: peer) }
        }
        // Ensure initial cooldown is applied
        self.perItemLimiter.setCooldown(minutes: self.perItemCooldownMinutes)
    }

    // MARK: - Skip approval UI

    struct PendingSkipRequest: Identifiable, Equatable {
        let id: UUID
        let itemID: UUID
        let memberID: MemberID
        let requestedAt: Date
    }

    func startHosting() {
        DebugLog.shared.add("HOST", "startHosting sessionID=\(state.sessionID)")
        // Ensure host-side location is active for distance checks
        locationService.requestWhenInUse()
        locationService.start()
        mpc.startHosting(discoveryInfo: ["sessionID": state.sessionID])
        startNowPlayingBroadcast()
    }

    // MARK: - Location helpers

    private func awaitHostLocation(maxSeconds: Double = 6.0) async -> CLLocation? {
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            let auth = locationService.authorizationStatus
            if auth == .denied || auth == .restricted { return nil }
            if let loc = locationService.lastLocation { return loc }
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        }
        return locationService.lastLocation
    }

    // MARK: - Incoming

    func startParty(withInitialQueue items: [QueueItem]) {
        DebugLog.shared.add("REWRITE", "startParty called - playlist population logic temporarily disabled")
        state.queue = []
        broadcastSnapshot()
    }

    func approveSkip(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "approveSkip called - skip/removal logic temporarily disabled")
    }

    func startNowPlayingBroadcast() {
        // Prevent duplicate initialization
        if isNowPlayingBroadcasting { return }
        isNowPlayingBroadcasting = true

        playback.startTick(every: 1.0) { [weak self] playing, pos, currentSongID in
            guard let self else { return }
            // Respect cancellation
            guard self.isNowPlayingBroadcasting else { return }

            Task { @MainActor in
                // Auto-advance when current song reaches (almost) its end
                if let currentID = self.state.nowPlayingItemID,
                   let item = self.state.queue.first(where: { $0.id == currentID }),
                   let duration = item.durationSeconds, duration > 0 {
                    let nearEndPlaying = playing && pos >= max(0, duration - 0.75)
                    let endedWhileNotPlaying = !playing && pos >= max(0, duration - 0.2)
                    if (nearEndPlaying || endedWhileNotPlaying) && !self.didAutoAdvanceForCurrentItem {
                        DebugLog.shared.add("ENGINE", "auto-advance triggered for item=\(item.title) pos=\(pos) dur=\(duration)")
                        self.didAutoAdvanceForCurrentItem = true
                        self.advanceToNextAndPlay()
                    }
                }

                let payload = PartyMessage.NowPlayingPayload(
                    nowPlayingItemID: self.state.nowPlayingItemID,
                    isPlaying: playing,
                    positionSeconds: pos,
                    sentAt: Date()
                )
                self.nowPlaying = payload
                await self.send(.nowPlaying(payload))
            }
        }
    }

    func stopNowPlayingBroadcast() {
        // Mark as stopped; callbacks will be ignored
        isNowPlayingBroadcasting = false
        // If we ever attach a Task-based ticker, cancel here
        nowPlayingBroadcastTask?.cancel()
        nowPlayingBroadcastTask = nil
    }

    private func advanceToNextAndPlay() {
        Task { @MainActor in
            if let next = await playlist.next() {
                state.nowPlayingItemID = next.id
                do {
                    try await playback.setQueue(withCatalogSongIDs: [next.songID])
                    try await playback.play()
                } catch {
                    DebugLog.shared.add("HOST", "advanceToNextAndPlay failed: \(error.localizedDescription)")
                }
                didAutoAdvanceForCurrentItem = false
                broadcastSnapshot()
            } else {
                // End of playlist
                state.nowPlayingItemID = nil
                broadcastSnapshot()
            }
        }
    }

    func loadDemoAndPlay() {
        Task {
            // Ensure MusicKit authorization before proceeding
            await self.playback.requestAuthorization()
            guard self.playback.isAuthorized else {
                DebugLog.shared.add("MUSIC", "authorization denied or not available; aborting demo load")
                return
            }
            do {
                let terms = [
                    "Liam Lynch United States of Whatever",
                    "Daft Punk One More Time",
                    "The Weeknd Blinding Lights",
                    "Ed Sheeran Shape of You",
                    "Kraftklub Unsterblich sein",
                    "Tame Impala The Less I Know The Better",
                    "Rosalia Divinize"
                ]

                let songs = try await playback.searchCatalogSongs(for: terms)

                let now = Date()
                let items: [QueueItem] = songs.map { song in
                    let urlString = song.artwork?.url(width: 256, height: 256)?.absoluteString
                    return QueueItem(
                        id: UUID(),
                        songID: song.id.rawValue,
                        title: song.title,
                        artist: song.artistName,
                        artworkURL: urlString,
                        durationSeconds: song.duration,
                        addedBy: hostMemberID,
                        addedAt: now,
                        upVotes: [],
                        downVotes: []
                    )
                }

                // Load into playlist engine and set state snapshot
                await playlist.loadInitial(items)
                let snapshot = await playlist.itemsSnapshot()
                state.queue = snapshot
                state.nowPlayingItemID = snapshot.first?.id

                // Prepare player queue for first song (do not auto-play)
                if let first = await playlist.current() {
                    do {
                        try await playback.setQueue(withCatalogSongIDs: [first.songID])
                    } catch {
                        DebugLog.shared.add("HOST", "prepare player after demo load failed: \(error.localizedDescription)")
                    }
                    didAutoAdvanceForCurrentItem = false
                }

                if !isNowPlayingBroadcasting { startNowPlayingBroadcast() }

                DebugLog.shared.add("HOST", "demo queue loaded via PlaylistEngine + playing first")
                broadcastSnapshot()
            } catch {
                DebugLog.shared.add("HOST", "demo failed: \(error.localizedDescription)")
                DebugLog.shared.add("MUSIC", "post-failure authStatus=\(MusicAuthorization.currentStatus)")
            }
        }
    }

    // MARK: - Admin: Search & Append Songs

    /// Search Apple Music catalog for songs matching a term (dynamic search for admin UI)
    func searchCatalogSongs(term: String, limit: Int = 25) async throws -> [Song] {
        // Ensure MusicKit authorization
        await self.playback.requestAuthorization()
        guard self.playback.isAuthorized else {
            throw NSError(
                domain: "PartyHostController",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Music-Autorisierung fehlt. Bitte in der Musik-App anmelden und Zugriff erlauben."]
            )
        }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = max(1, min(limit, 50))
        let response = try await request.response()
        return Array(response.songs)
    }

    /// Append selected catalog songs to the logical playlist (end of queue). If the queue was empty, set the first as current and prepare the player queue.
    func adminAppendSongs(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        Task { @MainActor in
            let now = Date()
            let items: [QueueItem] = songs.map { song in
                let urlString = song.artwork?.url(width: 256, height: 256)?.absoluteString
                return QueueItem(
                    id: UUID(),
                    songID: song.id.rawValue,
                    title: song.title,
                    artist: song.artistName,
                    artworkURL: urlString,
                    durationSeconds: song.duration,
                    addedBy: self.hostMemberID,
                    addedAt: now,
                    upVotes: [],
                    downVotes: []
                )
            }

            // Append each item to the engine
            for item in items { await self.playlist.appendItem(item) }

            // Mirror engine state back to controller state
            let snapshot = await self.playlist.itemsSnapshot()
            self.state.queue = snapshot

            // If nothing was current, set current and prepare the player queue (do not auto-play)
            if self.state.nowPlayingItemID == nil, let current = await self.playlist.current() {
                self.state.nowPlayingItemID = current.id
                do {
                    try await self.playback.setQueue(withCatalogSongIDs: [current.songID])
                } catch {
                    DebugLog.shared.add("HOST", "prepare player after append failed: \(error.localizedDescription)")
                }
            }

            self.broadcastSnapshot()
        }
    }
    
    /// Admin: Reorder upcoming items (UI supplies indices relative to the upcoming slice)
    func adminReorderUpcoming(fromOffsets: IndexSet, toOffset: Int) {
        Task { @MainActor in
            await playlist.reorderUpcoming(fromOffsets: fromOffsets, toOffset: toOffset)
            let snapshot = await playlist.itemsSnapshot()
            self.state.queue = snapshot
            if let current = await playlist.current() {
                self.state.nowPlayingItemID = current.id
            } else {
                self.state.nowPlayingItemID = nil
            }
            self.broadcastSnapshot()
        }
    }

    func togglePlayPause() {
        Task {
            do {
                if playback.isPlaying {
                    playback.pause()
                } else {
                    try await playback.play()
                }
            } catch {
                DebugLog.shared.add("HOST", "play/pause failed: \(error.localizedDescription)")
                self.playback.diagnoseEnvironment(prefix: "MUSIC")
            }
        }
    }

    func skip() {
        Task { @MainActor in
            DebugLog.shared.add("ENGINE", "admin skip -> next from PlaylistEngine")
            self.advanceToNextAndPlay()
        }
    }

    // MARK: - Next-Up helpers

    private func nextUpID() -> UUID? {
        guard let nowID = state.nowPlayingItemID,
              let idx = state.queue.firstIndex(where: { $0.id == nowID }) else { return nil }
        let nextIndex = idx + 1
        guard state.queue.indices.contains(nextIndex) else { return nil }
        return state.queue[nextIndex].id
    }

    private func isNextUp(itemID: UUID) -> Bool {
        return nextUpID() == itemID
    }

    // MARK: - Incoming

    private func handleIncoming(data: Data, from peer: MCPeerID) async {
        do {
            let msg = try PartyCodec.decode(data)
            switch msg {
            case .joinRequest(let req):
                await handleJoinRequest(req, from: peer)
            case .vote(let vote):
                handleVote(vote)
            case .skipRequest(let req):
                handleSkipRequest(req)
            default:
                break
            }
        } catch {
            // ignore malformed
        }
    }

    private func handleJoinRequest(_ req: PartyMessage.JoinRequest, from peer: MCPeerID) async {
        DebugLog.shared.add(
            "HOST",
            "joinRequest from=\(req.displayName) sessionID=\(req.sessionID) joinCode=\(req.joinCode)"
        )

        guard req.sessionID == state.sessionID else {
            await send(.joinDecision(.init(
                accepted: false,
                reason: "Falsche Session.",
                assignedMemberID: req.memberID
            )), to: peer)
            return
        }

        guard req.joinCode == joinCode else {
            await send(.joinDecision(.init(
                accepted: false,
                reason: "Falscher Join-Code.",
                assignedMemberID: req.memberID
            )), to: peer)
            return
        }

        // Location check (wartet robust bis zu 6s)
        let hostLoc = await awaitHostLocation(maxSeconds: 6.0)

        guard let loc = req.location, let finalHostLoc = hostLoc else {
            await send(.joinDecision(.init(
                accepted: false,
                reason: "Location fehlt.",
                assignedMemberID: req.memberID
            )), to: peer)
            return
        }

        let guestLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        let dist = finalHostLoc.distance(from: guestLoc)

        if dist > 65 {
            await send(.joinDecision(.init(
                accepted: false,
                reason: "Zu weit entfernt (\(Int(dist))m).",
                assignedMemberID: req.memberID
            )), to: peer)
            return
        }

        peerToMember[peer] = req.memberID

        if let idx = state.members.firstIndex(where: { $0.id == req.memberID }) {
            DebugLog.shared.add("HOST", "reconnect: \(req.displayName) (no +1)")
            state.members[idx].displayName = req.displayName
            state.members[idx].hasAppleMusic = req.hasAppleMusic
            state.members[idx].isAdmitted = true
            state.members[idx].lastSeen = Date()
        } else {
            DebugLog.shared.add("HOST", "accept new: \(req.displayName) (+1)")
            state.members.append(Member(
                id: req.memberID,
                displayName: req.displayName,
                isAdmitted: true,
                hasAppleMusic: req.hasAppleMusic,
                lastSeen: Date()
            ))
        }

        await sendWhenConnected(
            .joinDecision(.init(
                accepted: true,
                reason: nil,
                assignedMemberID: req.memberID
            )),
            to: peer,
            label: "joinDecision(accept)"
        )

        broadcastSnapshot()
    }

    // MARK: - Voting

    /// Public helper: returns remaining cooldown in seconds for given memberID and itemID, or nil if no cooldown
    func remainingCooldown(memberID: MemberID, itemID: UUID) -> TimeInterval? {
        return perItemLimiter.remainingCooldown(memberID: memberID, itemID: itemID)
    }

    private func handleVote(_ vote: PartyMessage.VoteMessage) {
        Task { @MainActor in
            guard let idx = state.queue.firstIndex(where: { $0.id == vote.itemID }) else { return }

            // Ignore votes on the currently playing item
            if state.nowPlayingItemID == vote.itemID {
                DebugLog.shared.add("VOTE", "ignored: now playing")
                return
            }

            // Spend action slot
            guard trySpendSlot(for: vote.memberID) else {
                DebugLog.shared.add("VOTE", "ignored: no action slots for \(vote.memberID)")
                return
            }

            // Per-item cooldown
            guard perItemLimiter.spend(memberID: vote.memberID, itemID: vote.itemID) else {
                DebugLog.shared.add("VOTE", "ignored: cooldown active for member=\(vote.memberID) item=\(vote.itemID)")
                restoreSlot(for: vote.memberID)
                return
            }

            // Update vote sets (replace previous decision)
            var item = state.queue[idx]
            switch vote.direction {
            case .up:
                item.downVotes.remove(vote.memberID)
                item.upVotes.insert(vote.memberID)
            case .down:
                item.upVotes.remove(vote.memberID)
                item.downVotes.insert(vote.memberID)
            }
            state.queue[idx] = item

            let isNext = {
                guard let nowID = state.nowPlayingItemID,
                      let nowIdx = state.queue.firstIndex(where: { $0.id == nowID }),
                      let itIdx = state.queue.firstIndex(where: { $0.id == vote.itemID }) else { return false }
                return itIdx == nowIdx + 1
            }()
            let played = isPlayed(itemID: vote.itemID)

            // Rules: block UP on next-up
            if vote.direction == .up && isNext {
                DebugLog.shared.add("VOTE", "ignored: UP on next-up item")
                // schedule slot restoration
                let cooldownSeconds = TimeInterval(perItemCooldownMinutes * 60)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(cooldownSeconds * 1_000_000_000))
                    await MainActor.run {
                        self?.restoreSlot(for: vote.memberID)
                        self?.broadcastSnapshot()
                    }
                }
                broadcastSnapshot()
                return
            }

            // Compute threshold
            let guestCount = state.members.filter { $0.isAdmitted }.count
            let threshold = max(1, Int(ceil(Double(guestCount) * Double(voteThresholdPercent) / 100.0)))

            var triggeredOutcome: PendingVoteOutcome.Kind? = nil

            if played {
                // Played items: allow DOWN to send to end
                if vote.direction == .down && item.downVotes.count >= threshold && processSendToEndOutcomes {
                    triggeredOutcome = .sendToEnd
                }
            } else {
                // Upcoming items (not current)
                if item.downVotes.count >= threshold && processDownOutcomes {
                    triggeredOutcome = .removeFromQueue
                } else if vote.direction == .up && item.upVotes.count >= threshold && processUpOutcomes && !isNext {
                    triggeredOutcome = .promoteNext
                }
            }

            if let kind = triggeredOutcome {
                if votingMode == .automatic {
                    await performOutcome(kind, for: vote.itemID)
                } else {
                    enqueuePendingOutcome(itemID: vote.itemID, kind: kind, threshold: threshold)
                }
            }

            // schedule slot restoration after per-item cooldown
            let cooldownSeconds = TimeInterval(perItemCooldownMinutes * 60)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(cooldownSeconds * 1_000_000_000))
                await MainActor.run {
                    self?.restoreSlot(for: vote.memberID)
                    self?.broadcastSnapshot()
                }
            }

            broadcastSnapshot()
        }
    }

    private func applyVoteOutcomeIfNeeded(for itemID: UUID, preferred: PartyMessage.VoteDirection? = nil) {
        DebugLog.shared.add("REWRITE", "applyVoteOutcomeIfNeeded called - disabled")
        return
    }

    private func enqueuePendingOutcome(itemID: UUID, kind: PendingVoteOutcome.Kind, threshold: Int) {
        // Respect per-kind toggles
        switch kind {
        case .promoteNext: guard processUpOutcomes else { return }
        case .removeFromQueue: guard processDownOutcomes else { return }
        case .sendToEnd: guard processSendToEndOutcomes else { return }
        }
        // Avoid duplicates
        if pendingVoteOutcomes.contains(where: { $0.itemID == itemID && $0.kind == kind }) { return }
        pendingVoteOutcomes.insert(
            PendingVoteOutcome(id: UUID(), itemID: itemID, kind: kind, threshold: threshold, createdAt: Date()),
            at: 0
        )
    }

    func approveVoteOutcome(id: UUID) {
        guard let idx = pendingVoteOutcomes.firstIndex(where: { $0.id == id }) else { return }
        let outcome = pendingVoteOutcomes.remove(at: idx)
        Task { @MainActor in
            await performOutcome(outcome.kind, for: outcome.itemID)
            broadcastSnapshot()
        }
    }

    func rejectVoteOutcome(id: UUID) {
        pendingVoteOutcomes.removeAll { $0.id == id }
    }

    private func performOutcome(_ kind: PendingVoteOutcome.Kind, for itemID: UUID) async {
        switch kind {
        case .promoteNext:
            await playlist.moveItemBehindCurrent(withID: itemID)
        case .removeFromQueue:
            let removed = state.queue.first(where: { $0.id == itemID })
            await playlist.removeItem(withID: itemID)
            if let r = removed, !removedItems.contains(where: { $0.id == r.id }) {
                removedItems.insert(r, at: 0)
            }
        case .sendToEnd:
            await playlist.moveItemToEnd(withID: itemID)
        }
        let snapshot = await playlist.itemsSnapshot()
        state.queue = snapshot
        if let current = await playlist.current() {
            state.nowPlayingItemID = current.id
        } else {
            state.nowPlayingItemID = nil
        }
        // Clear votes on the affected item
        if let pIdx = state.queue.firstIndex(where: { $0.id == itemID }) {
            state.queue[pIdx].upVotes = []
            state.queue[pIdx].downVotes = []
        }
    }

    func adminRemoveFromQueue(itemID: UUID) {
        Task { @MainActor in
            // Snapshot of current state before removal
            let wasCurrent = (state.nowPlayingItemID == itemID)

            // Remember item for removedItems list
            let removedItem = state.queue.first(where: { $0.id == itemID })

            // Remove from engine
            await playlist.removeItem(withID: itemID)

            // Mirror back to state
            let snapshot = await playlist.itemsSnapshot()
            state.queue = snapshot

            if let removedItem = removedItem, !removedItems.contains(where: { $0.id == removedItem.id }) {
                removedItems.insert(removedItem, at: 0)
            }

            if wasCurrent {
                // If current was removed, advance and play next
                if let next = await playlist.current() {
                    state.nowPlayingItemID = next.id
                    do {
                        try await playback.setQueue(withCatalogSongIDs: [next.songID])
                        try await playback.play()
                    } catch {
                        DebugLog.shared.add("HOST", "adminRemove current -> play failed: \(error.localizedDescription)")
                    }
                    didAutoAdvanceForCurrentItem = false
                } else {
                    // Playlist empty
                    state.nowPlayingItemID = nil
                }
            } else {
                // Keep nowPlayingItemID if still in list
                if let current = await playlist.current() {
                    state.nowPlayingItemID = current.id
                } else {
                    state.nowPlayingItemID = nil
                }
            }

            broadcastSnapshot()
        }
    }
    
    func adminMoveToEnd(itemID: UUID) {
        Task { @MainActor in
            await playlist.moveItemToEnd(withID: itemID)
            let snapshot = await playlist.itemsSnapshot()
            state.queue = snapshot
            if let current = await playlist.current() {
                state.nowPlayingItemID = current.id
            } else {
                state.nowPlayingItemID = nil
            }
            broadcastSnapshot()
        }
    }
    
    func requestSendToEndApproval(itemID: UUID) -> UUID {
        DebugLog.shared.add("REWRITE", "requestSendToEndApproval called - disabled")
        return UUID()
    }
    
    func restoreRemovedToEnd(itemID: UUID) {
        Task { @MainActor in
            // If the item exists in removedItems, take it from there; otherwise try to find it in the current queue
            var item: QueueItem?
            if let idx = removedItems.firstIndex(where: { $0.id == itemID }) {
                item = removedItems.remove(at: idx)
            } else {
                item = state.queue.first(where: { $0.id == itemID })
            }
            guard let toRestore = item else {
                DebugLog.shared.add("ENGINE", "restoreRemovedToEnd: item not found in removedItems or queue")
                return
            }

            // If the item is already in the playlist, move it to the end; otherwise append it
            if state.queue.contains(where: { $0.id == toRestore.id }) {
                await playlist.moveItemToEnd(withID: toRestore.id)
            } else {
                await playlist.appendItem(toRestore)
            }

            // Mirror engine state back to controller state
            let snapshot = await playlist.itemsSnapshot()
            state.queue = snapshot

            // Keep or set nowPlaying appropriately
            if let current = await playlist.current() {
                state.nowPlayingItemID = current.id
            } else {
                state.nowPlayingItemID = nil
            }

            broadcastSnapshot()
        }
    }

    private func applyPlayedOutcomeIfNeeded(for itemID: UUID) {
        DebugLog.shared.add("REWRITE", "applyPlayedOutcomeIfNeeded called - disabled")
    }

    private func moveBehindNowPlaying(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "moveBehindNowPlaying called - disabled")
    }

    private func removeFromQueue(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "removeFromQueue called - disabled")
    }
    
    private func removeFromQueueDueToDown(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "removeFromQueueDueToDown called - disabled")
    }

    private func sendToEnd(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "sendToEnd called - disabled")
    }

    /// Clears only the vote counts but keeps memberDecisions to prevent immediate counter-votes after an UP outcome
    private func clearVotes(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "clearVotes called - disabled")
    }
    
    /// Clears vote counts and member decisions for the specified item
    private func clearAllVotesAndDecisions(itemID: UUID) {
        DebugLog.shared.add("REWRITE", "clearAllVotesAndDecisions called - disabled")
    }

    /// Rebuild the underlying MusicKit player queue to reflect the current logical state.queue.
    /// Places the current logical nowPlaying item (if any) at the front so playback continues from there.
    private func rebuildPlayerQueuePreservingCurrent() async {
        DebugLog.shared.add("REWRITE", "rebuildPlayerQueuePreservingCurrent called - disabled")
        broadcastSnapshot()
    }

    // MARK: - Snapshot / send helpers

    private func broadcastSnapshot() {
        Task { @MainActor in
            // If we know peers, send personalized snapshots; else send generic
            if !mpc.connectedPeers.isEmpty {
                for peer in mpc.connectedPeers {
                    let memberID = peerToMember[peer] ?? hostMemberID
                    var cooldowns: [UUID: Double] = [:]
                    // Copy limiter to call mutating helpers safely
                    var lim = self.perItemLimiter
                    for item in state.queue {
                        if let remaining = lim.remainingCooldown(memberID: memberID, itemID: item.id) {
                            cooldowns[item.id] = max(0, remaining)
                        }
                    }
                    let snap = PartyMessage.StateSnapshot(state: state, cooldowns: cooldowns, remainingActionSlots: remainingSlots(for: memberID))
                    await send(.stateSnapshot(snap), to: peer)
                }
            } else {
                await send(.stateSnapshot(.init(state: state)))
            }
        }
    }

    private func send(_ msg: PartyMessage, to peer: MCPeerID? = nil) async {
        do {
            let data = try PartyCodec.encode(msg)
            try mpc.send(data, to: peer.map { [$0] })
        } catch { }
    }

    private func sendWhenConnected(_ msg: PartyMessage, to peer: MCPeerID, label: String) async {
        for attempt in 0..<10 {
            if mpc.connectedPeers.contains(peer) {
                await send(msg, to: peer)
                DebugLog.shared.add("HOST", "sent \(label) to=\(peer.displayName) attempt=\(attempt)")
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        DebugLog.shared.add("HOST", "failed to send \(label) to=\(peer.displayName) (never connected)")
    }

    // MARK: - Skip requests (legacy UI)

    private func handleSkipRequest(_ req: PartyMessage.SkipRequest) {
        DebugLog.shared.add("HOST", "skipRequest memberID=\(req.memberID) itemID=\(req.itemID)")

        guard state.queue.contains(where: { $0.id == req.itemID }) else { return }

        let alreadyPending = pendingSkipRequests.contains {
            $0.itemID == req.itemID && $0.memberID == req.memberID
        }
        guard !alreadyPending else { return }

        pendingSkipRequests.insert(
            PendingSkipRequest(
                id: UUID(),
                itemID: req.itemID,
                memberID: req.memberID,
                requestedAt: req.timestamp
            ),
            at: 0
        )
    }

    func approveSkipRequest(itemID: UUID) {
        pendingSkipRequests.removeAll { $0.itemID == itemID }
        DebugLog.shared.add("REWRITE", "approveSkipRequest called - disabled")
        broadcastSnapshot()
    }

    func rejectSkipRequest(itemID: UUID, memberID: MemberID) {
        pendingSkipRequests.removeAll { $0.itemID == itemID && $0.memberID == memberID }
    }
}

