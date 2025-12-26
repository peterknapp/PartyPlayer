import Foundation
import Combine
import MultipeerConnectivity

final class MPCService: NSObject, ObservableObject {
    private let serviceType = "partyplayer" // must be 1–15 chars, lowercase, numbers, hyphen
    private let myPeerID: MCPeerID
    private let session: MCSession

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var discoveryInfo: [String:String]?
    
    @Published var connectedPeers: [MCPeerID] = []

    var onData: ((Data, MCPeerID) -> Void)?
    var onPeerState: ((MCPeerID, MCSessionState) -> Void)?
    var onFoundPeer: ((MCPeerID, [String:String]?) -> Void)?

    init(displayName: String) {
        self.myPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }

    func startHosting(discoveryInfo: [String: String]) {
        guard advertiser == nil else { return }
        self.discoveryInfo = discoveryInfo
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                              discoveryInfo: discoveryInfo,
                                              serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }
    
    func stopHosting() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        discoveryInfo = nil
    }
    
    func startBrowsing() {
        guard browser == nil else { return }
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }
    
    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
    }
    
    func invite(_ peer: MCPeerID, context: Data? = nil) {
        browser?.invitePeer(peer, to: session, withContext: context, timeout: 10)
    }

    func send(_ data: Data, to peers: [MCPeerID]? = nil) throws {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty else { return }
        try session.send(data, toPeers: targets, with: .reliable)
    }
    
    func disconnect() {
        session.disconnect()
    }
}

extension MPCService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            let s: String
            switch state {
            case .notConnected: s = "notConnected"
            case .connecting: s = "connecting"
            case .connected: s = "connected"
            @unknown default: s = "unknown"
            }
            DebugLog.shared.add("MPC", "peerState \(peerID.displayName)=\(s)")
            self.connectedPeers = session.connectedPeers
            self.onPeerState?(peerID, state)
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.onData?(data, peerID) }
    }

    // Unused required delegates
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension MPCService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        
        let ctx = context.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        let mySessionID = self.discoveryInfo?["sessionID"] ?? "nil"
        
        DebugLog.shared.add("MPC", "inviteFrom=\(peerID.displayName) ctx=\(ctx) mySessionID=\(mySessionID)")
        
        if let context,
           let s = String(data: context, encoding: .utf8),
           let mySessionID = self.discoveryInfo?["sessionID"],
           s == mySessionID {
            DebugLog.shared.add("MPC", "accept invite")
            invitationHandler(true, session)
        } else {
            DebugLog.shared.add("MPC", "reject invite")
            invitationHandler(false, nil)
        }
    }
}

extension MPCService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            DebugLog.shared.add("MPC", "foundPeer=\(peerID.displayName) info=\(info ?? [:])")
            self.onFoundPeer?(peerID, info)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
