import Foundation
import Combine

struct HostLocalState: Codable {
    var partyState: PartyState
    var joinCode: String
    var removedItems: [QueueItem]
    var pendingSuggestions: [PartyHostController.PendingSuggestion]
    var votingMode: PartyHostController.VotingMode
    var perItemCooldownMinutes: Int
    var suggestionCooldownSeconds: Int
    var voteThresholdPercent: Int
    var maxConcurrentActions: Int
    var adminCodeHash: String?
    var savedAt: Date
}

@MainActor
final class HostLocalStateStore: ObservableObject {
    @Published var state: HostLocalState? { didSet { scheduleSave() } }

    private let defaults = UserDefaults.standard
    private let key = "pp_hostLocalState"
    private var pendingWorkItem: DispatchWorkItem?

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(HostLocalState.self, from: data) {
            self.state = decoded
        } else {
            self.state = nil
        }
    }

    func update(from host: PartyHostController) {
        let snapshot = HostLocalState(
            partyState: host.state,
            joinCode: host.joinCode,
            removedItems: host.removedItems,
            pendingSuggestions: host.pendingSuggestions,
            votingMode: host.votingMode,
            perItemCooldownMinutes: host.perItemCooldownMinutes,
            suggestionCooldownSeconds: host.suggestionCooldownSeconds,
            voteThresholdPercent: host.voteThresholdPercent,
            maxConcurrentActions: host.maxConcurrentActions,
            adminCodeHash: host.adminCodeHash,
            savedAt: Date()
        )
        self.state = snapshot
    }

    func clear() {
        state = nil
    }

    private func scheduleSave() {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveNow() {
        guard let state else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
