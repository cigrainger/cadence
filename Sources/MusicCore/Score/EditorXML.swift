// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum EditorXML {
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func encode(_ document: EditorDocument, includeTab: Bool = true, firstBarNumber: Int = 1) throws
        -> String
    {
        _ = try document.validated()
        let guitar = document.instrument == .guitar
        let staffCount = guitar ? (includeTab ? 2 : 1) : 2
        var xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><score-partwise version=\"4.0\"><work><work-title>\(escape(document.title))</work-title></work><identification><encoding><software>Cadence Compose</software></encoding></identification><part-list><score-part id=\"P1\"><part-name>\(document.instrument.rawValue)</part-name><score-instrument id=\"I1\"><instrument-name>\(document.instrument.rawValue)</instrument-name></score-instrument><midi-instrument id=\"I1\"><midi-channel>1</midi-channel><midi-program>\(guitar ? 25 : 1)</midi-program></midi-instrument></score-part></part-list><part id=\"P1\">"
        for bar in 0..<document.barCount {
            xml += "<measure number=\"\(bar+firstBarNumber)\">"
            if bar == 0 {
                xml +=
                    "<attributes><divisions>480</divisions><key><fifths>\(document.fifths)</fifths><mode>\(document.minor ? "minor" : "major")</mode></key><time><beats>\(document.meter.beats)</beats><beat-type>\(document.meter.unit)</beat-type></time><staves>\(staffCount)</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef>"
                if staffCount == 2 {
                    xml +=
                        guitar
                        ? "<clef number=\"2\"><sign>TAB</sign><line>5</line></clef>"
                        : "<clef number=\"2\"><sign>F</sign><line>4</line></clef>"
                }
                if guitar {
                    if includeTab {
                        xml +=
                            "<staff-details number=\"2\"><staff-type>alternate</staff-type><staff-lines>6</staff-lines>"
                        for (index, midi) in document.tuning.pitches.enumerated() {
                            let p = Pitch.spelled(midi, flats: false)
                            xml +=
                                "<staff-tuning line=\"\(index+1)\"><tuning-step>\(Pitch.letters[p.letter])</tuning-step><tuning-alter>\(p.accidental)</tuning-alter><tuning-octave>\((midi-Pitch.naturals[p.letter]-p.accidental)/12-1)</tuning-octave></staff-tuning>"
                        }
                        xml += "<capo>\(document.capo)</capo></staff-details>"
                    }
                    xml +=
                        "<transpose><diatonic>0</diatonic><chromatic>0</chromatic><octave-change>-1</octave-change></transpose>"
                }
                xml +=
                    "</attributes><direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>\(document.tempo)</per-minute></metronome></direction-type><sound tempo=\"\(document.tempo)\"/></direction>"
            }
            xml += document.harmonies(in: bar).map { HarmonyXML.encode($0) }.joined()
            var firstVoice = true
            for staff in 1...staffCount {
                for voice in document.voices(staff: guitar ? 1 : staff) {
                    if !firstVoice { xml += "<backup><duration>\(document.meter.ticks)</duration></backup>" }
                    firstVoice = false
                    let sourceStaff = guitar ? 1 : staff
                    let xmlVoice = (staff - 1) * 2 + voice
                    let sequence = document.ordered(staff: sourceStaff, voice: voice)
                    for event in document.inBar(bar, staff: sourceStaff, voice: voice) {
                        if staff == 1, let cue = event.picking {
                            xml +=
                                "<direction placement=\"above\"><direction-type><words>\(escape(cue))</words></direction-type><voice>\(xmlVoice)</voice><staff>1</staff></direction>"
                        }
                        if let dynamic = event.dynamic {
                            xml +=
                                "<direction placement=\"\(document.voices(staff:sourceStaff).count > 1 && voice == 1 ? "above" : "below")\"><direction-type><dynamics><\(dynamic.rawValue)/></dynamics></direction-type><voice>\(xmlVoice)</voice><staff>\(staff)</staff></direction>"
                        }
                        let slurStop = sequence.contains { $0.slurTo == event.id }
                        let tuplet = document.tuplet(event)
                        let previous = sequence.firstIndex(where: { $0.id == event.id }).flatMap {
                            $0 > 0 ? sequence[$0 - 1] : nil
                        }
                        let stopTie = previous?.tieNext == true
                        let entries: [EditorPitch?] = event.isRest ? [nil] : event.pitches.map { Optional($0) }
                        for (index, pitch) in entries.enumerated() {
                            xml +=
                                "<note id=\"n\(event.id.uuidString.replacingOccurrences(of:"-",with:""))s\(staff)p\(index)\">"
                            if index > 0 { xml += "<chord/>" }
                            if let pitch {
                                let midi = pitch.midi + (guitar ? 12 : 0)
                                xml +=
                                    "<pitch><step>\(Pitch.letters[pitch.spelling.letter])</step><alter>\(pitch.spelling.accidental)</alter><octave>\((midi-Pitch.naturals[pitch.spelling.letter]-pitch.spelling.accidental)/12-1)</octave></pitch>"
                            } else {
                                xml += "<rest/>"
                            }
                            xml += "<duration>\(event.rhythm.ticks)</duration>"
                            if stopTie { xml += "<tie type=\"stop\"/>" }
                            if event.tieNext { xml += "<tie type=\"start\"/>" }
                            xml += "<voice>\(xmlVoice)</voice><type>\(event.rhythm.xmlType)</type>"
                            if event.rhythm.dotted { xml += "<dot/>" }
                            if let tuplet {
                                xml +=
                                    "<time-modification><actual-notes>\(tuplet.actual)</actual-notes><normal-notes>\(tuplet.normal)</normal-notes><normal-type>\(event.rhythm.xmlType)</normal-type></time-modification>"
                            }
                            let stem =
                                event.stem == .automatic
                                ? (document.voices(staff: sourceStaff).count > 1 ? (voice == 1 ? "up" : "down") : nil)
                                : event.stem.rawValue
                            if let stem, pitch != nil { xml += "<stem>\(stem)</stem>" }
                            xml += "<staff>\(staff)</staff>"
                            for (level, value) in document.beams(event) {
                                xml += "<beam number=\"\(level)\">\(value)</beam>"
                            }
                            if (pitch != nil && (guitar || stopTie || event.tieNext)) || tuplet != nil
                                || (pitch != nil && (event.staccato || event.accent || event.slurTo != nil || slurStop))
                            {
                                xml += "<notations>"
                                if stopTie { xml += "<tied type=\"stop\"/>" }
                                if event.tieNext { xml += "<tied type=\"start\"/>" }
                                if index == 0 && pitch != nil {
                                    if slurStop { xml += "<slur type=\"stop\" number=\"\(xmlVoice)\"/>" }
                                    if event.slurTo != nil { xml += "<slur type=\"start\" number=\"\(xmlVoice)\"/>" }
                                    if event.staccato || event.accent {
                                        xml +=
                                            "<articulations>" + (event.staccato ? "<staccato/>" : "")
                                            + (event.accent ? "<accent/>" : "") + "</articulations>"
                                    }
                                }
                                if let pitch, guitar && staff == 2 {
                                    xml +=
                                        "<technical><string>\(6-pitch.string!)</string><fret>\(pitch.fret!)</fret></technical>"
                                }
                                if let tuplet, index == 0 {
                                    if event.id == tuplet.first {
                                        xml +=
                                            "<tuplet type=\"start\" number=\"1\" bracket=\"yes\"><tuplet-actual><tuplet-number>\(tuplet.actual)</tuplet-number><tuplet-type>\(tuplet.unit.xmlType)</tuplet-type></tuplet-actual><tuplet-normal><tuplet-number>\(tuplet.normal)</tuplet-number><tuplet-type>\(tuplet.unit.xmlType)</tuplet-type></tuplet-normal></tuplet>"
                                    }
                                    if event.id == tuplet.last { xml += "<tuplet type=\"stop\" number=\"1\"/>" }
                                }
                                xml += "</notations>"
                            }
                            xml += "</note>"
                        }
                    }
                }
            }
            xml += "</measure>"
        }
        return xml + "</part></score-partwise>"
    }
    public static func decode(_ data: Data) throws -> EditorDocument {
        let study = try StudyImport.read(data)
        guard study.parts.count == 1, let part = study.parts.first, let first = part.measures.first,
            (1...128).contains(part.measures.count),
            EditorMeter.choices.contains(EditorMeter(first.beats, first.beatUnit)),
            part.measures.allSatisfy({
                $0.beats == first.beats && $0.beatUnit == first.beatUnit
                    && abs($0.duration - Double(first.beats) * 4 / Double(first.beatUnit)) < 0.0001
                    && $0.fifths == first.fifths
            })
        else {
            throw MusicError.invalid(
                "Compose opens one part with 1–128 complete bars, one supported time signature and one key signature. Read other scores in Studies."
            )
        }
        let metadata = EditorXMLMetadata()
        let parser = XMLParser(data: Data(study.originalXML.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = metadata
        guard parser.parse(), metadata.unsupported == nil, metadata.tempos.count <= 1,
            metadata.tempos.allSatisfy({ $0.isFinite && (20...300).contains($0) && $0.rounded() == $0 }),
            metadata.rhythms.count == part.notes.count
        else {
            throw MusicError.invalid(
                metadata.unsupported ?? "Compose requires one constant tempo and supported written rhythms.")
        }
        let guitar = !part.tabStaves.isEmpty || part.name.lowercased().contains("guitar")
        guard
            metadata.clefs.allSatisfy({ clef in
                clef.octave == 0
                    && ((clef.staff == 1 && clef.sign == "G" && clef.line == 2)
                        || (clef.staff == 2 && (guitar ? clef.sign == "TAB" : clef.sign == "F" && clef.line == 4)))
            }), metadata.modes.count <= 1, metadata.modes.allSatisfy({ ["major", "minor"].contains($0) })
        else {
            throw MusicError.invalid(
                "Compose currently preserves treble guitar, or treble/bass piano, in a major or minor key. Read other clefs or key modes in Studies."
            )
        }
        if guitar {
            let standard = part.notes.filter { $0.staff == 1 }
            guard part.tabStaves.isSubset(of: [2]),
                standard.filter({ $0.midi >= 0 }).allSatisfy({ ($0.writtenMidi ?? $0.midi) - $0.midi == 12 }),
                part.notes.filter({ part.tabStaves.contains($0.staff) }).allSatisfy({ tab in
                    standard.contains {
                        $0.midi == tab.midi && abs($0.start - tab.start) < 0.0001
                            && abs($0.duration - tab.duration) < 0.0001
                    }
                })
            else {
                throw MusicError.invalid(
                    "The guitar score needs standard notation written one octave above sounding pitch, with matching linked tab. Read other guitar formats in Studies."
                )
            }
        }
        let sourceStaves = Set(part.notes.filter { !part.tabStaves.contains($0.staff) }.map(\.staff))
        var voiceMaps: [Int: [String: Int]] = [:]
        for staff in sourceStaves {
            let names = Array(Set(part.notes.filter { $0.staff == staff }.map(\.voice))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            guard names.count <= 2 else { throw MusicError.invalid("Compose supports up to two voices per staff.") }
            voiceMaps[staff] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset + 1) })
        }
        let tabNames = Array(Set(part.notes.filter { part.tabStaves.contains($0.staff) }.map(\.voice))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let tabVoices = Dictionary(uniqueKeysWithValues: tabNames.enumerated().map { ($0.element, $0.offset + 1) })
        if guitar, !part.tabStaves.isEmpty, tabNames.count != voiceMaps[1]?.count {
            throw MusicError.invalid(
                "The linked tab needs the same number of independent voices as the standard staff.")
        }
        var document = EditorDocument(title: study.title, instrument: guitar ? .guitar : .piano, events: [])
        document.barCount = part.measures.count
        document.meter = EditorMeter(first.beats, first.beatUnit)
        document.minor = metadata.modes.contains("minor")
        document.tempo = Int(study.tempo.rounded())
        document.fifths = part.measures[0].fifths
        document.capo = metadata.capo
        if guitar, metadata.tuning.count == 6 {
            document.tuning = Tuning("Imported tuning", (1...6).map { metadata.tuning[$0]! })
        }
        var usedTab = Set<UUID>()
        var noteEvents: [UUID: UUID] = [:]
        for (index, note) in part.notes.enumerated() where !part.tabStaves.contains(note.staff) {
            guard guitar ? note.staff == 1 : (1...2).contains(note.staff),
                let voice = voiceMaps[note.staff]?[note.voice]
            else {
                throw MusicError.invalid("Compose supports guitar, or two piano staves, with up to two voices each.")
            }
            let rhythm = metadata.rhythms[index]
            guard abs(Double(rhythm.ticks) / 480 - note.duration) < 0.0001 else {
                throw MusicError.invalid("This written rhythm is outside Compose’s supported note values.")
            }
            let tab =
                guitar
                ? part.notes.first {
                    !usedTab.contains($0.id) && part.tabStaves.contains($0.staff) && tabVoices[$0.voice] == voice
                        && $0.midi == note.midi && abs($0.start - note.start) < 0.0001
                        && abs($0.duration - note.duration) < 0.0001
                } : nil
            if guitar, !part.tabStaves.isEmpty, tab == nil {
                throw MusicError.invalid(
                    "Each standard note/rest needs matching rhythm and pitch in its linked tab voice.")
            }
            if let tab { usedTab.insert(tab.id) }
            let pitch: EditorPitch? =
                note.midi >= 0
                ? EditorPitch(
                    note.midi, spelling: note.writtenPitch, string: note.string ?? tab?.string,
                    fret: note.fret ?? tab?.fret) : nil
            let expr = note.expression ?? StudyExpression()
            let previous = document.inBar(note.measure, staff: note.staff, voice: voice).last
            if let previous,
                abs(Double(document.onset(previous)) / 480 + part.measures[note.measure].start - note.start) < 0.0001
            {
                guard let pitch, previous.rhythm == rhythm, previous.tieNext == note.tieStart else {
                    throw MusicError.invalid("Chord tones must share a duration and tie pattern in Compose.")
                }
                let i = document.events.firstIndex { $0.id == previous.id }!
                guard (!expr.staccato || previous.staccato) && (!expr.accent || previous.accent) else {
                    throw MusicError.invalid(
                        "Compose applies articulations to an entire chord. Put them on its first note before importing."
                    )
                }
                document.events[i].pitches.append(pitch)
                noteEvents[note.id] = previous.id
            } else {
                var event = EditorEvent(
                    bar: note.measure, staff: note.staff, voice: voice, rhythm: rhythm,
                    pitches: pitch.map { [$0] } ?? [], tieNext: note.tieStart, stem: metadata.stems[index],
                    staccato: expr.staccato, accent: expr.accent)
                let marks = (part.dynamics ?? []).filter {
                    $0.staff == note.staff && ($0.voice == nil || $0.voice == note.voice)
                        && abs($0.start - note.start) < 0.0001
                }
                guard marks.count <= 1 else {
                    throw MusicError.invalid("Compose needs one dynamic marking per voice at a note or rest onset.")
                }
                event.dynamic = marks.first?.dynamic
                let end = document.inBar(note.measure, staff: note.staff, voice: voice).reduce(0) {
                    $0 + $1.rhythm.ticks
                }
                guard abs(Double(end) / 480 + part.measures[note.measure].start - note.start) < 0.0001 else {
                    throw MusicError.invalid("Explicit rests are required between notes in each Compose voice.")
                }
                document.events.append(event)
                noteEvents[note.id] = event.id
            }
        }
        // Do not quietly discard unattached or off-grid direction markings.
        for mark in part.dynamics ?? [] where !part.tabStaves.contains(mark.staff) {
            guard
                part.notes.contains(where: {
                    $0.staff == mark.staff && (mark.voice == nil || mark.voice == $0.voice)
                        && abs($0.start - mark.start) < 0.0001
                })
            else {
                throw MusicError.invalid("Place dynamic markings on note or rest onsets before opening in Compose.")
            }
        }
        var openSlurs: [String: UUID] = [:]
        for note in part.notes where !part.tabStaves.contains(note.staff) {
            guard let eventID = noteEvents[note.id] else { continue }
            let expr = note.expression ?? StudyExpression()
            for number in expr.slurStops {
                let key = "\(note.staff):\(note.voice):\(number)"
                guard let start = openSlurs.removeValue(forKey: key),
                    let i = document.events.firstIndex(where: { $0.id == start }), document.events[i].slurTo == nil
                else { throw MusicError.invalid("Compose needs complete slurs within one voice.") }
                document.events[i].slurTo = eventID
            }
            for number in expr.slurStarts {
                let key = "\(note.staff):\(note.voice):\(number)"
                guard openSlurs[key] == nil else {
                    throw MusicError.invalid("Compose cannot preserve overlapping slurs in a voice.")
                }
                openSlurs[key] = eventID
            }
        }
        guard openSlurs.isEmpty else { throw MusicError.invalid("Compose needs both ends of every slur.") }
        if !guitar, !part.notes.contains(where: { $0.staff == 2 }) {
            for bar in 0..<document.barCount {
                document.events += try EditorDocument.blank(instrument: .piano, bars: 1, meter: document.meter).events
                    .filter { $0.staff == 2 }.map {
                        var e = $0
                        e.bar = bar
                        return e
                    }
            }
        }
        document.harmonies = try HarmonyXML.decode(study.originalXML)
        if guitar {
            // Missing technical marks can be proposed; explicit marks are retained.
            if document.events.flatMap(\.pitches).contains(where: { $0.string == nil || $0.fret == nil }) {
                try document.setGuitar(tuning: document.tuning, capo: document.capo)
            }
        }
        return try document.validated()
    }
}

private final class EditorXMLMetadata: NSObject, XMLParserDelegate {
    var stems: [EditorStem] = [], currentStem: EditorStem = .automatic
    var rhythms: [EditorRhythm] = [], unsupported: String?, capo = 0, tuning: [Int: Int] = [:]
    var tempos = Set<Double>()
    var modes = Set<String>()
    var clefs: [(staff: Int, sign: String, line: Int, octave: Int)] = []
    private var strings: [String] = [], stack: [String] = []
    private var type = "quarter", dots = 0, actual = 0, normal = 0, tuningLine = 0, step = "", alter = 0, octave = 2
    private var clefStaff = 1, clefSign = "", clefLine = 2, clefOctave = 0
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        stack.append(name)
        strings.append("")
        if name == "note" {
            currentStem = .automatic
            type = "quarter"
            dots = 0
            actual = 0
            normal = 0
        }
        if name == "sound", let value = attributes["tempo"].flatMap(Double.init) { tempos.insert(value) }
        if name == "clef" {
            clefStaff = Int(attributes["number"] ?? "1") ?? 1
            clefSign = ""
            clefLine = 2
            clefOctave = 0
        }
        if name == "dot" { dots += 1 }
        if [
            "grace", "unpitched", "ornaments", "lyric", "repeat", "ending", "pedal", "wedge", "words", "octave-shift",
            "arpeggiate", "non-arpeggiate", "fermata", "glissando", "slide", "hammer-on", "pull-off", "bend",
            "notehead", "tremolo", "scordatura", "metronome-dot", "segno", "coda", "rehearsal",
        ].contains(name) {
            unsupported =
                "This score contains \(name) markings that Compose cannot preserve yet. You can still read it in Studies."
        }
        if stack.dropLast().last == "articulations", !["staccato", "accent"].contains(name) {
            unsupported =
                "Compose currently preserves staccato and accent articulations. Read other markings in Studies."
        }
        if stack.dropLast().last == "dynamics", MusicDynamic(rawValue: name) == nil {
            unsupported = "Compose supports ppp through fff dynamic markings. Read other dynamics in Studies."
        }
        if name == "slur", !["start", "stop"].contains(attributes["type"] ?? "") {
            unsupported = "Compose needs simple start/stop slurs. Read complex slurs in Studies."
        }
        if name == "staff-tuning" {
            tuningLine = Int(attributes["line"] ?? "0") ?? 0
            step = ""
            alter = 0
            octave = 2
        }
    }
    func parser(_ parser: XMLParser, foundCharacters value: String) {
        if !strings.isEmpty { strings[strings.count - 1] += value }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = (strings.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "stem":
            if let stem = EditorStem(rawValue: value) {
                currentStem = stem
            } else {
                unsupported = "Compose supports up, down or automatic stems."
            }
        case "type": type = value
        case "actual-notes": actual = Int(value) ?? 0
        case "normal-notes": normal = Int(value) ?? 0
        case "per-minute": if let number = Double(value) { tempos.insert(number) }
        case "mode": modes.insert(value)
        case "sign": if stack.dropLast().last == "clef" { clefSign = value }
        case "line": if stack.dropLast().last == "clef" { clefLine = Int(value) ?? 0 }
        case "clef-octave-change": clefOctave = Int(value) ?? 0
        case "clef": clefs.append((clefStaff, clefSign, clefLine, clefOctave))
        case "beat-unit":
            if value != "quarter" {
                unsupported = "Compose currently uses quarter-note tempo markings. Read this score in Studies."
            }
        case "capo": capo = Int(value) ?? 0
        case "tuning-step": step = value
        case "tuning-alter": alter = Int(value) ?? 0
        case "tuning-octave": octave = Int(value) ?? 2
        case "staff-tuning":
            if let letter = Pitch.letters.firstIndex(of: step), (1...6).contains(tuningLine), (0...8).contains(octave),
                (-2...2).contains(alter)
            {
                tuning[tuningLine] = (octave + 1) * 12 + Pitch.naturals[letter] + alter
            }
        case "note":
            stems.append(currentStem)
            if let base = ["whole": 1920, "half": 960, "quarter": 480, "eighth": 240, "16th": 120][type], dots <= 1,
                actual == 0 || ((1...192).contains(actual) && (1...192).contains(normal) && actual * 2 == normal * 3),
                !(dots > 0 && actual > 0)
            {
                rhythms.append(EditorRhythm(base, dotted: dots == 1, triplet: actual > 0))
            } else {
                unsupported = "This score uses a written rhythm Compose cannot preserve yet."
            }
        default: break
        }
        strings.removeLast()
        stack.removeLast()
    }
}
