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

    /// Reorder upcoming items (items after the current cursor). If there is no current item, reorders the entire list.
    func reorderUpcoming(fromOffsets: IndexSet, toOffset: Int) {
        // Determine the base index for upcoming items: cursor+1, or 0 if no current
        let base = (cursorIndex ?? -1) + 1
        guard base >= 0 && base <= items.count else { return }
        // Map local (upcoming-slice) indices to global indices
        let fromGlobals = fromOffsets.map { base + $0 }.sorted()
        // Validate indices are within bounds and do not include the current index
        guard !fromGlobals.isEmpty else { return }
        if let c = cursorIndex, fromGlobals.contains(c) { return } // never move current
        // Extract moving elements (preserve original order)
        var moving: [QueueItem] = []
        for idx in fromGlobals.reversed() {
            guard items.indices.contains(idx) else { return }
            let element = items.remove(at: idx)
            moving.insert(element, at: 0)
        }
        // Compute global insertion target
        var target = base + toOffset
        // Adjust target for removed elements that were before the target
        let removedBeforeTarget = fromGlobals.filter { $0 < target }.count
        target -= removedBeforeTarget
        // Clamp target within valid bounds
        if target < base { target = base }
        if target > items.count { target = items.count }
        // Insert moved elements back
        items.insert(contentsOf: moving, at: target)
        // cursorIndex remains valid: we only moved items at or after `base`
    }
}
