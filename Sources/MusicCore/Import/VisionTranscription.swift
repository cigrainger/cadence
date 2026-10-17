// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Experimental benchmark format. Pitches are written MIDI; duplicate guitar
/// TAB is excluded, and bar/start offsets are local to the rendered excerpt.
public struct VisionNote: Codable, Equatable, Sendable {
    public var bar: Int
    public var staff: Int
    public var voice: Int
    public var midi: Int
    public var start: Double
    public var duration: Double
    public init(bar: Int, staff: Int, voice: Int, midi: Int, start: Double, duration: Double) {
        self.bar = bar
        self.staff = staff
        self.voice = voice
        self.midi = midi
        self.start = start
        self.duration = duration
    }
    public var valid: Bool {
        (1...128).contains(bar) && (1...2).contains(staff) && (1...2).contains(voice) && (-1...127).contains(midi)
            && start.isFinite && (0...32).contains(start) && duration.isFinite && duration > 0 && duration <= 32
    }
}
public struct VisionTranscription: Codable, Equatable, Sendable {
    public var beats: Int
    public var beatUnit: Int
    public var fifths: Int
    public var notes: [VisionNote]
    public var warnings: [String]
    public init(_ document: EditorDocument) {
        beats = document.meter.beats
        beatUnit = document.meter.unit
        fifths = document.fifths
        warnings = []
        notes = document.events.flatMap { event in
            let start = Double(document.onset(event)) / 480
            let duration = Double(event.rhythm.ticks) / 480
            if event.isRest {
                return [
                    VisionNote(
                        bar: event.bar + 1, staff: event.staff, voice: event.voice, midi: -1, start: start,
                        duration: duration)
                ]
            }
            return event.pitches.map {
                VisionNote(
                    bar: event.bar + 1, staff: event.staff, voice: event.voice,
                    midi: $0.midi + (document.instrument == .guitar ? 12 : 0), start: start, duration: duration)
            }
        }
    }
    public func validated() throws -> Self {
        guard (1...16).contains(beats), [2, 4, 8, 16].contains(beatUnit), (-7...7).contains(fifths), !notes.isEmpty,
            notes.count <= 10000, notes.allSatisfy(\.valid), warnings.count <= 100,
            warnings.allSatisfy({ $0.count <= 1000 })
        else { throw MusicError.invalid("The model returned invalid transcription data.") }
        return self
    }
    public static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 500000, let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else {
            throw MusicError.invalid("No transcription JSON was returned.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(text[a...b].utf8)).validated()
    }
    public func compare(to expected: Self) -> VisionComparison {
        func key(_ n: VisionNote, full: Bool) -> String {
            "\(n.bar):\(n.staff):\(n.midi):\(Int((n.start*480).rounded()))"
                + (full ? ":\(n.voice):\(Int((n.duration*480).rounded()))" : "")
        }
        func intersection(full: Bool) -> Int {
            var counts: [String: Int] = [:]
            for n in expected.notes { counts[key(n, full: full), default: 0] += 1 }
            var matched = 0
            for n in notes {
                let k = key(n, full: full)
                if counts[k, default: 0] > 0 {
                    matched += 1
                    counts[k]! -= 1
                }
            }
            return matched
        }
        let exact = intersection(full: true)
        let pitch = intersection(full: false)
        return VisionComparison(
            expectedNotes: expected.notes.count, returnedNotes: notes.count, exactMatches: exact,
            pitchOnsetMatches: pitch, meterCorrect: beats == expected.beats && beatUnit == expected.beatUnit,
            keyCorrect: fifths == expected.fifths)
    }
}
public struct VisionComparison: Codable, Equatable, Sendable {
    public var expectedNotes: Int
    public var returnedNotes: Int
    public var exactMatches: Int
    public var pitchOnsetMatches: Int
    public var meterCorrect: Bool
    public var keyCorrect: Bool
    public var exactF1: Double { Double(2 * exactMatches) / Double(max(1, expectedNotes + returnedNotes)) }
    public var pitchOnsetF1: Double { Double(2 * pitchOnsetMatches) / Double(max(1, expectedNotes + returnedNotes)) }
}

public enum VisionExamples {
    public static var compound: EditorDocument {
        var events: [EditorEvent] = []
        let lines = [[67, 69, 70, 74], [72, 75, 78, 79], [77, -1, 74, 72], [70, 69, 67, 67]]
        for bar in 0..<4 {
            for (i, midi) in lines[bar].enumerated() {
                let pitch = midi < 0 ? [] : [EditorPitch(midi, spelling: Pitch.spelled(midi, flats: midi != 78))]
                events.append(
                    EditorEvent(
                        bar: bar, rhythm: EditorRhythm(i == 3 ? 480 : 240, dotted: i == 3), pitches: pitch,
                        tieNext: bar == 3 && i == 2))
            }
        }
        for (bar, midi) in [43, 48, 50, 43].enumerated() {
            events.append(
                EditorEvent(bar: bar, staff: 2, rhythm: EditorRhythm(960, dotted: true), pitches: [EditorPitch(midi)]))
        }
        var document = EditorDocument(title: "A six-eight reading study", instrument: .piano, events: events)
        document.meter = EditorMeter(6, 8)
        document.fifths = -2
        document.minor = true
        document.tempo = 96
        return document
    }
}
