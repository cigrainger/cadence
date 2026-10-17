// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ReviewGrade: String, Codable, Sendable {
    case again, supported, good
    public var label: String {
        switch self {
        case .again: "Needs another look"
        case .supported: "With support"
        case .good: "Comfortable"
        }
    }
}
/// An intentionally simple local schedule, not a calibrated estimate of mastery.
/// One encounter advances at most once. Early practice never pushes reviews away.
public struct ReviewSchedule: Codable, Equatable, Sendable {
    public var encounters = 0
    public var difficult = 0
    public var intervalDays = 0
    public var due: Date?
    public var lastReview: Date?
    public var lastAdvance: Date?
    public var lastEpisode: UUID?
    public var lastGrade: ReviewGrade?
    public var lastInput: PracticeInput?
    public init() {}
    @discardableResult public mutating func record(
        _ grade: ReviewGrade, episode: UUID, input: PracticeInput, now: Date = Date()
    ) -> Bool {
        if episode == lastEpisode {
            // A later miss can shorten a supported encounter, but a retry can
            // never turn the same encounter into a clean recall.
            guard grade == .again && lastGrade != .again else { return false }
            difficult += 1
            intervalDays = 0
            lastGrade = .again
            lastInput = input
            lastReview = now
            due = min(due ?? now.addingTimeInterval(600), now.addingTimeInterval(600))
            return true
        }
        let eligible =
            (due == nil || due! <= now) && (lastAdvance == nil || now.timeIntervalSince(lastAdvance!) >= 20 * 3600)
        encounters += 1
        lastReview = now
        lastEpisode = episode
        lastGrade = grade
        lastInput = input
        switch grade {
        case .again:
            difficult += 1
            intervalDays = 0
            due = now.addingTimeInterval(10 * 60)
        case .supported:
            intervalDays = 0
            due = now.addingTimeInterval(20 * 60)
        case .good:
            if eligible {
                intervalDays = [1, 3, 7, 14, 30, 60].first { $0 > intervalDays } ?? 60
                due = now.addingTimeInterval(Double(intervalDays) * 86400)
                lastAdvance = now
            } else if due == nil || due! <= now {
                due = max(now.addingTimeInterval(3600), (lastAdvance ?? now).addingTimeInterval(86400))
            }
        }
        return true
    }
    public var valid: Bool {
        encounters >= 0 && encounters <= 1_000_000 && difficult >= 0 && difficult <= encounters
            && [0, 1, 3, 7, 14, 30, 60].contains(intervalDays)
            && [due, lastReview, lastAdvance].compactMap { $0 }.allSatisfy { $0.timeIntervalSince1970.isFinite }
    }
    public func reason(now: Date = Date()) -> String {
        guard encounters > 0, let due else { return "New · a small step into this passage" }
        let basis = lastInput == .selfReport ? "Your report" : "Your last check"
        if due <= now {
            switch lastGrade {
            case .again: return basis + " suggested another look"
            case .supported: return basis + " used support; try recalling it again"
            default: return "Spaced review · see what has stayed with you"
            }
        }
        if lastGrade == .again {
            return "Try a smaller step · review " + due.formatted(date: .abbreviated, time: .shortened)
        }
        return "Next review " + due.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Compatibility name for saved piece pathways. Both practice modes use the same policy.
public typealias PieceReview = ReviewSchedule

public enum ReviewQueue {
    public static func ordered<Item>(
        _ items: [Item], now: Date = Date(), review: (Item) -> ReviewSchedule, order: (Item, Item) -> Bool
    ) -> [Item] {
        let due = items.filter { review($0).due.map { $0 <= now } ?? false }.sorted { a, b in
            let x = review(a)
            let y = review(b)
            if (x.lastGrade == .again) != (y.lastGrade == .again) { return x.lastGrade == .again }
            if x.due != y.due { return (x.due ?? .distantPast) < (y.due ?? .distantPast) }
            return order(a, b)
        }
        let fresh = items.filter { review($0).encounters == 0 && review($0).due == nil }.sorted(by: order)
        return Array(due.prefix(2)) + Array(fresh.prefix(1)) + Array(due.dropFirst(2)) + Array(fresh.dropFirst())
    }
}
