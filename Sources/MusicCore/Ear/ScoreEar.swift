// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An immutable, bounded selection. Rebuilding from the current score is required
/// before capture or grading; the fingerprint includes music and PDF page mapping.
public struct ScoreEarMaterial: Codable, Equatable, Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PieceScope
    public var staff: Int
    public var voice: String
    public var harmonyStaff: Int
    public var fifths: Int
    public var minor: Bool
    public var tempo: Double
    public var beats: Double
    public var melody: [ScoreNote]
    public var sourcePages: [Int]
    public var chords: [ScoreEarChord]
    public var accompanimentIssue: String?
    public var id: String {
        "score-ear:"
            + ScoreRevision.digest(
                [
                    pieceID, fingerprint, String(scope.fromBar), String(scope.throughBar), scope.partID, String(staff),
                    voice, String(harmonyStaff),
                ].joined(separator: "|"))
    }
    public var tonic: Pitch { ScoreKey.tonic(fifths: fifths, minor: minor) }
    public var referenceTonic: Int {
        let note = 12 * ((melody.first?.midi ?? 60) / 12) + tonic.pc
        return note > 127 ? note - 12 : note
    }
    public var tones: [SingingTone] {
        melody.map {
            ScoreKey.tone(midi: $0.midi, pitch: $0.spelling ?? Pitch.spelled($0.midi, flats: fifths < 0), tonic: tonic)
        }
    }
    public var label: String { "Bars \(scope.fromBar)–\(scope.throughBar) · staff \(staff) · voice \(voice)" }
    public var sourceLabel: String {
        sourcePages.isEmpty
            ? "Linked to the library score"
            : "Original PDF · " + sourcePages.map { "page \($0)" }.joined(separator: ", ")
    }
    public var valid: Bool {
        let identity = pieceID.split(separator: ":")
        guard identity.count == 2, ["score", "study"].contains(String(identity[0])),
            UUID(uuidString: String(identity[1])) != nil,
            ScoreRevision.valid(fingerprint), title.count <= 500, scope.valid, scope.throughBar - scope.fromBar < 4,
            (1...16).contains(staff), !voice.isEmpty, voice.count <= 100, (1...16).contains(harmonyStaff),
            (-7...7).contains(fifths), tempo.isFinite, (5...450).contains(tempo), beats.isFinite,
            (0.1...64).contains(beats),
            (1...12).contains(melody.count), (try? Score(tempo: 120, notes: melody).validated()) != nil
        else { return false }
        guard
            melody.allSatisfy({ note in
                note.midi >= 0 && note.start >= 0 && note.start + note.duration <= beats + 0.00001
                    && (note.spelling.map { $0.pc == mod(note.midi) } ?? false)
            }), zip(melody, melody.dropFirst()).allSatisfy({ $0.start + $0.duration <= $1.start + 0.00001 }),
            sourcePages.count <= 4, sourcePages.allSatisfy({ (1...1000).contains($0) }),
            chords.count <= 64, chords.allSatisfy({ $0.valid && $0.end <= beats + 0.00001 }),
            zip(chords, chords.dropFirst()).allSatisfy({ abs($0.end - $1.start) < 0.00001 }),
            (accompanimentIssue?.count ?? 0) <= 1000
        else { return false }
        return accompanimentIssue != nil
            || (!chords.isEmpty && chords[0].start == 0 && abs(chords.last!.end - beats) < 0.00001)
    }

    public static func study(piece: LibraryPiece, scope: PieceScope) throws -> MusicStudy {
        guard scope.valid, scope.throughBar - scope.fromBar < 4 else {
            throw MusicError.invalid("Choose 1–4 bars for a short ear-training passage.")
        }
        var study: MusicStudy
        switch piece.source {
        case .score(let score):
            study = try ComposePractice.make(score, from: scope.fromBar - 1, through: scope.throughBar - 1)
        case .study(let value): study = value
        }
        _ = try study.document.validated()
        guard study.document.parts.contains(where: { $0.id == scope.partID }) else {
            throw MusicError.invalid("This part is no longer in the score.")
        }
        study.selectPart(scope.partID)
        study.staff = nil
        guard scope.valid, scope.throughBar - scope.fromBar < 4, scope.throughBar <= study.part.measures.count else {
            throw MusicError.invalid("Choose 1–4 bars for a short ear-training passage.")
        }
        study.select(from: scope.fromBar - 1, through: scope.throughBar - 1)
        return study
    }
    public init(piece: LibraryPiece, scope: PieceScope, staff: Int, voice: String, harmonyStaff: Int = 1) throws {
        let study = try Self.study(piece: piece, scope: scope)
        self.pieceID = piece.id
        fingerprint = piece.fingerprint
        title = piece.title
        self.scope = scope
        self.staff = staff
        self.voice = voice
        self.harmonyStaff = harmonyStaff
        sourcePages = try ReviewedSource.pages(piece: piece, from: scope.fromBar - 1, through: scope.throughBar - 1)
        let bars = study.selectedMeasures
        guard let first = bars.first,
            bars.allSatisfy({
                $0.fifths == first.fifths && ($0.minor ?? false) == (first.minor ?? false)
                    && ($0.keyMode == nil || ["major", "minor", "ionian", "aeolian"].contains($0.keyMode!))
            })
        else { throw MusicError.invalid("Choose a passage in one major or minor key for movable-Do solfège.") }
        fifths = first.fifths
        minor = first.minor ?? false
        tempo = study.document.tempo
        beats = study.end - study.start
        let raw = study.part.sourceNotes(staff: staff).filter {
            $0.voice == voice && $0.midi >= 0 && $0.start < study.end && $0.start + $0.duration > study.start
        }.sorted { $0.start < $1.start }
        guard let start = raw.first, let end = raw.last, !start.tieStop, !end.tieStart else {
            throw MusicError.invalid("Choose a voice with notes, and include the complete ties at both passage edges.")
        }
        for (index, note) in raw.enumerated() {
            if note.tieStart {
                guard index + 1 < raw.count, raw[index + 1].tieStop, raw[index + 1].midi == note.midi,
                    abs(note.start + note.duration - raw[index + 1].start) < 0.00001
                else { throw MusicError.invalid("Review an incomplete or overlapping tie in this voice.") }
            }
            if note.tieStop {
                guard index > 0, raw[index - 1].tieStart, raw[index - 1].midi == note.midi,
                    abs(raw[index - 1].start + raw[index - 1].duration - note.start) < 0.00001
                else { throw MusicError.invalid("Review an incomplete tie in this voice.") }
            }
        }
        let passage = try PassageMelody(study: study, voice: SingingVoice(staff: staff, voice: voice))
        guard !passage.reducedChords else {
            throw MusicError.invalid(
                "This voice contains chords. Choose a single melodic voice; no notes will be silently removed.")
        }
        melody = passage.notes.map {
            ScoreNote(midi: $0.tone.midi, start: $0.start - study.start, duration: $0.duration, spelling: $0.tone.pitch)
        }
        guard (1...12).contains(melody.count),
            zip(melody, melody.dropFirst()).allSatisfy({ $0.start + $0.duration <= $1.start + 0.00001 })
        else {
            throw MusicError.invalid(
                "Choose a shorter, single-note melody with up to 12 attacks. Rests and complete ties are kept.")
        }
        chords = []
        accompanimentIssue = nil
        do {
            guard bars.allSatisfy({ $0.beats == 4 && $0.beatUnit == 4 && abs($0.duration - 4) < 0.00001 }) else {
                throw MusicError.invalid(
                    "Band accompaniment currently needs complete 4/4 bars. Ear training still works here.")
            }
            let plan = try ChangesSource(
                piece: piece, from: scope.fromBar - 1, through: scope.throughBar - 1, partID: scope.partID
            ).plan(staff: harmonyStaff)
            guard let initial = plan.steps.first,
                initial.carried || (initial.bar == scope.fromBar - 1 && initial.tick == 0)
            else {
                throw MusicError.invalid(
                    "Add a chord or N.C. at the start of this passage. Cadence does not guess missing harmony.")
            }
            for (index, step) in plan.steps.enumerated() {
                let start = step.carried ? 0 : Double(step.bar - (scope.fromBar - 1)) * 4 + Double(step.tick) / 480
                let end =
                    index + 1 < plan.steps.count
                    ? Double(plan.steps[index + 1].bar - (scope.fromBar - 1)) * 4 + Double(plan.steps[index + 1].tick)
                        / 480 : beats
                chords.append(.init(start: start, end: end, symbol: step.chord.symbol))
            }
        } catch {
            chords = []
            accompanimentIssue = error.localizedDescription
        }
        guard valid else {
            throw MusicError.invalid(
                "This passage cannot yet be used for ear training. Review its notes, key and voice, or choose a smaller selection."
            )
        }
    }
    /// Note IDs are generated during XML import; semantic equality must ignore them.
    public func isCurrent(in piece: LibraryPiece) -> Bool {
        guard piece.id == pieceID, piece.fingerprint == fingerprint,
            let fresh = try? Self(piece: piece, scope: scope, staff: staff, voice: voice, harmonyStaff: harmonyStaff)
        else { return false }
        var a = self
        var b = fresh
        a.title = ""
        b.title = ""
        a.scope.partName = ""
        b.scope.partName = ""
        for i in a.melody.indices { a.melody[i].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
        for i in b.melody.indices { b.melody[i].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
        return a == b
    }
}
public struct ScoreEarChord: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var symbol: ChordSymbol
    public var valid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && symbol.valid
            && (try? ChordRealization(symbol)) != nil
    }
}

/// Several library passages can remain in progress; old score revisions are kept
/// but never launched against new notes. Grades live in the shared journal/cards.
public struct ScoreEarPractice: Codable, Equatable, Sendable {
    public var sessions: [EarSession] = []
    public var selectedID: UUID?
    public init() {}
    public var active: EarSession? { sessions.first { $0.id == selectedID } }
    public func latest(_ materialID: String) -> EarSession? { sessions.last { $0.opening.material?.id == materialID } }
    public func returnDate(_ materialID: String) -> Date? {
        sessions.filter { $0.opening.material?.id == materialID }.flatMap {
            $0.events.map(\.date) + [$0.startedAt].compactMap { $0 }
        }.max()?.addingTimeInterval(20 * 3600)
    }
    public mutating func open(_ material: ScoreEarMaterial, now: Date = Date()) throws {
        if let previous = latest(material.id), try previous.projection().stage != .complete {
            selectedID = previous.id
            return
        }
        guard sessions.count < 200 else {
            throw MusicError.invalid(
                "The saved passage-session limit is reached. Existing sessions and progress are preserved.")
        }
        let due = returnDate(material.id)
        var session = EarSession(phrase: EarPhrase(material: material))
        session.startedAt = now
        session.returnReadyAt = due
        sessions.append(session)
        selectedID = session.id
        _ = try validated()
    }
    public func validated() throws -> Self {
        guard sessions.count <= 200, Set(sessions.map(\.id)).count == sessions.count,
            selectedID == nil || sessions.contains(where: { $0.id == selectedID })
        else { throw MusicError.invalid("Invalid saved passage sessions.") }
        var previous = Self()
        for session in sessions {
            guard let material = session.opening.material, material.valid, session.startedAt != nil,
                session.returnReadyAt == previous.returnDate(material.id),
                previous.latest(material.id).map({ (try? $0.projection().stage) == .complete }) ?? true
            else { throw MusicError.invalid("Invalid passage return history.") }
            _ = try session.projection()
            previous.sessions.append(session)
        }
        return self
    }
}
