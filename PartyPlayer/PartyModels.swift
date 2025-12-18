import Foundation

typealias MemberID = UUID

struct Member: Codable, Hashable {
    var id: MemberID
    var displayName: String
    var isAdmitted: Bool
    var hasAppleMusic: Bool
    var lastSeen: Date
}

struct QueueItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var songID: String
    var title: String
    var artist: String
    var artworkURL: String?
    var durationSeconds: Double?
    var addedBy: MemberID
    var addedAt: Date

    var upVotes: Set<MemberID> = []
    var downVotes: Set<MemberID> = []
}

struct PartyState: Codable {
    var sessionID: String
    var hostName: String
    var createdAt: Date

    var nowPlayingItemID: UUID? = nil   // refers to QueueItem.id
    var queue: [QueueItem] = []
    var members: [Member] = []          // admitted guests only (host not counted)
}
