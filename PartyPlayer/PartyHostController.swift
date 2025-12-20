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

    // Fallback-Artwork für Public-Tab (z. B. beim ersten Start, bevor NowPlaying-IDs stabil sind)
    @Published var publicArtworkURLString: String? = nil

    private let mpc: MPCService
    // Concurrent action slots per member (e.g., 3). Each spent when a vote is accepted and restored when the per-item cooldown elapses.
    @Published var maxConcurrentActions: Int = 3
    private var activeActions: [MemberID: Int] = [:]

    private var perItemLimiter = PerItemVoteLimiter()
    @Published var perItemCooldownMinutes: Int = 1 { didSet { perItemLimiter.setCooldown(minutes: perItemCooldownMinutes) } }
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
            // Ensure MusicKit authorization before proceeding
            await self.playback.requestAuthorization()
            guard self.playback.isAuthorized else {
                DebugLog.shared.add("MUSIC", "authorization denied or not available; aborting demo load")
                return
            }
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

                // Set initial state and public artwork fallback for Public tab
                self.publicArtworkURLString = items.first?.artworkURL
                state.queue = items
                state.nowPlayingItemID = items.first?.id

                try await playback.setQueue(withSongs: songs)

                broadcastSnapshot()
                if !isNowPlayingBroadcasting { startNowPlayingBroadcast() }
                try await playback.play()

                DebugLog.shared.add("HOST", "demo queue loaded + playing")
            } catch {
                DebugLog.shared.add("HOST", "demo failed: \(error.localizedDescription)")
                DebugLog.shared.add("MUSIC", "post-failure authStatus=\(MusicAuthorization.currentStatus)")
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
                self.playback.diagnoseEnvironment(prefix: "MUSIC")
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
                if let nowID = self.state.nowPlayingItemID,
                   let nowItem = self.state.queue.first(where: { $0.id == nowID }) {
                    self.publicArtworkURLString = nowItem.artworkURL
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
        let now = Date()
        guard let idx = state.queue.firstIndex(where: { $0.id == vote.itemID }) else { return }

        if !votingEngineEnabled {
            // Simple counting only: one decision per member per item, replaceable within cooldown/limiter
            guard trySpendSlot(for: vote.memberID) else {
                DebugLog.shared.add("HOST", "vote ignored (no action slots) member=\(vote.memberID)")
                return
            }
            broadcastSnapshot()

            guard perItemLimiter.spend(memberID: vote.memberID, itemID: vote.itemID) else {
                var remaining: String = "?"
                if var lim = Optional(self.perItemLimiter) { // copy to call mutating helper safely
                    if let r = lim.remainingCooldown(memberID: vote.memberID, itemID: vote.itemID) {
                        remaining = String(Int(r.rounded()))
                    }
                }
                let df = DateFormatter()
                df.dateFormat = "HH:mm:ss.SSS"
                let nowStr = df.string(from: Date())
                DebugLog.shared.add("HOST", "\(nowStr) vote ignored (cooldown) member=\(vote.memberID) item=\(vote.itemID) remaining=\(remaining)s")
                restoreSlot(for: vote.memberID)
                return
            }
            var item = state.queue[idx]
            // Remove previous decision from sets, if any
            if let prev = memberDecisions[vote.itemID]?[vote.memberID] {
                switch prev { case .up: item.upVotes.remove(vote.memberID); case .down: item.downVotes.remove(vote.memberID) }
            }
            // Apply new decision
            switch vote.direction { case .up: item.upVotes.insert(vote.memberID); case .down: item.downVotes.insert(vote.memberID) }
            state.queue[idx] = item
            memberDecisions[vote.itemID, default: [:]][vote.memberID] = vote.direction

            DebugLog.shared.add("HOST", "vote recorded (engine OFF) dir=\(vote.direction) itemID=\(vote.itemID) up=\(item.upVotes.count) down=\(item.downVotes.count)")

            // Schedule slot restoration after per-item cooldown and update guests
            let cooldownSeconds = TimeInterval(perItemCooldownMinutes * 60)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(cooldownSeconds * 1_000_000_000))
                await MainActor.run {
                    self?.restoreSlot(for: vote.memberID)
                    self?.broadcastSnapshot()
                }
            }
            return
        }

        let isCurrent = (state.nowPlayingItemID == vote.itemID)
        let isNext = isNextUp(itemID: vote.itemID)
        let played = isPlayed(itemID: vote.itemID)
        let prevDecision = memberDecisions[vote.itemID]?[vote.memberID]
        let prevTime = lastMemberItemVoteAt[vote.memberID]?[vote.itemID]
        let withinGrace = (prevTime != nil) ? (now.timeIntervalSince(prevTime!) < 1.0) : false

        if let prev = prevDecision, withinGrace {
            // Allow override within 1s: revert previous vote and apply new one
            var item = state.queue[idx]
            switch prev {
            case .up: item.upVotes.remove(vote.memberID)
            case .down: item.downVotes.remove(vote.memberID)
            }
            switch vote.direction {
            case .up: item.upVotes.insert(vote.memberID)
            case .down: item.downVotes.insert(vote.memberID)
            }
            state.queue[idx] = item
            memberDecisions[vote.itemID]?[vote.memberID] = vote.direction
            var map = lastMemberItemVoteAt[vote.memberID] ?? [:]
            map[vote.itemID] = now
            lastMemberItemVoteAt[vote.memberID] = map

            // Respect exclusions: current item ignored, next-up cannot be promoted by up
            if isCurrent {
                DebugLog.shared.add("HOST", "override ignored (now playing)")
                return
            }
            if vote.direction == .up && isNext {
                DebugLog.shared.add("HOST", "override up blocked (next up)")
                broadcastSnapshot()
                return
            }

            if votingEngineEnabled {
                applyVoteOutcomeIfNeeded(for: vote.itemID, preferred: vote.direction)
            }
            broadcastSnapshot()
            return
        }

        // REMOVE THIS block which spent slot globally after cooldown, before isCurrent/isNext/played:
        /*
        guard trySpendSlot(for: vote.memberID) else {
            DebugLog.shared.add("HOST", "vote ignored (no action slots) member=\(vote.memberID)")
            return
        }
        broadcastSnapshot()
        */

        guard perItemLimiter.spend(memberID: vote.memberID, itemID: vote.itemID) else {
            var remaining: String = "?"
            if var lim = Optional(self.perItemLimiter) { // copy to call mutating helper safely
                if let r = lim.remainingCooldown(memberID: vote.memberID, itemID: vote.itemID) {
                    remaining = String(Int(r.rounded()))
                }
            }
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            let nowStr = df.string(from: Date())
            DebugLog.shared.add("HOST", "\(nowStr) vote ignored (cooldown) member=\(vote.memberID) item=\(vote.itemID) remaining=\(remaining)s")
            restoreSlot(for: vote.memberID)
            return
        }

        // NowPlaying ausgenommen
        if isCurrent {
            DebugLog.shared.add("HOST", "vote ignored (now playing) itemID=\(vote.itemID)")
            restoreSlot(for: vote.memberID)
            return
        }

        // Up auf Next-Up blocken, Down auf Next-Up erlauben
        if vote.direction == .up, isNext {
            DebugLog.shared.add("HOST", "vote ignored (next up / up blocked) itemID=\(vote.itemID)")
            restoreSlot(for: vote.memberID)
            return
        }

        // Played tracks: disable up/down for removal/promote, but allow voting to send to end via DOWN direction
        if played {
            // Spend an action slot for this vote
            guard trySpendSlot(for: vote.memberID) else {
                DebugLog.shared.add("HOST", "vote ignored (no action slots) member=\(vote.memberID)")
                return
            }
            broadcastSnapshot()

            // Interpret any vote as a request to send to end, count using upVotes for visibility
            memberDecisions[vote.itemID, default: [:]][vote.memberID] = vote.direction
            var item = state.queue[idx]
            item.upVotes.insert(vote.memberID)
            state.queue[idx] = item

            if votingEngineEnabled {
                applyPlayedOutcomeIfNeeded(for: vote.itemID)
            }

            // Schedule slot restoration after per-item cooldown and update guests
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

        // Erlaube neue Entscheidung nach abgelaufenem Cooldown: entferne vorherige Entscheidung, falls vorhanden
        if let prev = memberDecisions[vote.itemID]?[vote.memberID] {
            var item = state.queue[idx]
            switch prev {
            case .up: item.upVotes.remove(vote.memberID)
            case .down: item.downVotes.remove(vote.memberID)
            }
            state.queue[idx] = item
        }

        // Insert spending slot here, before applying vote in normal engine-ON path
        guard trySpendSlot(for: vote.memberID) else {
            DebugLog.shared.add("HOST", "vote ignored (no action slots) member=\(vote.memberID)")
            return
        }
        broadcastSnapshot()

        memberDecisions[vote.itemID, default: [:]][vote.memberID] = vote.direction
        var map = lastMemberItemVoteAt[vote.memberID] ?? [:]
        map[vote.itemID] = now
        lastMemberItemVoteAt[vote.memberID] = map

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

        let cooldownSeconds = TimeInterval(perItemCooldownMinutes * 60)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cooldownSeconds * 1_000_000_000))
            await MainActor.run {
                self?.restoreSlot(for: vote.memberID)
                self?.broadcastSnapshot()
            }
        }

        // Debug wie bei Dir
        let guestCount = state.members.filter { $0.isAdmitted }.count
        DebugLog.shared.add(
            "HOST",
            "vote received dir=\(vote.direction) itemID=\(vote.itemID) up=\(state.queue[idx].upVotes.count) down=\(state.queue[idx].downVotes.count) guests=\(guestCount) isNext=\(isNext) played=\(played)"
        )

        if votingEngineEnabled {
            applyVoteOutcomeIfNeeded(for: vote.itemID, preferred: vote.direction)
        }
        broadcastSnapshot()
    }

    private func applyVoteOutcomeIfNeeded(for itemID: UUID, preferred: PartyMessage.VoteDirection? = nil) {
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue[idx]

        // NowPlaying nie anfassen
        if state.nowPlayingItemID == itemID { return }

        // admitted Gäste zählen (Host nicht)
        let guestCount = state.members.filter { $0.isAdmitted }.count
        let threshold = max(1, Int(ceil(Double(guestCount) * Double(voteThresholdPercent) / 100.0)))

        let up = item.upVotes.count
        let down = item.downVotes.count
        let isNext = isNextUp(itemID: itemID)

        DebugLog.shared.add("HOST", "eval itemID=\(itemID) up=\(up) down=\(down) threshold=\(threshold) isNext=\(isNext) preferred=\(String(describing: preferred))")

        // 1) DOWN vor UP auswerten (und wenn preferred == .down, dann ausschließlich DOWN betrachten)
        if down >= threshold {
            if votingEngineEnabled && processDownOutcomes {
                if votingMode == .automatic {
                    clearAllVotesAndDecisions(itemID: itemID)
                    removeFromQueueDueToDown(itemID: itemID)
                    DebugLog.shared.add("HOST", "vote outcome DOWN (auto removed, cleared counts+decisions) itemID=\(itemID) threshold=\(threshold)")
                } else {
                    enqueuePendingOutcome(itemID: itemID, kind: .removeFromQueue, threshold: threshold)
                }
            } else {
                DebugLog.shared.add("HOST", "DOWN reached but engine/toggle disabled for down")
            }
            return
        } else if preferred == .down {
            // Bei unmittelbarer DOWN-Aktion keine UP-Promotion im selben Tick zulassen
            return
        }

        // 2) UP nur wenn nicht Next-Up und kein konkurrierender DOWN die Schwelle erreicht
        if up >= threshold && down < threshold && !isNext {
            if votingEngineEnabled && processUpOutcomes {
                if votingMode == .automatic {
                    moveBehindNowPlaying(itemID: itemID)
                    clearVotes(itemID: itemID)
                    DebugLog.shared.add("HOST", "vote outcome UP (auto moved) itemID=\(itemID) threshold=\(threshold)")
                } else {
                    enqueuePendingOutcome(itemID: itemID, kind: .promoteNext, threshold: threshold)
                }
            } else {
                DebugLog.shared.add("HOST", "UP reached but engine/toggle disabled for up or next-up blocked")
            }
            return
        }

        if up >= threshold && isNext {
            DebugLog.shared.add("HOST", "UP outcome blocked for Next-Up itemID=\(itemID) (no promote while next-up)")
        }
    }

    private func enqueuePendingOutcome(itemID: UUID, kind: PendingVoteOutcome.Kind, threshold: Int) {
        guard votingEngineEnabled else { return }
        switch kind {
        case .removeFromQueue:
            guard processDownOutcomes else { return }
        case .promoteNext:
            guard processUpOutcomes else { return }
        case .sendToEnd:
            guard processSendToEndOutcomes else { return }
        }
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
            removeFromQueueDueToDown(itemID: outcome.itemID)
        case .sendToEnd:
            sendToEnd(itemID: outcome.itemID)
        }
        broadcastSnapshot()
    }

    func rejectVoteOutcome(id: UUID) {
        pendingVoteOutcomes.removeAll { $0.id == id }
    }

    func adminRemoveFromQueue(itemID: UUID) {
        removeFromQueueDueToDown(itemID: itemID)
        broadcastSnapshot()
    }
    
    func requestSendToEndApproval(itemID: UUID) -> UUID {
        let threshold = max(1, Int(ceil(Double(state.members.filter { $0.isAdmitted }.count) * Double(voteThresholdPercent) / 100.0)))
        let outcome = PendingVoteOutcome(id: UUID(), itemID: itemID, kind: .sendToEnd, threshold: threshold, createdAt: Date())
        pendingVoteOutcomes.insert(outcome, at: 0)
        return outcome.id
    }
    
    func restoreRemovedToEnd(itemID: UUID) {
        guard let idx = removedItems.firstIndex(where: { $0.id == itemID }) else { return }
        let item = removedItems.remove(at: idx)
        // Avoid duplicates if item somehow already exists in queue
        if !state.queue.contains(where: { $0.id == itemID }) {
            state.queue.append(item)
        }
        broadcastSnapshot()
    }

    private func applyPlayedOutcomeIfNeeded(for itemID: UUID) {
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        if !isPlayed(itemID: itemID) { return }

        let guestCount = state.members.filter { $0.isAdmitted }.count
        let threshold = max(1, Int(ceil(Double(guestCount) * Double(voteThresholdPercent) / 100.0)))

        if state.queue[idx].upVotes.count >= threshold {
            if votingEngineEnabled && processSendToEndOutcomes {
                if votingMode == .automatic {
                    sendToEnd(itemID: itemID)
                    clearVotes(itemID: itemID)
                    DebugLog.shared.add("HOST", "played outcome SEND_TO_END (auto) itemID=\(itemID) threshold=\(threshold)")
                } else {
                    enqueuePendingOutcome(itemID: itemID, kind: .sendToEnd, threshold: threshold)
                }
            } else {
                DebugLog.shared.add("HOST", "SEND_TO_END reached but engine/toggle disabled")
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
    
    private func removeFromQueueDueToDown(itemID: UUID) {
        memberDecisions[itemID] = nil
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue[idx]
        // Append to removed list if not already present
        if !removedItems.contains(where: { $0.id == itemID }) {
            removedItems.insert(item, at: 0)
        }
        state.queue.remove(at: idx)
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
    
    /// Clears vote counts and member decisions for the specified item
    private func clearAllVotesAndDecisions(itemID: UUID) {
        memberDecisions[itemID] = nil
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        state.queue[idx].upVotes = []
        state.queue[idx].downVotes = []
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
                    if let nowID = self.state.nowPlayingItemID,
                       let nowItem = self.state.queue.first(where: { $0.id == nowID }) {
                        self.publicArtworkURLString = nowItem.artworkURL
                    }
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

