// PerItemVoteLimiter.swift
// Limits voting to once per item per member within a cooldown window (default: 20 minutes)

import Foundation

struct PerItemVoteLimiter {
    private var cooldown: TimeInterval
    // last vote timestamp per item per member
    private var lastVoteAt: [MemberID: [UUID: Date]] = [:]

    init(cooldown: TimeInterval = 20 * 60) {
        self.cooldown = cooldown
    }

    mutating func setCooldown(minutes: Int) {
        self.cooldown = TimeInterval(max(0, minutes) * 60)
    }

    mutating func canSpend(memberID: MemberID, itemID: UUID, now: Date = Date()) -> Bool {
        let memberMap = lastVoteAt[memberID] ?? [:]
        if let last = memberMap[itemID] {
            return now.timeIntervalSince(last) >= cooldown
        }
        return true
    }

    mutating func spend(memberID: MemberID, itemID: UUID, now: Date = Date()) -> Bool {
        guard canSpend(memberID: memberID, itemID: itemID, now: now) else { return false }
        var memberMap = lastVoteAt[memberID] ?? [:]
        memberMap[itemID] = now
        lastVoteAt[memberID] = memberMap
        return true
    }

    mutating func clear(memberID: MemberID, itemID: UUID) {
        var memberMap = lastVoteAt[memberID] ?? [:]
        memberMap[itemID] = nil
        lastVoteAt[memberID] = memberMap
    }

    mutating func clearAll(for itemID: UUID) {
        for (member, var map) in lastVoteAt {
            map[itemID] = nil
            lastVoteAt[member] = map
        }
    }

    mutating func remainingCooldown(memberID: MemberID, itemID: UUID, now: Date = Date()) -> TimeInterval? {
        let memberMap = lastVoteAt[memberID] ?? [:]
        guard let last = memberMap[itemID] else { return nil }
        let elapsed = now.timeIntervalSince(last)
        let remaining = cooldown - elapsed
        return max(0, remaining)
    }

    mutating func nextAvailableDate(memberID: MemberID, itemID: UUID, now: Date = Date()) -> Date? {
        let memberMap = lastVoteAt[memberID] ?? [:]
        guard let last = memberMap[itemID] else { return nil }
        return last.addingTimeInterval(cooldown)
    }
}
