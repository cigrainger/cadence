// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum SongLesson: String, Codable, CaseIterable, Identifiable, Sendable {
    case hear, changes, groove, arrange, independent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .hear: "Hear where home is"
        case .changes: "Make the changes flow"
        case .groove: "Give it a groove"
        case .arrange: "Make your own version"
        case .independent: "Take it somewhere new"
        }
    }
    public var goal: String {
        switch self {
        case .hear: "Hear → imagine → sing → play. Find the ending before seeing it."
        case .changes: "Find nearby chord tones. Keep shared notes and hear the movement."
        case .groove: "Play inside the pulse with accompaniment, then mute the guide."
        case .arrange: "Shape eight bars: melody, accompaniment, a contrast and a return."
        case .independent: "Return after time away. Try the idea in another piece without a guide."
        }
    }
    public var icon: String {
        switch self {
        case .hear: "ear"
        case .changes: "arrow.triangle.branch"
        case .groove: "metronome"
        case .arrange: "pencil.and.outline"
        case .independent: "sun.horizon"
        }
    }
}

/// Content and stable links only. Results stay in the canonical practice journal
/// and existing activity schedules; the course map never keeps a second gradebook.
public struct SongJourney: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var version = 1
    public var created: Date
    public var instrument: EditorInstrument
    public var material: ScoreEarMaterial
    public var transfer: ScoreEarMaterial
    public var compositionID = UUID()
    public var minutes = 15
    public init(
        material: ScoreEarMaterial, transfer: ScoreEarMaterial, instrument: EditorInstrument, now: Date = Date()
    ) {
        self.material = material
        self.transfer = transfer
        self.instrument = instrument
        created = now
    }
    public var valid: Bool {
        version == 1 && created.timeIntervalSince1970.isFinite && material.valid && transfer.valid
            && material.pieceID != transfer.pieceID && material.fingerprint != transfer.fingerprint
            && material.accompanimentIssue == nil && transfer.accompanimentIssue == nil
            && material.beats == Double(material.scope.throughBar - material.scope.fromBar + 1) * 4
            && transfer.beats == Double(transfer.scope.throughBar - transfer.scope.fromBar + 1) * 4
            && [10, 15, 25].contains(minutes)
    }
    /// Session duration is a preference, not an answer-key change.
    public func sameContent(as other: SongJourney) -> Bool {
        var copy = self
        copy.minutes = other.minutes
        return copy == other
    }
    public var openingID: String { "song-journey:\(id):opening" }
    public var explanationID: String { "song-journey:\(id):common-tone" }
    public var openingPrompt: VoicingPrompt { SmoothSession.focusPrompt(0) }

    public func arrangement(piece: LibraryPiece) throws -> EditorDocument {
        guard valid, material.isCurrent(in: piece) else {
            throw MusicError.invalid("Review the source again before making your arrangement.")
        }
        var document = try CreativeResponse(material: material, sessionID: id, now: created).makeDocument(piece: piece)
        guard document.instrument == instrument else {
            throw MusicError.invalid("Choose the same instrument as the source piece.")
        }
        document.id = compositionID
        document.title = String(("My version of “" + material.title + "”").prefix(120))
        // Share source spelling, meter, tuning, capo and provenance with every
        // creative answer. Extend its first phrase with space for a contrast.
        try document.insertBars(at: document.barCount, count: 8 - document.barCount)
        return try document.validated()
    }
}

public struct SongLessonEvidence: Equatable, Sendable {
    public var attempts: [PracticeAttempt]
    public var hasArtifact: Bool
    public var complete: Bool
    public init(attempts: [PracticeAttempt] = [], hasArtifact: Bool = false, complete: Bool = true) {
        self.attempts = attempts
        self.hasArtifact = hasArtifact
        self.complete = complete
    }
    public var latest: PracticeAttempt? { attempts.max { $0.date < $1.date } }
    public var independentSuccess: Bool {
        complete
            && (latest.map { $0.outcome == .correct && !$0.assisted && $0.input != .selfReport && $0.input != .choice }
                ?? false)
    }
    public var label: String {
        if hasArtifact { return "A version to keep" }
        guard let latest else { return "Ready to explore" }
        if latest.outcome == .skipped { return "Skipped · still open" }
        if latest.input == .selfReport { return "Explored · your report" }
        if latest.outcome == .incorrect { return "Give this some care" }
        if latest.assisted { return "With support" }
        if latest.input == .choice { return "On-screen check" }
        return complete ? "Checked independently" : "In progress"
    }
}

public struct SongSessionItem: Equatable, Identifiable, Sendable {
    public var lesson: SongLesson
    public var reason: String
    public var minutes: Int
    public var id: SongLesson { lesson }
    public init(lesson: SongLesson, reason: String, minutes: Int) {
        self.lesson = lesson
        self.reason = reason
        self.minutes = minutes
    }
}

/// A small inspectable policy. The adapters supply scoped observations, never a
/// fabricated mastery percentage. Artistic choices are reflected on, not scored.
public enum SongSessionPlanner {
    public static func session(
        minutes: Int, opening: SongLessonEvidence, evidence: [SongLesson: SongLessonEvidence],
        independentDue: Bool
    ) -> [SongSessionItem] {
        let focus: SongLesson
        let reason: String
        if independentDue {
            focus = .independent
            reason =
                "Time has passed. Try a different piece with the guide muted; this is separate from familiar practice."
        } else if opening.latest?.outcome == .incorrect,
            evidence[.changes]?.independentSuccess != true
                || (evidence[.changes]?.latest?.date ?? .distantPast) <= (opening.latest?.date ?? .distantPast)
        {
            focus = .changes
            reason = "The opening change was uncertain. Find its chord tones slowly, then return to the phrase."
        } else if let weak = [SongLesson.hear, .changes, .groove].first(where: {
            evidence[$0]?.latest.map { $0.outcome == .incorrect || $0.assisted } ?? false
        }) {
            focus = weak
            reason =
                weak == .groove
                ? "Your last pass needed care. Keep pitch and timing separate; slow down or tap the pulse, then rejoin the music."
                : "Your last attempt needed support. Try a smaller step, then return to the complete phrase."
        } else {
            focus = [SongLesson.hear, .changes, .groove].first { evidence[$0]?.independentSuccess != true } ?? .arrange
            reason =
                focus == .arrange
                ? "Use what you have explored in a musical choice of your own."
                : "A useful next step towards your own arrangement. Every chapter stays open."
        }
        let total = [10, 15, 25].contains(minutes) ? minutes : 15
        if focus == .arrange {
            return [.init(lesson: .arrange, reason: reason, minutes: total)]
        }
        return [
            .init(lesson: focus, reason: reason, minutes: max(3, total - 5)),
            .init(
                lesson: .arrange,
                reason: "Finish with a choice: change a rhythm, voicing or ending in your eight bars.",
                minutes: min(5, total - 3)),
        ]
    }
}

/// Original, redistributable examples. The eight-bar scores stay intact in the
/// library; bounded selections are only the activity's working material.
public enum SongJourneyExamples {
    public static func score(instrument: EditorInstrument, transfer: Bool = false) throws -> EditorDocument {
        let shift = transfer ? 5 : 0
        let roots = [0, 5, 7, 0, 9, 2, 7, 0]
        let pairs =
            transfer
            ? [[60, 64], [69, 65], [67, 62], [64, 60], [60, 64], [62, 65], [59, 62], [60, 60]]
            : [[64, 67], [65, 69], [62, 65], [64, 60], [64, 60], [65, 62], [62, 59], [60, 60]]
        var events: [EditorEvent] = []
        var harmonies: [EditorHarmony] = []
        for bar in 0..<8 {
            let root = Pitch.spelled((roots[bar] + shift) % 12, flats: transfer)
            harmonies.append(
                EditorHarmony(bar: bar, symbol: .init(root: root, kind: [4, 5].contains(bar) ? .minor : .major)))
            events += pairs[bar].map { note in
                let midi = note + shift - (instrument == .guitar ? 12 : 0)
                let position =
                    instrument == .guitar
                    ? Guitar.positions(midi: midi, tuning: Tuning.presets[0], capo: 0).min { $0.fret < $1.fret } : nil
                return EditorEvent(
                    bar: bar, rhythm: EditorRhythm(960),
                    pitches: [
                        EditorPitch(
                            midi,
                            spelling: Pitch.spelled(midi, flats: transfer), string: position?.string,
                            fret: position?.fret)
                    ])
            }
            if instrument == .piano { events.append(EditorEvent(bar: bar, staff: 2, rhythm: EditorRhythm(1920))) }
        }
        var document = EditorDocument(
            title: transfer ? "Another way home" : "A small beginning", instrument: instrument, events: events)
        document.barCount = 8
        document.tempo = 72
        document.fifths = transfer ? -1 : 0
        document.harmonies = harmonies
        return try document.validated()
    }
}
