// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct ChangesStep: Equatable, Sendable {
    public let bar: Int
    public let tick: Int
    public let beatUnit: Int
    public let carried: Bool
    public let chord: ChordRealization
    public var position: String {
        "Bar \(bar+1) · beat " + String(format: "%.3g", 1 + Double(tick) * Double(beatUnit) / 1920)
            + (carried ? " · carried in" : "")
    }
}

/// A source selection is independent of pitched notes: chord-only lead sheets work too.
public struct ChangesSource: Sendable {
    public let piece: LibraryPiece
    public let from: Int
    public let through: Int
    public let partID: String
    public let harmonies: [EditorHarmony]
    private let units: [Int]
    private let lengths: [Int]
    public var staffs: [Int] { Array(Set(harmonies.filter { $0.bar <= through }.map(\.staff))).sorted() }
    public init(piece: LibraryPiece, from: Int, through: Int, partID: String? = nil) throws {
        self.piece = piece
        self.from = from
        self.through = through
        switch piece.source {
        case .score(let document):
            _ = try document.validated()
            self.partID = "P1"
            harmonies = document.harmonies
            units = Array(repeating: document.meter.unit, count: document.barCount)
            lengths = Array(repeating: document.meter.ticks, count: document.barCount)
        case .study(let study):
            _ = try study.document.validated()
            guard let part = study.document.parts.first(where: { $0.id == (partID ?? study.partID) }) else {
                throw MusicError.invalid("Choose a part containing chord symbols.")
            }
            self.partID = part.id
            harmonies = try HarmonyXML.decode(study.document.originalXML, partID: part.id)
            units = part.measures.map(\.beatUnit)
            lengths = part.measures.map { Int(($0.duration * 480).rounded()) }
        }
        guard from >= 0, through >= from, through < lengths.count, through - from < 16 else {
            throw MusicError.invalid("Choose a passage of 1–16 bars for Follow the changes.")
        }
        guard
            harmonies.allSatisfy({
                lengths.indices.contains($0.bar) && (0..<lengths[$0.bar]).contains($0.tick)
                    && (1...16).contains($0.staff) && $0.symbol.valid
            }), Set(harmonies.map { "\($0.bar):\($0.tick):\($0.staff)" }).count == harmonies.count
        else { throw MusicError.invalid("Review the positions of the chord symbols in this part.") }
        guard !staffs.isEmpty else {
            throw MusicError.invalid(
                "Add chord symbols in Compose, or choose a part with written changes. Cadence does not infer them from the notes."
            )
        }
    }
    public func plan(staff: Int) throws -> ChangesPlan {
        guard staffs.contains(staff) else { throw MusicError.invalid("Choose a staff with written chord symbols.") }
        let ordered = harmonies.filter { $0.staff == staff }.sorted { ($0.bar, $0.tick) < ($1.bar, $1.tick) }
        var selected = ordered.filter { (from...through).contains($0.bar) }
        if !selected.contains(where: { $0.bar == from && $0.tick == 0 }),
            let prior = ordered.last(where: { $0.bar < from })
        {
            selected.insert(prior, at: 0)
        }
        guard !selected.isEmpty, selected.count <= 64 else {
            throw MusicError.invalid("Choose a shorter passage with 1–64 chord changes.")
        }
        let steps = try selected.map { item in
            ChangesStep(
                bar: item.bar, tick: item.tick, beatUnit: units[item.bar], carried: item.bar < from,
                chord: try ChordRealization(item.symbol))
        }
        guard steps.contains(where: { $0.chord.symbol.kind != .none }) else {
            throw MusicError.invalid("This passage only contains N.C. There is no chord to practise.")
        }
        return ChangesPlan(
            title: piece.title, pieceID: piece.id, fingerprint: piece.fingerprint, from: from, through: through,
            partID: partID, staff: staff, steps: steps, barTicks: Array(lengths[from...through]),
            barUnits: Array(units[from...through]))
    }
}

public struct ChangesPlan: Equatable, Sendable {
    public let title: String
    public let pieceID: String?
    public let fingerprint: String?
    public let from: Int
    public let through: Int
    public let partID: String
    public let staff: Int
    public let steps: [ChangesStep]
    public let barTicks: [Int]
    public let barUnits: [Int]
    public var id: String {
        "changes:"
            + ScoreRevision.digest(
                [pieceID ?? "ii-v-i", fingerprint ?? "1", String(from), String(through), partID, String(staff)].joined(
                    separator: ":"))
    }
    public var playableIndices: [Int] { steps.indices.filter { steps[$0].chord.symbol.kind != .none } }
    public func targets(_ mode: ChangesMode) throws -> [ChangesTarget] {
        try playableIndices.map { try steps[$0].chord.target(mode) }
    }
    public static var example: Self {
        let symbols: [ChordSymbol] = [
            .init(root: Pitch(1), kind: .minorSeventh), .init(root: Pitch(4), kind: .dominant),
            .init(root: Pitch(0), kind: .majorSeventh),
        ]
        return Self(
            title: "A first ii–V–I in C major", pieceID: nil, fingerprint: nil, from: 0, through: 3, partID: "P1",
            staff: 1,
            steps: symbols.enumerated().map {
                ChangesStep(
                    bar: $0.offset, tick: 0, beatUnit: 4, carried: false, chord: try! ChordRealization($0.element))
            }, barTicks: [1920, 1920, 1920, 1920], barUnits: [4, 4, 4, 4])
    }
}

/// One episode advances only after a committed answer. Failed saves can be retried verbatim.
public struct ChangesPractice: Sendable {
    public let plan: ChangesPlan
    public let mode: ChangesMode
    public let episode = UUID()
    public private(set) var cursor = 0
    public private(set) var tries = 0
    public private(set) var assisted = false
    public private(set) var completed = 0
    public private(set) var misses = 0
    public private(set) var hinted = 0
    public let targets: [ChangesTarget]
    public init(plan: ChangesPlan, mode: ChangesMode) throws {
        self.plan = plan
        self.mode = mode
        targets = try plan.targets(mode)
    }
    public var finished: Bool { cursor == targets.count }
    public var stepIndex: Int { plan.playableIndices[min(cursor, targets.count - 1)] }
    public mutating func reveal() { assisted = true }
    public func answer(_ notes: [Int], date: Date = Date()) throws -> PracticeAttempt {
        guard !finished, !notes.isEmpty, notes.count <= 128, notes.allSatisfy({ (0...127).contains($0) }),
            tries < 100000
        else { throw MusicError.invalid("Start a new pass before answering again.") }
        let target = targets[cursor]
        let step = plan.steps[stepIndex]
        let correct = target.judge(notes).correct
        var attempt = PracticeAttempt(
            sessionID: episode, activityID: plan.id + ":" + mode.rawValue + ":\(stepIndex)",
            title: "\(step.chord.symbol.label) · \(mode.rawValue) · \(step.position) · staff \(plan.staff)",
            skills: ["Follow the changes", mode.rawValue], input: .midi,
            outcome: correct ? .correct : .incorrect, assisted: assisted, ordinal: tries + 1,
            selectedChoice:
                "Untimed chord-tone gesture; inversions and octave doublings accepted unless a slash bass is printed. No timing, pedal or technique grade.",
            keyPC: step.chord.symbol.root?.pc, played: notes, target: target.pianoVoicings().first ?? [], date: date)
        attempt.pieceID = plan.pieceID
        attempt.scoreFingerprint = plan.fingerprint
        return attempt
    }
    public mutating func accept(_ attempt: PracticeAttempt) throws {
        guard !finished, attempt == (try answer(attempt.played, date: attempt.date)).withID(attempt.id) else {
            throw MusicError.invalid("This answer no longer matches the current change.")
        }
        tries += 1
        if attempt.outcome == .correct {
            completed += 1
            if assisted { hinted += 1 }
            cursor += 1
            tries = 0
            assisted = false
        } else {
            misses += 1
        }
    }
}

extension PracticeAttempt {
    fileprivate func withID(_ id: UUID) -> Self {
        var copy = self
        copy.id = id
        return copy
    }
}
