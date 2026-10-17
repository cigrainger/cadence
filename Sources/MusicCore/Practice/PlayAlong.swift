// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum PlayAlongChallenge: String, Codable, CaseIterable, Sendable {
    case none = "Just practise"
    case notes = "Find the notes"
    case pulse = "Keep the pulse"
    case clean = "Clean pass"
    public var invitation: String {
        switch self {
        case .none: "Keep going. Each note gives you something useful for the next pass."
        case .notes: "Land at least 90% of the written pitches. Timing stays visible as a separate skill."
        case .pulse: "Place at least 80% of entrances on the beat. Pitch stays visible as a separate skill."
        case .clean: "Match every pitch and entrance, leaving the spaces between them quiet."
        }
    }
    public func met(by report: TimedReport, tolerance: Double) -> Bool {
        guard !report.notes.isEmpty else { return false }
        switch self {
        case .none: return false
        case .notes: return Double(report.matchedPitch) / Double(report.notes.count) >= 0.9 && report.extras.isEmpty
        case .pulse:
            return Double(report.timedEntrances(tolerance: tolerance)) / Double(report.notes.count) >= 0.8
                && report.extras.isEmpty
        case .clean: return report.clean
        }
    }
}
extension TimedReport {
    /// Timing of an entrance is independent of its pitch verdict.
    public func timedEntrances(tolerance: Double) -> Int {
        notes.filter { $0.delta.map { abs($0) <= tolerance + 0.000001 } ?? false }.count
    }
}
public struct PlayAlongSetup: Codable, Equatable, Sendable {
    public var tempo = 80
    public var style = GrooveStyle.steady
    public var piano = true
    public var bass = true
    public var drums = true
    public var guide = false
    public var challenge = PlayAlongChallenge.none
    public init() {}
    public var valid: Bool { (50...160).contains(tempo) }
    public var options: GrooveArrangement {
        .init(tempo: Double(tempo), style: style, loops: 1, piano: piano, bass: bass, drums: drums)
    }
}
public struct PlayAlongPlan: Codable, Equatable, Sendable {
    public var material: ScoreEarMaterial
    public var sourceStart: Double
    public var setup: PlayAlongSetup
    public init(material: ScoreEarMaterial, sourceStart: Double, setup: PlayAlongSetup) throws {
        self.material = material
        self.sourceStart = sourceStart
        self.setup = setup
        guard valid else {
            throw MusicError.invalid(
                "Choose a reviewed melody of 1–4 complete 4/4 bars with written chords, at 50–160 bpm.")
        }
    }
    public var valid: Bool {
        material.valid && material.accompanimentIssue == nil && setup.valid && sourceStart.isFinite && sourceStart >= 0
            && abs(material.beats - Double(material.scope.throughBar - material.scope.fromBar + 1) * 4) < 0.00001
            && timed.valid
    }
    public var timed: TimedPracticePlan { TimedPracticePlan(playAlong: self) }
    public var accompaniment: ScoreAccompaniment {
        .init(material: material, options: setup.options, includeMelody: setup.guide)
    }
    public func identity(offsetMS: Int) -> String {
        // Challenge choice changes the invitation, never creates another review card.
        "play-along:"
            + ScoreRevision.digest(
                "v1|\(material.id)|\(setup.tempo)|\(setup.style.rawValue)|\(setup.piano)|\(setup.bass)|\(setup.drums)|\(setup.guide)|\(offsetMS)"
            )
    }
}
extension TimedPracticePlan {
    fileprivate init(playAlong plan: PlayAlongPlan) {
        let material = plan.material
        title = material.title
        rhythmID = nil
        tempo = plan.setup.tempo
        beatsPerBar = 4
        length = material.beats
        let scope = PassageScope(
            partID: material.scope.partID, staff: material.staff, from: material.scope.fromBar - 1,
            through: material.scope.throughBar - 1)
        source = TimedSource(
            studyID: UUID(uuidString: String(material.pieceID.split(separator: ":").last ?? "")) ?? UUID(
                uuidString: "00000000-0000-0000-0000-000000000000")!, pieceID: material.pieceID,
            fingerprint: material.fingerprint, scope: scope, startBeat: plan.sourceStart)
        targets = material.melody.map {
            TimedTarget(beat: $0.start, bar: material.scope.fromBar - 1 + Int(max(0, $0.start) / 4), pitch: $0.midi)
        }
    }
}
public struct PlayAlongResult: Codable, Equatable, Sendable {
    public var plan: PlayAlongPlan
    public var pass: TimedPracticeResult
    public init(plan: PlayAlongPlan, pass: TimedPracticeResult) {
        self.plan = plan
        self.pass = pass
    }
    public var practiceID: String { plan.identity(offsetMS: pass.conditions.offsetMS) }
    public var valid: Bool {
        plan.valid && pass.valid && pass.plan == plan.timed && pass.conditions.input == .midi && !pass.conditions.click
    }
    public var assisted: Bool { plan.setup.guide || pass.attacks.contains(where: \.arrivalTimestamp) }
    public var grade: ReviewGrade { !valid || !pass.report.clean ? .again : assisted ? .supported : .good }
    public var evidence: String {
        let r = pass.report
        return
            "Play-along, \(plan.material.label), \(plan.setup.tempo) bpm; \(plan.setup.style.rawValue); guide \(plan.setup.guide ? "on" : "off"), piano \(plan.setup.piano), bass \(plan.setup.bass), drums \(plan.setup.drums), offset \(pass.conditions.offsetMS) ms: \(r.matchedPitch)/\(r.notes.count) pitches, \(r.timedEntrances(tolerance:pass.plan.tolerance))/\(r.notes.count) entrances on time, \(r.extras.count) extra presses. Timing tolerance ±\(Int((pass.plan.tolerance*1000).rounded())) ms. \(assisted ? "Supported timing/guide conditions." : "Guide melody muted.") Durations, pedal, dynamics and technique ungraded."
    }
}
public struct PlayAlongProgress: Codable, Equatable, Sendable {
    public var latest: PlayAlongResult
    public var review = ReviewSchedule()
    public init(result: PlayAlongResult) { latest = result }
}
public struct LiveTimedNote: Equatable, Sendable {
    public var assessment: TimedAssessment
    public var settled: Bool
    public init(assessment: TimedAssessment, settled: Bool) {
        self.assessment = assessment
        self.settled = settled
    }
}
extension TimedMatcher {
    /// A small delivery grace keeps a late native callback from becoming a premature miss.
    /// Provisional hits can improve until their disjoint window closes; final grading
    /// still runs over the original timestamps after the complete passage.
    public static func live(_ plan: TimedPracticePlan, attacks: [TimedAttack], elapsed: Double, offsetMS: Int)
        -> [LiveTimedNote]
    {
        guard elapsed.isFinite, let report = try? assess(plan, attacks: attacks) else { return [] }
        let corrected = elapsed - Double(offsetMS) / 1000
        return report.notes.compactMap { note in
            let settled =
                corrected >= note.target.beat * plan.secondsPerBeat + windowRadius(plan, beat: note.target.beat) + 0.12
            guard settled || note.attack != nil else { return nil }
            return LiveTimedNote(assessment: note, settled: settled)
        }
    }
}
