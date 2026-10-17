// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct ChordTone: Equatable, Sendable {
    public let degree: Int
    public let semitones: Int
    public let pitch: Pitch
    public var label: String {
        let alteration = semitones - HarmonyKind.majorInterval(degree)
        return (alteration < 0 ? String(repeating: "♭", count: -alteration) : String(repeating: "♯", count: alteration))
            + String(degree)
    }
}

extension HarmonyKind {
    static func majorInterval(_ degree: Int) -> Int {
        [0, 2, 4, 5, 7, 9, 11][(degree - 1) % 7] + 12 * ((degree - 1) / 7)
    }
    var baseIntervals: [Int: Int] {
        var result = Dictionary(uniqueKeysWithValues: includedDegrees.map { ($0, Self.majorInterval($0)) })
        if [
            .minor, .diminished, .minorSeventh, .diminishedSeventh, .halfDiminished, .majorMinor, .minorSixth,
            .minorNinth, .minor11th, .minor13th,
        ].contains(self) {
            result[3] = 3
        }
        if [.diminished, .diminishedSeventh, .halfDiminished].contains(self) { result[5] = 6 }
        if [.augmented, .augmentedSeventh].contains(self) { result[5] = 8 }
        if includedDegrees.contains(7),
            ![.majorSeventh, .majorMinor, .majorNinth, .major11th, .major13th].contains(self)
        {
            result[7] = self == .diminishedSeventh ? 9 : 10
        }
        return result
    }
}

/// The structured MusicXML harmony is authoritative; printed suffixes are display text.
/// Degree alterations follow MusicXML 4: alter is relative to kind, add to dominant.
public struct ChordRealization: Equatable, Sendable {
    public let symbol: ChordSymbol
    public let tones: [ChordTone]
    public init(_ symbol: ChordSymbol) throws {
        guard symbol.valid else { throw MusicError.invalid("This chord symbol is invalid.") }
        self.symbol = symbol
        guard let root = symbol.root else {
            tones = []
            return
        }
        let base = symbol.kind.baseIntervals
        var intervals = base.mapValues { [$0] }
        for (degree, changes) in Dictionary(grouping: symbol.degrees, by: \.value) {
            let types = Set(changes.map(\.type))
            guard types.count == 1 else {
                throw MusicError.invalid("Review the conflicting changes to degree \(degree) in \(symbol.label).")
            }
            switch changes[0].type {
            case .subtract:
                guard base[degree] != nil, changes.count == 1, changes[0].alter == 0 else {
                    throw MusicError.invalid("Review the omitted degree in \(symbol.label).")
                }
                intervals.removeValue(forKey: degree)
            case .alter:
                guard let original = base[degree] else {
                    throw MusicError.invalid("An altered degree is missing from \(symbol.label).")
                }
                intervals[degree] = changes.map { original + $0.alter }
            case .add:
                let original = degree == 7 ? 10 : HarmonyKind.majorInterval(degree)
                intervals[degree, default: []] += changes.map { original + $0.alter }
            }
        }
        tones = intervals.keys.sorted().flatMap { degree in
            Set(intervals[degree]!).sorted().map {
                ChordTone(degree: degree, semitones: $0, pitch: root.transposed(semitones: $0, steps: degree - 1))
            }
        }
        guard !tones.isEmpty, Set(tones.map { $0.pitch.pc }).count <= 12 else {
            throw MusicError.invalid("This chord has no playable tones.")
        }
    }
    public func target(_ mode: ChangesMode) throws -> ChangesTarget {
        guard let root = symbol.root else {
            throw MusicError.invalid("N.C. means no chord; there is no MIDI answer to grade.")
        }
        let selected: [Pitch]
        switch mode {
        case .roots: selected = [root]
        case .guides, .shells:
            let guides = tones.filter { $0.degree == 3 || $0.degree == 7 }
            guard Set(guides.map(\.degree)) == [3, 7] else {
                throw MusicError.invalid(
                    "\(symbol.label) has no third-and-seventh pair. Choose roots or complete chords for this passage.")
            }
            selected = (mode == .shells ? [root] : []) + guides.map(\.pitch)
        case .complete: selected = tones.map(\.pitch)
        }
        // Slash bass belongs to the sounding voicing, but not to a root or guide-tone drill.
        let bass = mode == .complete || mode == .shells ? symbol.bass : nil
        var pitches = selected
        if let bass, !pitches.contains(where: { $0.pc == bass.pc }) { pitches.append(bass) }
        return ChangesTarget(pitches: pitches, bass: bass, root: root)
    }
}

public enum ChangesMode: String, CaseIterable, Codable, Sendable {
    case roots = "Roots"
    case guides = "Thirds & sevenths"
    case shells = "Shell voicings"
    case complete = "Complete chords"
    public var instruction: String {
        switch self {
        case .roots: "Play the chord root in any octave. Slash bass is not required in this drill."
        case .guides: "Play just the third and seventh. Listen for the small movements between chords."
        case .shells: "Play the root, third and seventh, plus the printed slash bass when present."
        case .complete: "Play every chord tone, including written extensions and alterations."
        }
    }
}

public struct ChangesTarget: Equatable, Sendable {
    public let pitches: [Pitch]
    public let bass: Pitch?
    public let root: Pitch
    public var pitchClasses: Set<Int> { Set(pitches.map(\.pc)) }
    public func judge(_ notes: [Int]) -> ChordJudgement {
        ChordJudgement.match(notes, required: pitchClasses, bass: bass?.pc)
    }
    public func pianoVoicings(previous: [Int] = []) -> [[Int]] {
        let classes = pitchClasses.sorted()
        var choices: [[Int]] = []
        for lowest in 48...71 where pitchClasses.contains(mod(lowest)) && (bass == nil || mod(lowest) == bass?.pc) {
            let notes = classes.map { lowest + mod($0 - mod(lowest)) }.sorted()
            if notes.last! <= 84 { choices.append(notes) }
        }
        return choices.sorted {
            let a = VoiceLeading.distance(previous, $0)
            let b = VoiceLeading.distance(previous, $1)
            return a == b ? $0.lexicographicallyPrecedes($1) : a < b
        }
    }
    public func guitarVoicings(tuning: Tuning, capo: Int) -> [Voicing] {
        let quality = ChordQuality.allCases.first { Set($0.intervals.map { mod(root.pc + $0) }) == pitchClasses }
        return Guitar.voicings(
            root: root, tones: pitchClasses, tuning: tuning, capo: capo, bass: bass?.pc, familiarQuality: quality)
    }
}

public enum VoiceLeading {
    /// Ordered voices, not fingering. Unequal sizes use nearest-note motion plus a voice-count penalty.
    public static func distance(_ previous: [Int], _ next: [Int]) -> Int {
        guard !previous.isEmpty else { return abs((next.first ?? 60) - 55) }
        if previous.count == next.count {
            return zip(previous.sorted(), next.sorted()).reduce(0) { $0 + abs($1.0 - $1.1) }
        }
        return next.reduce(0) { sum, n in sum + (previous.map { abs($0 - n) }.min() ?? 0) } + abs(
            previous.count - next.count) * 12
    }
    public static func commonTones(_ first: ChangesTarget, _ next: ChangesTarget) -> [Pitch] {
        first.pitches.filter { next.pitchClasses.contains($0.pc) }
    }
}
