// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum CoursePracticeMode: String, CaseIterable, Sendable {
    case listen = "Listen"
    case guided = "Wait for me"
    case timed = "Play in time"
    case recall = "Recall exercises"
    case apply =
        "Apply it"
}
public struct CourseEvidence: Equatable, Sendable, Identifiable {
    public var id: String { practiceID }
    public var lessonID: UUID
    public var practiceID: String
    public var mode: CoursePracticeMode
    public var date: Date
    public var review: ReviewSchedule
    public var summary: String
    public var timingOnlyDifficulty: Bool
    public init(
        lessonID: UUID, practiceID: String, mode: CoursePracticeMode, date: Date, review: ReviewSchedule,
        summary: String, timingOnlyDifficulty: Bool = false
    ) {
        self.lessonID = lessonID
        self.practiceID = practiceID
        self.mode = mode
        self.date = date
        self.review = review
        self.summary = summary
        self.timingOnlyDifficulty = timingOnlyDifficulty
    }
}
public struct CourseSuggestion: Equatable, Identifiable, Sendable {
    public var id: String { "\(lessonID):\(kind)" }
    public enum Kind: String, Sendable {
        case review = "Return"
        case new = "Explore"
        case apply = "Make music"
    }
    public var lessonID: UUID
    public var kind: Kind
    public var reason: String
    public var evidenceID: String?
}
public enum CourseSessionPlanner {
    /// A bounded, explainable suggestion list, not a mastery estimate or gate.
    /// Source eligibility is resolved first; changed/unreviewed scores contribute no evidence.
    public static func suggestions(
        chapter: CourseChapter, ready: Set<UUID>, introduced: Set<UUID>, evidence: [CourseEvidence], now: Date = Date()
    ) -> [CourseSuggestion] {
        guard chapter.reviewed else { return [] }
        let ids = Set(chapter.lessons.map(\.id))
        let current = evidence.filter {
            ready.contains($0.lessonID) && ids.contains($0.lessonID) && $0.review.valid && $0.review.encounters > 0
                && $0.date.timeIntervalSince1970.isFinite
        }
        var result: [CourseSuggestion] = []
        let due = ReviewQueue.ordered(current, now: now, review: { $0.review }) { $0.date < $1.date }
        if let first = due.first {
            let reason =
                first.timingOnlyDifficulty
                ? "The notes matched in your last timed pass, while the entrances were less steady. Revisit the rhythm slowly; keep this distinct from pitch reading."
                : first.review.reason(now: now)
            result.append(.init(lessonID: first.lessonID, kind: .review, reason: reason, evidenceID: first.practiceID))
        }
        let seen = introduced.union(current.map(\.lessonID))
        let unread = chapter.lessons.filter { !seen.contains($0.id) }
        if let next = unread.first(where: { Set($0.prerequisites).isSubset(of: seen) }) ?? unread.first {
            let missing = next.prerequisites.filter { !seen.contains($0) }
            result.append(
                .init(
                    lessonID: next.id, kind: .new,
                    reason: missing.isEmpty
                        ? "A small new step in the chapter's sequence."
                        : "You can open this now. Its earlier lesson is a useful starting point if it feels unfamiliar.",
                    evidenceID: nil))
        }
        if let played = current.filter({ $0.review.lastGrade != .again }).sorted(by: { $0.date > $1.date }).first,
            !result.contains(where: { $0.lessonID == played.lessonID })
        {
            result.append(
                .init(
                    lessonID: played.lessonID, kind: .apply,
                    reason:
                        "Use the idea in a small variation. This is an invitation to apply it, not evidence of transfer until you try and reflect.",
                    evidenceID: nil))
        }
        return Array(result.prefix(3))
    }
}
