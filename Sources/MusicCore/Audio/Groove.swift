// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum GrooveStyle: String, CaseIterable, Codable, Sendable {
    case steady = "On the beat"
    case offbeat = "Offbeat comping"
    case swing = "Swing eighths"
    public var invitation: String {
        switch self {
        case .steady: return "Hear where bass and piano meet. Tap quarters, then sing the root before each change."
        case .offbeat:
            return "Keep the quarter-note pulse inside while the piano answers between beats. Count 1 & 2 & 3 & 4 &."
        case .swing:
            return
                "Hear the long–short pair. This study uses a fixed 2:1 ratio; real swing varies with tempo and style."
        }
    }
}
public enum BandVoice: Int, CaseIterable, Codable, Sendable {
    case piano = 0
    case electricPiano = 4
    case bass = 32
    case drums = 128
}
public struct BandLane: Sendable {
    public var voice: BandVoice
    public var notes: [ScoreNote]
    public init(_ voice: BandVoice, notes: [ScoreNote]) {
        self.voice = voice
        self.notes = notes
    }
}
public struct GrooveArrangement: Sendable {
    public var tempo: Double
    public var style: GrooveStyle
    public var loops: Int
    public var piano: Bool
    public var bass: Bool
    public var drums: Bool
    public var electric: Bool
    public init(
        tempo: Double = 80, style: GrooveStyle = .steady, loops: Int = 2, piano: Bool = true, bass: Bool = true,
        drums: Bool = true, electric: Bool = false
    ) {
        self.tempo = tempo
        self.style = style
        self.loops = loops
        self.piano = piano
        self.bass = bass
        self.drums = drums
        self.electric = electric
    }
    public static let symbols = ["Dm7", "G7", "Cmaj7", "Cmaj7"]
    public static let voicings = [[53, 57, 60, 62], [53, 55, 59, 62], [52, 55, 59, 60], [52, 55, 59, 60]]
    public static let roots = [38, 43, 36, 36]
    public var endBeat: Double { Double(4 + loops * 16) }
    public var valid: Bool { tempo.isFinite && (50...160).contains(tempo) && (1...4).contains(loops) }
    public func lanes() throws -> [BandLane] {
        guard valid else { throw MusicError.invalid("Choose 50–160 bpm and one to four rounds.") }
        return try BandPattern.lanes(
            segments: (0..<4).map {
                BandSegment(
                    start: Double($0 * 4), end: Double(($0 + 1) * 4), voicing: Self.voicings[$0], bass: Self.roots[$0],
                    alternateFifth: true)
            }, beats: 16, options: self)
    }
    public func bar(at seconds: Double) -> Int? {
        guard valid, seconds.isFinite else { return nil }
        let beat = seconds * tempo / 60
        guard beat >= 4, beat < endBeat else { return nil }
        return Int((beat - 4) / 4) % 4
    }
}

struct BandSegment: Sendable {
    var start: Double
    var end: Double
    var voicing: [Int]
    var bass: Int?
    var alternateFifth = false
}
/// The authored groove and library accompaniment share the same rhythmic engine.
enum BandPattern {
    static func lanes(segments: [BandSegment], beats: Double, options: GrooveArrangement, melody: [ScoreNote] = [])
        throws -> [BandLane]
    {
        guard options.valid, beats.isFinite, beats > 0, beats <= 64 else {
            throw MusicError.invalid("Choose 50–160 bpm and one to four rounds.")
        }
        var comp: [ScoreNote] = []
        var low: [ScoreNote] = []
        var kit: [ScoreNote] = []
        var lead: [ScoreNote] = []
        func note(_ midi: Int, _ beat: Double, _ duration: Double, _ velocity: Int) -> ScoreNote {
            var n = ScoreNote(midi: midi, start: beat, duration: duration)
            n.performance = NotePerformance(velocity: velocity, gate: 0.9)
            return n
        }
        for beat in 0..<4 { kit.append(note(37, Double(beat), 0.1, beat == 0 ? 82 : 62)) }
        let compGrid = (0..<Int(beats / 4)).flatMap { bar -> [Double] in
            let pattern: [Double] =
                options.style == .steady
                ? [0, 2] : options.style == .offbeat ? [0.5, 1.5, 2.5, 3.5] : [0, Double(5) / 3, 3]
            return pattern.map { Double(bar * 4) + $0 }
        }
        let bassGrid = stride(from: 0.0, to: beats, by: 2).map { $0 }
        for loop in 0..<options.loops {
            let offset = 4 + Double(loop) * beats
            for segment in segments {
                // Keep a change audible if it falls between the pattern's attacks.
                var hits = compGrid.filter { $0 >= segment.start && $0 < segment.end }
                if segment.start.truncatingRemainder(dividingBy: 4) != 0 && !hits.contains(segment.start) {
                    hits.append(segment.start)
                }
                if options.piano {
                    for beat in hits {
                        for midi in segment.voicing {
                            comp.append(
                                note(
                                    midi, offset + beat, min(segment.end - beat, options.style == .steady ? 1.4 : 0.35),
                                    64))
                        }
                    }
                }
                if options.bass, let root = segment.bass {
                    var hits = bassGrid.filter { $0 >= segment.start && $0 < segment.end }
                    if !hits.contains(segment.start) { hits.append(segment.start) }
                    for beat in hits {
                        low.append(
                            note(
                                root + (segment.alternateFifth && beat.truncatingRemainder(dividingBy: 4) == 2 ? 7 : 0),
                                offset + beat, min(segment.end - beat, 1.7), 83))
                    }
                }
            }
            if options.drums {
                for beat in 0..<Int(beats) {
                    kit.append(
                        note(options.style == .swing ? 51 : 42, offset + Double(beat), 0.15, beat % 2 == 0 ? 58 : 70))
                    kit.append(
                        note(
                            options.style == .swing ? 51 : 42,
                            offset + Double(beat) + (options.style == .swing ? 2.0 / 3 : 0.5), 0.12, 42))
                    kit.append(note(beat % 2 == 0 ? 36 : 38, offset + Double(beat), 0.15, beat % 2 == 0 ? 68 : 63))
                }
            }
            lead += melody.map { item in
                var n = item
                n.start += offset
                return n
            }
        }
        var lanes = [
            BandLane(options.electric ? .electricPiano : .piano, notes: comp), BandLane(.bass, notes: low),
            BandLane(.drums, notes: kit),
        ]
        if !lead.isEmpty { lanes.append(BandLane(.piano, notes: lead)) }
        return lanes
    }
}
public struct ScoreAccompaniment: Sendable {
    public var material: ScoreEarMaterial
    public var options: GrooveArrangement
    public var includeMelody: Bool
    public init(
        material: ScoreEarMaterial, options: GrooveArrangement = GrooveArrangement(), includeMelody: Bool = false
    ) {
        self.material = material
        self.options = options
        self.includeMelody = includeMelody
    }
    public var endBeat: Double { 4 + material.beats * Double(options.loops) }
    public func lanes() throws -> [BandLane] {
        guard material.valid, material.accompanimentIssue == nil else {
            throw MusicError.invalid(material.accompanimentIssue ?? "Review this passage first.")
        }
        var previous: [Int] = []
        let segments = try material.chords.map { chord -> BandSegment in
            if chord.symbol.kind == .none {
                return BandSegment(start: chord.start, end: chord.end, voicing: [], bass: nil)
            }
            let target = try ChordRealization(chord.symbol).target(.complete)
            let voicing = target.pianoVoicings(previous: previous).first ?? []
            previous = voicing
            return BandSegment(
                start: chord.start, end: chord.end, voicing: voicing, bass: 36 + (target.bass ?? target.root).pc)
        }
        return try BandPattern.lanes(
            segments: segments, beats: material.beats, options: options, melody: includeMelody ? material.melody : [])
    }
    public func bar(at seconds: Double) -> Int? {
        guard options.valid, seconds.isFinite, material.valid else { return nil }
        let beat = seconds * options.tempo / 60
        guard beat >= 4, beat < endBeat else { return nil }
        return Int((beat - 4).truncatingRemainder(dividingBy: material.beats) / 4) + material.scope.fromBar
    }
}
