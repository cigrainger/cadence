// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// These are audible practice conditions, never a claim of independent learning.
public enum FlowPulse: String, Codable, CaseIterable, Sendable {
    case beats = "Every beat"
    case bars = "First beat of each bar"
    case gaps = "Alternate bar starts"
    case off = "Count-in only"
    public var click: Bool { self != .off }
    public var next: Self? {
        switch self {
        case .beats: .bars
        case .bars: .gaps
        case .gaps: .off
        case .off: nil
        }
    }
    public func sounds(at beat: Int, beatsPerBar: Int) -> Bool {
        guard beat >= 0, beatsPerBar > 0 else { return false }
        switch self {
        case .beats: return true
        case .bars: return beat % beatsPerBar == 0
        case .gaps: return beat % beatsPerBar == 0 && (beat / beatsPerBar) % 2 == 0
        case .off: return false
        }
    }
}

public struct FlowSettings: Codable, Equatable, Sendable {
    /// Canonical source at the opening tempo. The performed tempo is separate.
    public var plan: TimedPracticePlan
    public var tempo: Int
    public var pulse: FlowPulse
    public var partner: Bool
    public init(plan: TimedPracticePlan, tempo: Int, pulse: FlowPulse = .beats, partner: Bool = true) {
        self.plan = plan
        self.tempo = tempo
        self.pulse = pulse
        self.partner = partner
    }
    public func valid(in opening: TimedPracticePlan) -> Bool {
        FlowPractice.contains(plan, in: opening) && (40...opening.tempo).contains(tempo)
            && (try? PieceRehearsal.exercisePlan(plan, exercise: .notes, tempo: tempo)) != nil
    }
}

public enum FlowReflection: String, Codable, CaseIterable, Sendable {
    case easier = "Easier and more intentional"
    case mixed = "Some parts felt easier"
    case effortful =
        "Still takes concentration"
}

public struct FlowJoin: Identifiable, Equatable, Sendable {
    public var bar: Int
    public var plan: TimedPracticePlan
    public var reason: String
    public var id: Int { bar }
    public var title: String { "Join bars \(bar) → \(bar+1)" }
}

public struct FlowAdvice: Equatable, Sendable {
    public var title: String
    public var reason: String
    public var settings: FlowSettings?
}

public enum FlowPractice {
    /// Verify a subphrase against its parent targets, not merely its source ID.
    public static func contains(_ plan: TimedPracticePlan, in opening: TimedPracticePlan) -> Bool {
        guard plan.valid, opening.valid, let p = plan.source, let o = opening.source,
            p.pieceID == o.pieceID, p.fingerprint == o.fingerprint, p.studyID == o.studyID,
            p.scope.partID == o.scope.partID, p.scope.staff == o.scope.staff,
            p.scope.from >= o.scope.from, p.scope.through <= o.scope.through,
            plan.tempo == opening.tempo, plan.handStaves == opening.handStaves, plan.beatsPerBar == opening.beatsPerBar
        else { return false }
        let offset = p.startBeat - o.startBeat
        let barLength = Double(plan.beatsPerBar)
        // Sparse clicks promise written bar starts. Keep this first version to
        // complete regular bars; a pickup must be outside the selected phrase.
        guard abs(opening.length - Double(o.scope.through - o.scope.from + 1) * barLength) < 0.00001,
            abs(plan.length - Double(p.scope.through - p.scope.from + 1) * barLength) < 0.00001,
            abs(offset - Double(p.scope.from - o.scope.from) * barLength) < 0.00001,
            offset >= 0, offset + plan.length <= opening.length + 0.00001
        else { return false }
        let expected = opening.targets.filter { (p.scope.from...p.scope.through).contains($0.bar) }.map {
            target -> TimedTarget in
            var target = target
            target.beat -= offset
            return target
        }
        return expected == plan.targets
    }

    /// Include both sides of a barline, expanding only as needed for complete
    /// ties and supported two-staff material. Never invent a hand-position cause.
    public static func joins(piece: LibraryPiece, record: PieceRehearsal) throws -> [FlowJoin] {
        guard let scope = record.opening.source?.scope, scope.from < scope.through else { return [] }
        var joins: [FlowJoin] = []
        for bar in (scope.from + 1)...scope.through {
            var found: TimedPracticePlan?
            search: for length in 2...(scope.through - scope.from + 1) {
                let first = max(scope.from, bar - length + 1)
                let last = min(bar - 1, scope.through - length + 1)
                guard first <= last else { continue }
                for start in first...last {
                    let candidate = PassageScope(
                        partID: scope.partID, staff: scope.staff, from: start, through: start + length - 1)
                    if let plan = try? RehearsalSource.plan(piece, scope: candidate, tempo: record.opening.tempo),
                        contains(plan, in: record.opening)
                    {
                        found = plan
                        break search
                    }
                }
            }
            if let plan = found {
                let notes = record.openingResult?.report.notes.filter { $0.target.bar == bar } ?? []
                let first = notes.map(\.target.beat).min()
                let entrance = notes.filter { $0.target.beat == first }
                let reason: String
                if entrance.contains(where: { $0.verdict == .late }) {
                    reason =
                        "The first entrance in bar \(bar+1) was late in the opening pass. Include the lead-in and keep moving across the barline."
                } else if entrance.contains(where: { $0.verdict == .missed || $0.verdict == .wrongPitch }) {
                    reason =
                        "The first entrance in bar \(bar+1) had missing or different pitches in the opening pass. Try it with the bar before it."
                } else if entrance.contains(where: { $0.verdict == .early }) {
                    reason =
                        "The first entrance in bar \(bar+1) was early in the opening pass. Give the preceding bar its full time."
                } else {
                    reason =
                        "Carry the pulse from bar \(bar) into bar \(bar+1). This is an exploration, not a detected technique problem."
                }
                joins.append(.init(bar: bar, plan: plan, reason: reason))
            }
        }
        func difficulty(_ join: FlowJoin) -> Int {
            let notes = record.openingResult?.report.notes.filter { $0.target.bar == join.bar } ?? []
            let first = notes.map(\.target.beat).min()
            return notes.filter { $0.target.beat == first && $0.verdict != .onTime }.count
        }
        return joins.sorted { difficulty($0) == difficulty($1) ? $0.bar < $1.bar : difficulty($0) > difficulty($1) }
    }

    /// A transparent authored suggestion. Two recent comparable passes are
    /// required, using consecutive saved attempts with the same conditions.
    public static func advice(_ record: PieceRehearsal, exercise: RehearsalExercise, now: Date = Date()) -> FlowAdvice {
        guard let settings = record.flow, record.stage == .focus else {
            return .init(title: "Explore a join", reason: "Choose Make it flow during focused practice.", settings: nil)
        }
        let matching = record.focusResults.reversed().prefix { result in
            result.exercise == exercise && result.flowSource == settings.plan
                && result.pass.plan.tempo == settings.tempo && result.pass.conditions.flowPulse == settings.pulse
                && result.pass.conditions.partnerStaff
                    == (settings.partner ? PianoHands.partner(in: settings.plan, exercise: exercise) : nil)
                && result.pass.date <= now && now.timeIntervalSince(result.pass.date) <= 24 * 3600
        }
        let recent = Array(matching.prefix(2))
        guard recent.count == 2,
            recent.allSatisfy({
                !$0.pass.attacks.contains(where: \.arrivalTimestamp) && $0.pass.plan.onsetBeats.count >= 3
            }),
            recent[0].pass.conditions == recent[1].pass.conditions
        else {
            return .init(
                title: "Give this setting two passes",
                reason:
                    "Keep the same passage, exercise, tempo and support. Suggestions use recent MIDI timing; you can change any setting yourself.",
                settings: nil)
        }
        func fraction(_ pass: TimedPracticeResult) -> Double {
            // Count entrances, so a dense chord does not outweigh a melody note.
            let groups = Dictionary(grouping: pass.report.notes, by: { $0.target.beat })
            return Double(groups.values.filter { $0.allSatisfy { $0.verdict == .onTime } }.count)
                / Double(max(1, groups.count))
        }
        var next = settings
        if recent.allSatisfy({ fraction($0.pass) >= 0.8 && $0.pass.report.extras.count <= 1 }) {
            if settings.tempo < record.opening.tempo {
                next.tempo = min(record.opening.tempo, settings.tempo + 5)
                guard next.valid(in: record.opening) else {
                    return .init(
                        title: "Keep this pace",
                        reason:
                            "A faster pass would exceed the supported entrance spacing. You can explore less support instead.",
                        settings: nil)
                }
                return .init(
                    title: "Try \(next.tempo) bpm",
                    reason:
                        "At least four in five entrances were on time in both recent passes. Try five bpm more if it feels comfortable.",
                    settings: next)
            }
            if exercise.isHand && settings.partner {
                next.partner = false
                return .init(
                    title: "Try without the partner",
                    reason:
                        "Both recent passes were steady at your opening tempo. Imagine the other part while you play yours.",
                    settings: next)
            }
            if let pulse = settings.pulse.next {
                if pulse == .gaps && settings.plan.length <= Double(settings.plan.beatsPerBar) {
                    next.pulse = .off
                } else {
                    next.pulse = pulse
                }
                return .init(
                    title: "Try less click",
                    reason:
                        "Both recent passes were steady. Next: \(next.pulse.rawValue.lowercased()). Carry the pulse through the quiet spaces.",
                    settings: next)
            }
            return .init(
                title: "Bring it back into the music",
                reason:
                    "You have two steady passes with just a count-in. Try the surrounding phrase, then listen to your take. This is practice evidence, not a mastery score.",
                settings: nil)
        }
        if recent.allSatisfy({ fraction($0.pass) < 0.6 || $0.pass.report.extras.count > 2 }) {
            if settings.tempo > 40 {
                next.tempo = max(40, settings.tempo - 5)
                if next.valid(in: record.opening) {
                    return .init(
                        title: "Give it more room · \(next.tempo) bpm",
                        reason:
                            "Several entrances were missed, different or outside the timing window in both passes. Try five bpm slower, or choose a smaller join.",
                        settings: next)
                }
            }
            if settings.pulse != .beats {
                next.pulse = .beats
                return .init(
                    title: "Bring back the beat",
                    reason: "Both recent passes were uneven. Restore the click for a while, or choose a smaller join.",
                    settings: next)
            }
        }
        return .init(
            title: "Stay here if it helps",
            reason:
                "The two passes were mixed. Repeat at this pace, choose another join or return to the phrase whenever you feel ready.",
            settings: nil)
    }
}
