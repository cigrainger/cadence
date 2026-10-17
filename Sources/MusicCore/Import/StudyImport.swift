// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ZIPFoundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

public enum StudyImport {
    public static let maximumBytes = 20 * 1024 * 1024
    public static func read(_ data: Data) throws -> StudyDocument {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MusicError.invalid("Choose a MusicXML file smaller than 20 MB.")
        }
        let xml: Data
        if data.prefix(2) == Data([0x50, 0x4b]) {
            let archive = try Archive(data: data, accessMode: .read)
            func entryData(_ path: String, limit: Int) throws -> Data {
                guard let entry = archive[path], entry.type == .file, entry.uncompressedSize <= UInt64(limit) else {
                    throw MusicError.invalid(
                        "The compressed score is missing a valid \(path) entry, or it is too large.")
                }
                var output = Data()
                let checksum = try archive.extract(
                    entry,
                    consumer: { chunk in
                        guard output.count + chunk.count <= limit else {
                            throw MusicError.invalid("The expanded score exceeds the size limit.")
                        }
                        output.append(chunk)
                    })
                guard checksum == entry.checksum else {
                    throw MusicError.invalid("The compressed score failed its integrity check.")
                }
                return output
            }
            let container = try entryData("META-INF/container.xml", limit: 65536)
            guard let containerText = String(data: container, encoding: .utf8),
                containerText.range(of: "<!ENTITY", options: .caseInsensitive) == nil
            else { throw MusicError.invalid("The compressed MusicXML container is not supported.") }
            let reader = RootFileReader()
            let parser = XMLParser(data: container)
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            guard parser.parse(), let rootfile = reader.path, !rootfile.hasPrefix("/"),
                !rootfile.split(separator: "/").contains("..")
            else { throw MusicError.invalid("The compressed MusicXML container has no valid root score.") }
            xml = try entryData(rootfile, limit: maximumBytes)
        } else {
            xml = data
        }
        guard let text = String(data: xml, encoding: .utf8) ?? String(data: xml, encoding: .utf16) else {
            throw MusicError.invalid("Use a UTF-8 or UTF-16 MusicXML score.")
        }
        guard text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw MusicError.invalid("Export the score without custom XML entity declarations and try again.")
        }
        let reader = StudyXMLReader()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.failure == nil else {
            throw MusicError.invalid(reader.failure ?? "This file is not a readable partwise MusicXML score.")
        }
        guard reader.isPartwise, !reader.parts.isEmpty, reader.parts.allSatisfy({ !$0.measures.isEmpty }) else {
            throw MusicError.invalid("No score parts were found. Export score-partwise MusicXML and try again.")
        }
        guard reader.parts.contains(where: { $0.notes.contains { $0.midi >= 0 } }) else {
            throw MusicError.invalid(
                "This score contains no supported pitched notes. Percussion-only scores are not playable yet.")
        }
        return try StudyDocument(
            title: reader.title.isEmpty ? "Untitled study" : reader.title, composer: reader.composer,
            tempo: reader.tempo, originalXML: text, parts: reader.parts, notices: Array(reader.notices).sorted()
        ).validated()
    }
}
private final class RootFileReader: NSObject, XMLParserDelegate {
    var path: String?
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        if elementName.split(separator: ":").last == "rootfile", path == nil { path = attributes["full-path"] }
    }
}

private final class StudyXMLReader: NSObject, XMLParserDelegate {
    var title = "", composer = "", tempo = 90.0
    var parts: [StudyPart] = []
    var notices: Set<String> = []
    var failure: String?
    var isPartwise = false
    private var stack: [String] = [], strings: [String] = []
    private var names: [String: String] = [:], listingID = "", creatorType = ""
    private var current: StudyPart?
    private var divisions = 1.0, cursor = 0.0, furthest = 0.0, previousStart = 0.0, base = 0.0
    private var beats = 4, unit = 4, fifths = 0, measureLabel = "", implicit = false
    private var keyMode: String?
    private var minor: Bool?
    private var transpose: [Int: Int] = [:], transposeStaff = 0, chromatic = 0, octaveChange = 0
    private var clefStaff = 1, clefSign = "", metronomeUnit = "quarter", metronomeDot = false
    private var step = "", alteration = 0, octave = 4, duration: Double?
    private var voice = "1", staff = 1, string: Int?, fret: Int?
    private var rest = false, chord = false, grace = false, unpitched = false, wholeRest = false, tieStart = false,
        tieStop = false
    private var expression = StudyExpression()
    private var directionDynamic: MusicDynamic?, directionVoice: String?, directionStaff = 1, directionOffset = 0.0
    private var totalNotes = 0, sawTempo = false, timeBeatItems = 0

    private func fail(_ parser: XMLParser, _ message: String) {
        failure = message
        parser.abortParsing()
    }
    func parser(
        _ parser: XMLParser, didStartElement raw: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = String(raw.split(separator: ":").last ?? Substring(raw))
        stack.append(name)
        strings.append("")
        if stack.count > 64 {
            fail(parser, "The MusicXML document is nested too deeply.")
            return
        }
        switch name {
        case "score-partwise": isPartwise = true
        case "score-timewise": fail(parser, "Export partwise MusicXML before importing this score.")
        case "score-part": listingID = attributes["id"] ?? ""
        case "creator": creatorType = attributes["type"] ?? ""
        case "part":
            guard parts.count < 64 else {
                fail(parser, "This score has too many parts.")
                return
            }
            let id = attributes["id"] ?? "P\(parts.count+1)"
            current = StudyPart(
                id: id, name: names[id] ?? "Part \(parts.count+1)", measures: [], notes: [], tabStaves: [])
            divisions = 1
            base = 0
            beats = 4
            unit = 4
            fifths = 0
            minor = nil
            keyMode = nil
            transpose = [:]
        case "key":
            minor = nil
            keyMode = nil
        case "measure":
            guard current != nil, (current?.measures.count ?? 0) < 1000 else {
                fail(parser, "A score part can contain up to 1,000 bars.")
                return
            }
            measureLabel = attributes["number"] ?? String((current?.measures.count ?? 0) + 1)
            implicit = attributes["implicit"] == "yes"
            cursor = 0
            furthest = 0
            previousStart = 0
        case "note":
            expression = StudyExpression()
            step = ""
            alteration = 0
            octave = 4
            duration = nil
            voice = "1"
            staff = 1
            string = nil
            fret = nil
            rest = false
            chord = false
            grace = false
            unpitched = false
            wholeRest = false
            tieStart = false
            tieStop = false
        case "direction":
            directionDynamic = nil
            directionVoice = nil
            directionStaff = 1
            directionOffset = 0
        case "staccato": if stack.contains("note") { expression.staccato = true }
        case "accent": if stack.contains("note") { expression.accent = true }
        case "slur":
            if stack.contains("note") {
                let number = String((attributes["number"] ?? "1").prefix(100))
                if attributes["type"] == "start" { expression.slurStarts.append(number) }
                if attributes["type"] == "stop" { expression.slurStops.append(number) }
            }
        case "rest":
            rest = true
            wholeRest = attributes["measure"] == "yes"
        case "chord": chord = true
        case "grace":
            grace = true
            notices.insert("Grace notes are displayed but are not played.")
        case "unpitched":
            unpitched = true
            notices.insert("Unpitched percussion is displayed but is not played.")
        case "tie", "tied":
            tieStart = tieStart || attributes["type"] == "start"
            tieStop = tieStop || attributes["type"] == "stop"
        case "transpose":
            transposeStaff = Int(attributes["number"] ?? "0") ?? 0
            chromatic = 0
            octaveChange = 0
        case "clef":
            clefStaff = Int(attributes["number"] ?? "1") ?? 1
            clefSign = ""
        case "sound":
            if let value = attributes["tempo"].flatMap(Double.init), !sawTempo, value.isFinite,
                (20...300).contains(value)
            {
                tempo = value
                sawTempo = true
            }
            if attributes["dacapo"] != nil || attributes["dalsegno"] != nil {
                notices.insert("Playback follows written bars; navigation marks are not performed.")
            }
        case "repeat", "ending":
            notices.insert("Playback follows written bars; printed repeats and endings are not expanded.")
        case "ornaments": notices.insert("Ornaments are displayed; playback uses the main written notes.")
        case "time": timeBeatItems = 0
        case "senza-misura": fail(parser, "Unmetered scores are not supported for passage playback yet.")
        case "metronome":
            metronomeUnit = "quarter"
            metronomeDot = false
        case "beat-unit-dot": metronomeDot = true
        default:
            if stack.dropLast().last == "dynamics", let dynamic = MusicDynamic(rawValue: name) {
                directionDynamic = dynamic
            }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters value: String) {
        if !strings.isEmpty { strings[strings.count - 1] += value }
    }
    func parser(_ parser: XMLParser, didEndElement raw: String, namespaceURI: String?, qualifiedName: String?) {
        let name = String(raw.split(separator: ":").last ?? Substring(raw))
        let value = (strings.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last ?? ""
        func integer(_ text: String) -> Int? {
            guard let d = Double(text), d.isFinite, abs(d) < 1_000_000, d.rounded() == d else { return nil }
            return Int(d)
        }
        switch name {
        case "work-title": if !value.isEmpty { title = value }
        case "movement-title": if title.isEmpty { title = value }
        case "creator": if creatorType == "composer" { composer = value }
        case "part-name": if parent == "score-part" { names[listingID] = value }
        case "divisions":
            guard let number = Double(value), number.isFinite, number > 0, number <= 1_000_000 else {
                fail(parser, "A MusicXML divisions value is invalid.")
                return
            }
            divisions = number
        case "beats":
            timeBeatItems += 1
            if timeBeatItems > 1 {
                fail(parser, "Simplify additive time signatures before importing this score.")
                return
            }
            guard let number = integer(value), (1...16).contains(number) else {
                fail(parser, "Additive or unsupported time signatures must be simplified before importing.")
                return
            }
            beats = number
        case "beat-type":
            guard let number = integer(value), [2, 4, 8, 16].contains(number) else {
                fail(parser, "This time-signature denominator is not supported yet.")
                return
            }
            unit = number
        case "fifths":
            guard let number = integer(value), (-7...7).contains(number) else {
                fail(parser, "This key signature is not supported yet.")
                return
            }
            fifths = number
        case "mode":
            if parent == "key" {
                keyMode = String(value.prefix(100))
                minor =
                    ["minor", "aeolian"].contains(value) ? true : ["major", "ionian"].contains(value) ? false : nil
            }
        case "chromatic": if parent == "transpose" { chromatic = integer(value) ?? 0 }
        case "octave-change": if parent == "transpose" { octaveChange = integer(value) ?? 0 }
        case "transpose": transpose[transposeStaff] = chromatic + 12 * octaveChange
        case "sign": if parent == "clef" { clefSign = value }
        case "clef": if clefSign == "TAB" { current?.tabStaves.insert(clefStaff) }
        case "step": if parent == "pitch" { step = value }
        case "alter":
            if parent == "pitch" {
                guard let number = integer(value), abs(number) <= 2 else {
                    fail(parser, "Microtonal pitches are not supported for playback yet.")
                    return
                }
                alteration = number
            }
        case "octave": if parent == "pitch" { octave = integer(value) ?? -100 }
        case "voice":
            if stack.contains("note") {
                voice = String(value.prefix(100))
            } else if stack.contains("direction") {
                directionVoice = String(value.prefix(100))
            }
        case "staff":
            if stack.contains("note") {
                staff = integer(value) ?? 1
            } else if stack.contains("direction") {
                directionStaff = integer(value) ?? 1
            }
        case "offset":
            if parent == "direction", let amount = Double(value), amount.isFinite {
                directionOffset = amount / divisions
            }
        case "direction":
            if let dynamic = directionDynamic {
                if current?.dynamics == nil { current?.dynamics = [] }
                current?.dynamics?.append(
                    StudyDynamic(
                        start: base + cursor + directionOffset, staff: directionStaff, voice: directionVoice,
                        dynamic: dynamic))
            }
        case "string": string = integer(value).map { 6 - $0 }
        case "fret": fret = integer(value)
        case "beat-unit": if parent == "metronome" { metronomeUnit = value }
        case "per-minute":
            if !sawTempo, let number = Double(value) {
                let factors: [String: Double] = ["whole": 4, "half": 2, "quarter": 1, "eighth": 0.5, "16th": 0.25]
                let factor = factors[metronomeUnit] ?? 1
                let candidate = number * factor * (metronomeDot ? 1.5 : 1)
                if candidate.isFinite, (20...300).contains(candidate) {
                    tempo = candidate
                    sawTempo = true
                }
            }
        case "duration":
            guard let raw = Double(value), raw.isFinite, raw >= 0 else {
                fail(parser, "A MusicXML duration is invalid.")
                return
            }
            let amount = raw / divisions
            if parent == "backup" {
                cursor -= amount
                if cursor < -0.0001 {
                    fail(parser, "A voice moves before the start of a bar.")
                    return
                }
                cursor = max(0, cursor)
            } else if parent == "forward" {
                cursor += amount
                furthest = max(furthest, cursor)
            } else if parent == "note" {
                duration = amount
            }
        case "note":
            if !grace {
                let length = duration ?? (wholeRest ? Double(beats) * 4 / Double(unit) : 0)
                guard length.isFinite, length > 0, length <= 128, (1...16).contains(staff), totalNotes < 10000 else {
                    fail(parser, "A note has an unsupported duration or staff, or the score exceeds 10,000 events.")
                    return
                }
                let onset = chord ? previousStart : cursor
                let pitch = Pitch(Pitch.letters.firstIndex(of: step) ?? 0, alteration)
                let written = (octave + 1) * 12 + Pitch.naturals[pitch.letter] + alteration
                let sounding = written + (transpose[staff] ?? transpose[0] ?? 0)
                guard
                    rest || unpitched
                        || (Pitch.letters.contains(step) && (0...127).contains(sounding) && (0...127).contains(written))
                else {
                    fail(parser, "A note has an invalid or unsupported pitch.")
                    return
                }
                if let s = string, !(0..<6).contains(s) {
                    string = nil
                    fret = nil
                    notices.insert(
                        "TAB for instruments with more than six strings is shown in the score; six-string guitar positions are suggested separately."
                    )
                }
                if let f = fret, !(0...24).contains(f) {
                    string = nil
                    fret = nil
                }
                let measureIndex = current?.measures.count ?? 0
                current?.notes.append(
                    StudyNote(
                        midi: rest || unpitched ? -1 : sounding, writtenPitch: rest || unpitched ? nil : pitch,
                        writtenMidi: rest || unpitched ? nil : written, start: base + onset, duration: length,
                        measure: measureIndex, voice: voice, staff: staff, string: string, fret: fret,
                        tieStart: tieStart, tieStop: tieStop,
                        expression: expression == StudyExpression() ? nil : expression))
                totalNotes += 1
                if !chord {
                    previousStart = onset
                    cursor += length
                }
                furthest = max(furthest, onset + length)
            }
        case "measure":
            let nominal = Double(beats) * 4 / Double(unit)
            let pickup = (current?.measures.isEmpty ?? true) && furthest > 0 && furthest < nominal - 0.0001
            let length = (implicit || pickup) && furthest > 0 ? furthest : max(nominal, furthest)
            guard length.isFinite, length > 0, length <= 128, base + length < 100000 else {
                fail(parser, "A bar has an unsupported length.")
                return
            }
            let measureIndex = current?.measures.count ?? 0
            current?.measures.append(
                StudyMeasure(
                    index: measureIndex, label: measureLabel, start: base, duration: length, beats: beats,
                    beatUnit: unit, fifths: fifths, minor: minor, keyMode: keyMode))
            base += length
        case "part":
            if let part = current { parts.append(part) }
            current = nil
        default: break
        }
        if !stack.isEmpty { stack.removeLast() }
        if !strings.isEmpty { strings.removeLast() }
        if !strings.isEmpty { strings[strings.count - 1] += value }
    }
}
