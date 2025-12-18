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
    
    private let mpc: MPCService
    private let limiter = VoteLimiter()
    private let locationService: LocationService
    private let playback = HostPlaybackController()
    private var nowPlayingBroadcastTask: Task<Void, Never>?
    private var peerToMember: [MCPeerID: MemberID] = [:]
    private let hostMemberID: MemberID = DeviceIdentity.memberID()

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
        playback.startTick(every: 1.0) { [weak self] playing, pos in
            guard let self else { return }
            Task { @MainActor in
                let payload = PartyMessage.NowPlayingPayload(
                    nowPlayingItemID: self.state.nowPlayingItemID,
                    isPlaying: playing,
                    positionSeconds: pos,
                    sentAt: Date()
                )
                self.nowPlaying = payload
                let msg = PartyMessage.nowPlaying(payload)
                await self.send(msg)
            }
        }
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

                // 1) Songs suchen (statt nur IDs)
                let songs = try await playback.searchCatalogSongs(for: terms)

                // 2) QueueItems aus Song-Daten bauen (erfüllt songID/addedBy/addedAt)
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

                // 3) Music queue setzen + play
                try await playback.setQueue(withSongs: songs)

                broadcastSnapshot()
                startNowPlayingBroadcast()
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
                    state.nowPlayingItemID = state.queue.indices.contains(nextIndex) ? state.queue[nextIndex].id : state.queue.last?.id
                }
                broadcastSnapshot()
            } catch {
                DebugLog.shared.add("HOST", "skip failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleIncoming(data: Data, from peer: MCPeerID) async {
        do {
            let msg = try PartyCodec.decode(data)
            switch msg {
            case .joinRequest(let req):
                await handleJoinRequest(req, from: peer)
            case .vote(let vote):
                handleVote(vote)
            case .skipRequest:
                break
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
        
        // 1) Session-ID prüfen
        guard req.sessionID == state.sessionID else {
            DebugLog.shared.add(
                "HOST",
                "reject: wrong session (wanted \(state.sessionID), got \(req.sessionID))"
            )
            await send(
                .joinDecision(.init(
                    accepted: false,
                    reason: "Falsche Session.",
                    assignedMemberID: req.memberID
                )),
                to: peer
            )
            return
        }
        
        // 2) Join-Code prüfen
        guard req.joinCode == joinCode else {
            DebugLog.shared.add(
                "HOST",
                "reject: wrong joinCode (wanted \(joinCode), got \(req.joinCode))"
            )
            await send(
                .joinDecision(.init(
                    accepted: false,
                    reason: "Falscher Join-Code.",
                    assignedMemberID: req.memberID
                )),
                to: peer
            )
            return
        }
        
        // 3) Location prüfen (mit kurzer Wartezeit für Debug-Timing)
        var hostLoc = locationService.lastLocation
        
        if hostLoc == nil {
            DebugLog.shared.add("HOST", "hostLoc missing -> wait briefly")
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                hostLoc = locationService.lastLocation
                if hostLoc != nil { break }
            }
        }
        
        guard
            let loc = req.location,
            let finalHostLoc = hostLoc
        else {
            DebugLog.shared.add("HOST", "reject: Location fehlt (after wait)")
            await send(
                .joinDecision(.init(
                    accepted: false,
                    reason: "Location fehlt.",
                    assignedMemberID: req.memberID
                )),
                to: peer
            )
            return
        }
        
        let guestLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        let dist = finalHostLoc.distance(from: guestLoc)
        
        if dist > 65 {
            DebugLog.shared.add("HOST", "reject: too far (\(Int(dist))m)")
            await send(
                .joinDecision(.init(
                    accepted: false,
                    reason: "Zu weit entfernt (\(Int(dist))m).",
                    assignedMemberID: req.memberID
                )),
                to: peer
            )
            return
        }
        
        // 4) Accept / Reconnect-Handling (no +1 on rejoin)
        peerToMember[peer] = req.memberID
        
        if let idx = state.members.firstIndex(where: { $0.id == req.memberID }) {
            DebugLog.shared.add("HOST", "reconnect: \(req.displayName) (no +1)")
            state.members[idx].displayName = req.displayName
            state.members[idx].hasAppleMusic = req.hasAppleMusic
            state.members[idx].isAdmitted = true
            state.members[idx].lastSeen = Date()
        } else {
            DebugLog.shared.add("HOST", "accept new: \(req.displayName) (+1)")
            let member = Member(
                id: req.memberID,
                displayName: req.displayName,
                isAdmitted: true,
                hasAppleMusic: req.hasAppleMusic,
                lastSeen: Date()
            )
            state.members.append(member)
        }
        
        // ✅ Robust: JoinDecision erst senden, wenn Peer wirklich connected ist
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
    
    private func handleVote(_ vote: PartyMessage.VoteMessage) {
        guard limiter.spendAction(memberID: vote.memberID) else { return }
        guard let idx = state.queue.firstIndex(where: { $0.id == vote.itemID }) else { return }
        
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
        
        applyThresholdIfNeeded(for: item.id)
        broadcastSnapshot()
    }
    
    private func applyThresholdIfNeeded(for itemID: UUID) {
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue[idx]
        
        let guestCount = max(state.members.count, 1)
        let threshold = Int(ceil(Double(guestCount) * 0.5))
        
        if item.upVotes.count >= threshold {
            moveBehindNowPlaying(itemID: itemID)
        } else if item.downVotes.count >= threshold {
            moveToEnd(itemID: itemID)
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
        
        resetVotes(itemID: itemID)
    }
    
    private func moveToEnd(itemID: UUID) {
        guard let from = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = state.queue.remove(at: from)
        state.queue.append(item)
        resetVotes(itemID: itemID)
    }
    
    private func resetVotes(itemID: UUID) {
        guard let idx = state.queue.firstIndex(where: { $0.id == itemID }) else { return }
        state.queue[idx].upVotes = []
        state.queue[idx].downVotes = []
    }
    
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
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
        }
        
        DebugLog.shared.add("HOST", "failed to send \(label) to=\(peer.displayName) (never connected)")
    }
}
