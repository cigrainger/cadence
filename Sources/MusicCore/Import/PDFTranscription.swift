// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct PDFScoreSource: Codable, Equatable, Sendable {
    public var fileID: UUID
    public var filename: String
    public var page: Int
    public var model: String
    public var importedAt: Date
    public var costUSD: Double?
    public var warnings: [String]
    public var reviewed: Bool
    public var pages: [PDFImportPage]?
    public init(
        fileID: UUID = UUID(), filename: String, page: Int, model: String, costUSD: Double? = nil,
        warnings: [String] = [], reviewed: Bool = false
    ) {
        self.fileID = fileID
        self.filename = filename
        self.page = page
        self.model = model
        importedAt = Date()
        self.costUSD = costUSD
        self.warnings = warnings
        self.reviewed = reviewed
    }
    public var valid: Bool {
        !filename.isEmpty && filename.count <= 300 && (1...1000).contains(page) && !model.isEmpty && model.count <= 200
            && importedAt.timeIntervalSince1970.isFinite && warnings.count <= 100
            && warnings.allSatisfy { $0.count <= 1000 }
            && (costUSD.map { $0.isFinite && $0 >= 0 && $0 <= 10000 } ?? true)
            && (pages.map {
                !$0.isEmpty && $0.count <= 16 && Set($0.map(\.page)).count == $0.count
                    && $0.map(\.page) == $0.map(\.page).sorted() && $0.allSatisfy(\.valid)
            } ?? true)
    }
}

public struct PDFWrittenNote: Codable, Equatable, Sendable {
    public var bar: Int
    public var staff: Int
    public var voice: Int
    public var midi: Int
    public var start: Double
    public var duration: Double
    public var step: String?
    public var alter: Int?
    public var tieNext: Bool
    public var staccato: Bool
    public var accent: Bool
    public var dynamic: String?
    public init(
        bar: Int, staff: Int = 1, voice: Int = 1, midi: Int, start: Double, duration: Double, step: String? = nil,
        alter: Int? = nil, tieNext: Bool = false, staccato: Bool = false, accent: Bool = false, dynamic: String? = nil
    ) {
        self.bar = bar
        self.staff = staff
        self.voice = voice
        self.midi = midi
        self.start = start
        self.duration = duration
        self.step = step
        self.alter = alter
        self.tieNext = tieNext
        self.staccato = staccato
        self.accent = accent
        self.dynamic = dynamic
    }
}
public struct PDFWrittenHarmony: Codable, Equatable, Sendable {
    public var bar: Int
    public var start: Double
    public var staff: Int
    public var symbol: String
    public init(bar: Int, start: Double, staff: Int = 1, symbol: String) {
        self.bar = bar
        self.start = start
        self.staff = staff
        self.symbol = symbol
    }
}
public struct PDFDraftResult: Sendable {
    public var document: EditorDocument
    public var warnings: [String]
}
public struct PDFTranscription: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var title: String
    public var barCount: Int
    public var beats: Int
    public var beatUnit: Int
    public var fifths: Int
    public var minor: Bool
    public var tempo: Int?
    public var notes: [PDFWrittenNote]
    public var harmonies: [PDFWrittenHarmony]?
    public var warnings: [String]
    public var unsupported: [String]
    public init(_ document: EditorDocument) {
        title = document.title
        barCount = document.barCount
        beats = document.meter.beats
        beatUnit = document.meter.unit
        fifths = document.fifths
        minor = document.minor
        tempo = document.tempo
        warnings = []
        unsupported = []
        harmonies = document.harmonies.map {
            PDFWrittenHarmony(bar: $0.bar + 1, start: Double($0.tick) / 480, staff: $0.staff, symbol: $0.symbol.label)
        }
        notes = document.events.flatMap { event in
            let pitches: [EditorPitch?] = event.isRest ? [nil] : event.pitches.map { Optional($0) }
            return pitches.map { pitch in
                PDFWrittenNote(
                    bar: event.bar + 1, staff: event.staff, voice: event.voice,
                    midi: pitch.map { $0.midi + (document.instrument == .guitar ? 12 : 0) } ?? -1,
                    start: Double(document.onset(event)) / 480, duration: Double(event.rhythm.ticks) / 480,
                    step: pitch.map { Pitch.letters[$0.spelling.letter] }, alter: pitch?.spelling.accidental,
                    tieNext: event.tieNext, staccato: event.staccato, accent: event.accent,
                    dynamic: event.dynamic?.rawValue)
            }
        }
        if document.events.contains(where: { $0.slurTo != nil }) {
            warnings.append("Slurs need manual review and entry in the full editor.")
        }
    }
    public static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 1_000_000, let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b
        else { throw MusicError.invalid("The model did not return a complete notation draft.") }
        return try JSONDecoder().decode(Self.self, from: Data(text[a...b].utf8))
    }
    /// Convert untrusted model data into a complete, validated editor score.
    /// Gaps become explicit rests with a warning; overlaps never erase notes.
    public func makeDocument(instrument: EditorInstrument, tuning: Tuning = Tuning.presets[0], capo: Int = 0) throws
        -> PDFDraftResult
    {
        let meter = EditorMeter(beats, beatUnit)
        guard schemaVersion == 1, (1...32).contains(barCount), EditorMeter.choices.contains(meter),
            (-7...7).contains(fifths), title.count <= 500, tempo.map({ (20...300).contains($0) }) ?? true,
            !notes.isEmpty, notes.count <= 8192
        else {
            throw MusicError.invalid(
                "Choose an excerpt of 1–32 bars with one supported key, meter and tempo. A smaller passage may help.")
        }
        guard warnings.count <= 100, unsupported.count <= 30, (warnings + unsupported).allSatisfy({ $0.count <= 1000 })
        else { throw MusicError.invalid("The model returned an unreadable review report.") }
        let structures = [
            "pickup_or_incomplete_bar": "pickups or incomplete bars", "changing_key": "a changing key signature",
            "changing_meter": "a changing time signature", "more_than_two_voices": "more than two voices per staff",
            "cross_staff_voice": "a voice crossing staves",
            "unsupported_tuplet": "tuplets other than complete triplet groups",
        ]
        guard unsupported.isEmpty else {
            throw MusicError.invalid(
                "This excerpt includes unsupported notation: "
                    + unsupported.prefix(3).map { structures[$0] ?? $0 }.joined(separator: "; ")
                    + ". Choose a simpler passage; the original PDF is unchanged.")
        }
        guard notes.contains(where: { $0.midi >= 0 }) else {
            throw MusicError.invalid("No pitched notes were found. Choose a page or passage containing notation.")
        }
        let staffs = instrument == .piano ? 2 : 1
        struct Location: Hashable {
            var bar: Int
            var staff: Int
            var voice: Int
            var start: Int
            var duration: Int
        }
        var groups: [Location: [PDFWrittenNote]] = [:]
        for note in notes {
            guard (1...barCount).contains(note.bar), (1...staffs).contains(note.staff), (1...2).contains(note.voice),
                (-1...127).contains(note.midi), note.start.isFinite, note.duration.isFinite, note.start >= 0,
                note.start <= 32, note.duration > 0, note.duration <= 32
            else {
                throw MusicError.invalid("A note has an invalid pitch, bar, staff or position. Try a smaller passage.")
            }
            let start = Int((note.start * 480).rounded())
            let length = Int((note.duration * 480).rounded())
            guard abs(note.start * 480 - Double(start)) < 0.02, abs(note.duration * 480 - Double(length)) < 0.02,
                start + length <= meter.ticks, EditorRhythm.matching(length) != nil
            else {
                throw MusicError.invalid(
                    "An unsupported or incomplete rhythm was found in bar \(note.bar). The draft has not been saved.")
            }
            let location = Location(
                bar: note.bar - 1, staff: note.staff, voice: note.voice, start: start, duration: length)
            groups[location, default: []].append(note)
        }
        var events: [EditorEvent] = []
        var review = warnings
        var gaps = 0
        var spellingConflicts = false
        var partialTies = false
        func rests(_ ticks: Int, bar: Int, staff: Int, voice: Int) throws -> [EditorEvent] {
            var remaining = ticks
            var result: [EditorEvent] = []
            let values = EditorRhythm.choices.sorted { $0.ticks > $1.ticks }
            while remaining > 0 {
                guard let value = values.first(where: { $0.ticks <= remaining }) else {
                    throw MusicError.invalid(
                        "A rhythmic gap in bar \(bar+1) cannot be represented. Try a smaller passage.")
                }
                result.append(EditorEvent(bar: bar, staff: staff, voice: voice, rhythm: value))
                remaining -= value.ticks
            }
            return result
        }
        for staff in 1...staffs {
            let voices = Set([1] + notes.filter { $0.staff == staff }.map(\.voice)).sorted()
            for voice in voices {
                for bar in 0..<barCount {
                    let locations = groups.keys.filter { $0.staff == staff && $0.voice == voice && $0.bar == bar }
                        .sorted { $0.start == $1.start ? $0.duration < $1.duration : $0.start < $1.start }
                    var position = 0
                    for location in locations {
                        guard location.start >= position else {
                            throw MusicError.invalid(
                                "Notes overlap in bar \(bar+1), staff \(staff), voice \(voice). The model must separate simultaneous lines into voices."
                            )
                        }
                        if location.start > position {
                            events += try rests(location.start - position, bar: bar, staff: staff, voice: voice)
                            gaps += 1
                        }
                        let written = groups[location]!
                        let rest = written.contains { $0.midi == -1 }
                        guard !rest || written.count == 1, Set(written.map(\.midi)).count == written.count,
                            written.count <= (instrument == .guitar ? 6 : 8)
                        else {
                            throw MusicError.invalid(
                                "Conflicting notes or rests were found in bar \(bar+1). Choose a smaller passage.")
                        }
                        var pitches: [EditorPitch] = []
                        if !rest {
                            for note in written.sorted(by: { $0.midi < $1.midi }) {
                                let sounding = note.midi - (instrument == .guitar ? 12 : 0)
                                guard (21...108).contains(sounding) else {
                                    throw MusicError.invalid(
                                        "A detected note is outside the supported instrument range in bar \(bar+1).")
                                }
                                var spelling = Pitch.spelled(sounding, flats: fifths < 0)
                                if let step = note.step, let letter = Pitch.letters.firstIndex(of: step.uppercased()),
                                    let alter = note.alter, (-2...2).contains(alter)
                                {
                                    let supplied = Pitch(letter, alter)
                                    if supplied.pc == mod(sounding) {
                                        spelling = supplied
                                    } else {
                                        spellingConflicts = true
                                    }
                                } else {
                                    spellingConflicts = true
                                }
                                pitches.append(EditorPitch(sounding, spelling: spelling))
                            }
                        }
                        if written.contains(where: { $0.tieNext }) && !written.allSatisfy(\.tieNext) {
                            partialTies = true
                        }
                        let dynamics = Set(written.compactMap(\.dynamic))
                        guard dynamics.count <= 1 else {
                            throw MusicError.invalid("Conflicting dynamics were returned in bar \(bar+1).")
                        }
                        let dynamic = dynamics.first.flatMap(MusicDynamic.init(rawValue:))
                        if !dynamics.isEmpty && dynamic == nil {
                            review.append("An unsupported dynamic in bar \(bar+1) needs review.")
                        }
                        events.append(
                            EditorEvent(
                                bar: bar, staff: staff, voice: voice, rhythm: EditorRhythm.matching(location.duration)!,
                                pitches: pitches, tieNext: !rest && written.allSatisfy(\.tieNext),
                                staccato: !rest && written.contains(where: { $0.staccato }),
                                accent: !rest && written.contains(where: { $0.accent }), dynamic: dynamic))
                        position = location.start + location.duration
                    }
                    if position < meter.ticks {
                        events += try rests(meter.ticks - position, bar: bar, staff: staff, voice: voice)
                        gaps += 1
                    }
                }
            }
        }
        var document = EditorDocument(
            title: title.isEmpty ? "Imported score" : String(title.prefix(120)), instrument: instrument, events: events)
        document.barCount = barCount
        document.meter = meter
        document.fifths = fifths
        document.minor = minor
        document.tempo = tempo ?? 90
        let requestedTies = document.events.filter(\.tieNext).count
        document.clearInvalidTies()
        if requestedTies != document.events.filter(\.tieNext).count || partialTies {
            review.append(
                "Some ties could not be joined. Partial chord ties are not supported; full-chord ties can be corrected in the editor."
            )
        }
        if gaps > 0 {
            review.append(
                "Filled \(gaps) gaps with explicit rests. Check these against the source, including empty hands and voices."
            )
        }
        if spellingConflicts {
            review.append(
                "Some note spellings were missing or inconsistent; automatic spellings were used. Check accidentals.")
        }
        if tempo == nil {
            review.append("No tempo was detected. Playback starts at 90 bpm; adjust it to suit the source.")
        }
        if instrument == .guitar {
            try document.setGuitar(tuning: tuning, capo: capo)
            review.append(
                "Tab fingerings are proposed from the detected pitches, not copied from the PDF. Review string choices and comfort."
            )
        }
        var seen = Set<String>()
        review = review.filter { seen.insert($0).inserted }
        guard (harmonies?.count ?? 0) <= 512 else {
            throw MusicError.invalid("Too many chord symbols were returned. Choose a shorter passage.")
        }
        for item in harmonies ?? [] {
            guard (1...barCount).contains(item.bar), (1...staffs).contains(item.staff), item.start.isFinite,
                item.start >= 0, item.start < Double(meter.ticks) / 480, item.symbol.count <= 64
            else { throw MusicError.invalid("A chord symbol has an invalid bar, staff or position.") }
            let ticks = item.start * 480
            guard abs(ticks.rounded() - ticks) < 0.02 else {
                throw MusicError.invalid("A chord symbol falls outside the supported timing grid.")
            }
            do {
                try document.setHarmony(
                    EditorHarmony(
                        bar: item.bar - 1, tick: Int(ticks.rounded()), staff: item.staff,
                        symbol: ChordSymbol.parse(item.symbol)))
            } catch {
                review.insert(
                    "Chord symbol ‘\(item.symbol)’ at bar \(item.bar), quarter-beat \(item.start+1) needs manual entry: "
                        + error.localizedDescription, at: 0)
            }
        }
        if !(harmonies ?? []).isEmpty {
            review.append(
                "Check every chord symbol and its beat against the original; printed harmony is separate from the written notes."
            )
        }
        return PDFDraftResult(document: try document.validated(), warnings: Array(review.prefix(100)))
    }
}
