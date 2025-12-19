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

    private let mpc: MPCService
    private let limiter = VoteLimiter()
    private var perItemLimiter = PerItemVoteLimiter()
    @Published var perItemCooldownMinutes: Int = 20 { didSet { perItemLimiter.setCooldown(minutes: perItemCooldownMinutes) } }
    private let locationService: LocationService
    private let playback = HostPlaybackController()

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

    private var peerToMember: [MCPeerID: MemberID] = [:]
    private let hostMemberID: MemberID = DeviceIdentity.memberID()

    // Pro Item: pro Member genau 1 Entscheidung (bis Item entfernt wird)
    private var memberDecisions: [UUID: [MemberID: PartyMessage.VoteDirection]] = [:]

    // Helper to check played tracks (index < nowPlaying index)
    private func isPlayed(itemID: UUID) -> Bool {
        guard let nowID = state.nowPlayingItemID,
              let nowIdx = state.queue.firstIndex(where: { $0.id == nowID }),
              let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return false }
        return idx < nowIdx
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
        mpc.startHosting(discoveryInfo: ["sessionID": state.sessionID])
        startNowPlayingBroadcast()
    }

    func startParty(withInitialQueue items: [QueueItem]) {
        state.queue = items
        broadcastSnapshot()
    }

    func approveSkip(itemID: UUID) {
        state.queue.removeAll { $0.id == itemID }
        broadcastSnapshot()
    }

    func startNowPlayingBroadcast() {
        // Prevent duplicate initialization
        if isNowPlayingBroadcasting { return }
        isNowPlayingBroadcasting = true

        playback.startTick(every: 1.0) { [weak self] playing, pos in
            guard let self else { return }
            // Respect cancellation
            guard self.isNowPlayingBroadcasting else { return }
            Task { @MainActor in
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

    func loadDemoAndPlay() {
        Task {
            do {
                let terms = [
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

                state.queue = items
                state.nowPlayingItemID = items.first?.id

                try await playback.setQueue(withSongs: songs)

                broadcastSnapshot()
                if !isNowPlayingBroadcasting { startNowPlayingBroadcast() }
                try await playback.play()

                DebugLog.shared.add("HOST", "demo queue loaded + playing")
            } catch {
                DebugLog.shared.add("HOST", "demo failed: \(error.localizedDescription)")
            }
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
            }
        }
    }

    func skip() {
        Task {
            do {
                try await playback.skipToNext()
                if let current = state.nowPlayingItemID,
                   let idx = state.queue.firstIndex(where: { $0.id == current }) {
                    let nextIndex = min(idx + 1, state.queue.count - 1)
                    state.nowPlayingItemID = state.queue.indices.contains(nextIndex)
                        ? state.queue[nextIndex].id
                        : state.queue.last?.id
                }
                broadcastSnapshot()
            } catch {
                DebugLog.shared.add("HOST", "skip failed: \(error.localizedDescription)")
            }
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

        // Location check (mit kurzer Wartezeit)
        var hostLoc = locationService.lastLocation
        if hostLoc == nil {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                hostLoc = locationService.lastLocation
                if hostLoc != nil { break }
            }
        }

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

    private func handleVote(_ vote: PartyMessage.VoteMessage) {
        guard limiter.spendAction(memberID: vote.memberID) else { return }

        // Enforce per-item per-20-min cooldown
        guard perItemLimiter.spend(memberID: vote.memberID, itemID: vote.itemID) else {
            DebugLog.shared.add("HOST", "vote ignored (cooldown) member=\(vote.memberID) item=\(vote.itemID)")
            return
        }

        // Item muss existieren
        guard let idx = state.queue.firstIndex(where: { $0.id == vote.itemID }) else { return }

        // NowPlaying ausgenommen
        if state.nowPlayingItemID == vote.itemID {
            DebugLog.shared.add("HOST", "vote ignored (now playing) itemID=\(vote.itemID)")
            return
        }

        // Up auf Next-Up blocken, Down auf Next-Up erlauben
        if vote.direction == .up, isNextUp(itemID: vote.itemID) {
            DebugLog.shared.add("HOST", "vote ignored (next up / up blocked) itemID=\(vote.itemID)")
            return
        }

        // Played tracks: disable up/down for removal/promote, but allow voting to send to end via DOWN direction
        if isPlayed(itemID: vote.itemID) {
            // Interpret any vote as a request to send to end, count using upVotes for visibility
            memberDecisions[vote.itemID, default: [:]][vote.memberID] = vote.direction
            var item = state.queue[idx]
            item.upVotes.insert(vote.memberID)
            state.queue[idx] = item
            applyPlayedOutcomeIfNeeded(for: vote.itemID)
            broadcastSnapshot()
            return
        }

        // Pro Member nur 1 Entscheidung pro Item (bis Item entfernt wird)
        if let existing = memberDecisions[vote.itemID]?[vote.memberID] {
            DebugLog.shared.add(
                "HOST",
                "vote ignored (already decided \(existing)) member=\(vote.memberID) item=\(vote.itemID)"
            )
            return
        }

        memberDecisions[vote.itemID, default: [:]][vote.memberID] = vote.direction

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

        // Debug wie bei Dir
        let guestCount = state.members.filter { $0.isAdmitted }.count
        DebugLog.shared.add(
            "HOST",
            "vote received dir=\(vote.direction) itemID=\(vote.itemID) up=\(state.queue[idx].upVotes.count) down=\(state.queue[idx].downVotes.count) guests=\(guestCount)"
        )

        applyVoteOutcomeIfNeeded(for: vote.itemID)
        broadcastSnapshot()
    }

    private func applyVoteOutcomeIfNeeded(for itemID: UUID) {
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue[idx]

        // NowPlaying nie anfassen
        if state.nowPlayingItemID == itemID { return }

        // admitted Gäste zählen (Host nicht)
        let guestCount = state.members.filter { $0.isAdmitted }.count
        let threshold = max(1, (guestCount + 1) / 2) // >= 50%: for 1 guest -> 1

        // Early exit if no votes yet
        let up = item.upVotes.count
        let down = item.downVotes.count
        guard up >= threshold || down >= threshold else { return }

        if up >= threshold {
            if votingMode == .automatic {
                moveBehindNowPlaying(itemID: itemID)
                clearVotes(itemID: itemID)
                DebugLog.shared.add("HOST", "vote outcome UP (auto moved) itemID=\(itemID) threshold=\(threshold)")
            } else {
                enqueuePendingOutcome(itemID: itemID, kind: .promoteNext, threshold: threshold)
            }
            return
        }

        if down >= threshold {
            if votingMode == .automatic {
                removeFromQueue(itemID: itemID)
                DebugLog.shared.add("HOST", "vote outcome DOWN (auto removed) itemID=\(itemID) threshold=\(threshold)")
            } else {
                enqueuePendingOutcome(itemID: itemID, kind: .removeFromQueue, threshold: threshold)
            }
            return
        }
    }

    private func enqueuePendingOutcome(itemID: UUID, kind: PendingVoteOutcome.Kind, threshold: Int) {
        // avoid duplicates
        if pendingVoteOutcomes.contains(where: { $0.itemID == itemID && $0.kind == kind }) { return }
        pendingVoteOutcomes.insert(
            PendingVoteOutcome(id: UUID(), itemID: itemID, kind: kind, threshold: threshold, createdAt: Date()),
            at: 0
        )
    }

    func approveVoteOutcome(id: UUID) {
        guard let idx = pendingVoteOutcomes.firstIndex(where: { $0.id == id }) else { return }
        let outcome = pendingVoteOutcomes.remove(at: idx)
        switch outcome.kind {
        case .promoteNext:
            moveBehindNowPlaying(itemID: outcome.itemID)
            clearVotes(itemID: outcome.itemID)
        case .removeFromQueue:
            removeFromQueue(itemID: outcome.itemID)
        case .sendToEnd:
            sendToEnd(itemID: outcome.itemID)
        }
        broadcastSnapshot()
    }

    func rejectVoteOutcome(id: UUID) {
        pendingVoteOutcomes.removeAll { $0.id == id }
    }
    
    func requestSendToEndApproval(itemID: UUID) -> UUID {
        let threshold = max(1, (state.members.filter { $0.isAdmitted }.count + 1) / 2)
        let outcome = PendingVoteOutcome(id: UUID(), itemID: itemID, kind: .sendToEnd, threshold: threshold, createdAt: Date())
        pendingVoteOutcomes.insert(outcome, at: 0)
        return outcome.id
    }

    private func applyPlayedOutcomeIfNeeded(for itemID: UUID) {
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        if !isPlayed(itemID: itemID) { return }

        let guestCount = state.members.filter { $0.isAdmitted }.count
        let threshold = max(1, (guestCount + 1) / 2)

        if state.queue[idx].upVotes.count >= threshold {
            if votingMode == .automatic {
                sendToEnd(itemID: itemID)
                clearVotes(itemID: itemID)
                DebugLog.shared.add("HOST", "played outcome SEND_TO_END (auto) itemID=\(itemID) threshold=\(threshold)")
            } else {
                enqueuePendingOutcome(itemID: itemID, kind: .sendToEnd, threshold: threshold)
            }
        }
    }

    private func moveBehindNowPlaying(itemID: UUID) {
        guard let from = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue.remove(at: from)

        if let nowID = state.nowPlayingItemID,
           let nowIndex = state.queue.firstIndex(where: { $0.id == nowID }) {
            let insertIndex = min(nowIndex + 1, state.queue.count)
            state.queue.insert(item, at: insertIndex)
        } else {
            state.queue.insert(item, at: 0)
        }
    }

    private func removeFromQueue(itemID: UUID) {
        memberDecisions[itemID] = nil
        state.queue.removeAll { $0.id == itemID }
    }

    private func sendToEnd(itemID: UUID) {
        guard let from = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue.remove(at: from)
        state.queue.append(item)
    }

    /// Clears only the vote counts but keeps memberDecisions to prevent immediate counter-votes after an UP outcome
    private func clearVotes(itemID: UUID) {
        // Keep memberDecisions to prevent immediate counter-votes after an UP outcome
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        state.queue[idx].upVotes = []
        state.queue[idx].downVotes = []
    }

    // MARK: - Snapshot / send helpers

    private func broadcastSnapshot() {
        Task { await send(.stateSnapshot(.init(state: state))) }
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

        if state.nowPlayingItemID == itemID {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.playback.skipToNext()
                    if let idx = self.state.queue.firstIndex(where: { $0.id == itemID }) {
                        let nextIndex = min(idx + 1, self.state.queue.count - 1)
                        self.state.nowPlayingItemID = self.state.queue.indices.contains(nextIndex)
                            ? self.state.queue[nextIndex].id
                            : self.state.queue.last?.id
                    }
                    self.state.queue.removeAll { $0.id == itemID }
                    self.broadcastSnapshot()
                } catch {
                    DebugLog.shared.add("HOST", "approveSkipRequest failed: \(error.localizedDescription)")
                }
            }
        } else {
            state.queue.removeAll { $0.id == itemID }
            broadcastSnapshot()
        }
    }

    func rejectSkipRequest(itemID: UUID, memberID: MemberID) {
        pendingSkipRequests.removeAll { $0.itemID == itemID && $0.memberID == memberID }
    }
}

