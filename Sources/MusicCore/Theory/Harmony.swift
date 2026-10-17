// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Chord symbols describe harmony independently of the notes used to voice it.
public enum HarmonyKind: String, Codable, CaseIterable, Sendable {
    case major, minor, augmented, diminished, dominant
    case majorSeventh = "major-seventh"
    case minorSeventh = "minor-seventh"
    case diminishedSeventh = "diminished-seventh"
    case augmentedSeventh = "augmented-seventh"
    case halfDiminished = "half-diminished"
    case majorMinor = "major-minor"
    case majorSixth = "major-sixth"
    case minorSixth = "minor-sixth"
    case dominantNinth = "dominant-ninth"
    case majorNinth = "major-ninth"
    case minorNinth = "minor-ninth"
    case dominant11th = "dominant-11th"
    case major11th = "major-11th"
    case minor11th = "minor-11th"
    case dominant13th = "dominant-13th"
    case major13th = "major-13th"
    case minor13th = "minor-13th"
    case suspendedSecond = "suspended-second"
    case suspendedFourth = "suspended-fourth"
    case power, none
    public var suffix: String {
        switch self {
        case .major: ""
        case .minor: "m"
        case .augmented: "+"
        case .diminished: "dim"
        case .dominant: "7"
        case .majorSeventh: "maj7"
        case .minorSeventh: "m7"
        case .diminishedSeventh: "dim7"
        case .augmentedSeventh: "+7"
        case .halfDiminished: "m7♭5"
        case .majorMinor: "m(maj7)"
        case .majorSixth: "6"
        case .minorSixth: "m6"
        case .dominantNinth: "9"
        case .majorNinth: "maj9"
        case .minorNinth: "m9"
        case .dominant11th: "11"
        case .major11th: "maj11"
        case .minor11th: "m11"
        case .dominant13th: "13"
        case .major13th: "maj13"
        case .minor13th: "m13"
        case .suspendedSecond: "sus2"
        case .suspendedFourth: "sus4"
        case .power: "5"
        case .none: "N.C."
        }
    }
    var includedDegrees: Set<Int> {
        switch self {
        case .none: []
        case .power: [1, 5]
        case .suspendedSecond: [1, 2, 5]
        case .suspendedFourth: [1, 4, 5]
        case .major, .minor, .augmented, .diminished: [1, 3, 5]
        case .majorSixth, .minorSixth: [1, 3, 5, 6]
        case .dominantNinth, .majorNinth, .minorNinth: [1, 3, 5, 7, 9]
        case .dominant11th, .major11th, .minor11th: [1, 3, 5, 7, 9, 11]
        case .dominant13th, .major13th, .minor13th: [1, 3, 5, 7, 9, 11, 13]
        default: [1, 3, 5, 7]
        }
    }
}
public enum HarmonyDegreeType: String, Codable, Sendable { case add, alter, subtract }
public struct HarmonyDegree: Codable, Equatable, Hashable, Sendable {
    public var value: Int
    public var alter: Int
    public var type: HarmonyDegreeType
    public var hidden: Bool
    public init(_ value: Int, alter: Int = 0, type: HarmonyDegreeType = .add, hidden: Bool = false) {
        self.value = value
        self.alter = alter
        self.type = type
        self.hidden = hidden
    }
    public var label: String {
        (type == .subtract ? "no" : alter == 0 ? "add" : "")
            + (alter < 0 ? String(repeating: "♭", count: -alter) : String(repeating: "♯", count: alter)) + String(value)
    }
    var valid: Bool { (1...13).contains(value) && (-2...2).contains(alter) }
}
public struct ChordSymbol: Codable, Equatable, Sendable {
    public var root: Pitch?
    public var kind: HarmonyKind
    public var bass: Pitch?
    public var degrees: [HarmonyDegree]
    /// MusicXML's kind text, when a printed suffix differs from its conventional spelling.
    public var kindText: String?
    public init(
        root: Pitch?, kind: HarmonyKind, bass: Pitch? = nil, degrees: [HarmonyDegree] = [], kindText: String? = nil
    ) {
        self.root = root
        self.kind = kind
        self.bass = bass
        self.degrees = degrees
        self.kindText = kindText
    }
    public var label: String {
        if kind == .none { return "N.C." }
        let additions = degrees.filter { !$0.hidden }.map(\.label)
        var text = root?.name ?? ""
        text += kindText ?? kind.suffix
        if !additions.isEmpty { text += "(" + additions.joined(separator: ",") + ")" }
        if let bass { text += "/" + bass.name }
        return text
    }
    public var valid: Bool {
        func pitch(_ p: Pitch) -> Bool { (0..<7).contains(p.letter) && (-2...2).contains(p.accidental) }
        return (kind == .none ? root == nil && bass == nil && degrees.isEmpty : root.map(pitch) == true)
            && (bass.map(pitch) ?? true) && degrees.count <= 8 && degrees.allSatisfy(\.valid)
            && Set(degrees).count == degrees.count
            && (kindText.map {
                $0.count <= 48 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            } ?? true)
    }
    public func transposed(_ semitones: Int, flats: Bool) -> Self {
        guard semitones % 12 != 0 else { return self }
        var copy = self
        copy.root = root.map { Pitch.spelled($0.pc + semitones, flats: flats || $0.accidental < 0) }
        copy.bass = bass.map { Pitch.spelled($0.pc + semitones, flats: flats || $0.accidental < 0) }
        return copy
    }
    public static func parse(_ text: String) throws -> Self {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 64,
            !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw MusicError.invalid("Enter a chord such as Cmaj7, Dm7, G7(b9), or C/E.") }
        var depth = 0
        for character in input {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            guard (0...1).contains(depth) else {
                throw MusicError.invalid("Keep chord alterations inside a matched pair of parentheses.")
            }
        }
        guard depth == 0 else { throw MusicError.invalid("Close the parentheses around the chord alterations.") }
        if ["NC", "N.C.", "N.C"].contains(input.uppercased()) { return Self(root: nil, kind: .none) }
        var value = input.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "𝄪", with: "##").replacingOccurrences(of: " ", with: "")
        func readPitch(_ value: inout String) -> Pitch? {
            guard let letter = value.first, let index = Pitch.letters.firstIndex(of: String(letter).uppercased()) else {
                return nil
            }
            value.removeFirst()
            var accidental = 0
            if value.hasPrefix("bb") {
                accidental = -2
                value.removeFirst(2)
            } else if value.hasPrefix("##") {
                accidental = 2
                value.removeFirst(2)
            } else if value.hasPrefix("b") {
                accidental = -1
                value.removeFirst()
            } else if value.hasPrefix("#") {
                accidental = 1
                value.removeFirst()
            }
            return Pitch(index, accidental)
        }
        guard let root = readPitch(&value) else { throw MusicError.invalid("Start the chord with a note name, A–G.") }
        var bass: Pitch?
        if let slash = value.lastIndex(of: "/") {
            var tail = String(value[value.index(after: slash)...])
            if let pitch = readPitch(&tail), tail.isEmpty {
                bass = pitch
                value = String(value[..<slash])
            }
        }
        let printed = value.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭")
        value = value.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ",", with: "")
        let aliases: [(String, HarmonyKind)] = [
            ("mmaj7", .majorMinor), ("mMaj7", .majorMinor), ("minmaj7", .majorMinor),
            ("maj13", .major13th), ("maj11", .major11th), ("maj9", .majorNinth), ("maj7", .majorSeventh),
            ("M13", .major13th), ("M11", .major11th), ("M9", .majorNinth), ("M7", .majorSeventh),
            ("Δ13", .major13th), ("Δ9", .majorNinth), ("Δ7", .majorSeventh), ("Δ", .majorSeventh),
            ("min13", .minor13th), ("min11", .minor11th), ("min9", .minorNinth), ("min7", .minorSeventh),
            ("min6", .minorSixth),
            ("m7b5", .halfDiminished), ("ø7", .halfDiminished), ("ø", .halfDiminished),
            ("dim7", .diminishedSeventh), ("o7", .diminishedSeventh), ("°7", .diminishedSeventh),
            ("aug7", .augmentedSeventh), ("+7", .augmentedSeventh),
            ("m13", .minor13th), ("m11", .minor11th), ("m9", .minorNinth), ("m7", .minorSeventh), ("m6", .minorSixth),
            ("-13", .minor13th), ("-11", .minor11th), ("-9", .minorNinth), ("-7", .minorSeventh), ("-6", .minorSixth),
            ("sus2", .suspendedSecond), ("sus4", .suspendedFourth), ("sus", .suspendedFourth),
            ("dim", .diminished), ("aug", .augmented), ("min", .minor), ("maj", .major),
            ("13", .dominant13th), ("11", .dominant11th), ("9", .dominantNinth), ("7", .dominant), ("6", .majorSixth),
            ("5", .power), ("m", .minor), ("-", .minor), ("M", .major), ("+", .augmented), ("°", .diminished),
            ("o", .diminished),
        ]
        var kind: HarmonyKind = .major
        var degrees: [HarmonyDegree] = []
        if let match = aliases.first(where: { value.hasPrefix($0.0) }) {
            kind = match.1
            value.removeFirst(match.0.count)
        }
        if value == "/9", kind == .majorSixth || kind == .minorSixth {
            degrees.append(HarmonyDegree(9))
            value = ""
        }
        if value.hasPrefix("sus"), [.dominant, .dominantNinth, .dominant13th].contains(kind) {
            degrees =
                [HarmonyDegree(7)] + (kind == .dominant ? [] : [HarmonyDegree(9)])
                + (kind == .dominant13th ? [HarmonyDegree(13)] : [])
            value.removeFirst(3)
            if value.hasPrefix("2") {
                kind = .suspendedSecond
                value.removeFirst()
            } else {
                kind = .suspendedFourth
                if value.hasPrefix("4") { value.removeFirst() }
            }
        }
        while !value.isEmpty {
            var type: HarmonyDegreeType = .add
            var alteration = 0
            if value.hasPrefix("add") {
                value.removeFirst(3)
            } else if value.hasPrefix("omit") {
                type = .subtract
                value.removeFirst(4)
            } else if value.hasPrefix("no") {
                type = .subtract
                value.removeFirst(2)
            } else if !value.hasPrefix("b") && !value.hasPrefix("#") {
                throw MusicError.invalid(
                    "That chord suffix is not supported yet. Try maj7, m7, 9, 13, sus4, add9, b9 or #11.")
            }
            if value.hasPrefix("b") {
                alteration = -1
                value.removeFirst()
            } else if value.hasPrefix("#") {
                alteration = 1
                value.removeFirst()
            }
            let digits = value.prefix(while: { $0.isNumber })
            guard let number = Int(digits), (1...13).contains(number) else {
                throw MusicError.invalid("Use chord degrees 1–13 after add, no, b or #.")
            }
            value.removeFirst(digits.count)
            if type == .add && alteration != 0, let original = kind.baseIntervals[number] {
                type = .alter
                alteration += HarmonyKind.majorInterval(number) - original
            }
            degrees.append(HarmonyDegree(number, alter: alteration, type: type))
        }
        // The printed suffix already includes these degrees; don't display them twice.
        degrees = degrees.map {
            var d = $0
            d.hidden = true
            return d
        }
        let symbol = Self(root: root, kind: kind, bass: bass, degrees: degrees, kindText: printed)
        guard symbol.valid else {
            throw MusicError.invalid("This chord contains duplicate or unsupported alterations.")
        }
        return symbol
    }
}

public struct EditorHarmony: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var bar: Int
    public var tick: Int
    public var staff: Int
    public var symbol: ChordSymbol
    public init(bar: Int, tick: Int = 0, staff: Int = 1, symbol: ChordSymbol) {
        self.bar = bar
        self.tick = tick
        self.staff = staff
        self.symbol = symbol
    }
}
extension EditorDocument {
    public static var leadSheetExample: Self {
        var doc = Self.guitarExample
        doc.title = "A little set of changes"
        doc.harmonies = [
            (0, 0, "Dm7"), (0, 960, "G7(b9)"), (1, 0, "Cmaj7/E"), (2, 240, "F#dim7"), (3, 0, "Bb13"), (3, 960, "N.C."),
        ].compactMap { bar, tick, text in
            (try? ChordSymbol.parse(text)).map { EditorHarmony(bar: bar, tick: tick, symbol: $0) }
        }
        return doc
    }
    public func harmonies(in bar: Int) -> [EditorHarmony] {
        harmonies.filter { $0.bar == bar }.sorted { ($0.tick, $0.staff) < ($1.tick, $1.staff) }
    }
    public mutating func setHarmony(_ item: EditorHarmony) throws {
        var copy = self
        if let index = copy.harmonies.firstIndex(where: { $0.id == item.id }) {
            copy.harmonies[index] = item
        } else {
            copy.harmonies.append(item)
        }
        self = try copy.validated()
    }
    public mutating func removeHarmony(_ id: UUID) { harmonies.removeAll { $0.id == id } }
    func validateHarmonies() throws {
        guard harmonies.count <= 2048, Set(harmonies.map(\.id)).count == harmonies.count,
            Set(harmonies.map { "\($0.bar):\($0.tick):\($0.staff)" }).count == harmonies.count,
            harmonies.allSatisfy({
                (0..<barCount).contains($0.bar) && (0..<meter.ticks).contains($0.tick)
                    && (1...staffCount).contains($0.staff) && $0.symbol.valid
            })
        else {
            throw MusicError.invalid(
                "Place one chord symbol at each beat/staff position, inside the bar. Keep up to 2,048 symbols in a score."
            )
        }
    }
}
