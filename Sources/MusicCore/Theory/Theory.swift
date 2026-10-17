// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public func mod(_ value: Int, _ base: Int = 12) -> Int { (value % base + base) % base }

public struct Pitch: Hashable, Codable, Sendable {
    public var letter: Int
    public var accidental: Int
    public static let letters = ["C", "D", "E", "F", "G", "A", "B"]
    public static let naturals = [0, 2, 4, 5, 7, 9, 11]
    public init(_ letter: Int, _ accidental: Int = 0) {
        self.letter = mod(letter, 7)
        self.accidental = accidental
    }
    public var pc: Int { mod(Self.naturals[letter] + accidental) }
    public var name: String {
        Self.letters[letter]
            + (accidental > 0 ? String(repeating: "♯", count: accidental) : String(repeating: "♭", count: -accidental))
    }
    public static let roots = [
        Pitch(0), Pitch(0, 1), Pitch(1, -1), Pitch(1), Pitch(1, 1), Pitch(2, -1), Pitch(2), Pitch(3), Pitch(3, 1),
        Pitch(4, -1), Pitch(4), Pitch(4, 1), Pitch(5, -1), Pitch(5), Pitch(5, 1), Pitch(6, -1), Pitch(6), Pitch(0, -1),
    ]
    public static let fifths = [
        Pitch(0), Pitch(4), Pitch(1), Pitch(5), Pitch(2), Pitch(6), Pitch(3, 1), Pitch(1, -1), Pitch(5, -1),
        Pitch(2, -1), Pitch(6, -1), Pitch(3),
    ]
    public static func chromatic(_ midi: Int, flats: Bool = false) -> String {
        (flats
            ? ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
            : ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"])[mod(midi)]
    }
    public func transposed(semitones: Int, steps: Int) -> Pitch {
        let newLetter = mod(letter + steps, 7)
        var accidental = mod(pc + semitones - Self.naturals[newLetter])
        if accidental > 6 { accidental -= 12 }
        return Pitch(newLetter, accidental)
    }
    public var majorFifths: Int { [0, 2, 4, -1, 1, 3, 5][letter] + accidental * 7 }
    public static func spelled(_ midi: Int, flats: Bool = false) -> Pitch {
        roots.first { $0.pc == mod(midi) && (flats ? $0.accidental <= 0 : $0.accidental >= 0) } ?? Pitch(0)
    }
}

public enum Scale: String, CaseIterable, Codable, Sendable {
    case major = "Major / Ionian"
    case dorian = "Dorian"
    case phrygian = "Phrygian"
    case lydian = "Lydian"
    case mixolydian =
        "Mixolydian"
    case minor = "Natural minor / Aeolian"
    case locrian = "Locrian"
    case harmonicMinor = "Harmonic minor"
    case
        melodicMinor = "Melodic minor"
    case majorPentatonic = "Major pentatonic"
    case minorPentatonic = "Minor pentatonic"
    case
        blues = "Minor blues"
    public var intervals: [Int] {
        switch self {
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        case .phrygian: [0, 1, 3, 5, 7, 8, 10]
        case .lydian: [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
        case .minor: [0, 2, 3, 5, 7, 8, 10]
        case .locrian: [0, 1, 3, 5, 6, 8, 10]
        case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor: [0, 2, 3, 5, 7, 9, 11]
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .blues: [0, 3, 5, 6, 7, 10]
        }
    }
    public var degrees: [Int] {
        switch self {
        case .majorPentatonic: [0, 1, 2, 4, 5]
        case .minorPentatonic: [0, 2, 3, 4, 6]
        case .blues: [0, 2, 3, 4, 4, 6]
        default: Array(0..<7)
        }
    }
    public var formula: [String] {
        zip(intervals, degrees).map { interval, degree in
            let alteration = interval - Pitch.naturals[degree]
            return
                (alteration < 0
                ? String(repeating: "♭", count: -alteration) : String(repeating: "♯", count: alteration))
                + "\(degree + 1)"
        }
    }
    public func notes(_ root: Pitch) -> [Pitch] {
        zip(intervals, degrees).map { root.transposed(semitones: $0, steps: $1) }
    }
    public func signature(_ root: Pitch) -> Int {
        let offset: Int
        switch self {
        case .major, .majorPentatonic: offset = 0
        case .dorian: offset = -2
        case .phrygian: offset = -4
        case .lydian: offset = 1
        case .mixolydian: offset = -1
        case .locrian: offset = -5
        default: offset = -3
        }
        return root.majorFifths + offset
    }
    public var character: String {
        switch self {
        case .major: "The home base: a bright major sound. The 3rd and 7th define its character."
        case .dorian: "Minor with a natural 6. Compare that 6 with natural minor to hear the difference."
        case .phrygian: "Minor with a flat 2. The half step above the root creates its distinctive tension."
        case .lydian: "Major with a sharp 4. Hold the root as a drone and listen to that floating colour."
        case .mixolydian: "Major with a flat 7. A familiar sound in blues, rock, folk, and dominant harmony."
        case .minor: "The natural minor scale. Hear the flat 3, flat 6, and flat 7 against the tonic."
        case .locrian: "The flat 2 and flat 5 create an unstable sound. Its tonic triad is diminished."
        case .harmonicMinor: "Natural minor with a raised 7, creating a strong pull back to the tonic."
        case .melodicMinor:
            "The jazz form uses a minor 3 with natural 6 and 7 in both directions. Classical descending melodic minor usually returns to natural minor."
        case .majorPentatonic: "Five notes: 1, 2, 3, 5, 6. Try melodic phrases that end on the root or 3rd."
        case .minorPentatonic: "Five notes: 1, flat 3, 4, 5, flat 7. Connect small phrases across the fretboard."
        case .blues: "Minor pentatonic plus the flat 5. Use the blue note as movement and tension."
        }
    }
}

public enum ChordQuality: String, CaseIterable, Codable, Sendable {
    case major = "Major"
    case minor = "Minor"
    case diminished = "Diminished"
    case augmented = "Augmented"
    case sus2 = "Sus2"
    case sus4 =
        "Sus4"
    case maj7 = "Major 7"
    case min7 = "Minor 7"
    case dominant7 = "Dominant 7"
    case halfDim = "Half diminished 7"
    case dim7 =
        "Diminished 7"
    case add9 = "Add9"
    case sixth = "Major 6"
    case minorSixth = "Minor 6"
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .diminished: [0, 3, 6]
        case .augmented: [0, 4, 8]
        case .sus2: [0, 2, 7]
        case .sus4: [0, 5, 7]
        case .maj7: [0, 4, 7, 11]
        case .min7: [0, 3, 7, 10]
        case .dominant7: [0, 4, 7, 10]
        case .halfDim: [0, 3, 6, 10]
        case .dim7: [0, 3, 6, 9]
        case .add9: [0, 4, 7, 14]
        case .sixth: [0, 4, 7, 9]
        case .minorSixth: [0, 3, 7, 9]
        }
    }
    public var steps: [Int] {
        switch self {
        case .sus2: [0, 1, 4]
        case .sus4: [0, 3, 4]
        case .add9: [0, 2, 4, 8]
        case .sixth, .minorSixth: [0, 2, 4, 5]
        default: intervals.count == 3 ? [0, 2, 4] : [0, 2, 4, 6]
        }
    }
    public var symbol: String {
        switch self {
        case .major: ""
        case .minor: "m"
        case .diminished: "dim"
        case .augmented: "+"
        case .sus2: "sus2"
        case .sus4: "sus4"
        case .maj7: "maj7"
        case .min7: "m7"
        case .dominant7: "7"
        case .halfDim: "m7♭5"
        case .dim7: "dim7"
        case .add9: "add9"
        case .sixth: "6"
        case .minorSixth: "m6"
        }
    }
    public func notes(_ root: Pitch) -> [Pitch] {
        zip(intervals, steps).map { root.transposed(semitones: $0, steps: $1) }
    }
}

public struct Tuning: Hashable, Codable, Sendable {
    public var name: String
    /// Low string to high string, at concert pitch.
    public var pitches: [Int]
    public init(_ name: String, _ pitches: [Int]) {
        self.name = name
        self.pitches = pitches
    }
    public static let presets = [
        Tuning("Standard", [40, 45, 50, 55, 59, 64]), Tuning("Drop D", [38, 45, 50, 55, 59, 64]),
        Tuning("DADGAD", [38, 45, 50, 55, 57, 62]), Tuning("Open G", [38, 43, 50, 55, 59, 62]),
    ]
}

public struct Voicing: Hashable, Sendable {
    public var frets: [Int]  // -1 means muted; low string first
    public var pitches: [Int]
    public var rank: Double
    public var label: String { frets.map { $0 < 0 ? "×" : String($0) }.joined(separator: " · ") }
}

public enum Guitar {
    public static func positions(midi: Int, tuning: Tuning, capo: Int = 0) -> [(string: Int, fret: Int)] {
        tuning.pitches.enumerated().compactMap { i, open in
            let fret = midi - open - capo
            return (0...24).contains(fret) ? (i, fret) : nil
        }
    }
    public static func voicings(
        root: Pitch, quality: ChordQuality, tuning: Tuning, capo: Int = 0, triads: Bool = false, stringGroup: Int? = nil
    ) -> [Voicing] {
        let tones = Set(quality.intervals.map { mod(root.pc + $0) })
        return voicings(
            root: root, tones: tones, tuning: tuning, capo: capo, triads: triads, stringGroup: stringGroup,
            familiarQuality: quality)
    }
    public static func voicings(
        root: Pitch, tones: Set<Int>, tuning: Tuning, capo: Int = 0, triads: Bool = false, stringGroup: Int? = nil,
        bass: Int? = nil, familiarQuality quality: ChordQuality? = nil
    ) -> [Voicing] {
        guard tuning.pitches.count == 6, tuning.pitches.allSatisfy({ (21...100).contains($0) }), (0...9).contains(capo),
            !tones.isEmpty, tones.count <= 6, tones.allSatisfy({ (0...11).contains($0) }),
            bass.map({ tones.contains($0) }) ?? true
        else { return [] }
        let options: [[Int]] = tuning.pitches.map { open in
            [-1] + (0...12).filter { tones.contains(mod(open + capo + $0)) }
        }
        var found: [Voicing] = []
        // Familiar open and CAGED shapes are preferred when they match the tuning and chord.
        let openShapes: [(Int, ChordQuality, [Int])] = [
            (0, .major, [-1, 3, 2, 0, 1, 0]), (2, .major, [-1, -1, 0, 2, 3, 2]), (4, .major, [0, 2, 2, 1, 0, 0]),
            (7, .major, [3, 2, 0, 0, 0, 3]), (9, .major, [-1, 0, 2, 2, 2, 0]), (9, .minor, [-1, 0, 2, 2, 1, 0]),
            (4, .minor, [0, 2, 2, 0, 0, 0]), (2, .minor, [-1, -1, 0, 2, 3, 1]), (0, .maj7, [-1, 3, 2, 0, 0, 0]),
            (9, .min7, [-1, 0, 2, 0, 1, 0]), (4, .min7, [0, 2, 0, 0, 0, 0]), (2, .min7, [-1, -1, 0, 2, 1, 1]),
            (7, .dominant7, [3, 2, 0, 0, 0, 1]), (4, .dominant7, [0, 2, 0, 1, 0, 0]),
            (9, .dominant7, [-1, 0, 2, 0, 2, 0]),
            (2, .dominant7, [-1, -1, 0, 2, 1, 2]), (0, .dominant7, [-1, 3, 2, 3, 1, 0]),
        ]
        var familiar = Set<[Int]>()
        if tuning.pitches == Tuning.presets[0].pitches && !triads {
            for (pc, q, frets) in openShapes where q == quality && mod(pc + capo) == root.pc { familiar.insert(frets) }
            let eShapes: [(ChordQuality, [Int])] = [
                (.major, [0, 2, 2, 1, 0, 0]), (.minor, [0, 2, 2, 0, 0, 0]), (.dominant7, [0, 2, 0, 1, 0, 0]),
                (.maj7, [0, 2, 1, 1, 0, 0]), (.min7, [0, 2, 0, 0, 0, 0]),
            ]
            let aShapes: [(ChordQuality, [Int])] = [
                (.major, [-1, 0, 2, 2, 2, 0]), (.minor, [-1, 0, 2, 2, 1, 0]), (.dominant7, [-1, 0, 2, 0, 2, 0]),
                (.maj7, [-1, 0, 2, 1, 2, 0]), (.min7, [-1, 0, 2, 0, 1, 0]),
            ]
            for (q, shape) in eShapes where q == quality {
                let shift = mod(root.pc - 4 - capo)
                familiar.insert(shape.map { $0 + shift })
            }
            for (q, shape) in aShapes where q == quality {
                let shift = mod(root.pc - 9 - capo)
                familiar.insert(shape.map { $0 < 0 ? -1 : $0 + shift })
            }
        }
        func search(_ frets: [Int]) {
            if frets.count < 6 {
                for fret in options[frets.count] {
                    let positive = (frets + [fret]).filter { $0 > 0 }
                    if let lo = positive.min(), let hi = positive.max(), hi - lo > 3 { continue }
                    search(frets + [fret])
                }
                return
            }
            let played = frets.enumerated().filter { $0.element >= 0 }
            guard played.count >= tones.count, !triads || played.count == 3 else { return }
            if triads, let stringGroup, (0...3).contains(stringGroup),
                Set(played.map(\.offset)) != Set((3 - stringGroup)...(5 - stringGroup))
            {
                return
            }
            let pitches = played.map { tuning.pitches[$0.offset] + capo + $0.element }
            guard Set(pitches.map { mod($0) }) == tones else { return }
            if let bass, mod(pitches.min() ?? -1) != bass { return }
            // Keep a continuous group of strings for practical strumming and triad drills.
            guard let first = played.first?.offset, let last = played.last?.offset, last - first + 1 == played.count
            else { return }
            let positive = frets.filter { $0 > 0 }
            let lo = positive.min() ?? 0
            let hi = positive.max() ?? 0
            let uniqueFretted = Set(positive).count
            guard positive.count <= 4 || uniqueFretted <= 3 else { return }
            let bassPenalty = mod(pitches.min() ?? 0) == root.pc ? 0.0 : 5.0
            // Open strings between fretted notes cannot be covered by a barre.
            let fingerCount = positive.count > 4 && frets.contains(0) ? positive.count : uniqueFretted
            guard fingerCount <= 4 else { return }
            let rank =
                Double(hi) + Double(hi - lo) * 1.4 + bassPenalty + Double(6 - played.count) * 0.4 - Double(
                    frets.filter { $0 == 0 }.count) * 0.7 - (familiar.contains(frets) ? 35 : 0)
            found.append(Voicing(frets: frets, pitches: pitches, rank: rank))
        }
        search([])
        return Array(found.sorted { $0.rank == $1.rank ? $0.label < $1.label : $0.rank < $1.rank }.prefix(24))
    }
}

public struct ScaleChord: Sendable {
    public var root: Pitch
    public var quality: ChordQuality
    public var degree: String
}

public func harmonize(root: Pitch, scale: Scale) -> [ScaleChord] {
    guard scale.intervals.count == 7 else { return [] }
    let notes = scale.notes(root)
    return (0..<7).compactMap { i in
        let intervals = [
            0, mod(scale.intervals[(i + 2) % 7] - scale.intervals[i]),
            mod(scale.intervals[(i + 4) % 7] - scale.intervals[i]),
        ]
        guard let quality = ChordQuality.allCases.first(where: { $0.intervals == intervals }) else { return nil }
        let roman = ["I", "II", "III", "IV", "V", "VI", "VII"][i]
        let degree = quality == .minor || quality == .diminished ? roman.lowercased() : roman
        return ScaleChord(
            root: notes[i], quality: quality,
            degree: degree + (quality == .diminished ? "°" : quality == .augmented ? "+" : ""))
    }
}
