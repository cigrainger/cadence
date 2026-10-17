// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum PieceTaskKind: String, Codable, CaseIterable, Sendable {
    case passage = "Play a passage"
    case signature = "Key signature"
    case reading = "Note reading"
    case interval =
        "Hear an interval"
    case rhythm = "Rhythm values"
    case chord = "Play the chord"
}
public struct PieceTask: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var stage: Int
    public var kind: PieceTaskKind
    public var title: String
    public var instructions: String
    public var readyWhen: String
    public var scope: PieceScope
    public var choices: [String] = []
    public var answer: Int? = nil
    public var explanation = ""
    public var audio: Score? = nil
    public var target: [Int] = []
    public var review = PieceReview()
    public var needsAudio: Bool { kind == .interval }
    public var isChecked: Bool { kind != .passage }
    public var skill: String { kind.rawValue }
    public func chordMatches(_ played: [Int]) -> Bool {
        guard kind == .chord, let bass = target.min(), let heard = played.min(),
            played.allSatisfy({ (0...127).contains($0) })
        else { return false }
        return Set(played.map { mod($0) }) == Set(target.map { mod($0) }) && mod(bass) == mod(heard)
    }
    public func validated(scope parent: PieceScope, stepCount: Int) throws -> Self {
        guard (0..<stepCount).contains(stage), scope.valid, scope.partID == parent.partID,
            scope.fromBar >= parent.fromBar, scope.throughBar <= parent.throughBar,
            !title.isEmpty, title.count <= 200, !instructions.isEmpty, instructions.count <= 3000,
            readyWhen.count <= 1000, explanation.count <= 2000,
            choices.count <= 8, choices.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
            Set(choices).count == choices.count,
            target.count <= 16, target.allSatisfy({ (0...127).contains($0) }), review.valid
        else { throw MusicError.invalid("This pathway has an invalid exercise or passage link.") }
        if kind == .chord {
            guard Set(target.map { mod($0) }).count >= 3 else {
                throw MusicError.invalid("This chord exercise has incomplete tones.")
            }
        } else if kind != .passage {
            guard choices.count >= 2, let answer, choices.indices.contains(answer) else {
                throw MusicError.invalid("This exercise has no valid answer.")
            }
        }
        if needsAudio && audio == nil { throw MusicError.invalid("This listening exercise has no reference.") }
        if let audio { _ = try audio.validated() }
        return self
    }
}
public struct PiecePathway: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var pieceID: String
    public var fingerprint: String
    public var scope: PieceScope
    public var origin: String
    public var tasks: [PieceTask]
    public var paused = false
    public init(snapshot: PieceSnapshot, origin: String, tasks: [PieceTask]) {
        pieceID = snapshot.pieceID
        fingerprint = snapshot.fingerprint
        scope = snapshot.scope
        self.origin = origin
        self.tasks = tasks
    }
    public func validated(stepCount: Int) throws -> Self {
        let parts = pieceID.split(separator: ":")
        guard schemaVersion == 1, parts.count == 2, ["score", "study"].contains(String(parts[0])),
            UUID(uuidString: String(parts[1])) != nil,
            ScoreRevision.valid(fingerprint), scope.valid, (1...32).contains(tasks.count),
            Set(tasks.map(\.id)).count == tasks.count, origin.count <= 300
        else { throw MusicError.invalid("This piece pathway is damaged or needs a newer Cadence.") }
        for task in tasks { _ = try task.validated(scope: scope, stepCount: stepCount) }
        return self
    }
    public func queue(now: Date = Date(), excluding: UUID? = nil) -> [PieceTask] {
        guard !paused else { return [] }
        let eligible = tasks.filter { $0.id != excluding }
        let positions = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($0.element.id, $0.offset) })
        return ReviewQueue.ordered(eligible, now: now, review: { $0.review }) {
            $0.stage == $1.stage ? positions[$0.id, default: 0] < positions[$1.id, default: 0] : $0.stage < $1.stage
        }
    }
    public var evidence: String {
        tasks.filter { $0.review.encounters > 0 }.map { task in
            "\(task.kind.rawValue), \(task.scope.label): \(task.review.encounters) encounters; \(task.review.difficult) difficult; latest \(task.review.lastGrade?.label ?? "unknown") via \(task.review.lastInput?.rawValue ?? "unknown")."
        }.joined(separator: "\n")
    }
}

public enum PiecePathwayFactory {
    public static func study(_ piece: LibraryPiece, scope: PieceScope) throws -> MusicStudy {
        var study: MusicStudy
        switch piece.source {
        case .score(let score):
            study = try ComposePractice.make(score, from: scope.fromBar - 1, through: scope.throughBar - 1)
        case .study(let source):
            study = source
            study.selectPart(scope.partID)
        }
        guard study.partID == scope.partID, scope.throughBar <= study.part.measures.count else {
            throw MusicError.invalid("The linked part or bars are no longer available.")
        }
        study.staff = nil
        study.select(from: scope.fromBar - 1, through: scope.throughBar - 1)
        return study
    }
    public static func make(
        piece: LibraryPiece, snapshot: PieceSnapshot, record: PieceRecord, profile: LearnerProfile,
        analysis: SavedPieceAnalysis? = nil
    ) throws -> LearningPathway {
        guard piece.id == snapshot.pieceID, piece.fingerprint == snapshot.fingerprint else {
            throw MusicError.invalid("The score changed. Choose the passage again.")
        }
        let brief = try LearningBrief(
            profile: profile, focus: .song, target: String(piece.title.prefix(500)),
            detail: String(record.goal.prefix(1500))
        ).validated()
        let study = try study(piece, scope: snapshot.scope)
        let matching = analysis.flatMap {
            $0.fingerprint == snapshot.fingerprint && $0.scope == snapshot.scope ? $0 : nil
        }
        let sourceSteps: [PiecePracticeStep]
        if let matching {
            sourceSteps = matching.outline.practice
        } else {
            sourceSteps = stride(from: snapshot.scope.fromBar, through: snapshot.scope.throughBar, by: 4).map { from in
                PiecePracticeStep(
                    title: "Make room for bars \(from)–\(min(from+3,snapshot.scope.throughBar))",
                    instructions:
                        "Listen once, count the pulse, then play slowly. Isolate one bar or one hand if the whole phrase feels difficult. Stop and reset if you feel tension.",
                    readyWhen:
                        "You can keep the pulse at a comfortable speed and describe the part that still needs attention.",
                    fromBar: from, throughBar: min(from + 3, snapshot.scope.throughBar))
            }
        }
        let minutes = max(1, min(5, profile.minutesPerSession / 2))
        func step(_ title: String, _ focus: String, _ ready: String) -> PathwayStep {
            PathwayStep(
                title: title, focus: focus,
                activities: [PathwayActivity(title: title, instructions: focus, minutes: minutes)],
                application: "Return to \(snapshot.scope.label). "
                    + (record.goal.isEmpty
                        ? "Aim for an unhurried, comfortable phrase." : String(record.goal.prefix(600))),
                readyWhen: ready, tool: .none)
        }
        var steps = [
            step(
                "Find your bearings",
                "Read the opening of this passage. Use its note and key exercises, then locate the same details in the score.",
                "You can locate the notes and explain what the key signature changes.")
        ]
        steps += sourceSteps.map { step($0.title, $0.instructions, $0.readyWhen) }
        steps.append(
            step(
                "Bring the phrase together",
                "Play the selected passage, then report how it felt. Compare today with your own earlier attempts; there is no deadline.",
                "The phrase feels comfortable at your chosen tempo, with a steady pulse. This is your own assessment."))
        var tasks = exercises(study: study, scope: snapshot.scope, finalStage: steps.count - 1)
        for (index, item) in sourceSteps.enumerated() {
            tasks.append(
                PieceTask(
                    stage: index + 1, kind: .passage, title: item.title, instructions: item.instructions,
                    readyWhen: item.readyWhen,
                    scope: PieceScope(
                        fromBar: item.fromBar, throughBar: item.throughBar, partID: snapshot.scope.partID,
                        partName: snapshot.scope.partName)))
        }
        tasks.append(
            PieceTask(
                stage: steps.count - 1, kind: .passage, title: "Play the whole passage",
                instructions: steps.last!.focus, readyWhen: steps.last!.readyWhen, scope: snapshot.scope))
        var sourceNotes = "Based on the selected symbolic score and your stated goal. "
        sourceNotes +=
            matching == nil
            ? "This starting plan is created locally. "
            : "Passage guidance comes from an AI analysis and needs your review. "
        sourceNotes += matching?.outline.caveats.joined(separator: " ") ?? ""
        sourceNotes +=
            " It does not assess recordings or physical technique. Exercises use source pitches and durations; check imported drafts against the original."
        let summary =
            matching?.outline.summary
            ?? "Start with the written details, work on small sections, and bring them back into the music. Reviews adapt to your checks and reports; every step stays available."
        let outline = PathwayOutline(
            title: "Learning · " + String(piece.title.prefix(100)), summary: summary,
            sourceNotes: String(sourceNotes.prefix(2000)), questions: [], steps: steps)
        var path = LearningPathway(
            brief: brief, outline: try outline.validated(minutesPerSession: profile.minutesPerSession),
            study: snapshot.reference)
        path.piecePractice = PiecePathway(
            snapshot: snapshot, origin: matching.map { "AI passage guidance · " + $0.model } ?? "Local starting plan",
            tasks: tasks)
        _ = try path.piecePractice!.validated(stepCount: steps.count)
        return path
    }
    private static func exercises(study: MusicStudy, scope: PieceScope, finalStage: Int) -> [PieceTask] {
        let source = study.part.sourceNotes().filter {
            $0.measure >= scope.fromBar - 1 && $0.measure < scope.throughBar
        }.sorted { $0.start == $1.start ? $0.midi < $1.midi : $0.start < $1.start }
        let pitched = source.filter { $0.midi >= 0 }
        var tasks: [PieceTask] = []
        func barScope(_ bar: Int) -> PieceScope {
            PieceScope(fromBar: bar + 1, throughBar: bar + 1, partID: scope.partID, partName: scope.partName)
        }
        func choice(
            _ title: String, _ instructions: String, _ kind: PieceTaskKind, _ correct: String, _ alternatives: [String],
            _ explanation: String, _ bar: Int, _ stage: Int = 0, _ audio: Score? = nil
        ) -> PieceTask {
            let options = Array(Set([correct] + alternatives)).sorted()
            var task = PieceTask(
                stage: stage, kind: kind, title: title, instructions: instructions,
                readyWhen: "Recall it without the answer showing.", scope: barScope(bar))
            task.choices = options
            task.answer = options.firstIndex(of: correct)
            task.explanation = explanation
            task.audio = audio
            return task
        }
        if let measure = study.selectedMeasures.first {
            let correct = QuestionFactory.signature(measure.fifths)
            let counts = Array(
                Set([
                    measure.fifths, 0, measure.fifths == 0 ? 1 : -measure.fifths,
                    measure.fifths == 7 ? 6 : measure.fifths + 1,
                ])
            ).sorted()
            tasks.append(
                choice(
                    "Remember the key signature",
                    "Without looking back, which signature is written in bar \(measure.index+1)?", .signature, correct,
                    counts.map(QuestionFactory.signature),
                    "The source writes \(correct.lowercased()). " + QuestionFactory.signatureNotes(measure.fifths),
                    measure.index))
        }
        if let first = pitched.first, let written = first.writtenPitch {
            let options = [
                written.name, Pitch(mod(written.letter + 1, 7)).name, Pitch(mod(written.letter + 2, 7)).name,
                Pitch(mod(written.letter + 4, 7)).name,
            ]
            tasks.append(
                choice(
                    "Recall the opening note",
                    "Read bar \(first.measure+1), then look away. What is the first written note in the selected part (lowest note if it begins with a chord)?",
                    .reading, written.name, options,
                    "The first written pitch is \(written.name). This checks recall from the score; opening the notation counts as support.",
                    first.measure))
        }
        if let first = pitched.first {
            let line = pitched.filter { $0.staff == first.staff && $0.voice == first.voice && !$0.tieStop }
            if let next = line.first(where: { $0.start > first.start + 0.0001 }), abs(next.midi - first.midi) <= 12 {
                let names = [
                    "Unison", "Minor second", "Major second", "Minor third", "Major third", "Perfect fourth", "Tritone",
                    "Perfect fifth", "Minor sixth", "Major sixth", "Minor seventh", "Major seventh", "Octave",
                ]
                let distance = abs(next.midi - first.midi)
                let direction =
                    next.midi == first.midi ? "same pitch" : next.midi > first.midi ? "ascending" : "descending"
                let nearby = Array(Set([distance, max(0, distance - 1), min(12, distance + 1), (distance + 5) % 13]))
                    .sorted().map { names[$0] }
                let sound = Score(
                    tempo: 80, notes: [ScoreNote(midi: first.midi, start: 0), ScoreNote(midi: next.midi, start: 1.3)])
                var task = choice(
                    "Hear a movement from the piece",
                    "Listen to these two notes from staff \(first.staff), voice \(first.voice). How far apart are they?",
                    .interval, names[distance], nearby,
                    "\(names[distance]), \(direction): \(distance) semitones. This ear exercise simplifies the source rhythm and uses sounding pitches.",
                    first.measure, 1, sound)
                task.scope.throughBar = next.measure + 1
                tasks.append(task)
            }
            let length = first.duration
            let values: [(Double, String)] = [
                (0.25, "A quarter of a quarter-note beat"), (0.5, "Half a quarter-note beat"),
                (1, "One quarter-note beat"), (1.5, "One and a half quarter-note beats"), (2, "Two quarter-note beats"),
                (3, "Three quarter-note beats"), (4, "Four quarter-note beats"),
            ]
            if let correct = values.first(where: { abs($0.0 - length) < 0.0001 }) {
                let other = values.filter { $0.1 != correct.1 }.sorted { abs($0.0 - length) < abs($1.0 - length) }
                    .prefix(3).map(\.1)
                tasks.append(
                    choice(
                        "Remember a written duration",
                        "Look at the first pitched event in bar \(first.measure+1), staff \(first.staff), voice \(first.voice), then look away. How long is that written event, before any continuation tie?",
                        .rhythm, correct.1, other,
                        "The written duration is \(String(format:"%g",length)) quarter-note beats. This is a reading check, not a test of your performed timing.",
                        first.measure, 1))
            }
        }
        for note in pitched {
            let tones = pitched.filter {
                $0.staff == note.staff && $0.voice == note.voice && abs($0.start - note.start) < 0.0001 && !$0.tieStop
            }.map(\.midi)
            guard Set(tones).count <= 16, (3...6).contains(Set(tones.map { mod($0) }).count) else { continue }
            var task = PieceTask(
                stage: finalStage, kind: .chord, title: "Play a chord from bar \(note.measure+1)",
                instructions:
                    "Read the chord in staff \(note.staff), voice \(note.voice), then play its tones on your MIDI keyboard and release. Keep its lowest pitch class in the bass; any comfortable octave is welcome.",
                readyWhen: "Play the chord tones and bass without a hint. Timing and technique are not graded.",
                scope: barScope(note.measure))
            task.target = Array(Set(tones)).sorted()
            task.explanation =
                "Source chord tones: "
                + task.target.map {
                    Solfege.noteName(
                        midi: $0, pitch: Pitch.spelled($0, flats: (study.selectedMeasures.first?.fifths ?? 0) < 0))
                }.joined(separator: " · ")
            task.audio = Score(tempo: 80, notes: task.target.map { ScoreNote(midi: $0, start: 0, duration: 2) })
            tasks.append(task)
            break
        }
        return tasks
    }
}
