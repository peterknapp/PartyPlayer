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

    let memberID: MemberID = DeviceIdentity.memberID()

    private let mpc: MPCService
    private let locationService: LocationService
    
    private let defaults = UserDefaults.standard
    private let lastSessionKey = "pp_lastSessionID"
    private let lastJoinCodeKey = "pp_lastJoinCode"
    private let lastAdmittedAtKey = "pp_lastAdmittedAt"

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

    init(displayName: String, hasAppleMusic: Bool, locationService: LocationService) {
        self.displayName = displayName
        self.hasAppleMusic = hasAppleMusic
        self.locationService = locationService

        self.mpc = MPCService(displayName: "GUEST-\(displayName)")

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
        
        let lastSession = defaults.string(forKey: lastSessionKey)
        let wasSameSessionBefore = (lastSession == sessionID)

        status = wasSameSessionBefore ? .reconnecting : .connecting

        DebugLog.shared.add("GUEST", wasSameSessionBefore ? "UI: reconnecting" : "UI: connecting")
        
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

    func voteUp(itemID: UUID) { Task { await sendVote(itemID: itemID, dir: .up) } }
    func voteDown(itemID: UUID) { Task { await sendVote(itemID: itemID, dir: .down) } }

    func requestSkip(itemID: UUID) {
        let msg = PartyMessage.skipRequest(.init(memberID: memberID, itemID: itemID, timestamp: Date()))
        Task {
            guard let peer = targetPeer else { return }
            await send(msg, to: peer)
        }
    }

    private func sendVote(itemID: UUID, dir: PartyMessage.VoteDirection) async {
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
                    defaults.set(self.sessionID, forKey: lastSessionKey)
                    defaults.set(self.joinCode, forKey: lastJoinCodeKey)
                    defaults.set(Date().timeIntervalSince1970, forKey: lastAdmittedAtKey)
                } else {
                    status = .rejected(dec.reason ?? "Abgelehnt")
                }
                mpc.stopBrowsing()
                
            case .stateSnapshot(let snap):
                state = snap.state

            case .nowPlaying(let np):
                self.nowPlaying = np
//                DebugLog.shared.add(
//                    "GUEST",
//                    "nowPlaying '\(np.title ?? "-")' – '\(np.artist ?? "-")' playing=\(np.isPlaying) pos=\(Int(np.positionSeconds))s"
//                )
                
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
}
