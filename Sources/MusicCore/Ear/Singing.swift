// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Movable Do, with Do-based minor. Spelling determines the altered syllable:
/// a raised fourth is Fi; a lowered fifth is Se, even though they sound alike.
public enum Solfege {
    public static func syllable(degree: Int, alteration: Int = 0) -> String {
        let index = mod(degree - 1, 7)
        let natural = ["Do", "Re", "Mi", "Fa", "Sol", "La", "Ti"][index]
        if alteration == 0 { return natural }
        let raised = [0: "Di", 1: "Ri", 3: "Fi", 4: "Si", 5: "Li"]
        let lowered = [1: "Ra", 2: "Me", 4: "Se", 5: "Le", 6: "Te"]
        if alteration == 1, let name = raised[index] { return name }
        if alteration == -1, let name = lowered[index] { return name }
        return natural + String(repeating: alteration > 0 ? "♯" : "♭", count: min(2, abs(alteration)))
    }
    public static func noteName(midi: Int, pitch: Pitch) -> String {
        // Letter-based octave numbering also handles C-flat and B-sharp.
        let octave = (midi - Pitch.naturals[pitch.letter] - pitch.accidental) / 12 - 1
        return pitch.name + String(octave)
    }
    public static func notes(root: Pitch, scale: Scale, octave: Int = 4) -> [SingingTone] {
        zip(scale.intervals, scale.degrees).map { interval, degree in
            SingingTone(
                midi: 12 * (octave + 1) + root.pc + interval,
                pitch: root.transposed(semitones: interval, steps: degree), degree: degree + 1,
                alteration: interval - Pitch.naturals[degree])
        }
    }
}

public struct SingingTone: Sendable, Equatable {
    public var midi: Int
    public var pitch: Pitch
    public var degree: Int
    public var alteration: Int
    public init(midi: Int, pitch: Pitch, degree: Int, alteration: Int = 0) {
        self.midi = midi
        self.pitch = pitch
        self.degree = degree
        self.alteration = alteration
    }
    public var solfege: String { Solfege.syllable(degree: degree, alteration: alteration) }
    public var singingLabel: String { solfege + (degree == 8 ? "′" : "") }
    public var noteName: String { Solfege.noteName(midi: midi, pitch: pitch) }
    public var degreeLabel: String {
        String(repeating: alteration < 0 ? "♭" : "♯", count: abs(alteration)) + String(degree)
    }
}

public enum SingingDirection: String, CaseIterable, Codable, Sendable {
    case ascending = "Ascending"
    case descending = "Descending"
    case mixed = "Both directions"
}
public enum SingingIntervalSet: String, CaseIterable, Codable, Sendable {
    case scale = "In this scale"
    case chromatic = "All intervals"
}

public struct SingingInterval: Sendable, Equatable {
    public var first: SingingTone
    public var second: SingingTone
    public var semitones: Int { second.midi - first.midi }
    public var name: String { Self.intervalName(abs(semitones)) }
    public var direction: String { semitones < 0 ? "Descending" : "Ascending" }
    public var prompt: String { "\(direction) \(name.lowercased())" }
    public var audio: Score {
        Score(
            tempo: 90,
            notes: [
                ScoreNote(midi: first.midi, start: 0, duration: 1.1),
                ScoreNote(midi: second.midi, start: 2, duration: 1.1),
            ])
    }
    public static func intervalName(_ distance: Int) -> String {
        let names = [
            "Unison", "Minor 2nd", "Major 2nd", "Minor 3rd", "Major 3rd", "Perfect 4th", "Tritone", "Perfect 5th",
            "Minor 6th", "Major 6th", "Minor 7th", "Major 7th", "Octave",
        ]
        return names.indices.contains(abs(distance)) ? names[abs(distance)] : "\(abs(distance)) semitones"
    }
    public static func describe(_ distance: Int) -> String {
        if distance == 0 { return "the same note" }
        return "\(distance < 0 ? "a descending" : "an ascending") \(intervalName(abs(distance)).lowercased())"
    }
}

public enum IntervalSingingFactory {
    public static func deck(
        root: Pitch, scale: Scale, set: SingingIntervalSet = .scale, direction: SingingDirection = .mixed,
        octave: Int = 3
    ) -> [PracticeQuestion] {
        let base = 12 * (min(4, max(2, octave)) + 1) + root.pc
        let tonic = SingingTone(midi: base, pitch: root, degree: 1)
        let targets: [SingingTone]
        if set == .scale {
            targets =
                Array(Solfege.notes(root: root, scale: scale, octave: min(4, max(2, octave))).dropFirst()) + [
                    SingingTone(midi: base + 12, pitch: root, degree: 8)
                ]
        } else {
            // A consistent written function for each chromatic distance from Do.
            let degrees = [2, 2, 3, 3, 4, 4, 5, 6, 6, 7, 7, 8]
            let alterations = [-1, 0, -1, 0, 0, 1, 0, -1, 0, -1, 0, 0]
            targets = (1...12).map { distance in
                SingingTone(
                    midi: base + distance,
                    pitch: root.transposed(semitones: distance, steps: degrees[distance - 1] - 1),
                    degree: degrees[distance - 1], alteration: alterations[distance - 1])
            }
        }
        let descending = direction == .mixed ? [false, true] : [direction == .descending]
        return targets.flatMap { target in
            descending.map { down in
                let interval = SingingInterval(first: down ? target : tonic, second: down ? tonic : target)
                return PracticeQuestion(
                    id: "sing-interval:\(root.pc):\(interval.semitones):\(target.degree)", exercise: .intervals,
                    title: "Echo the interval",
                    detail:
                        "Hear two notes, then sing both back in the same order. Hold each note steadily for about a second.",
                    choices: [interval.prompt], answer: 0,
                    explanation:
                        "\(interval.prompt): \(interval.first.singingLabel) → \(interval.second.singingLabel), \(abs(interval.semitones)) semitones \(down ? "down" : "up"). The space between both sung notes is what counts.",
                    audio: interval.audio, target: interval.second.midi,
                    singingNotes: [interval.first, interval.second], singingInterval: interval)
            }
        }
    }
}

public enum IntervalEchoResult: Equatable, Sendable {
    case ignored
    case firstNote(Int)
    case wrongReference(Int)
    case wrongInterval(Int)
    case correct
}

/// Receives stable held notes from the pitch detector. A held note is never
/// counted twice as a two-note answer. Whole-octave shifts preserve the interval;
/// shifting only one of the notes does not.
public struct IntervalEchoAttempt: Sendable {
    public private(set) var firstHeard: Int?
    public private(set) var complete = false
    private var lastHeard: Int?
    public init() {}
    public mutating func hear(_ midi: Int, for interval: SingingInterval, matchReference: Bool = false)
        -> IntervalEchoResult
    {
        guard (0...127).contains(midi), !complete, midi != lastHeard else { return .ignored }
        lastHeard = midi
        guard let first = firstHeard else {
            if matchReference && mod(midi) != mod(interval.first.midi) { return .wrongReference(midi) }
            firstHeard = midi
            return .firstNote(midi)
        }
        guard midi != first else { return .ignored }
        let distance = midi - first
        guard distance == interval.semitones else { return .wrongInterval(distance) }
        complete = true
        return .correct
    }
    public mutating func reset() { self = Self() }
}
