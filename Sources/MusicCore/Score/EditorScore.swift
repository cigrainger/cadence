// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

public enum EditorInstrument: String, Codable, CaseIterable, Sendable {
    case guitar = "Guitar"
    case piano = "Piano"
}
public struct EditorMeter: Codable, Equatable, Hashable, Sendable {
    public var beats: Int
    public var unit: Int
    public init(_ beats: Int, _ unit: Int) {
        self.beats = beats
        self.unit = unit
    }
    public var label: String { "\(beats)/\(unit)" }
    public var ticks: Int { beats * 1920 / unit }
    public static let choices = [
        Self(2, 4), Self(3, 4), Self(4, 4), Self(5, 4), Self(6, 8), Self(9, 8), Self(12, 8), Self(2, 2),
    ]
}
public struct EditorRhythm: Codable, Equatable, Hashable, Sendable {
    public var base: Int
    public var dotted: Bool
    public var triplet: Bool
    public init(_ base: Int = 480, dotted: Bool = false, triplet: Bool = false) {
        self.base = base
        self.dotted = dotted
        self.triplet = triplet
    }
    public var ticks: Int { triplet ? base * 2 / 3 : dotted ? base * 3 / 2 : base }
    public var xmlType: String {
        [1920: "whole", 960: "half", 480: "quarter", 240: "eighth", 120: "16th"][base] ?? "quarter"
    }
    public var label: String {
        [1920: "Whole", 960: "Half", 480: "Quarter", 240: "Eighth", 120: "Sixteenth"][base, default: "Quarter"]
            + (dotted ? " · dotted" : triplet ? " · triplet" : "")
    }
    public static var choices: [EditorRhythm] {
        [1920, 960, 480, 240, 120].flatMap {
            [EditorRhythm($0), EditorRhythm($0, dotted: true), EditorRhythm($0, triplet: true)]
        }
    }
    public static func matching(_ ticks: Int) -> EditorRhythm? { choices.first { $0.ticks == ticks } }
}
public struct EditorPitch: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var midi: Int
    public var spelling: Pitch
    public var string: Int?
    public var fret: Int?
    public init(_ midi: Int, spelling: Pitch? = nil, string: Int? = nil, fret: Int? = nil) {
        self.midi = midi
        self.spelling = spelling ?? Pitch.spelled(midi, flats: false)
        self.string = string
        self.fret = fret
    }
    public var label: String { Solfege.noteName(midi: midi, pitch: spelling) }
}
public enum EditorStem: String, Codable, CaseIterable, Sendable { case automatic, up, down }
public struct EditorEvent: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var bar: Int
    public var staff: Int
    public var voice: Int
    public var rhythm: EditorRhythm
    public var pitches: [EditorPitch]
    public var tieNext: Bool
    public var stem: EditorStem
    public var staccato: Bool
    public var accent: Bool
    public var dynamic: MusicDynamic?
    public var slurTo: UUID?
    public var picking: String?
    public init(
        bar: Int, staff: Int = 1, voice: Int = 1, rhythm: EditorRhythm = EditorRhythm(), pitches: [EditorPitch] = [],
        tieNext: Bool = false, stem: EditorStem = .automatic, staccato: Bool = false, accent: Bool = false,
        dynamic: MusicDynamic? = nil, slurTo: UUID? = nil
    ) {
        self.bar = bar
        self.staff = staff
        self.voice = voice
        self.rhythm = rhythm
        self.pitches = pitches
        self.tieNext = tieNext
        self.stem = stem
        self.staccato = staccato
        self.accent = accent
        self.dynamic = dynamic
        self.slurTo = slurTo
    }
    private enum CodingKeys: String, CodingKey {
        case id, bar, staff, voice, rhythm, pitches, tieNext, stem, staccato, accent, dynamic, slurTo, picking
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bar = try c.decode(Int.self, forKey: .bar)
        staff = try c.decode(Int.self, forKey: .staff)
        rhythm = try c.decode(EditorRhythm.self, forKey: .rhythm)
        pitches = try c.decode([EditorPitch].self, forKey: .pitches)
        tieNext = try c.decode(Bool.self, forKey: .tieNext)
        voice = try c.decodeIfPresent(Int.self, forKey: .voice) ?? 1
        stem = try c.decodeIfPresent(EditorStem.self, forKey: .stem) ?? .automatic
        staccato = try c.decodeIfPresent(Bool.self, forKey: .staccato) ?? false
        accent = try c.decodeIfPresent(Bool.self, forKey: .accent) ?? false
        dynamic = try c.decodeIfPresent(MusicDynamic.self, forKey: .dynamic)
        slurTo = try c.decodeIfPresent(UUID.self, forKey: .slurTo)
        picking = try c.decodeIfPresent(String.self, forKey: .picking)
    }
    public var isRest: Bool { pitches.isEmpty }
    public var label: String { isRest ? "Rest" : pitches.map(\.label).joined(separator: " + ") }
}
/// Two independent, complete voices per staff, with integer quarter-note ticks.
public struct EditorDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 9
    public var id = UUID()
    public var title: String
    public var instrument: EditorInstrument
    public var tempo = 90
    public var fifths = 0
    public var minor = false
    public var tuning = Tuning.presets[0]
    public var capo = 0
    public var barCount = 4
    public var meter = EditorMeter(4, 4)
    public var events: [EditorEvent]
    public var harmonies: [EditorHarmony] = []
    public var pdfSource: PDFScoreSource?
    public var responseSource: CreativeResponse?
    public var triadSource: TriadMaterial?
    public var pickingSource: PickingMaterial?
    public var pickingStyle: PickingStyle?
    public var tensionSource: TensionSource?
    public var reharmSource: ReharmSource?
    public init(title: String, instrument: EditorInstrument, events: [EditorEvent]) {
        self.title = title
        self.instrument = instrument
        self.events = events
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, instrument, tempo, fifths, minor, tuning, capo, barCount, meter, events,
            harmonies, pdfSource, responseSource, triadSource, tensionSource, reharmSource, pickingSource, pickingStyle
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard [1, 2, 3, 4, 5, 6, 7, 8, 9].contains(version) else {
            throw MusicError.invalid("This score needs a newer version of Cadence.")
        }
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        instrument = try values.decode(EditorInstrument.self, forKey: .instrument)
        tempo = try values.decode(Int.self, forKey: .tempo)
        fifths = try values.decode(Int.self, forKey: .fifths)
        minor = try values.decodeIfPresent(Bool.self, forKey: .minor) ?? false
        tuning = try values.decode(Tuning.self, forKey: .tuning)
        capo = try values.decode(Int.self, forKey: .capo)
        events = try values.decode([EditorEvent].self, forKey: .events)
        harmonies = try values.decodeIfPresent([EditorHarmony].self, forKey: .harmonies) ?? []
        pdfSource = try values.decodeIfPresent(PDFScoreSource.self, forKey: .pdfSource)
        responseSource = try values.decodeIfPresent(CreativeResponse.self, forKey: .responseSource)
        pickingStyle = try values.decodeIfPresent(PickingStyle.self, forKey: .pickingStyle)
        pickingSource = try values.decodeIfPresent(PickingMaterial.self, forKey: .pickingSource)
        triadSource = try values.decodeIfPresent(TriadMaterial.self, forKey: .triadSource)
        tensionSource = try values.decodeIfPresent(TensionSource.self, forKey: .tensionSource)
        reharmSource = try values.decodeIfPresent(ReharmSource.self, forKey: .reharmSource)
        barCount = version == 1 ? 4 : try values.decode(Int.self, forKey: .barCount)
        meter = version == 1 ? EditorMeter(4, 4) : try values.decode(EditorMeter.self, forKey: .meter)
        schemaVersion = 9
    }
    public var staffCount: Int { instrument == .piano ? 2 : 1 }
    public func voices(staff: Int) -> [Int] { Array(Set(events.filter { $0.staff == staff }.map(\.voice))).sorted() }
    public func ordered(staff: Int, voice: Int = 1) -> [EditorEvent] {
        events.filter { $0.staff == staff && $0.voice == voice }.sorted { $0.bar < $1.bar }
    }
    public func inBar(_ bar: Int, staff: Int, voice: Int = 1) -> [EditorEvent] {
        events.filter { $0.bar == bar && $0.staff == staff && $0.voice == voice }
    }
    public func onset(_ event: EditorEvent) -> Int {
        inBar(event.bar, staff: event.staff, voice: event.voice).prefix { $0.id != event.id }.reduce(0) {
            $0 + $1.rhythm.ticks
        }
    }
    public func tuplet(_ event: EditorEvent) -> (first: UUID, last: UUID, actual: Int, normal: Int, unit: EditorRhythm)?
    {
        guard event.rhythm.triplet else { return nil }
        let items = inBar(event.bar, staff: event.staff, voice: event.voice)
        guard let index = items.firstIndex(where: { $0.id == event.id }) else { return nil }
        var lo = index
        var hi = index
        while lo > 0 && items[lo - 1].rhythm.triplet { lo -= 1 }
        while hi + 1 < items.count && items[hi + 1].rhythm.triplet { hi += 1 }
        let group = items[lo...hi]
        let unit = group.map(\.rhythm.base).min()!
        let actual = group.reduce(0) { $0 + $1.rhythm.base } / unit
        return (items[lo].id, items[hi].id, actual, actual * 2 / 3, EditorRhythm(unit))
    }
    public func validated() throws -> Self {
        guard pickingSource?.valid ?? true else {
            throw MusicError.invalid("The accompaniment source link is invalid.")
        }
        guard reharmSource?.valid ?? true else {
            throw MusicError.invalid("The reharmonisation’s source link is invalid.")
        }
        guard tensionSource?.valid ?? true else {
            throw MusicError.invalid("The alternative ending’s source link is invalid.")
        }
        guard triadSource?.valid ?? true else {
            throw MusicError.invalid("The guitar answer’s source link is invalid.")
        }
        guard responseSource?.valid ?? true else {
            throw MusicError.invalid("The composition’s source link is invalid.")
        }
        guard pdfSource?.valid ?? true else { throw MusicError.invalid("The score's PDF source reference is invalid.") }
        if let source = pdfSource, source.pages != nil {
            guard source.totalPageBars == barCount || (source.totalPageBars == 0 && barCount == 1) else {
                throw MusicError.invalid("The imported page links do not match the score's bars.")
            }
        }
        guard schemaVersion == 9, (1...128).contains(barCount), EditorMeter.choices.contains(meter), title.count <= 500,
            (20...300).contains(tempo), (-7...7).contains(fifths), (0...9).contains(capo), tuning.pitches.count == 6,
            tuning.pitches.allSatisfy({ (24...88).contains($0) }), events.count <= 4096,
            events.reduce(0, { $0 + max(1, $1.pitches.count) }) * (instrument == .guitar ? 2 : 1) <= 10000,
            Set(events.map(\.id)).count == events.count
        else {
            throw MusicError.invalid(
                "Choose 1–128 bars, a supported meter, and a score with up to 4,096 events / 10,000 written notes.")
        }
        try validateHarmonies()
        let allPitches = events.flatMap(\.pitches)
        guard Set(allPitches.map(\.id)).count == allPitches.count else {
            throw MusicError.invalid("Duplicate note identities in the score.")
        }
        for event in events {
            guard event.picking.map({ ["p", "i", "m", "a", "p + m", "↓", "↑"].contains($0) }) ?? true else {
                throw MusicError.invalid("Unknown picking guidance.")
            }
            guard (0..<barCount).contains(event.bar), (1...staffCount).contains(event.staff),
                (1...2).contains(event.voice), [1920, 960, 480, 240, 120].contains(event.rhythm.base),
                !(event.rhythm.dotted && event.rhythm.triplet), event.pitches.count <= (instrument == .guitar ? 6 : 8)
            else { throw MusicError.invalid("This note has an unsupported rhythm or staff.") }
            var strings = Set<Int>()
            for pitch in event.pitches {
                guard (21...108).contains(pitch.midi), (0..<7).contains(pitch.spelling.letter),
                    (-2...2).contains(pitch.spelling.accidental), pitch.spelling.pc == mod(pitch.midi)
                else { throw MusicError.invalid("Invalid written note spelling.") }
                if instrument == .guitar {
                    guard let string = pitch.string, let fret = pitch.fret, (0..<6).contains(string),
                        (0...24).contains(fret), tuning.pitches[string] + capo + fret == pitch.midi,
                        strings.insert(string).inserted
                    else { throw MusicError.invalid("Choose playable guitar fingerings on separate strings.") }
                }
            }
            if event.tieNext {
                guard !event.isRest, let next = nextEvent(event),
                    next.pitches.map(\.midi).sorted() == event.pitches.map(\.midi).sorted()
                else { throw MusicError.invalid("A tie needs the same notes immediately afterwards.") }
            }
        }
        for staff in 1...staffCount {
            guard voices(staff: staff).contains(1) else { throw MusicError.invalid("Every staff needs voice 1.") }
            for voice in voices(staff: staff) {
                for bar in 0..<barCount {
                    let items = inBar(bar, staff: staff, voice: voice)
                    guard !items.isEmpty, items.reduce(0, { $0 + $1.rhythm.ticks }) == meter.ticks else {
                        throw MusicError.invalid("Every bar must be complete in \(meter.label), including rests.")
                    }
                }
            }
        }
        try validateExpressionAndStrings()
        for event in events where event.rhythm.triplet {
            guard let group = tuplet(event), group.actual % 3 == 0 else {
                throw MusicError.invalid(
                    "Keep a complete triplet group together. Edit its pitches, or undo the rhythm change first.")
            }
        }
        return self
    }
    public func nextEvent(_ event: EditorEvent) -> EditorEvent? {
        let sequence = ordered(staff: event.staff, voice: event.voice)
        guard let index = sequence.firstIndex(where: { $0.id == event.id }), index + 1 < sequence.count else {
            return nil
        }
        return sequence[index + 1]
    }
    public mutating func clearInvalidTies() {
        clearInvalidSlurs()
        for i in events.indices {
            if events[i].tieNext, let next = nextEvent(events[i]),
                next.pitches.map(\.midi).sorted() == events[i].pitches.map(\.midi).sorted()
            {
            } else {
                events[i].tieNext = false
            }
        }
    }
    public mutating func setRhythm(_ id: UUID, _ rhythm: EditorRhythm) throws {
        var copy = self
        try copy.applyRhythm(id, rhythm)
        self = copy
    }
    private mutating func applyRhythm(_ id: UUID, _ rhythm: EditorRhythm) throws {
        guard let old = events.first(where: { $0.id == id }) else { return }
        guard EditorRhythm.choices.contains(rhythm) else { throw MusicError.invalid("Choose a supported note value.") }
        var remaining = rhythm.ticks - old.rhythm.ticks
        if remaining > 0 {
            let following = inBar(old.bar, staff: old.staff, voice: old.voice).drop { $0.id != id }.dropFirst()
            for rest in following where remaining > 0 {
                guard rest.isRest, rest.dynamic == nil else {
                    throw MusicError.invalid(
                        "Make space in this voice first: replace the following note with a rest, or choose a shorter duration. Dynamic markings are kept."
                    )
                }
                let index = events.firstIndex { $0.id == rest.id }!
                events.remove(at: index)
                if rest.rhythm.ticks > remaining {
                    events.insert(
                        contentsOf: try Self.rests(
                            ticks: rest.rhythm.ticks - remaining, bar: old.bar, staff: old.staff, voice: old.voice),
                        at: index)
                }
                remaining = max(0, remaining - rest.rhythm.ticks)
            }
            guard remaining == 0 else { throw MusicError.invalid("This note would extend past its bar.") }
        } else if remaining < 0 {
            let index = events.firstIndex { $0.id == id }!
            events.insert(
                contentsOf: try Self.rests(ticks: -remaining, bar: old.bar, staff: old.staff, voice: old.voice),
                at: index + 1)
        }
        events[events.firstIndex { $0.id == id }!].rhythm = rhythm
        clearInvalidTies()
    }
    private static func rests(ticks: Int, bar: Int, staff: Int, voice: Int = 1) throws -> [EditorEvent] {
        let choices = EditorRhythm.choices.sorted { $0.ticks > $1.ticks }
        var failed = Set<Int>()
        func find(_ remaining: Int) -> [EditorRhythm]? {
            if remaining == 0 { return [] }
            if failed.contains(remaining) { return nil }
            for rhythm in choices where rhythm.ticks <= remaining {
                if let tail = find(remaining - rhythm.ticks) { return [rhythm] + tail }
            }
            failed.insert(remaining)
            return nil
        }
        guard let rhythms = find(ticks) else {
            throw MusicError.invalid("That rhythm leaves a gap smaller than a supported note value.")
        }
        return rhythms.map { EditorEvent(bar: bar, staff: staff, voice: voice, rhythm: $0) }
    }
    public mutating func setPitch(_ id: UUID, pitchID: UUID? = nil, midi: Int, spelling: Pitch? = nil) throws {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let slot = pitchID.flatMap { value in events[index].pitches.firstIndex { $0.id == value } } ?? 0
        let old = events[index].pitches.indices.contains(slot) ? events[index].pitches[slot] : nil
        var pitch = EditorPitch(midi, spelling: spelling ?? Pitch.spelled(midi, flats: fifths < 0))
        if let old { pitch.id = old.id }
        if instrument == .guitar {
            let used = Set(
                events[index].pitches.enumerated().filter { $0.offset != slot }.compactMap { $0.element.string }
            ).union(otherVoiceStrings(events[index]))
            let positions = Guitar.positions(midi: midi, tuning: tuning, capo: capo).filter {
                !used.contains($0.string)
            }
            guard
                let position = positions.min(by: {
                    abs($0.fret - (old?.fret ?? 3)) + ($0.string == old?.string ? -3 : 0) < abs(
                        $1.fret - (old?.fret ?? 3)) + ($1.string == old?.string ? -3 : 0)
                })
            else { throw MusicError.invalid("That note needs a different string or is outside this guitar's range.") }
            pitch.string = position.string
            pitch.fret = position.fret
        }
        if events[index].pitches.isEmpty {
            events[index].pitches = [pitch]
        } else {
            events[index].pitches[slot] = pitch
        }
        clearInvalidTies()
    }
    public mutating func setFingering(_ eventID: UUID, pitchID: UUID, string: Int, fret: Int) throws {
        guard instrument == .guitar, let index = events.firstIndex(where: { $0.id == eventID }),
            let slot = events[index].pitches.firstIndex(where: { $0.id == pitchID }),
            tuning.pitches.indices.contains(string), (0...24).contains(fret)
        else { throw MusicError.invalid("Choose a guitar string and fret from 0–24.") }
        guard !otherVoiceStrings(events[index]).contains(string),
            !events[index].pitches.enumerated().contains(where: { $0.offset != slot && $0.element.string == string })
        else { throw MusicError.invalid("Another note in this chord already uses that string.") }
        var pitch = events[index].pitches[slot]
        pitch.string = string
        pitch.fret = fret
        pitch.midi = tuning.pitches[string] + capo + fret
        pitch.spelling = Pitch.spelled(pitch.midi, flats: fifths < 0)
        events[index].pitches[slot] = pitch
        clearInvalidTies()
    }
    public mutating func addChordTone(_ id: UUID) throws {
        guard let index = events.firstIndex(where: { $0.id == id }), let root = events[index].pitches.first else {
            throw MusicError.invalid("Enter a note before adding a chord tone.")
        }
        guard events[index].pitches.count < (instrument == .guitar ? 6 : 8) else {
            throw MusicError.invalid("This chord is full.")
        }
        let used = Set(events[index].pitches.compactMap(\.string)).union(otherVoiceStrings(events[index]))
        let last = events[index].pitches.last!.midi
        for interval in [4, 3, 7, 12, 5] {
            let midi = last + interval
            guard midi <= 108, !events[index].pitches.contains(where: { $0.midi == midi }) else { continue }
            var pitch = EditorPitch(midi, spelling: Pitch.spelled(midi, flats: fifths < 0))
            if instrument == .guitar {
                guard
                    let position = Guitar.positions(midi: midi, tuning: tuning, capo: capo).filter({
                        !used.contains($0.string)
                    }).min(by: { abs($0.fret - (root.fret ?? 3)) < abs($1.fret - (root.fret ?? 3)) })
                else { continue }
                pitch.string = position.string
                pitch.fret = position.fret
            }
            events[index].pitches.append(pitch)
            clearInvalidTies()
            return
        }
        throw MusicError.invalid("No additional playable chord tone is available here.")
    }
    public mutating func setGuitar(tuning: Tuning, capo: Int) throws {
        guard tuning.pitches.count == 6, tuning.pitches.allSatisfy({ (24...88).contains($0) }), (0...9).contains(capo)
        else { throw MusicError.invalid("Choose a supported guitar tuning and capo.") }
        var copy = self
        try copy.applyGuitar(tuning: tuning, capo: capo)
        self = copy
    }
    private mutating func applyGuitar(tuning: Tuning, capo: Int) throws {
        self.tuning = tuning
        self.capo = capo
        // Allocate across the full timeline so a sustained bass keeps its string.
        let raw = events.flatMap { event in
            event.pitches.map { pitch -> ScoreNote in
                var n = ScoreNote(
                    midi: pitch.midi, start: Double(event.bar * meter.ticks + onset(event)) / 480,
                    duration: Double(event.rhythm.ticks) / 480, string: pitch.string, fret: pitch.fret,
                    spelling: pitch.spelling)
                n.id = pitch.id
                return n
            }
        }
        let fingered = Score(notes: raw).fingered(tuning: tuning, capo: capo)
        let positions = Dictionary(uniqueKeysWithValues: fingered.notes.map { ($0.id, $0) })
        for i in events.indices {
            for p in events[i].pitches.indices {
                guard let note = positions[events[i].pitches[p].id], let string = note.string, let fret = note.fret
                else {
                    throw MusicError.invalid(
                        "This tuning or capo cannot play all the overlapping voices. Change a pitch or shorten a note first."
                    )
                }
                events[i].pitches[p].string = string
                events[i].pitches[p].fret = fret
            }
        }
        try validateExpressionAndStrings()
    }
    public static func blank(instrument: EditorInstrument, bars: Int = 4, meter: EditorMeter = EditorMeter(4, 4)) throws
        -> Self
    {
        guard (1...128).contains(bars), EditorMeter.choices.contains(meter) else {
            throw MusicError.invalid("Choose 1–128 bars and a supported time signature.")
        }
        var doc = Self(title: "Untitled score", instrument: instrument, events: [])
        doc.barCount = bars
        doc.meter = meter
        for staff in 1...doc.staffCount {
            for bar in 0..<bars { doc.events += try rests(ticks: meter.ticks, bar: bar, staff: staff) }
        }
        return try doc.validated()
    }
    private func checked(_ range: ClosedRange<Int>) throws {
        guard range.lowerBound >= 0, range.upperBound < barCount else {
            throw MusicError.invalid("Choose bars inside this score.")
        }
    }
    /// The excerpt retains note identities so a paged renderer can select the original.
    public func excerpt(_ range: ClosedRange<Int>) throws -> Self {
        _ = try validated()
        try checked(range)
        var copy = self
        copy.barCount = range.count
        copy.events = events.filter { range.contains($0.bar) }.map {
            var e = $0
            e.bar -= range.lowerBound
            return e
        }
        for staff in 1...staffCount {
            for voice in voices(staff: staff) {
                if let first = copy.ordered(staff: staff, voice: voice).first, first.dynamic == nil,
                    let inherited = ordered(staff: staff, voice: voice).last(where: {
                        $0.bar < range.lowerBound && $0.dynamic != nil
                    })?.dynamic,
                    let index = copy.events.firstIndex(where: { $0.id == first.id })
                {
                    copy.events[index].dynamic = inherited
                }
            }
        }
        copy.harmonies = harmonies.filter { range.contains($0.bar) }.map {
            var h = $0
            h.bar -= range.lowerBound
            return h
        }
        copy.pdfSource = pdfSource?.excerpt(range)
        copy.clearInvalidTies()
        return try copy.validated()
    }
    public mutating func insertBars(at index: Int, count: Int = 1) throws {
        _ = try validated()
        guard (0...barCount).contains(index), (1...128).contains(count), barCount + count <= 128 else {
            throw MusicError.invalid("Scores can contain up to 128 bars.")
        }
        var copy = self
        copy.barCount += count
        copy.pdfSource?.insertBars(at: index, count: count)
        for i in copy.harmonies.indices where copy.harmonies[i].bar >= index { copy.harmonies[i].bar += count }
        for i in copy.events.indices where copy.events[i].bar >= index { copy.events[i].bar += count }
        for staff in 1...staffCount {
            for voice in voices(staff: staff) {
                for bar in index..<(index + count) {
                    copy.events += try Self.rests(ticks: meter.ticks, bar: bar, staff: staff, voice: voice)
                }
            }
        }
        copy.sortEvents()
        copy.clearInvalidTies()
        self = try copy.validated()
    }
    public mutating func deleteBars(_ range: ClosedRange<Int>) throws {
        _ = try validated()
        try checked(range)
        guard range.count < barCount else {
            throw MusicError.invalid("Keep at least one bar. Use Clear passage to empty the score.")
        }
        var copy = self
        copy.events.removeAll { range.contains($0.bar) }
        copy.barCount -= range.count
        copy.pdfSource?.deleteBars(range)
        copy.harmonies.removeAll { range.contains($0.bar) }
        for i in copy.harmonies.indices where copy.harmonies[i].bar > range.upperBound {
            copy.harmonies[i].bar -= range.count
        }
        // A deletion never creates a tie between notes that were not adjacent before.
        let boundary = Set(
            (1...staffCount).flatMap { staff in
                voices(staff: staff).compactMap { inBar(range.lowerBound - 1, staff: staff, voice: $0).last?.id }
            })
        for i in copy.events.indices {
            if boundary.contains(copy.events[i].id) { copy.events[i].tieNext = false }
            if copy.events[i].bar > range.upperBound { copy.events[i].bar -= range.count }
        }
        copy.clearInvalidTies()
        self = try copy.validated()
    }
    public mutating func paste(_ passage: Self, at index: Int, inserting: Bool) throws {
        _ = try validated()
        _ = try passage.validated()
        guard instrument == passage.instrument, meter == passage.meter else {
            throw MusicError.invalid("Copy and paste between scores with the same instrument and time signature.")
        }
        guard index >= 0, index <= barCount, index + passage.barCount <= 128 else {
            throw MusicError.invalid("This passage would exceed 128 bars.")
        }
        let required = Dictionary(
            uniqueKeysWithValues: (1...staffCount).map {
                ($0, Array(Set(voices(staff: $0) + passage.voices(staff: $0))).sorted())
            })
        var copy = self
        if inserting {
            try copy.insertBars(at: index, count: passage.barCount)
        } else if index + passage.barCount > barCount {
            try copy.insertBars(at: barCount, count: index + passage.barCount - barCount)
        }
        let end = index + passage.barCount - 1
        copy.events.removeAll { (index...end).contains($0.bar) }
        copy.harmonies.removeAll { (index...end).contains($0.bar) }
        copy.harmonies += passage.harmonies.map {
            var h = $0
            h.id = UUID()
            h.bar += index
            return h
        }
        let boundary = Set(
            (1...staffCount).flatMap { staff in
                copy.voices(staff: staff).compactMap { copy.inBar(index - 1, staff: staff, voice: $0).last?.id }
            })
        for i in copy.events.indices where boundary.contains(copy.events[i].id) { copy.events[i].tieNext = false }
        let identities = Dictionary(uniqueKeysWithValues: passage.events.map { ($0.id, UUID()) })
        copy.events += passage.events.map { item in
            var e = item
            e.id = identities[item.id]!
            e.slurTo = item.slurTo.flatMap { identities[$0] }
            e.bar += index
            e.pitches = e.pitches.map {
                var p = $0
                p.id = UUID()
                return p
            }
            if e.bar == end, passage.nextEvent(item)?.bar != item.bar { e.tieNext = false }
            return e
        }
        try copy.fillMissingVoices(required)
        copy.sortEvents()
        if instrument == .guitar { try copy.setGuitar(tuning: tuning, capo: capo) }
        copy.clearInvalidTies()
        self = try copy.validated()
    }
    public mutating func clearBars(_ range: ClosedRange<Int>) throws {
        _ = try validated()
        try checked(range)
        var blank = try Self.blank(instrument: instrument, bars: range.count, meter: meter)
        blank.tuning = tuning
        blank.capo = capo
        try paste(blank, at: range.lowerBound, inserting: false)
    }
    public mutating func transpose(_ range: ClosedRange<Int>, semitones: Int) throws {
        _ = try validated()
        try checked(range)
        guard (-24...24).contains(semitones) else {
            throw MusicError.invalid("Transpose by up to two octaves at a time.")
        }
        var copy = self
        for i in copy.harmonies.indices where range.contains(copy.harmonies[i].bar) {
            copy.harmonies[i].symbol = copy.harmonies[i].symbol.transposed(semitones, flats: fifths < 0)
        }
        for i in copy.events.indices where range.contains(copy.events[i].bar) {
            for j in copy.events[i].pitches.indices {
                let midi = copy.events[i].pitches[j].midi + semitones
                guard (21...108).contains(midi) else {
                    throw MusicError.invalid("This passage would move outside the supported instrument range.")
                }
                copy.events[i].pitches[j].midi = midi
                copy.events[i].pitches[j].spelling = Pitch.spelled(midi, flats: fifths < 0)
            }
        }
        if instrument == .guitar { try copy.setGuitar(tuning: tuning, capo: capo) }
        copy.clearInvalidTies()
        self = try copy.validated()
    }
    /// Preserve every sounding note and onset. A shorter bar may remove only trailing rests.
    public mutating func setMeter(_ value: EditorMeter) throws {
        _ = try validated()
        guard EditorMeter.choices.contains(value) else {
            throw MusicError.invalid("Choose a supported time signature.")
        }
        guard value != meter else { return }
        var copy = self
        copy.meter = value
        copy.events = []
        for staff in 1...staffCount {
            for voice in voices(staff: staff) {
                for bar in 0..<barCount {
                    var used = 0
                    for event in inBar(bar, staff: staff, voice: voice) {
                        let end = used + event.rhythm.ticks
                        if end <= value.ticks {
                            copy.events.append(event)
                        } else {
                            guard event.isRest else {
                                throw MusicError.invalid(
                                    "Bar \(bar+1) contains a note past the end of \(value.label). Clear or shorten those notes first; changing meter preserves their positions within each bar."
                                )
                            }
                            if used < value.ticks {
                                copy.events += try Self.rests(
                                    ticks: value.ticks - used, bar: bar, staff: staff, voice: voice)
                            }
                        }
                        used = end
                    }
                    if used < value.ticks {
                        copy.events += try Self.rests(ticks: value.ticks - used, bar: bar, staff: staff, voice: voice)
                    }
                }
            }
        }
        copy.clearInvalidTies()
        self = try copy.validated()
    }
    private mutating func sortEvents() {
        events = events.enumerated().sorted { a, b in
            if a.element.staff != b.element.staff { return a.element.staff < b.element.staff }
            if a.element.voice != b.element.voice { return a.element.voice < b.element.voice }
            if a.element.bar != b.element.bar { return a.element.bar < b.element.bar }
            return a.offset < b.offset
        }.map(\.element)
    }
    public func playback(from bar: Int = 0, through endBar: Int? = nil, speed: Double = 1) -> Score {
        let through = min(barCount - 1, endBar ?? barCount - 1)
        let bar = max(0, bar)
        guard bar <= through, let xml = try? EditorXML.encode(self), let study = try? StudyImport.read(Data(xml.utf8))
        else { return Score(title: title, tempo: Double(tempo), beatsPerBar: meter.beats, beatUnit: meter.unit) }
        let start = Double(bar * meter.ticks) / 480
        let end = Double((through + 1) * meter.ticks) / 480
        let notes = study.parts[0].soundingNotes().filter { $0.start < end && $0.start + $0.duration > start }.map {
            note -> ScoreNote in
            var n = note
            n.start = max(start, note.start) - start
            n.duration = min(end, note.start + note.duration) - max(start, note.start)
            return n
        }
        return Score(
            title: title, tempo: Double(tempo) * speed, beatsPerBar: meter.beats, beatUnit: meter.unit, fifths: fifths,
            notes: notes)
    }
    public static var guitarExample: Self {
        let phrases = [[60, 62, 64, 67], [65, 64, 62, 60], [57, 60, 64, 62], [55, 59, 60, 60]]
        var events: [EditorEvent] = []
        for bar in 0..<4 {
            for midi in phrases[bar] {
                let pos = Guitar.positions(midi: midi, tuning: Tuning.presets[0], capo: 0).min { $0.fret < $1.fret }!
                events.append(EditorEvent(bar: bar, pitches: [EditorPitch(midi, string: pos.string, fret: pos.fret)]))
            }
        }
        events[14].tieNext = true
        return Self(title: "A phrase to make your own", instrument: .guitar, events: events)
    }
    public static var pianoExample: Self {
        var events: [EditorEvent] = []
        for (bar, melody) in [[64, 67, 72, 71], [69, 67, 65, 64], [62, 65, 69, 67], [64, 62, 60, 60]].enumerated() {
            for midi in melody { events.append(EditorEvent(bar: bar, pitches: [EditorPitch(midi)])) }
        }
        for (bar, chord) in [[48, 52, 55], [45, 48, 52], [50, 53, 57], [48, 52, 55]].enumerated() {
            events.append(
                EditorEvent(bar: bar, staff: 2, rhythm: EditorRhythm(1920), pitches: chord.map { EditorPitch($0) }))
        }
        events[14].tieNext = true
        return Self(title: "Two hands, one small phrase", instrument: .piano, events: events)
    }
}

extension EditorDocument {
    public mutating func addVoice(staff: Int) throws {
        guard (1...staffCount).contains(staff), !voices(staff: staff).contains(2) else { return }
        var copy = self
        for bar in 0..<barCount { copy.events += try Self.rests(ticks: meter.ticks, bar: bar, staff: staff, voice: 2) }
        copy.sortEvents()
        self = try copy.validated()
    }
    public mutating func removeSecondVoice(staff: Int) throws {
        var copy = self
        copy.events.removeAll { $0.staff == staff && $0.voice == 2 }
        copy.clearInvalidTies()
        self = try copy.validated()
    }
    private mutating func fillMissingVoices(_ required: [Int: [Int]]) throws {
        for staff in 1...staffCount {
            for voice in required[staff] ?? voices(staff: staff) {
                for bar in 0..<barCount where inBar(bar, staff: staff, voice: voice).isEmpty {
                    events += try Self.rests(ticks: meter.ticks, bar: bar, staff: staff, voice: voice)
                }
            }
        }
    }
    private func otherVoiceStrings(_ event: EditorEvent) -> Set<Int> {
        guard voices(staff: event.staff).count > 1 else { return [] }
        let start = onset(event)
        let end = start + event.rhythm.ticks
        return Set(
            events.filter { other in
                guard other.bar == event.bar, other.staff == event.staff, other.voice != event.voice else {
                    return false
                }
                let time = onset(other)
                return time < end && time + other.rhythm.ticks > start
            }.flatMap(\.pitches).compactMap(\.string))
    }
    private mutating func clearInvalidSlurs() {
        for i in events.indices {
            if let id = events[i].slurTo, !slurTargets(events[i]).contains(where: { $0.id == id }) {
                events[i].slurTo = nil
            }
            if events[i].isRest {
                events[i].staccato = false
                events[i].accent = false
                events[i].slurTo = nil
            }
        }
    }
    public func slurTargets(_ event: EditorEvent) -> [EditorEvent] {
        guard !event.isRest else { return [] }
        let sequence = ordered(staff: event.staff, voice: event.voice)
        guard let index = sequence.firstIndex(where: { $0.id == event.id }) else { return [] }
        return Array(sequence.dropFirst(index + 1).prefix { !$0.isRest })
    }
    /// Beam eighths/sixteenths within written beats (dotted quarters in compound time).
    public func beams(_ event: EditorEvent) -> [(Int, String)] {
        guard !event.isRest, event.rhythm.base <= 240 else { return [] }
        let items = inBar(event.bar, staff: event.staff, voice: event.voice)
        guard let i = items.firstIndex(where: { $0.id == event.id }) else { return [] }
        let beat = meter.unit == 8 && [6, 9, 12].contains(meter.beats) ? 720 : 1920 / meter.unit
        let bucket = onset(event) / beat
        func connects(_ index: Int, _ base: Int) -> Bool {
            guard items.indices.contains(index) else { return false }
            let e = items[index]
            let start = onset(e)
            return !e.isRest && e.rhythm.base <= base && start / beat == bucket
                && (start + e.rhythm.ticks - 1) / beat == bucket
        }
        guard (onset(event) + event.rhythm.ticks - 1) / beat == bucket else { return [] }
        let before = connects(i - 1, 240)
        let after = connects(i + 1, 240)
        guard before || after else { return [] }
        var result = [(1, before ? (after ? "continue" : "end") : "begin")]
        if event.rhythm.base == 120 {
            let a = connects(i - 1, 120)
            let b = connects(i + 1, 120)
            result.append((2, a ? (b ? "continue" : "end") : b ? "begin" : after ? "forward hook" : "backward hook"))
        }
        return result
    }
    private func validateExpressionAndStrings() throws {
        for staff in 1...staffCount {
            for voice in voices(staff: staff) {
                let sequence = ordered(staff: staff, voice: voice)
                var previousEnd = -1
                for (i, event) in sequence.enumerated() {
                    guard !event.isRest || (!event.staccato && !event.accent && event.slurTo == nil) else {
                        throw MusicError.invalid("Attach articulations and slurs to notes, rather than rests.")
                    }
                    if let id = event.slurTo {
                        guard let end = sequence.firstIndex(where: { $0.id == id }), end > i, i >= previousEnd,
                            sequence[i...end].allSatisfy({ !$0.isRest })
                        else {
                            throw MusicError.invalid(
                                "A slur joins later notes in the same voice, without rests or overlapping slurs.")
                        }
                        previousEnd = end
                    }
                }
            }
        }
        if instrument == .guitar {
            for event in events where !event.isRest {
                guard Set(event.pitches.compactMap(\.string)).isDisjoint(with: otherVoiceStrings(event)) else {
                    throw MusicError.invalid(
                        "Two voices need the same guitar string at once. Choose a different string, shorten the held note, or change the pitch."
                    )
                }
            }
        }
    }
    /// Original two-voice study. Bass sustains beneath independently moving upper notes.
    public static var fingerstyleExample: Self {
        var doc = Self(title: "Quiet strings · fingerstyle study", instrument: .guitar, events: [])
        doc.tempo = 84
        let melody = [
            [64, 67, 69, 67, 64, 62, 60, 62], [65, 69, 72, 69, 65, 64, 62, 60], [64, 67, 71, 67, 64, 62, 59, 62],
            [64, 67, 64, 62, 60, 62, 60, 60],
        ]
        let bass = [[48, 55], [41, 48], [43, 50], [48, 55]]
        for bar in 0..<4 {
            var phrase: [EditorEvent] = []
            for (i, midi) in melody[bar].enumerated() {
                let pos = Guitar.positions(midi: midi, tuning: doc.tuning, capo: 0).filter { $0.string >= 3 }.min {
                    $0.fret < $1.fret
                }!
                phrase.append(
                    EditorEvent(
                        bar: bar, rhythm: EditorRhythm(240),
                        pitches: [EditorPitch(midi, string: pos.string, fret: pos.fret)], accent: i == 0,
                        dynamic: i == 0 && bar == 0 ? .mp : nil))
            }
            phrase[0].slurTo = phrase[3].id
            phrase[4].slurTo = phrase[7].id
            doc.events += phrase
        }
        for bar in 0..<4 {
            for (i, midi) in bass[bar].enumerated() {
                let pos = Guitar.positions(midi: midi, tuning: doc.tuning, capo: 0).filter { $0.string < 3 }.min {
                    $0.fret < $1.fret
                }!
                doc.events.append(
                    EditorEvent(
                        bar: bar, voice: 2, rhythm: EditorRhythm(960),
                        pitches: [EditorPitch(midi, string: pos.string, fret: pos.fret)],
                        dynamic: bar == 0 && i == 0 ? .p : nil))
            }
        }
        return doc
    }
    public static var innerVoiceExample: Self {
        var doc = Self(title: "Between the hands · piano study", instrument: .piano, events: [])
        doc.tempo = 76
        for (bar, melody) in [[76, 74], [77, 76], [74, 71], [72, 72]].enumerated() {
            let a = EditorEvent(
                bar: bar, rhythm: EditorRhythm(960), pitches: [EditorPitch(melody[0])], dynamic: bar == 0 ? .mp : nil)
            let b = EditorEvent(bar: bar, rhythm: EditorRhythm(960), pitches: [EditorPitch(melody[1])])
            var first = a
            first.slurTo = b.id
            doc.events += [first, b]
        }
        for (bar, line) in [[60, 64, 67, 64], [60, 65, 69, 65], [59, 62, 67, 62], [60, 64, 67, 64]].enumerated() {
            for (i, midi) in line.enumerated() {
                doc.events.append(
                    EditorEvent(
                        bar: bar, voice: 2, pitches: [EditorPitch(midi)], staccato: bar == 2,
                        accent: bar == 3 && i == 0, dynamic: bar == 0 && i == 0 ? .p : nil))
            }
        }
        for (bar, bass) in [48, 41, 43, 48].enumerated() {
            doc.events.append(
                EditorEvent(
                    bar: bar, staff: 2, rhythm: EditorRhythm(1920), pitches: [EditorPitch(bass)],
                    dynamic: bar == 0 ? .pp : nil))
        }
        return doc
    }
}
