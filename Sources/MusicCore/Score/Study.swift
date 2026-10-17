// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct StudyMeasure: Codable, Equatable, Sendable {
    public var index: Int
    public var label: String
    public var start: Double
    public var duration: Double
    public var beats: Int
    public var beatUnit: Int
    public var fifths: Int
    public var minor: Bool? = nil
    public var keyMode: String? = nil
    public var end: Double { start + duration }
}
public struct StudyNote: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var midi: Int
    public var writtenPitch: Pitch?
    public var writtenMidi: Int?
    public var start: Double
    public var duration: Double
    public var measure: Int
    public var voice: String
    public var staff: Int
    public var string: Int?
    public var fret: Int?
    public var tieStart: Bool
    public var tieStop: Bool
    public var expression: StudyExpression? = nil
}
public struct StudyPart: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var measures: [StudyMeasure]
    public var notes: [StudyNote]
    public var dynamics: [StudyDynamic]? = nil
    public var tabStaves: Set<Int>
    public var staves: [Int] { Array(Set(notes.map(\.staff))).sorted() }
    public var defaultStaff: Int? { nil }
    public func sourceNotes(staff: Int? = nil) -> [StudyNote] {
        let hasStandardStaff = notes.contains { !tabStaves.contains($0.staff) && $0.midi >= 0 }
        return notes.filter { note in
            if let staff { return note.staff == staff }
            return !hasStandardStaff || !tabStaves.contains(note.staff)
        }
    }
    /// Merge sound ties by part, staff, voice and pitch. A TAB duplicate must not
    /// cause a second attack, and simultaneous equal pitches in other voices
    /// must not be mistaken for a continuation of the same tie.
    public func soundingNotes(staff: Int? = nil) -> [ScoreNote] {
        var result: [ScoreNote] = []
        var openTies: [String: [Int]] = [:]
        let voiceScopes = Array(Set(sourceNotes(staff: staff).map { "\($0.staff):\($0.voice)" })).sorted()
        let channels = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15]
        var onsetExpressions: [String: StudyExpression] = [:]
        for n in sourceNotes(staff: staff) {
            guard let e = n.expression else { continue }
            let key = "\(n.staff):\(n.voice):\(n.start)"
            var combined = onsetExpressions[key] ?? StudyExpression()
            combined.staccato = combined.staccato || e.staccato
            combined.accent = combined.accent || e.accent
            combined.slurStarts = Array(Set(combined.slurStarts + e.slurStarts))
            combined.slurStops = Array(Set(combined.slurStops + e.slurStops))
            onsetExpressions[key] = combined
        }
        var slurs = Set<String>()
        let expressive = notes.contains { $0.expression != nil } || !(dynamics ?? []).isEmpty
        for note in sourceNotes(staff: staff).sorted(by: {
            $0.start == $1.start ? $0.midi < $1.midi : $0.start < $1.start
        }) {
            guard note.midi >= 0 else { continue }
            let key = "\(note.staff):\(note.voice):\(note.midi)"
            let expression = onsetExpressions["\(note.staff):\(note.voice):\(note.start)"] ?? StudyExpression()
            let scope = "\(note.staff):\(note.voice):"
            for n in expression.slurStops { slurs.remove(scope + n) }
            for n in expression.slurStarts { slurs.insert(scope + n) }
            let dynamic =
                (dynamics ?? []).filter {
                    $0.staff == note.staff && ($0.voice == nil || $0.voice == note.voice)
                        && $0.start <= note.start + 0.00001
                }.sorted { $0.start < $1.start }.last?.dynamic ?? .mf
            let legato = slurs.contains { $0.hasPrefix(scope) }
            let performance = NotePerformance(
                velocity: min(127, dynamic.velocity + (expression.accent ? 18 : 0)),
                gate: expression.staccato ? 0.45 : legato ? 1.03 : 0.9)
            if note.tieStop,
                let index = openTies[key]?.first(where: {
                    abs(result[$0].start + result[$0].duration - note.start) < 0.0001
                })
            {
                result[index].duration += note.duration
                if expressive { result[index].performance = performance }
                if !note.tieStart { openTies[key]?.removeAll { $0 == index } }
            } else {
                var event = ScoreNote(
                    midi: note.midi, start: note.start, duration: note.duration, string: note.string, fret: note.fret,
                    spelling: note.writtenPitch?.pc == mod(note.midi) ? note.writtenPitch : nil)
                event.id = note.id
                if let index = voiceScopes.firstIndex(of: "\(note.staff):\(note.voice)") {
                    event.channel = channels[index % channels.count]
                }
                if expressive { event.performance = performance }
                // Technical fingering often lives only on the duplicated TAB staff.
                if event.string == nil,
                    let tab = notes.first(where: {
                        tabStaves.contains($0.staff) && $0.midi == note.midi && abs($0.start - note.start) < 0.0001
                            && $0.string != nil
                    })
                {
                    event.string = tab.string
                    event.fret = tab.fret
                }
                result.append(event)
                if note.tieStart { openTies[key, default: []].append(result.count - 1) }
            }
        }
        return result
    }
}
public struct StudyDocument: Codable, Equatable, Sendable {
    public var title: String
    public var composer: String
    public var tempo: Double
    public var originalXML: String
    public var parts: [StudyPart]
    public var notices: [String]
    public func validated() throws -> Self {
        guard tempo.isFinite, (20...300).contains(tempo), !parts.isEmpty, parts.count <= 64,
            Set(parts.map(\.id)).count == parts.count, originalXML.utf8.count <= StudyImport.maximumBytes
        else { throw MusicError.invalid("This study has invalid score settings.") }
        guard parts.reduce(0, { $0 + $1.notes.count }) <= 10000 else {
            throw MusicError.invalid("This study contains too many note events.")
        }
        for part in parts {
            guard !part.measures.isEmpty, part.measures.count <= 1000, part.notes.count <= 10000 else {
                throw MusicError.invalid("This score part has an unsupported size.")
            }
            var expectedStart = 0.0
            for (index, bar) in part.measures.enumerated() {
                guard bar.index == index, bar.start.isFinite, bar.start >= 0, abs(bar.start - expectedStart) < 0.0001,
                    bar.duration.isFinite, bar.duration > 0, bar.duration <= 128, (1...16).contains(bar.beats),
                    [2, 4, 8, 16].contains(bar.beatUnit), (-7...7).contains(bar.fifths)
                else { throw MusicError.invalid("This study contains an invalid bar.") }
                expectedStart = bar.end
            }
            for mark in part.dynamics ?? [] {
                guard mark.start.isFinite, mark.start >= 0, mark.start < expectedStart, (1...16).contains(mark.staff),
                    (mark.voice?.count ?? 0) <= 100
                else { throw MusicError.invalid("Invalid dynamic marking.") }
            }
            for note in part.notes {
                guard part.measures.indices.contains(note.measure), (-1...127).contains(note.midi), note.start.isFinite,
                    note.start >= 0, note.duration.isFinite, note.duration > 0, note.duration <= 128,
                    note.start < 100000, (1...16).contains(note.staff)
                else { throw MusicError.invalid("This study contains an invalid note.") }
                if let pitch = note.writtenPitch {
                    guard (0..<7).contains(pitch.letter), abs(pitch.accidental) <= 2 else {
                        throw MusicError.invalid("Invalid written pitch.")
                    }
                }
                if let string = note.string {
                    guard (0..<6).contains(string) else { throw MusicError.invalid("Invalid guitar string.") }
                }
                if let fret = note.fret {
                    guard (0...24).contains(fret) else { throw MusicError.invalid("Invalid guitar fret.") }
                }
            }
        }
        return self
    }
}

public struct StudyReference: Codable, Equatable, Sendable {
    public var studyID: UUID
    public var title: String
    public var partID: String
    public var partName: String
    public var from: Int
    public var through: Int
    public var context: String
    public var passageLabel: String
    public var staff: Int? = nil
}
public struct MusicStudy: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var importedAt = Date()
    public var filename: String
    public var document: StudyDocument
    public var partID: String
    public var staff: Int?
    public var from = 0
    public var through: Int
    public var speed = 1.0
    public var loop = true
    public var countIn = true
    public var metronome = false
    public var notes = ""
    public var pathwayID: UUID?
    public var sourceEditor: ComposeStudySource? = nil
    public var practiceBook: PassagePracticeBook? = nil
    public init(document: StudyDocument, filename: String) {
        self.document = document
        self.filename = filename
        let part = document.parts.first { $0.notes.contains { $0.midi >= 0 } } ?? document.parts[0]
        partID = part.id
        through = min(3, part.measures.count - 1)
    }
    public var part: StudyPart { document.parts.first { $0.id == partID } ?? document.parts[0] }
    public var selectedMeasures: [StudyMeasure] {
        let lo = min(max(0, from), part.measures.count - 1)
        let hi = min(max(lo, through), part.measures.count - 1)
        return Array(part.measures[lo...hi])
    }
    public var start: Double { selectedMeasures.first?.start ?? 0 }
    public var end: Double { selectedMeasures.last?.end ?? 0 }
    public var passageLabel: String {
        guard let first = selectedMeasures.first, let last = selectedMeasures.last else { return "No bars" }
        return first.index == last.index ? "Bar \(first.label)" : "Bars \(first.label)–\(last.label)"
    }
    public var selectedNotes: [ScoreNote] {
        part.soundingNotes(staff: staff).filter { $0.start < end - 0.00001 && $0.start + $0.duration > start + 0.00001 }
    }
    public var reference: StudyReference {
        let source = part.sourceNotes(staff: staff).filter { $0.start >= start - 0.00001 && $0.start < end - 0.00001 }
        let events = source.prefix(160).map { note -> String in
            let bar = part.measures[note.measure]
            let pitch =
                note.midi < 0
                ? "rest" : Solfege.noteName(midi: note.midi, pitch: Pitch.spelled(note.midi, flats: bar.fifths < 0))
            let written =
                note.writtenMidi != note.midi && note.writtenMidi != nil && note.writtenPitch != nil
                ? "; written \(Solfege.noteName(midi:note.writtenMidi!,pitch:note.writtenPitch!))" : ""
            let e = note.expression ?? StudyExpression()
            let expression = [
                e.staccato ? "staccato" : "", e.accent ? "accent" : "", !e.slurStarts.isEmpty ? "slur begins" : "",
                !e.slurStops.isEmpty ? "slur ends" : "",
            ].filter { !$0.isEmpty }.joined(separator: ", ")
            let fingering =
                note.string.flatMap { string in
                    note.fret.map { "; source technical fingering: string \(6-string), fret \($0)" }
                } ?? ""
            return
                "bar \(bar.label), quarter-beat \(Self.number(note.start-bar.start)): \(pitch), duration \(Self.number(note.duration)) quarter beats, staff \(note.staff), voice \(note.voice)\(written)\(fingering)\(note.tieStop ? "; tie continuation" : "")\(expression.isEmpty ? "" : "; "+expression)"
        }
        let carried = selectedNotes.filter { $0.start < start - 0.00001 }.prefix(32).map { note in
            "Held into the first selected bar: \(Solfege.noteName(midi:note.midi,pitch:Pitch.spelled(note.midi,flats:selectedMeasures[0].fifths<0))), for \(Self.number(min(end,note.start+note.duration)-start)) quarter beats from its beginning."
        }.joined(separator: "\n")
        let details = selectedMeasures.map {
            "bar \($0.label): \($0.beats)/\($0.beatUnit), \(QuestionFactory.signature($0.fifths)), key mode \($0.keyMode ?? $0.minor.map { $0 ? "minor" : "major" } ?? "not supplied"), actual length \(Self.number($0.duration)) quarter beats"
        }.joined(separator: "; ")
        let progress = practiceBook?.tempos.first { $0.scope == PassageScope(self) }
        let practiceContext =
            progress.map {
                "Learner-set target: \(Self.number($0.targetBPM)) quarter-note bpm. Self-reported comfortable tempos: \($0.comfortable.suffix(8).map { Self.number($0.bpm) }.joined(separator:", ")). These are the learner’s own reports, not an assessment of audio or playing accuracy."
            } ?? "No tempo progress has been reported for this selection."
        let dynamicContext = (part.dynamics ?? []).filter { $0.start < end }.suffix(32).map {
            "Quarter-beat \(Self.number($0.start)): staff \($0.staff), voice \($0.voice ?? "all"), \($0.dynamic.rawValue)."
        }.joined(separator: " ")
        let context = """
            IMPORTED SCORE PASSAGE (symbolic MusicXML data, not a recording or an assessment of the learner's playing):
            Title: \(document.title). Composer: \(document.composer.isEmpty ? "not supplied" : document.composer). Part: \(part.name). \(passageLabel). \(staff.map { "Only staff \($0) is selected for playback." } ?? "Standard-notation staves selected; duplicate TAB staves excluded from playback.")
            Source tempo: \(Self.number(document.tempo)) quarter-note bpm. Practice speed: \(Int(speed*100))%. \(details).
            Notes in written order, with sounding pitches and zero-based quarter-beat offsets within each bar:
            \(carried)
            \(events.joined(separator:"\n"))
            \(source.count > 160 ? "Only the first 160 of \(source.count) events are included. Ask for a shorter passage before analysing omitted material." : "All \(source.count) note/rest events that begin in this passage are included.")
            Playback reads written bars in order, with ties sustained, basic ppp–fff dynamics, accents, staccato and slur legato. Repeats, grace notes, ornaments, pedal and tempo changes are not performed. Technical fingerings, when supplied, are from the score and may use a different tuning or capo from the learner; verify before using them. Do not infer articulation, unsupplied fingering, performance quality, or material outside these supplied notes. Learner practice notes: \(notes)
            Dynamics (absolute quarter beats, including preceding context): \(dynamicContext)
            \(HarmonyXML.context(self))
            \(practiceContext)
            """
        return StudyReference(
            studyID: id, title: document.title, partID: part.id, partName: part.name, from: from, through: through,
            context: context, passageLabel: passageLabel, staff: staff)
    }
    public mutating func selectPart(_ id: String) {
        guard document.parts.contains(where: { $0.id == id }) else { return }
        partID = id
        staff = nil
        from = 0
        through = min(3, part.measures.count - 1)
    }
    public mutating func select(from: Int, through: Int) {
        self.from = min(max(0, from), part.measures.count - 1)
        self.through = min(part.measures.count - 1, max(self.from, min(through, self.from + 15)))
    }
    public func restored() throws -> Self {
        _ = try document.validated()
        var copy = self
        // Enrich older saves from their retained XML without replacing note identities.
        let needsMode =
            document.parts.contains { $0.measures.contains { $0.keyMode == nil } }
            && (document.originalXML.contains("<mode") || document.originalXML.contains(":mode"))
        let needsExpression =
            document.parts.contains { $0.dynamics == nil && $0.notes.allSatisfy { $0.expression == nil } }
            && ["slur", "articulations", "dynamics"].contains {
                document.originalXML.contains("<" + $0) || document.originalXML.contains(":" + $0)
            }
        if needsMode || needsExpression, let parsed = try? StudyImport.read(Data(document.originalXML.utf8)) {
            for p in copy.document.parts.indices {
                guard let source = parsed.parts.first(where: { $0.id == copy.document.parts[p].id }),
                    source.measures.count == copy.document.parts[p].measures.count
                else { continue }
                for m in copy.document.parts[p].measures.indices where copy.document.parts[p].measures[m].keyMode == nil
                {
                    copy.document.parts[p].measures[m].keyMode = source.measures[m].keyMode
                    copy.document.parts[p].measures[m].minor = source.measures[m].minor
                }
                if needsExpression, source.notes.count == copy.document.parts[p].notes.count,
                    zip(source.notes, copy.document.parts[p].notes).allSatisfy({
                        $0.midi == $1.midi && $0.staff == $1.staff && $0.voice == $1.voice
                            && abs($0.start - $1.start) < 0.0001 && abs($0.duration - $1.duration) < 0.0001
                    })
                {
                    if copy.document.parts[p].dynamics == nil { copy.document.parts[p].dynamics = source.dynamics }
                    for n in source.notes.indices where copy.document.parts[p].notes[n].expression == nil {
                        copy.document.parts[p].notes[n].expression = source.notes[n].expression
                    }
                }
            }
        }
        if !document.parts.contains(where: { $0.id == partID }) { copy.partID = document.parts[0].id }
        if let staff = copy.staff, !copy.part.staves.contains(staff) { copy.staff = nil }
        copy.select(from: from, through: through)
        copy.notes = String(copy.notes.prefix(4000))
        if !copy.speed.isFinite || !(0.25...1.5).contains(copy.speed) { copy.speed = 1 }
        copy.practiceBook = practiceBook?.restored(in: document)
        if let source = copy.sourceEditor,
            source.tuning.pitches.count != 6 || !source.tuning.pitches.allSatisfy({ (24...88).contains($0) })
                || !(0...9).contains(source.capo)
        {
            copy.sourceEditor = nil
        }
        return copy
    }
    private static func number(_ value: Double) -> String { String(format: "%.3g", value) }
}
public struct StudyLibrary: Codable, Equatable, Sendable {
    public var schemaVersion: Int? = 1
    public var studies: [MusicStudy] = []
    public var activeID: UUID?
    public init() {}
    public func restored() throws -> Self {
        guard schemaVersion == nil || schemaVersion == 1, studies.count <= 100,
            Set(studies.map(\.id)).count == studies.count
        else { throw MusicError.invalid("This study library is damaged or needs a newer Cadence.") }
        var copy = self
        copy.schemaVersion = 1
        copy.studies = try studies.map { try $0.restored() }
        return copy
    }
    public func validated() throws -> Self {
        guard schemaVersion == nil || schemaVersion == 1, studies.count <= 100,
            Set(studies.map(\.id)).count == studies.count
        else { throw MusicError.invalid("The study library is invalid.") }
        for study in studies { _ = try study.document.validated() }
        return self
    }
    public var active: MusicStudy? { studies.first { $0.id == activeID } ?? studies.first }
    public mutating func add(_ study: MusicStudy) {
        studies.insert(study, at: 0)
        activeID = study.id
    }
}

public struct StudyPlaybackPlan: Sendable {
    public var intro: Score
    public var cycle: Score
    public var introBeats: Double
    public var cycleBeats: Double
    public var sourceStart: Double
    public var countInPulse: Double
    public var tempo: Double { cycle.tempo }
    public init(study: MusicStudy, wholePiece: Bool = false) throws {
        let bars = study.selectedMeasures
        guard let first = bars.first, bars.count <= (wholePiece ? 1000 : 16), study.speed.isFinite,
            (0.25...1.5).contains(study.speed)
        else { throw MusicError.invalid("Choose a passage of up to 16 bars and a playback speed from 25–150%.") }
        let tempo = study.document.tempo * study.speed
        sourceStart = study.start
        cycleBeats = study.end - study.start
        guard tempo.isFinite, (5...450).contains(tempo), cycleBeats > 0, cycleBeats * 60 / tempo <= 300 else {
            throw MusicError.invalid(
                "Choose a shorter passage or a faster practice speed. Playback passages can be up to five minutes.")
        }
        countInPulse = 4 / Double(first.beatUnit)
        introBeats = study.countIn ? Double(first.beats) * 4 / Double(first.beatUnit) : 0
        let introNotes =
            study.countIn
            ? (0..<first.beats).map {
                ScoreNote(midi: $0 == 0 ? 84 : 79, start: Double($0) * 4 / Double(first.beatUnit), duration: 0.06)
            } : []
        intro = Score(tempo: tempo, beatsPerBar: first.beats, beatUnit: first.beatUnit, notes: introNotes)
        var events = study.selectedNotes.map { event in
            var copy = event
            copy.start = max(event.start, study.start) - study.start
            copy.duration = min(event.start + event.duration, study.end) - max(event.start, study.start)
            return copy
        }
        if study.metronome {
            for bar in bars {
                for pulse in 0..<bar.beats {
                    let time = bar.start - study.start + Double(pulse) * 4 / Double(bar.beatUnit)
                    if time < cycleBeats {
                        events.append(ScoreNote(midi: pulse == 0 ? 84 : 79, start: time, duration: 0.04))
                    }
                }
            }
        }
        cycle = Score(
            title: study.document.title, tempo: tempo, beatsPerBar: first.beats, beatUnit: first.beatUnit,
            fifths: first.fifths, notes: events)
    }
    public func position(seconds: Double, loop: Bool) -> StudyPlayhead {
        let elapsed = max(0, seconds) * tempo / 60
        if elapsed < introBeats {
            return StudyPlayhead(
                sourceBeat: sourceStart, isCountIn: true, countInRemaining: (introBeats - elapsed) / countInPulse,
                cycle: 0)
        }
        let after = max(0, elapsed - introBeats)
        let position = loop ? after.truncatingRemainder(dividingBy: cycleBeats) : min(after, cycleBeats)
        return StudyPlayhead(
            sourceBeat: sourceStart + position, isCountIn: false, countInRemaining: 0,
            cycle: loop ? Int(after / cycleBeats) : 0)
    }
}
public struct StudyPlayhead: Sendable, Equatable {
    public init(sourceBeat: Double, isCountIn: Bool, countInRemaining: Double, cycle: Int) {
        self.sourceBeat = sourceBeat
        self.isCountIn = isCountIn
        self.countInRemaining = countInRemaining
        self.cycle = cycle
    }
    public var sourceBeat: Double
    public var isCountIn: Bool
    public var countInRemaining: Double
    public var cycle: Int
}
