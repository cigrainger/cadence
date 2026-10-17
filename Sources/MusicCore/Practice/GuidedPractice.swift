// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An untimed reading exercise. Attacks are exact sounding pitches; tied notes
/// are merged and previously held notes may continue across the next attack.
public struct GuidedStep: Equatable, Sendable {
    public var beat: Double
    public var bar: Int
    public var notes: [Int]
    public var carried: Set<Int>
}
public struct GuidedPassage: Equatable, Sendable {
    public var studyID: UUID
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PassageScope
    public var steps: [GuidedStep]
    public var accompaniment: [ScoreNote]
    public var tempo: Double
    public var end: Double
    public var id: String {
        "guided:"
            + ScoreRevision.digest(
                "\(pieceID)|\(fingerprint)|\(scope.partID)|\(scope.staff ?? 0)|\(scope.from)|\(scope.through)")
    }
    public init(study: MusicStudy, pieceID: String, fingerprint: String) throws {
        _ = try study.document.validated()
        guard PassageScope(study).isValid(in: study.document), !study.part.tabStaves.contains(study.staff ?? 0),
            ScoreRevision.valid(fingerprint), !pieceID.isEmpty, pieceID.count <= 100
        else {
            throw MusicError.invalid("Choose standard notation and a passage of up to 16 bars.")
        }
        self.studyID = study.id
        self.pieceID = pieceID
        self.fingerprint = fingerprint
        title = String(study.document.title.prefix(500))
        scope = PassageScope(study)
        tempo = study.document.tempo * study.speed
        end = study.end
        let notes = study.selectedNotes
        guard !notes.isEmpty, notes.count <= 512 else {
            throw MusicError.invalid("Choose a shorter passage containing 1–512 pitched notes.")
        }
        let onsets = notes.map { max(study.start, $0.start) }.sorted().reduce(into: [Double]()) { result, beat in
            if result.last.map({ abs($0 - beat) > 0.00001 }) ?? true { result.append(beat) }
        }
        steps = onsets.map { beat in
            let attacks = notes.filter { abs(max(study.start, $0.start) - beat) < 0.00001 }
            let carried = notes.filter { $0.start < beat - 0.00001 && $0.start + $0.duration > beat + 0.00001 }
            return GuidedStep(
                beat: beat, bar: study.selectedMeasures.last { $0.start <= beat + 0.00001 }!.index,
                notes: Array(Set(attacks.map(\.midi))).sorted(), carried: Set(carried.map(\.midi)))
        }
        guard steps.allSatisfy({ !$0.notes.isEmpty && $0.notes.count <= 10 }) else {
            throw MusicError.invalid("This passage needs more than ten simultaneous pitches. Choose one staff.")
        }
        accompaniment =
            study.staff == nil
            ? []
            : study.part.staves.filter { $0 != study.staff && !study.part.tabStaves.contains($0) }
                .flatMap { study.part.soundingNotes(staff: $0) }
    }
    public func otherHand(at index: Int) -> Score? {
        guard steps.indices.contains(index) else { return nil }
        let start = steps[index].beat
        let stop = index + 1 < steps.count ? steps[index + 1].beat : end
        let selected = accompaniment.filter { $0.start < stop - 0.00001 && $0.start + $0.duration > start + 0.00001 }
            .map { note -> ScoreNote in
                var copy = note
                copy.start = max(0, note.start - start)
                copy.duration = min(stop, note.start + note.duration) - max(start, note.start)
                return copy
            }
        return selected.isEmpty ? nil : Score(title: "Other hand", tempo: tempo, notes: selected)
    }
}

public enum GuidedInputResult: Equatable, Sendable {
    case ignored
    case correction(Int)
    case advanced, complete
}
public struct GuidedFollower: Sendable {
    public let plan: GuidedPassage
    public private(set) var index = 0
    public private(set) var waitingForRelease = false
    public private(set) var mistakes: [Int]
    public private(set) var hints: Set<Int> = []
    private var witnessed: Set<Int> = []
    private var physical: Set<Int> = []
    public var complete: Bool { index == plan.steps.count }
    public var current: GuidedStep? { complete ? nil : plan.steps[index] }
    public init(plan: GuidedPassage, held: Set<Int> = []) {
        self.plan = plan
        mistakes = Array(repeating: 0, count: plan.steps.count)
        resume(held: held)
    }
    public mutating func resume(held: Set<Int>) {
        physical = held
        witnessed = []
        waitingForRelease = !held.isEmpty
    }
    public mutating func hint() { if !complete { hints.insert(index) } }
    public mutating func receive(_ message: MIDIMessage, keyboard: MIDIKeyboardState) -> GuidedInputResult {
        defer { physical = keyboard.downNotes }
        if message == .reset {
            resume(held: keyboard.downNotes)
            return .ignored
        }
        if case .control(_, let number, _) = message, number == 120 || number == 123 {
            resume(held: keyboard.downNotes)
            return .ignored
        }
        guard let step = current else { return .ignored }
        if waitingForRelease {
            if keyboard.downNotes.isEmpty { waitingForRelease = false }
            return .ignored
        }
        let expected = Set(step.notes)
        let allowed = expected.union(step.carried)
        if case .noteOn(let channel, let note, let velocity) = message,
            (0...15).contains(channel), (0...127).contains(note), (1...127).contains(velocity), !physical.contains(note)
        {
            if !allowed.contains(note) {
                mistakes[index] = min(10000, mistakes[index] + 1)
                return .correction(note)
            }
            if expected.contains(note) { witnessed.insert(note) }
        }
        // All chord pitches must be physically down together. A repeated pitch
        // needs a new attack; sustain and duplicate note-on packets cannot advance.
        witnessed.formIntersection(keyboard.downNotes)
        guard expected.isSubset(of: witnessed), expected.isSubset(of: keyboard.downNotes),
            keyboard.downNotes.isSubset(of: allowed)
        else { return .ignored }
        index += 1
        witnessed = []
        return complete ? .complete : .advanced
    }
    public func result(id: UUID, date: Date = Date()) throws -> GuidedPassageResult {
        guard complete else { throw MusicError.invalid("Finish the passage before saving its result.") }
        return GuidedPassageResult(
            id: id, date: date, practiceID: plan.id, studyID: plan.studyID, pieceID: plan.pieceID,
            fingerprint: plan.fingerprint, title: plan.title, scope: plan.scope,
            steps: plan.steps.enumerated().map {
                GuidedStepResult(
                    bar: $0.element.bar, beat: $0.element.beat, target: $0.element.notes,
                    corrections: mistakes[$0.offset], hinted: hints.contains($0.offset))
            })
    }
}
public struct GuidedStepResult: Codable, Equatable, Sendable {
    public var bar: Int
    public var beat: Double
    public var target: [Int]
    public var corrections: Int
    public var hinted: Bool
}
public struct GuidedPassageResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var practiceID: String
    public var studyID: UUID
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PassageScope
    public var steps: [GuidedStepResult]
    public var corrections: Int { steps.reduce(0) { $0 + $1.corrections } }
    public var firstPass: Int { steps.filter { $0.corrections == 0 && !$0.hinted }.count }
    public var difficultBars: [Int] { Array(Set(steps.filter { $0.corrections > 0 || $0.hinted }.map(\.bar))).sorted() }
    public var grade: ReviewGrade { corrections > 0 ? .again : steps.contains(where: \.hinted) ? .supported : .good }
    public var valid: Bool {
        practiceID.hasPrefix("guided:") && practiceID.count == 71
            && ScoreRevision.valid(String(practiceID.dropFirst(7))) && ScoreRevision.valid(fingerprint)
            && !pieceID.isEmpty && pieceID.count <= 100 && title.count <= 500 && date.timeIntervalSince1970.isFinite
            && (0..<1000).contains(scope.from) && scope.through >= scope.from && scope.through - scope.from < 16
            && scope.partID.count <= 200 && (scope.staff.map { (1...16).contains($0) } ?? true)
            && (1...512).contains(steps.count)
            && steps.allSatisfy { step in
                (scope.from...scope.through).contains(step.bar) && step.beat.isFinite
                    && (0..<100000).contains(step.beat) && (1...10).contains(step.target.count)
                    && Set(step.target).count == step.target.count && step.target.allSatisfy { (0...127).contains($0) }
                    && (0...10000).contains(step.corrections)
            }
    }
    public var evidence: String {
        "Guided MIDI reading, \(scope.staff.map { "staff \($0)" } ?? "both staves"), bars \(scope.from + 1)–\(scope.through + 1): \(firstPass)/\(steps.count) attacks matched without correction or an extra hint; \(corrections) wrong-note presses. Bars needing another look: \(difficultBars.map { String($0 + 1) }.joined(separator: ", ")). Wait-for-me mode; rhythm, duration, fluency and physical technique were not graded."
    }
}
public struct GuidedPassageProgress: Codable, Equatable, Sendable {
    public var latest: GuidedPassageResult
    public var review = ReviewSchedule()
    public init(result: GuidedPassageResult) { latest = result }
}
