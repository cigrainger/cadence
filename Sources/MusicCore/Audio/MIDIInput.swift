// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum MIDIMessage: Equatable, Sendable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int)
    case control(channel: Int, number: Int, value: Int)
    case reset
}
/// CoreMIDI converts the source to MIDI 1.0 UMP before delivering packets.
public enum MIDIWords {
    public static func decode(_ words: [UInt32]) -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        var i = 0
        let sizes = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        while i < words.count {
            let w = words[i]
            let type = Int(w >> 28)
            let count = sizes[type]
            guard i + count <= words.count else { break }
            if type == 2 {
                let status = Int((w >> 16) & 255)
                let channel = status & 15
                let a = Int((w >> 8) & 127)
                let b = Int(w & 127)
                switch status >> 4 {
                case 9:
                    result.append(
                        b == 0 ? .noteOff(channel: channel, note: a) : .noteOn(channel: channel, note: a, velocity: b))
                case 8: result.append(.noteOff(channel: channel, note: a))
                case 11: result.append(.control(channel: channel, number: a, value: b))
                default: break
                }
            } else if type == 1, (w >> 16) & 255 == 255 {
                result.append(.reset)
            }
            i += count
        }
        return result
    }
}
public struct MIDIKey: Hashable, Sendable {
    public var channel: Int
    public var note: Int
}
public struct MIDIKeyboardState: Equatable, Sendable {
    public private(set) var pressed = Set<MIDIKey>()
    public private(set) var sustained = Set<MIDIKey>()
    public private(set) var pedals = Set<Int>()
    public init() {}
    public var downNotes: Set<Int> { Set(pressed.map(\.note)) }
    public var soundingNotes: Set<Int> { Set(pressed.union(sustained).map(\.note)) }
    public mutating func reset() {
        pressed = []
        sustained = []
        pedals = []
    }
    public mutating func receive(_ message: MIDIMessage) {
        switch message {
        case .noteOn(let channel, let note, let velocity):
            guard (0...15).contains(channel), (0...127).contains(note), (0...127).contains(velocity) else { return }
            if velocity == 0 {
                receive(.noteOff(channel: channel, note: note))
                return
            }
            let key = MIDIKey(channel: channel, note: note)
            pressed.insert(key)
            sustained.remove(key)
        case .noteOff(let channel, let note):
            let key = MIDIKey(channel: channel, note: note)
            if pressed.remove(key) != nil, pedals.contains(channel) { sustained.insert(key) }
        case .control(let channel, let number, let value):
            if number == 64 {
                if value >= 64 {
                    pedals.insert(channel)
                } else {
                    pedals.remove(channel)
                    sustained = sustained.filter { $0.channel != channel }
                }
            } else if number == 120 || number == 123 {
                pressed = pressed.filter { $0.channel != channel }
                sustained = sustained.filter { $0.channel != channel }
                pedals.remove(channel)
            } else if number == 121 {
                pedals.remove(channel)
                sustained = sustained.filter { $0.channel != channel }
            }
        case .reset: reset()
        }
    }
}
/// A gesture is committed once all physical keys are up. Pedal never joins
/// successive entries. Arming or changing context while keys are down waits.
public struct MIDIStepCapture: Sendable {
    public private(set) var waitingForRelease = false
    public private(set) var notes = Set<Int>()
    public init() {}
    public mutating func reset(held: Set<Int> = []) {
        notes = []
        waitingForRelease = !held.isEmpty
    }
    public mutating func receive(_ message: MIDIMessage, state: MIDIKeyboardState) -> [Int]? {
        if message == .reset {
            reset(held: state.downNotes)
            return nil
        }
        if case .control(_, let number, _) = message, number == 120 || number == 123 {
            reset(held: state.downNotes)
            return nil
        }
        if waitingForRelease {
            if state.downNotes.isEmpty { waitingForRelease = false }
            return nil
        }
        if case .noteOn(_, let note, let velocity) = message, velocity > 0 { notes.insert(note) }
        if state.downNotes.isEmpty, !notes.isEmpty {
            let result = notes.sorted()
            notes = []
            return result
        }
        return nil
    }
}

public struct PlayedChord: Codable, Equatable, Identifiable, Sendable {
    public var root: Pitch
    public var quality: ChordQuality
    public var inversion: Int
    public init(root: Pitch, quality: ChordQuality, inversion: Int = 0) {
        self.root = root
        self.quality = quality
        self.inversion = inversion
    }
    public var id: String { "play-chord:\(root.pc):\(quality.rawValue):\(inversion)" }
    public var tones: [Pitch] { quality.notes(root) }
    public var pitchClasses: Set<Int> { Set(tones.map(\.pc)) }
    public var bass: Pitch { tones[min(max(0, inversion), tones.count - 1)] }
    public var title: String { "\(root.name) \(quality.rawValue.lowercased())" }
    public var inversionLabel: String {
        ["Root position", "First inversion", "Second inversion", "Third inversion"][min(3, max(0, inversion))]
    }
    public var reference: [Int] {
        var values = tones.map { 60 + root.pc + mod($0.pc - root.pc) }
        for _ in 0..<min(max(0, inversion), values.count - 1) { values.append(values.removeFirst() + 12) }
        return values
    }
    public func judge(_ notes: [Int]) -> ChordJudgement {
        ChordJudgement.match(notes, required: pitchClasses, bass: bass.pc)
    }
}
public struct ChordJudgement: Equatable, Sendable {
    public var missing: [Int]
    public var extra: [Int]
    public var bassCorrect: Bool
    public var correct: Bool { missing.isEmpty && extra.isEmpty && bassCorrect }
    public static func match(_ notes: [Int], required: Set<Int>, bass: Int?) -> Self {
        let valid = notes.filter { (0...127).contains($0) }
        let played = Set(valid.map { mod($0) })
        return Self(
            missing: required.subtracting(played).sorted(), extra: played.subtracting(required).sorted(),
            bassCorrect: valid.count == notes.count && !valid.isEmpty
                && (bass.map { expected in valid.min().map { mod($0) == expected } ?? false } ?? true))
    }
}

extension EditorDocument {
    /// One atomic gesture replaces the selected event's whole chord. All
    /// subsequent rhythm edits/advance stay in the selected staff and voice.
    public mutating func enterMIDI(_ notes: [Int], eventID: UUID, rhythm: EditorRhythm, appendBar: Bool = true) throws
        -> UUID
    {
        var copy = self
        let pitches = Array(Set(notes)).sorted()
        guard !pitches.isEmpty, pitches.count <= (instrument == .guitar ? 6 : 8),
            pitches.allSatisfy({ (21...108).contains($0) }), copy.events.contains(where: { $0.id == eventID })
        else {
            throw MusicError.invalid("Enter 1–\(instrument == .guitar ? 6 : 8) notes in the supported range A0–C8.")
        }
        try copy.setRhythm(eventID, rhythm)
        let i = copy.events.firstIndex { $0.id == eventID }!
        let event = copy.events[i]
        copy.events[i].pitches = pitches.map { EditorPitch($0, spelling: Pitch.spelled($0, flats: copy.fifths < 0)) }
        if instrument == .guitar { try copy.setGuitar(tuning: copy.tuning, capo: copy.capo) }
        copy.clearInvalidTies()
        if appendBar, copy.nextEvent(event) == nil, copy.barCount < 128 { try copy.insertBars(at: copy.barCount) }
        let updated = copy.events.first { $0.id == eventID }!
        let next = copy.nextEvent(updated)?.id ?? eventID
        self = try copy.validated()
        return next
    }
}
