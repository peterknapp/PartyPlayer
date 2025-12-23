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

    func removeItem(withID id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if let c = cursorIndex {
            if index < c {
                cursorIndex = max(0, c - 1)
            } else if index == c {
                // Keep cursor pointing at the same numeric index, which now refers to what used to be the next item.
                if items.isEmpty {
                    cursorIndex = nil
                } else if index >= items.count {
                    cursorIndex = items.count - 1
                } else {
                    cursorIndex = index
                }
            }
        }
    }

    func moveItemToEnd(withID id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        items.append(item)
        if let c = cursorIndex {
            if index < c {
                cursorIndex = max(0, c - 1)
            } else if index == c {
                // Keep cursor pointing at the same numeric index so playback continues with what used to be the next item.
                if items.isEmpty {
                    cursorIndex = nil
                } else if c >= items.count {
                    cursorIndex = items.count - 1
                } else {
                    cursorIndex = c
                }
            }
        }
    }

    func appendItem(_ item: QueueItem) {
        items.append(item)
        if cursorIndex == nil {
            cursorIndex = 0
        }
    }

    func moveItemBehindCurrent(withID id: UUID) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        // Do not move the currently playing item via this API
        if let c = cursorIndex, from == c { return }

        let moving = items.remove(at: from)
        // Adjust cursor if removal was before current
        if let c = cursorIndex {
            if from < c {
                cursorIndex = max(0, c - 1)
            }
        }
        // Compute insert index directly behind current
        if let c2 = cursorIndex {
            let insertIndex = min(c2 + 1, items.count)
            items.insert(moving, at: insertIndex)
        } else {
            // No current -> put at start
            items.insert(moving, at: 0)
            if cursorIndex == nil { cursorIndex = 0 }
        }
    }
}
