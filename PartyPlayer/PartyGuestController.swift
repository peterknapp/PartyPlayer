import Foundation
import Combine
import CoreLocation
import MultipeerConnectivity

@MainActor
final class PartyGuestController: ObservableObject {
    enum Status: Equatable {
        case idle
        case scanning
        case connecting
        case reconnecting
        case admitted
        case rejected(String)
    }
    
    @Published var status: Status = .idle
    @Published private(set) var state: PartyState?
    @Published private(set) var nowPlaying: PartyMessage.NowPlayingPayload?
    @Published private(set) var itemCooldowns: [UUID: Double] = [:]
    @Published private(set) var lastSnapshotAt: Date = Date()
    @Published private(set) var remainingActionSlots: Int = 3
    @Published private(set) var suggestionCooldownSeconds: Int = 60

    @Published private(set) var lastSearchResults: [PartyMessage.MinimalSongPreview] = []
    @Published private(set) var lastSearchRequestID: UUID? = nil

    let memberID: MemberID = DeviceIdentity.memberID()

    private let mpc: MPCService
    private let locationService: LocationService
    private let localStore = GuestLocalStateStore()
    
    private let defaults = UserDefaults.standard
    private let lastSessionKey = "pp_lastSessionID" // migration only
    private let lastJoinCodeKey = "pp_lastJoinCode" // migration only
    private let lastAdmittedAtKey = "pp_lastAdmittedAt" // migration only

    private var joinAttemptID = UUID()
    private var joinTimeoutTask: Task<Void, Never>?
    private var retryCount = 0
    private let maxRetries = 5
    
    private var sessionID: String?
    private var joinCode: String?
    private var displayName: String
    private var hasAppleMusic: Bool

    private var targetPeer: MCPeerID?
    private var didSendJoin: Bool = false
    @Published var sendUpVotesEnabled: Bool = true { didSet { localStore.state.sendUpVotesEnabled = sendUpVotesEnabled } }
    @Published var sendDownVotesEnabled: Bool = true { didSet { localStore.state.sendDownVotesEnabled = sendDownVotesEnabled } }
    private var pendingVoteTasks: [UUID: Task<Void, Never>] = [:]
    private var lastVoteTapAt: [UUID: Date] = [:]

    init(displayName: String, hasAppleMusic: Bool, locationService: LocationService) {
        self.displayName = displayName
        self.hasAppleMusic = hasAppleMusic
        self.locationService = locationService

        // Load persisted preferences
        if !localStore.state.displayName.isEmpty {
            self.displayName = localStore.state.displayName
        } else {
            localStore.state.displayName = displayName
        }
        self.hasAppleMusic = localStore.state.hasAppleMusic || hasAppleMusic
        if localStore.state.hasAppleMusic != self.hasAppleMusic {
            localStore.state.hasAppleMusic = self.hasAppleMusic
        }
        self.sendUpVotesEnabled = localStore.state.sendUpVotesEnabled
        self.sendDownVotesEnabled = localStore.state.sendDownVotesEnabled

        self.mpc = MPCService(displayName: "GUEST-\(self.displayName)")

        self.mpc.onData = { [weak self] data, peer in
            Task { await self?.handleIncoming(data: data, from: peer) }
        }

        self.mpc.onFoundPeer = { [weak self] peer, info in
            guard let self else { return }
            guard let wantedSessionID = self.sessionID else { return }

            if self.targetPeer != nil { return }

            if info?["sessionID"] == wantedSessionID {
                self.targetPeer = peer
                DebugLog.shared.add(
                    "GUEST",
                    "match host=\(peer.displayName) discoverySessionID=\(info?["sessionID"] ?? "nil") -> invite"
                )
                let ctx = wantedSessionID.data(using: .utf8)
                self.mpc.invite(peer, context: ctx)
            }
        }

        self.mpc.onPeerState = { [weak self] peer, st in
            guard let self else { return }
            guard peer == self.targetPeer else { return }

            switch st {
            case .connected:
                DebugLog.shared.add("GUEST", "peerState connected")
                if !self.didSendJoin {
                    self.didSendJoin = true
                    Task { await self.sendJoinRequest(to: peer) }
                }

            case .notConnected:
                DebugLog.shared.add("GUEST", "peerState notConnected -> retry soon")
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                    if self.status == .connecting || self.status == .reconnecting {
                        await self.retryJoin()
                    }
                }
                
            default:
                break
            }
        }
        // Migrate legacy keys into the consolidated local store (one-time)
        migrateLegacyKeysIfNeeded()
    } // ✅ <- init endet hier korrekt!

    func startJoin(sessionID: String, joinCode: String) {
        DebugLog.shared.add("GUEST", "startJoin sessionID=\(sessionID) joinCode=\(joinCode)")
        self.sessionID = sessionID
        self.joinCode = joinCode
        self.targetPeer = nil
        self.didSendJoin = false
        self.state = nil
        retryCount = 0
        joinAttemptID = UUID()
        joinTimeoutTask?.cancel()
        joinTimeoutTask = nil
        
        let lastSession = localStore.state.lastSessionID
        let wasSameSessionBefore = (lastSession == sessionID)
        // persist current preferences
        localStore.state.displayName = self.displayName
        localStore.state.hasAppleMusic = self.hasAppleMusic
        localStore.state.sendUpVotesEnabled = self.sendUpVotesEnabled
        localStore.state.sendDownVotesEnabled = self.sendDownVotesEnabled

        status = wasSameSessionBefore ? .reconnecting : .connecting

        DebugLog.shared.add("GUEST", wasSameSessionBefore ? "UI: reconnecting" : "UI: connecting")

        // Restore locally persisted cooldowns (decayed by elapsed time) for immediate UI feedback
        if let ts = localStore.state.cooldownsSnapshotAt {
            let elapsed = Date().timeIntervalSince(ts)
            let decayed = localStore.state.lastKnownCooldowns.mapValues { max(0, $0 - elapsed) }
            self.itemCooldowns = decayed
        }
        
        locationService.requestWhenInUse()
        locationService.start()

        mpc.startBrowsing()
    }

    private func sendJoinRequest(to peer: MCPeerID) async {
        guard let sessionID, let joinCode else { return }

        DebugLog.shared.add(
            "GUEST",
            "sendJoinRequest to=\(peer.displayName) sessionID=\(sessionID) joinCode=\(joinCode)"
        )

        let myAttempt = joinAttemptID

        joinTimeoutTask?.cancel()
        joinTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000) // 6s

            // wenn inzwischen ein neuer Attempt läuft -> ignorieren
            guard self.joinAttemptID == myAttempt else { return }

            // wenn wir bis hier keine admitted/rejected haben -> retry
            if self.status == .connecting || self.status == .reconnecting {
                DebugLog.shared.add("GUEST", "join timeout -> retry")
                await self.retryJoin()
            }
        }
        
        guard let loc = await waitForLocation() else {
            DebugLog.shared.add("GUEST", "reject: location unavailable")
            status = .rejected("Location nicht verfügbar.")
            return
        }

        DebugLog.shared.add(
            "GUEST",
            "location ok lat=\(loc.coordinate.latitude) lon=\(loc.coordinate.longitude) acc=\(Int(loc.horizontalAccuracy))m"
        )

        let payload = PartyMessage.LocationPayload(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            accuracy: loc.horizontalAccuracy,
            timestamp: Date()
        )

        let req = PartyMessage.joinRequest(.init(
            sessionID: sessionID,
            joinCode: joinCode,
            memberID: memberID,
            displayName: displayName,
            hasAppleMusic: hasAppleMusic,
            location: payload
        ))

        await send(req, to: peer)
    }

    private func waitForLocation(maxSeconds: Double = 6.0) async -> CLLocation? {
        let deadline = Date().addingTimeInterval(maxSeconds)

        while Date() < deadline {
            if locationService.authorizationStatus == .authorizedWhenInUse ||
               locationService.authorizationStatus == .authorizedAlways {
                if let loc = locationService.lastLocation { return loc }
            } else if locationService.authorizationStatus == .denied ||
                      locationService.authorizationStatus == .restricted {
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return locationService.lastLocation
    }

    // MARK: - Actions

    func voteUp(itemID: UUID) {
        if !sendUpVotesEnabled {
            DebugLog.shared.add("GUEST", "voteUp suppressed (sendUpVotesEnabled=false) itemID=\(itemID)")
            return
        }
        scheduleVote(itemID: itemID, dir: .up)
    }
    func voteDown(itemID: UUID) {
        if !sendDownVotesEnabled {
            DebugLog.shared.add("GUEST", "voteDown suppressed (sendDownVotesEnabled=false) itemID=\(itemID)")
            return
        }
        scheduleVote(itemID: itemID, dir: .down)
    }

    func requestSkip(itemID: UUID) {
        let msg = PartyMessage.skipRequest(.init(memberID: memberID, itemID: itemID, timestamp: Date()))
        Task {
            guard let peer = targetPeer else { return }
            await send(msg, to: peer)
        }
    }

    private func scheduleVote(itemID: UUID, dir: PartyMessage.VoteDirection) {
        if (dir == .up && !sendUpVotesEnabled) || (dir == .down && !sendDownVotesEnabled) {
            DebugLog.shared.add("GUEST", "schedule suppressed dir=\(dir) itemID=\(itemID) upEnabled=\(sendUpVotesEnabled) downEnabled=\(sendDownVotesEnabled)")
            return
        }
        // Cancel any pending send for this item
        pendingVoteTasks[itemID]?.cancel()

        // Record latest tap time
        lastVoteTapAt[itemID] = Date()

        // Debounce: only send the last vote after 120ms
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            // If another task replaced this one, this task would be cancelled
            if Task.isCancelled { return }
            await self.sendVote(itemID: itemID, dir: dir)
        }

        pendingVoteTasks[itemID] = task
    }

    private func sendVote(itemID: UUID, dir: PartyMessage.VoteDirection) async {
        DebugLog.shared.add("GUEST", "sendVote dir=\(dir) itemID=\(itemID)")
        let msg = PartyMessage.vote(.init(memberID: memberID, itemID: itemID, direction: dir, timestamp: Date()))
        guard let peer = targetPeer else { return }
        await send(msg, to: peer)
    }

    // MARK: - Incoming

    private func handleIncoming(data: Data, from peer: MCPeerID) async {
        do {
            let msg = try PartyCodec.decode(data)
            switch msg {
            case .joinDecision(let dec):
                DebugLog.shared.add("GUEST", "joinDecision accepted=\(dec.accepted) reason=\(dec.reason ?? "nil")")
                if dec.accepted {
                    status = .admitted
                    localStore.state.lastSessionID = self.sessionID
                    localStore.state.lastJoinCode = self.joinCode
                    localStore.state.lastAdmittedAt = Date()
                } else {
                    status = .rejected(dec.reason ?? "Abgelehnt")
                }
                mpc.stopBrowsing()
                
            case .stateSnapshot(let snap):
                state = snap.state
                itemCooldowns = snap.cooldowns ?? [:]
                lastSnapshotAt = Date()

                // Persist last known cooldowns with timestamp for crash-safe UX
                localStore.state.lastKnownCooldowns = self.itemCooldowns
                localStore.state.cooldownsSnapshotAt = self.lastSnapshotAt

                if let slots = snap.remainingActionSlots { self.remainingActionSlots = slots }
                if let sc = snap.suggestionCooldownSeconds { self.suggestionCooldownSeconds = sc }
                
            case .nowPlaying(let np):
                self.nowPlaying = np
//                DebugLog.shared.add(
//                    "GUEST",
//                    "nowPlaying '\(np.title ?? "-")' – '\(np.artist ?? "-")' playing=\(np.isPlaying) pos=\(Int(np.positionSeconds))s"
//                )
            case .searchResults(let res):
                self.lastSearchResults = res.results
                self.lastSearchRequestID = res.requestID
                
            default:
                break
            }
        } catch {
            // ignore malformed
        }
    }

    // MARK: - Sending helpers

    private func send(_ msg: PartyMessage, to peer: MCPeerID) async {
        do {
            let data = try PartyCodec.encode(msg)
            try mpc.send(data, to: [peer])
        } catch {
            if status == .connecting {
                status = .rejected("Senden fehlgeschlagen (nicht verbunden).")
            }
        }
    }
    
    private func retryJoin() async {
        guard retryCount < maxRetries else {
            DebugLog.shared.add("GUEST", "retry limit reached -> reject")
            status = .rejected("Verbindung instabil. Bitte QR erneut scannen.")
            mpc.stopBrowsing()
            return
        }

        retryCount += 1
        DebugLog.shared.add("GUEST", "retryJoin #\(retryCount)")

        // neuer Attempt: alles, was im Flug war, verwerfen
        joinAttemptID = UUID()
        didSendJoin = false
        targetPeer = nil

        // Browsing einmal sauber neu starten
        mpc.stopBrowsing()
        try? await Task.sleep(nanoseconds: 200_000_000)
        mpc.startBrowsing()
    }

    // MARK: - Host-gestützte Suche

    func requestHostSearch(term: String) {
        let reqID = UUID()
        self.lastSearchRequestID = reqID
        self.lastSearchResults = []
        let msg = PartyMessage.searchRequest(.init(requestID: reqID, term: term, memberID: memberID))
        Task {
            guard let peer = targetPeer else { return }
            await send(msg, to: peer)
        }
    }

    func requestAddSong(songID: String, preview: PartyMessage.MinimalSongPreview?) {
        let msg = PartyMessage.addSongRequest(.init(memberID: memberID, songID: songID, preview: preview, requestedAt: Date()))
        Task {
            guard let peer = targetPeer else { return }
            await send(msg, to: peer)
        }
    }
    
    func leave() {
        // Cancel timers/tasks
        joinTimeoutTask?.cancel()
        joinTimeoutTask = nil

        // Stop discovery/connection attempts
        mpc.stopBrowsing()
        mpc.disconnect()

        // Reset transient state
        state = nil
        nowPlaying = nil
        itemCooldowns = [:]
        lastSnapshotAt = Date()
        remainingActionSlots = 3
        lastSearchResults = []
        lastSearchRequestID = nil

        // Reset connection/session info
        targetPeer = nil
        didSendJoin = false
        sessionID = nil
        joinCode = nil
        retryCount = 0

        // Stop location updates for guest
        locationService.stop()

        // Back to idle
        status = .idle
    }

    private func migrateLegacyKeysIfNeeded() {
        // If the new store already has a lastSessionID, assume migration done
        if localStore.state.lastSessionID != nil { return }
        let lastSession = defaults.string(forKey: lastSessionKey)
        let lastJoin = defaults.string(forKey: lastJoinCodeKey)
        let lastAdmittedTs = defaults.double(forKey: lastAdmittedAtKey)
        var migrated = false
        if lastSession != nil || lastJoin != nil || lastAdmittedTs > 0 {
            localStore.state.lastSessionID = lastSession
            localStore.state.lastJoinCode = lastJoin
            if lastAdmittedTs > 0 {
                localStore.state.lastAdmittedAt = Date(timeIntervalSince1970: lastAdmittedTs)
            }
            migrated = true
        }
        if migrated {
            // Optionally clear legacy keys
            defaults.removeObject(forKey: lastSessionKey)
            defaults.removeObject(forKey: lastJoinCodeKey)
            defaults.removeObject(forKey: lastAdmittedAtKey)
        }
    }
}

