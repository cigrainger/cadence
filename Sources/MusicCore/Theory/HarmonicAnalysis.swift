// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum HarmonicFunction: String, Codable, CaseIterable, Sendable {
    case tonic = "Tonic / home"
    case predominant = "Predominant / departure"
    case dominant = "Dominant / return"
    case applied =
        "Applied dominant"
    case colour = "Colour / other"
    case open = "Open interpretation"
}
public struct HarmonicReading: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var roman: String
    public var function: HarmonicFunction
    public var convention: String
    public var explanation: String
    public init(
        roman: String = "", function: HarmonicFunction = .open, convention: String = "Jazz / tonal",
        explanation: String = ""
    ) {
        self.roman = roman
        self.function = function
        self.convention = convention
        self.explanation = explanation
    }
    public var valid: Bool { roman.count <= 80 && convention.count <= 120 && explanation.count <= 2000 }
}
public struct HarmonyAnchor: Codable, Equatable, Identifiable, Sendable {
    public var partID: String
    public var staff: Int
    public var bar: Int
    public var tick: Int
    public var symbol: ChordSymbol
    public var id: String { "\(partID):\(staff):\(bar):\(tick)" }
    public var valid: Bool {
        !partID.isEmpty && partID.count <= 200 && (1...16).contains(staff) && (0..<1000).contains(bar)
            && (0...24000).contains(tick) && symbol.valid
    }
}
public struct HarmonicAnnotation: Codable, Equatable, Identifiable, Sendable {
    public var anchor: HarmonyAnchor
    public var readings: [HarmonicReading]
    public var id: String { anchor.id }
    public init(anchor: HarmonyAnchor, readings: [HarmonicReading]) {
        self.anchor = anchor
        self.readings = readings
    }
    public var valid: Bool {
        anchor.valid && (1...6).contains(readings.count) && Set(readings.map(\.id)).count == readings.count
            && readings.allSatisfy(\.valid)
    }
}
/// Musical revision anchors prevent an old interpretation silently moving onto
/// different music. Annotation edits themselves never change the source score.
public struct ScoreAnalysis: Codable, Equatable, Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var annotations: [HarmonicAnnotation] = []
    public var id: String { pieceID + ":" + fingerprint }
    public init(piece: LibraryPiece) {
        pieceID = piece.id
        fingerprint = piece.fingerprint
    }
    public var valid: Bool {
        !pieceID.isEmpty && pieceID.count <= 100 && ScoreRevision.valid(fingerprint) && annotations.count <= 512
            && Set(annotations.map(\.id)).count == annotations.count && annotations.allSatisfy(\.valid)
    }
    public mutating func set(_ item: HarmonicAnnotation) throws {
        guard item.valid else {
            throw MusicError.invalid(
                "Keep up to six readings, with a short label and up to 2,000 characters of explanation.")
        }
        if let index = annotations.firstIndex(where: { $0.id == item.id }) {
            annotations[index] = item
        } else {
            guard annotations.count < 512 else { throw MusicError.invalid("This analysis is full.") }
            annotations.append(item)
        }
    }
}
public enum HarmonyTheory {
    public static let omt = "https://viva.pressbooks.pub/openmusictheory/chapter/tonicization/"
    public static let jazz = "https://viva.pressbooks.pub/openmusictheory/part/jazz/"
    public static let mit =
        "https://ocw.mit.edu/courses/21m-302-harmony-and-counterpoint-ii-spring-2005/pages/syllabus/"
    public static func majorTonic(fifths: Int) -> Pitch {
        [
            Pitch(0, -1), Pitch(4, -1), Pitch(1, -1), Pitch(5, -1), Pitch(2, -1), Pitch(6, -1), Pitch(3), Pitch(0),
            Pitch(4), Pitch(1), Pitch(5), Pitch(2), Pitch(6), Pitch(3, 1), Pitch(0, 1),
        ][max(-7, min(7, fifths)) + 7]
    }
    public static func anchors(piece: LibraryPiece, scope: PassageScope) throws -> [HarmonyAnchor] {
        let source = try ChangesSource(piece: piece, from: scope.from, through: scope.through, partID: scope.partID)
        let plan = try source.plan(staff: scope.staff ?? source.staffs[0])
        _ = try ReviewedSource.pages(piece: piece, from: plan.steps.first?.bar ?? scope.from, through: scope.through)
        return plan.steps.map {
            HarmonyAnchor(partID: source.partID, staff: plan.staff, bar: $0.bar, tick: $0.tick, symbol: $0.chord.symbol)
        }
    }
    public static func isDominant(_ chord: ChordSymbol) -> Bool {
        guard let c = try? ChordRealization(chord) else { return false }
        return c.tones.filter { $0.degree == 3 }.map(\.semitones) == [4]
            && c.tones.filter { $0.degree == 7 }.map(\.semitones) == [10]
    }
    public static func resolves(_ first: ChordSymbol, to next: ChordSymbol) -> Bool {
        guard isDominant(first), let root = first.root, let target = next.root,
            let triad = try? TriadNeck.tones(next), [3, 4].contains(mod(triad[1].pc - target.pc)),
            mod(triad[2].pc - target.pc) == 7
        else { return false }
        return mod(root.pc - target.pc) == 7
    }
    public static func roman(_ symbol: ChordSymbol, tonic: Pitch) -> String {
        guard symbol.valid, (0..<7).contains(tonic.letter), (-2...2).contains(tonic.accidental) else { return "?" }
        guard let root = symbol.root else { return "N.C." }
        let degree = (root.letter - tonic.letter + 7) % 7
        let expected = Scale.major.notes(tonic)[degree]
        var alteration = mod(root.pc - expected.pc)
        if alteration > 6 { alteration -= 12 }
        guard abs(alteration) <= 2, let triad = try? TriadNeck.tones(symbol) else { return "?" }
        let third = mod(triad[1].pc - root.pc)
        let fifth = mod(triad[2].pc - root.pc)
        let numeral = ["I", "II", "III", "IV", "V", "VI", "VII"][degree]
        let tones = (try? ChordRealization(symbol).tones) ?? []
        let seventhTone = tones.first { $0.degree == 7 }?.semitones
        let quality = fifth == 6 ? (seventhTone == 10 ? "ø" : "°") : fifth == 8 ? "+" : ""
        let extensionDegree = tones.filter { [7, 9, 11, 13].contains($0.degree) }.map(\.degree).max()
        let seventh =
            extensionDegree.map { (seventhTone == 11 ? "maj" : "") + String($0) }
            ?? (tones.contains { $0.degree == 6 } ? "6" : "")
        return String(repeating: alteration < 0 ? "♭" : "♯", count: abs(alteration))
            + (third == 3 ? numeral.lowercased() : numeral) + quality + seventh
    }
    public static func suggestion(_ symbol: ChordSymbol, next: ChordSymbol?, tonic: Pitch) -> HarmonicReading {
        guard (0..<7).contains(tonic.letter), (-2...2).contains(tonic.accidental), symbol.valid else {
            return .init(explanation: "Choose a valid key and chord before suggesting a reading.")
        }
        if let next, resolves(symbol, to: next), next.root?.pc != tonic.pc {
            let target = roman(
                ChordSymbol(
                    root: next.root,
                    kind: ((try? TriadNeck.tones(next)).map { mod($0[1].pc - $0[0].pc) == 3 } ?? false)
                        ? .minor : .major), tonic: tonic)
            return .init(
                roman: "V7/" + target, function: .applied, convention: "Jazz / tonal · \(tonic.name) major",
                explanation:
                    "A possible applied dominant of \(next.label). Hear its major third move a semitone up to the next root. Confirm the local key and musical context; this is a suggested reading."
            )
        }
        let label = roman(symbol, tonic: tonic)
        let root = symbol.root?.pc
        let degree = root.flatMap { pc in Scale.major.notes(tonic).firstIndex { $0.pc == pc } }
        let function: HarmonicFunction =
            degree == 0
            ? .tonic
            : [1, 3].contains(degree ?? -1) ? .predominant : degree == 4 && isDominant(symbol) ? .dominant : .open
        return .init(
            roman: label, function: function, convention: "Jazz / tonal · \(tonic.name) major",
            explanation:
                "A starting reading in \(tonic.name) major. Chord symbols alone do not establish function, inversion, phrase structure or a modulation; edit this interpretation in context."
        )
    }
}

extension HarmonyTheory {
    /// A display-only copy. XML nodes escape learner text; the score and its
    /// fingerprint retain their original content. Offsets respect each part's divisions.
    public static func displayStudy(piece: LibraryPiece, partID: String, analysis: ScoreAnalysis?) throws -> MusicStudy
    {
        var study = try RehearsalSource.whole(piece, partID: partID)
        guard let analysis, analysis.pieceID == piece.id, analysis.fingerprint == piece.fingerprint, analysis.valid
        else { return study }
        let xml = try XMLDocument(xmlString: study.document.originalXML, options: [.nodeLoadExternalEntitiesNever])
        guard
            let part = xml.rootElement()?.elements(forName: "part").first(where: {
                $0.attribute(forName: "id")?.stringValue == partID
            })
        else { return study }
        var divisions = 1
        for (bar, measure) in part.elements(forName: "measure").enumerated() {
            if let raw = measure.elements(forName: "attributes").first?.elements(forName: "divisions").first?
                .stringValue, let value = Int(raw), value > 0
            {
                divisions = value
            }
            for item in analysis.annotations where item.anchor.partID == partID && item.anchor.bar == bar {
                guard let reading = item.readings.first, !reading.roman.isEmpty else { continue }
                let direction = XMLElement(name: "direction")
                direction.addAttribute(XMLNode.attribute(withName: "placement", stringValue: "above") as! XMLNode)
                let type = XMLElement(name: "direction-type")
                let words = XMLElement(name: "words", stringValue: reading.roman)
                words.addAttribute(XMLNode.attribute(withName: "font-style", stringValue: "italic") as! XMLNode)
                type.addChild(words)
                direction.addChild(type)
                direction.addChild(
                    XMLElement(name: "offset", stringValue: String(Double(item.anchor.tick) * Double(divisions) / 480)))
                direction.addChild(XMLElement(name: "staff", stringValue: String(item.anchor.staff)))
                let insertion =
                    (measure.children ?? []).firstIndex { $0.name != "attributes" && $0.name != "print" }
                    ?? measure.childCount
                measure.insertChild(direction, at: insertion)
            }
        }
        study.document.originalXML = xml.xmlString
        return study
    }
}
