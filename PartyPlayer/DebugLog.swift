import Foundation
import Combine

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let tag: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    func add(_ tag: String, _ message: String) {
        entries.append(Entry(time: Date(), tag: tag, message: message))
        // Keep last 200
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        print("[\(tag)] \(message)")
    }

    func clear() {
        entries.removeAll()
    }
}
