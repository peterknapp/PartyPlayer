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
    case searchRequest(SearchRequest)
    case searchResults(SearchResults)
    case addSongRequest(AddSongRequest)

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
        // Optional map: itemID -> remaining seconds for the requesting member
        var cooldowns: [UUID: Double]? = nil
        // Optional: remaining concurrent action slots for the requesting member
        var remainingActionSlots: Int? = nil
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
    }
    
    struct MinimalSongPreview: Codable, Identifiable, Equatable {
        var id: String
        var title: String
        var artist: String
        var artworkURL: String?
    }
    
    struct SearchRequest: Codable {
        var requestID: UUID
        var term: String
        var memberID: MemberID
    }
    
    struct SearchResults: Codable {
        var requestID: UUID
        var results: [MinimalSongPreview]
    }
    
    struct AddSongRequest: Codable {
        var memberID: MemberID
        var songID: String
        var preview: MinimalSongPreview?
        var requestedAt: Date
    }
}

final class PartyCodec {
    static func encode(_ msg: PartyMessage) throws -> Data {
        try JSONEncoder().encode(msg)
    }
    static func decode(_ data: Data) throws -> PartyMessage {
        try JSONDecoder().decode(PartyMessage.self, from: data)
    }
}

