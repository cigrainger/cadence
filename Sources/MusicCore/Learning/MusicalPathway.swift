// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum PathwayFocus: String, Codable, CaseIterable, Sendable {
    case balanced = "A little of everything"
    case fluency = "Smoother playing"
    case writing = "Writing my own music"
}
public struct MusicalPathway: Codable, Equatable, Identifiable, Sendable {
    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var courseID: UUID
        public var lessonID: UUID
        public var title: String
        public var role: Role
        public enum Role: String, Codable, Sendable {
            case discover = "Discover"
            case practise = "Play"
            case transfer = "Try somewhere new"
            case compose = "Make it yours"
        }
        public init(courseID: UUID, lessonID: UUID, title: String, role: Role) {
            self.courseID = courseID
            self.lessonID = lessonID
            self.title = title
            self.role = role
        }
    }
    public var id = UUID()
    public var recipe: String
    public var title: String
    public var goal: String
    public var steps: [Step]
    public var minutes = 15
    public var focus = PathwayFocus.balanced
    public var compositionID: UUID?
    public var compositionReflection = ""
    public var compositionReviewedFingerprint: String?
    public init(recipe: String, title: String, goal: String, steps: [Step]) {
        self.recipe = recipe
        self.title = title
        self.goal = goal
        self.steps = steps
    }
    public func validate(in library: CourseLibrary) throws {
        guard courseText(recipe, 100), courseText(title, 160), courseText(goal, 1500), [10, 15, 25].contains(minutes),
            (1...24).contains(steps.count), Set(steps.map(\.id)).count == steps.count,
            compositionReflection.count <= 3000,
            compositionReviewedFingerprint.map(ScoreRevision.valid) ?? true
        else { throw MusicError.invalid("This learning pathway has invalid settings.") }
        for step in steps {
            guard courseText(step.title, 160), let course = library.courses.first(where: { $0.id == step.courseID }),
                course.chapter.lessons.contains(where: { $0.id == step.lessonID })
            else { throw MusicError.invalid("A pathway lesson has lost its chapter link.") }
        }
    }
}
public struct PathwayObservation: Sendable {
    public var stepID: UUID
    public var ready: Bool
    public var introduced: Bool
    public var evidence: [CourseEvidence]
    public init(stepID: UUID, ready: Bool, introduced: Bool, evidence: [CourseEvidence]) {
        self.stepID = stepID
        self.ready = ready
        self.introduced = introduced
        self.evidence = evidence
    }
}
public struct PathwaySessionItem: Equatable, Identifiable, Sendable {
    public var id: UUID { stepID }
    public var stepID: UUID
    public var label: String
    public var reason: String
    public var minutes: Int
    public var evidenceID: String?
}
/// Reuses canonical practice reviews. A session is a recommendation, not a
/// separate result ledger, timer, mastery score or prerequisite gate.
public enum MusicalSessionPlanner {
    public static func session(pathway: MusicalPathway, observations: [PathwayObservation], now: Date = Date())
        -> [PathwaySessionItem]
    {
        let observations = Dictionary(observations.map { ($0.stepID, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [PathwaySessionItem] = []
        let evidence = pathway.steps.flatMap { step -> [(MusicalPathway.Step, CourseEvidence)] in
            guard let observation = observations[step.id], observation.ready else { return [] }
            return observation.evidence.filter {
                $0.lessonID == step.lessonID && $0.review.valid && $0.review.encounters > 0
                    && $0.date.timeIntervalSince1970.isFinite
            }.map { (step, $0) }
        }
        let due = ReviewQueue.ordered(evidence, now: now, review: { $0.1.review }) { $0.1.date < $1.1.date }
        if let (step, item) = due.first {
            result.append(
                .init(
                    stepID: step.id, label: item.timingOnlyDifficulty ? "Steady the transition" : "Bring it back",
                    reason: item.timingOnlyDifficulty
                        ? "Your notes matched, but some entrances were less steady. Count or tap first, then try the change slowly."
                        : item.review.reason(now: now), minutes: 4, evidenceID: item.practiceID))
        }
        let musical = pathway.steps.filter { $0.role != .compose }
        let next =
            musical.first { step in
                guard !result.contains(where: { $0.stepID == step.id }) else { return false }
                let o = observations[step.id]
                // An earlier reflection never approves changed notation. Only
                // evidence admitted above can move an assessed study forward.
                if o?.ready != true { return true }
                return o?.introduced != true && !evidence.contains { $0.0.id == step.id }
            }
            ?? musical.first { step in
                !result.contains(where: { $0.stepID == step.id }) && observations[step.id]?.ready == true
            }
        if let next {
            let ready = observations[next.id]?.ready == true
            result.append(
                .init(
                    stepID: next.id,
                    label: ready
                        ? (next.role == .transfer ? "Change the setting" : "A small next step")
                        : "Read, listen & review",
                    reason: ready
                        ? (next.role == .transfer
                            ? "Try the idea in a different key. Success here is recorded separately from the familiar example."
                            : "Continue toward your goal with a short, supported attempt. Hide the note names when you feel ready.")
                        : "Read the linked source and check the proposed exercise before using it for assessed practice.",
                    minutes: 6, evidenceID: nil))
        }
        if let compose = pathway.steps.first(where: { $0.role == .compose }) {
            result.append(
                .init(
                    stepID: compose.id, label: "Make something yours",
                    reason: pathway.focus == .writing
                        ? "Your focus is writing. Give your own phrase the largest part of this session."
                        : "Use one idea from today in your own four-bar phrase. Listen back and choose a change you like.",
                    minutes: 5, evidenceID: nil))
        }
        guard !result.isEmpty else { return [] }
        let weights = result.map {
            $0.label == "Make something yours" && pathway.focus == .writing
                ? 9 : ($0.label == "Make something yours" && pathway.focus == .fluency ? 3 : $0.minutes)
        }
        let total = weights.reduce(0, +)
        let budget = [10, 15, 25].contains(pathway.minutes) ? pathway.minutes : 15
        var remaining = budget
        for i in result.indices {
            result[i].minutes = i == result.count - 1 ? remaining : max(1, budget * weights[i] / total)
            remaining -= result[i].minutes
        }
        return result
    }
}
