// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

public struct ScoreNote: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var midi: Int  // -1 denotes a rest
    public var start: Double
    public var duration: Double
    public var string: Int?
    public var fret: Int?
    public var channel: Int? = nil
    public var performance: NotePerformance? = nil
    public var spelling: Pitch?
    public init(
        midi: Int, start: Double, duration: Double = 1, string: Int? = nil, fret: Int? = nil, spelling: Pitch? = nil
    ) {
        self.id = UUID()
        self.midi = midi
        self.start = start
        self.duration = duration
        self.string = string
        self.fret = fret
        self.spelling = spelling
    }
}

public struct Score: Codable, Equatable, Sendable {
    public var title: String
    public var tempo: Double
    public var beatsPerBar: Int
    public var beatUnit: Int
    public var fifths: Int
    public var notes: [ScoreNote]
    public init(
        title: String = "Untitled study", tempo: Double = 90, beatsPerBar: Int = 4, beatUnit: Int = 4, fifths: Int = 0,
        notes: [ScoreNote] = []
    ) {
        self.title = title
        self.tempo = tempo
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
        self.fifths = fifths
        self.notes = notes
    }
    public var barLength: Double { Double(beatsPerBar) * 4 / Double(beatUnit) }
    public var length: Double { max(barLength, notes.map { $0.start + $0.duration }.max() ?? 0) }
    public static var example: Score {
        Score(
            title: "A little C major",
            notes: [60, 62, 64, 67, 65, 64, 62, 60].enumerated().map {
                ScoreNote(midi: $0.element, start: Double($0.offset))
            })
    }
    public func validated() throws -> Score {
        guard tempo.isFinite, (20...300).contains(tempo), (1...16).contains(beatsPerBar),
            [2, 4, 8, 16].contains(beatUnit), (-7...7).contains(fifths), notes.count <= 10000
        else { throw MusicError.invalid("Invalid score settings or score is too large.") }
        for note in notes {
            guard (-1...127).contains(note.midi), note.start.isFinite, note.start >= 0, note.start < 100000,
                note.duration.isFinite, note.duration > 0, note.duration <= 64
            else { throw MusicError.invalid("A note has an invalid pitch, position, or duration.") }
            if let c = note.channel {
                guard (0...15).contains(c) else { throw MusicError.invalid("Invalid MIDI channel.") }
            }
            if let p = note.performance {
                guard (1...127).contains(p.velocity), p.gate.isFinite, (0.1...1.1).contains(p.gate) else {
                    throw MusicError.invalid("Invalid note expression.")
                }
            }
            if let s = note.string {
                guard (0..<6).contains(s) else { throw MusicError.invalid("Invalid guitar string.") }
            }
            if let f = note.fret {
                guard (0...24).contains(f) else { throw MusicError.invalid("Invalid guitar fret.") }
            }
            if let spelling = note.spelling {
                guard (0..<7).contains(spelling.letter), abs(spelling.accidental) <= 2, spelling.pc == mod(note.midi)
                else { throw MusicError.invalid("Invalid note spelling.") }
            }
        }
        return self
    }
    public func fingered(tuning: Tuning, capo: Int) -> Score {
        var copy = self
        var previousFret = 3
        var occupied: [(end: Double, string: Int)] = []
        for index in copy.notes.indices.sorted(by: { copy.notes[$0].start < copy.notes[$1].start }) {
            let note = copy.notes[index]
            if note.midi < 0 {
                copy.notes[index].string = nil
                copy.notes[index].fret = nil
                continue
            }
            occupied.removeAll { $0.end <= note.start + 0.00001 }
            let unavailable = Set(occupied.map(\.string))
            if let string = note.string, let fret = note.fret, (0..<tuning.pitches.count).contains(string),
                !unavailable.contains(string), tuning.pitches[string] + capo + fret == note.midi
            {
                previousFret = fret
                occupied.append((note.start + note.duration, string))
                continue
            }
            let possible = Guitar.positions(midi: note.midi, tuning: tuning, capo: capo).filter {
                !unavailable.contains($0.string)
            }
            let choice = possible.min {
                abs($0.fret - previousFret) + ($0.fret == 0 ? -2 : 0) < abs($1.fret - previousFret)
                    + ($1.fret == 0 ? -2 : 0)
            }
            copy.notes[index].string = choice?.string
            copy.notes[index].fret = choice?.fret
            if let choice {
                previousFret = choice.fret
                occupied.append((note.start + note.duration, choice.string))
            }
        }
        return copy
    }
}

public enum MusicError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public enum MIDIFile {
    private static func be(_ value: Int, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
    }
    private static func vlq(_ value: Int) -> [UInt8] {
        var v = value
        var bytes = [UInt8(v & 127)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 127) | 128, at: 0)
            v >>= 7
        }
        return bytes
    }
    public static func encode(_ score: Score, endBeat: Double? = nil, program: Int = 0, minor: Bool = false) -> Data {
        let division = 480
        let micros = Int(60_000_000 / score.tempo)
        let denominator = [2: 1, 4: 2, 8: 3, 16: 4][score.beatUnit] ?? 2
        let pulse = score.beatUnit == 8 && [6, 9, 12].contains(score.beatsPerBar) ? 36 : 96 / max(1, score.beatUnit)
        var events: [(tick: Int, order: Int, bytes: [UInt8])] = [
            (0, -5, [0xff, 0x51, 3] + be(micros, bytes: 3)),
            (
                0, -4,
                [0xff, 0x58, 4, UInt8(clamping: score.beatsPerBar), UInt8(denominator), UInt8(clamping: pulse), 8]
            ),
            (0, -3, [0xff, 0x59, 2, UInt8(bitPattern: Int8(clamping: score.fifths)), minor ? 1 : 0]),
            (0, -1, [0xc0, UInt8(clamping: min(127, max(0, program)))]),
        ]
        for channel in Set(score.notes.compactMap(\.channel)).sorted() where channel != 0 {
            events.append((0, -1, [0xc0 + UInt8(clamping: channel), UInt8(clamping: min(127, max(0, program)))]))
        }
        for note in score.notes where note.midi >= 0 && note.midi <= 127 {
            events.append(
                (
                    Int((note.start * Double(division)).rounded()), 1,
                    [
                        0x90 + UInt8(clamping: note.channel ?? 0), UInt8(note.midi),
                        UInt8(clamping: note.performance?.velocity ?? 90),
                    ]
                ))
            var end = note.start + note.duration * (note.performance?.gate ?? 1)
            if let next = score.notes.filter({
                $0.midi == note.midi && ($0.channel ?? 0) == (note.channel ?? 0) && $0.start > note.start
            }).map(\.start).min() {
                end = min(end, next)
            }
            events.append(
                (
                    Int((end * Double(division)).rounded()), 0,
                    [0x80 + UInt8(clamping: note.channel ?? 0), UInt8(note.midi), 0]
                ))
        }
        events.sort { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }
        var track: [UInt8] = []
        var tick = 0
        for event in events {
            track += vlq(event.tick - tick) + event.bytes
            tick = event.tick
        }
        let end =
            endBeat.flatMap { $0.isFinite && (0...100000).contains($0) ? Int(($0 * Double(division)).rounded()) : nil }
            ?? tick
        track += vlq(max(0, end - tick)) + [0xff, 0x2f, 0]
        return Data(
            Array("MThd".utf8) + be(6, bytes: 4) + be(0, bytes: 2) + be(1, bytes: 2) + be(division, bytes: 2)
                + Array("MTrk".utf8) + be(track.count, bytes: 4) + track)
    }
}

public enum MusicXML {
    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
            of: ">", with: "&gt;"
        ).replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func encode(_ score: Score) -> String {
        let divisions = 480
        let barCount = max(1, Int(ceil(score.length / score.barLength)))
        var xml =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><score-partwise version=\"4.0\"><work><work-title>\(escaped(score.title))</work-title></work><part-list><score-part id=\"P1\"><part-name>Study</part-name></score-part></part-list><part id=\"P1\">"
        for bar in 0..<barCount {
            let base = Double(bar) * score.barLength
            xml += "<measure number=\"\(bar+1)\">"
            if bar == 0 {
                xml +=
                    "<attributes><divisions>\(divisions)</divisions><key><fifths>\(score.fifths)</fifths></key><time><beats>\(score.beatsPerBar)</beats><beat-type>\(score.beatUnit)</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><direction><sound tempo=\"\(score.tempo)\"/></direction>"
            }
            let inBar = score.notes.filter {
                $0.start < base + score.barLength - 0.0001 && $0.start + $0.duration > base + 0.0001
            }.sorted { $0.start == $1.start ? $0.midi < $1.midi : $0.start < $1.start }
            var cursor = 0.0
            for note in inBar {
                let start = max(0, note.start - base)
                let duration = min(note.start + note.duration, base + score.barLength) - max(note.start, base)
                if start > cursor + 0.0001 {
                    xml +=
                        "<forward><duration>\(Int(((start-cursor)*Double(divisions)).rounded()))</duration></forward>"
                }
                if start < cursor - 0.0001 {
                    xml += "<backup><duration>\(Int(((cursor-start)*Double(divisions)).rounded()))</duration></backup>"
                }
                xml += "<note>"
                if note.midi < 0 {
                    xml += "<rest/>"
                } else {
                    let pitch = note.spelling ?? Pitch.roots.first { $0.pc == mod(note.midi) }!
                    let octave = (note.midi - Pitch.naturals[pitch.letter] - pitch.accidental) / 12 - 1
                    xml +=
                        "<pitch><step>\(Pitch.letters[pitch.letter])</step><alter>\(pitch.accidental)</alter><octave>\(octave)</octave></pitch>"
                    if note.start < base { xml += "<tie type=\"stop\"/>" }
                    if note.start + note.duration > base + score.barLength + 0.0001 { xml += "<tie type=\"start\"/>" }
                }
                xml += "<duration>\(max(1,Int((duration * Double(divisions)).rounded())))</duration>"
                if let s = note.string, let f = note.fret {
                    xml += "<notations><technical><string>\(6-s)</string><fret>\(f)</fret></technical></notations>"
                }
                xml += "</note>"
                cursor = start + duration
            }
            if cursor < score.barLength {
                xml +=
                    "<forward><duration>\(Int(((score.barLength-cursor)*Double(divisions)).rounded()))</duration></forward>"
            }
            xml += "</measure>"
        }
        return xml + "</part></score-partwise>"
    }
    public static func decode(_ data: Data) throws -> Score {
        let delegate = XMLScoreParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let error = delegate.failure else {
            if let failure = delegate.failure { throw MusicError.invalid(failure) }
            if parser.parserError != nil { throw MusicError.invalid("This is not a supported MusicXML document.") }
            guard delegate.sawPart else {
                throw MusicError.invalid("No score found. Open an uncompressed MusicXML file.")
            }
            return try delegate.score.validated()
        }
        throw MusicError.invalid(error)
    }
}

private final class XMLScoreParser: NSObject, XMLParserDelegate {
    var score = Score()
    var failure: String?
    var sawPart = false
    var stack: [String] = []
    var text = ""
    var divisions = 1.0
    var cursor = 0.0, measureBase = 0.0, measureEnd = 0.0, previousStart = 0.0
    var step = "C", alter = 0, octave = 4, duration = 1.0
    var rest = false, chord = false, grace = false, tieStart = false, tieStop = false
    var string: Int?, fret: Int?
    var ties: [Int: Int] = [:]
    var partOffset = 0.0
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        stack.append(name)
        text = ""
        if name == "score-timewise" {
            failure = "Please export partwise MusicXML first."
            parser.abortParsing()
        }
        if name == "part" {
            sawPart = true
            measureBase = 0
            measureEnd = 0
            cursor = 0
            ties = [:]
        }
        if name == "measure" {
            measureBase = max(measureBase, measureEnd)
            cursor = measureBase
            previousStart = cursor
        }
        if name == "note" {
            step = "C"
            alter = 0
            octave = 4
            duration = 1
            rest = false
            chord = false
            grace = false
            tieStart = false
            tieStop = false
            string = nil
            fret = nil
        }
        if name == "rest" { rest = true }
        if name == "chord" { chord = true }
        if name == "grace" { grace = true }
        if name == "tie" {
            tieStart = tieStart || attributes["type"] == "start"
            tieStop = tieStop || attributes["type"] == "stop"
        }
        if name == "sound", let tempo = attributes["tempo"].flatMap(Double.init) { score.tempo = tempo }
        if name == "repeat" {
            failure = "Expand repeats before importing this score. Cadence currently reads written notes in order."
            parser.abortParsing()
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "work-title": if !value.isEmpty { score.title = value }
        case "divisions": divisions = max(1, Double(value) ?? 1)
        case "fifths": score.fifths = Int(value) ?? 0
        case "beats": score.beatsPerBar = Int(value) ?? 4
        case "beat-type": score.beatUnit = Int(value) ?? 4
        case "step": step = value
        case "alter": alter = Int(value) ?? 0
        case "octave": octave = Int(value) ?? 4
        case "string": string = Int(value).map { 6 - $0 }
        case "fret": fret = Int(value)
        case "duration":
            let d = (Double(value) ?? 1) / divisions
            if stack.contains("backup") {
                cursor -= d
            } else if stack.contains("forward") {
                cursor += d
                measureEnd = max(measureEnd, cursor)
            } else {
                duration = d
            }
        case "note":
            if !grace {
                let letter = Pitch.letters.firstIndex(of: step) ?? 0
                let midi = rest ? -1 : (octave + 1) * 12 + Pitch.naturals[letter] + alter
                let start = chord ? previousStart : cursor
                if tieStop, let index = ties[midi],
                    abs(score.notes[index].start + score.notes[index].duration - start) < 0.001
                {
                    score.notes[index].duration += duration
                    if !tieStart { ties[midi] = nil }
                } else {
                    score.notes.append(
                        ScoreNote(
                            midi: midi, start: start, duration: duration, string: string, fret: fret,
                            spelling: rest ? nil : Pitch(letter, alter)))
                    if tieStart { ties[midi] = score.notes.count - 1 }
                }
                if !chord {
                    previousStart = start
                    cursor += duration
                }
                measureEnd = max(measureEnd, start + duration)
            }
        case "measure": measureBase = measureEnd
        default: break
        }
        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }
}
