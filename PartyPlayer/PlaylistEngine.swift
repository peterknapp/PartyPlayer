import Foundation

actor PlaylistEngine {
    private(set) var items: [QueueItem] = []
    private(set) var cursorIndex: Int? = nil

    // Load initial items and set cursor to first if available
    func loadInitial(_ items: [QueueItem]) {
        self.items = items
        self.cursorIndex = items.isEmpty ? nil : 0
    }

    func itemsSnapshot() -> [QueueItem] {
        return items
    }

    func current() -> QueueItem? {
        guard let idx = cursorIndex, items.indices.contains(idx) else { return nil }
        return items[idx]
    }

    func next() -> QueueItem? {
        guard let idx = cursorIndex else { return nil }
        let nextIdx = idx + 1
        guard items.indices.contains(nextIdx) else { return nil }
        cursorIndex = nextIdx
        return items[nextIdx]
    }
}
