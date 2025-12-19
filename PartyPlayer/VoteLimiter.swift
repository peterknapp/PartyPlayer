import Foundation
import Combine

final class VoteLimiter {
    struct Window {
        var startedAt: Date
        var used: Int
    }

    private let windowSeconds: TimeInterval = 10 * 60
    private let maxActions = 5

    private var windows: [MemberID: Window] = [:]

    func canSpendAction(memberID: MemberID, now: Date = Date()) -> Bool {
        let w = currentWindow(memberID: memberID, now: now)
        return w.used < maxActions
    }

    func spendAction(memberID: MemberID, now: Date = Date()) -> Bool {
        var w = currentWindow(memberID: memberID, now: now)
        guard w.used < maxActions else { return false }
        w.used += 1
        windows[memberID] = w
        return true
    }

    private func currentWindow(memberID: MemberID, now: Date) -> Window {
        if var w = windows[memberID] {
            if now.timeIntervalSince(w.startedAt) >= windowSeconds {
                w = Window(startedAt: now, used: 0)
            }
            windows[memberID] = w
            return w
        } else {
            let w = Window(startedAt: now, used: 0)
            windows[memberID] = w
            return w
        }
    }

    // MARK: - Debug helpers

    func remainingWindowSeconds(memberID: MemberID, now: Date = Date()) -> TimeInterval {
        let w = currentWindow(memberID: memberID, now: now)
        let elapsed = now.timeIntervalSince(w.startedAt)
        let remaining = max(0, windowSeconds - elapsed)
        return remaining
    }

    func usedCount(memberID: MemberID, now: Date = Date()) -> Int {
        let w = currentWindow(memberID: memberID, now: now)
        return w.used
    }

    func windowResetAt(memberID: MemberID, now: Date = Date()) -> Date {
        let w = currentWindow(memberID: memberID, now: now)
        return w.startedAt.addingTimeInterval(windowSeconds)
    }

    func windowLengthSeconds() -> TimeInterval { windowSeconds }
    func maxActionsPerWindow() -> Int { maxActions }
}
