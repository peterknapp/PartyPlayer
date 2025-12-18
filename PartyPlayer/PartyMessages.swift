import Foundation

enum PartyRole: String, Codable { case host, guest }

enum PartyMessage: Codable {
    case hello(Hello)
    case joinRequest(JoinRequest)
    case joinDecision(JoinDecision)
    case stateSnapshot(StateSnapshot)
    case vote(VoteMessage)
    case skipRequest(SkipRequest)
    case nowPlaying(NowPlayingPayload)

    struct Hello: Codable {
        var role: PartyRole
        var sessionID: String
        var displayName: String
    }

    struct JoinRequest: Codable {
        var sessionID: String
        var joinCode: String
        var memberID: MemberID
        var displayName: String
        var hasAppleMusic: Bool
        var location: LocationPayload?
    }

    struct JoinDecision: Codable {
        var accepted: Bool
        var reason: String?
        var assignedMemberID: MemberID
    }

    struct StateSnapshot: Codable {
        var state: PartyState
    }

    enum VoteDirection: String, Codable { case up, down }

    struct VoteMessage: Codable {
        var memberID: MemberID
        var itemID: UUID
        var direction: VoteDirection
        var timestamp: Date
    }

    struct SkipRequest: Codable {
        var memberID: MemberID
        var itemID: UUID
        var timestamp: Date
    }

    struct LocationPayload: Codable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        var timestamp: Date
    }
    
    struct NowPlayingPayload: Codable {
        var nowPlayingItemID: UUID?
        var title: String?
        var artist: String?
        var isPlaying: Bool
        var positionSeconds: Double
        var sentAt: Date
    }}

final class PartyCodec {
    static func encode(_ msg: PartyMessage) throws -> Data {
        try JSONEncoder().encode(msg)
    }
    static func decode(_ data: Data) throws -> PartyMessage {
        try JSONDecoder().decode(PartyMessage.self, from: data)
    }
}
