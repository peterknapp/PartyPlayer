import Foundation

struct GuestLocalState: Codable, Equatable {
    // Join context
    var lastSessionID: String?
    var lastJoinCode: String?
    var lastAdmittedAt: Date?

    // User preferences
    var displayName: String
    var hasAppleMusic: Bool
    var sendUpVotesEnabled: Bool
    var sendDownVotesEnabled: Bool

    static let empty = GuestLocalState(
        lastSessionID: nil,
        lastJoinCode: nil,
        lastAdmittedAt: nil,
        displayName: "",
        hasAppleMusic: false,
        sendUpVotesEnabled: true,
        sendDownVotesEnabled: true
    )
}

@MainActor
final class GuestLocalStateStore: ObservableObject {
    @Published var state: GuestLocalState { didSet { scheduleSave() } }

    private let defaults = UserDefaults.standard
    private let key = "pp_guestLocalState"
    private var pendingWorkItem: DispatchWorkItem?

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(GuestLocalState.self, from: data) {
            self.state = decoded
        } else {
            self.state = .empty
        }
    }

    private func scheduleSave() {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
