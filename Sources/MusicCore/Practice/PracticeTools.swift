// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum BeatSubdivision: String, Codable, CaseIterable, Sendable {
    case beat = "Beat"
    case eighths = "Eighths"
    case triplets = "Triplets"
    case sixteenths = "Sixteenths"
    public var count: Int {
        switch self {
        case .beat: 1
        case .eighths: 2
        case .triplets: 3
        case .sixteenths: 4
        }
    }
}
public struct MetronomeSettings: Codable, Equatable, Sendable {
    public var bpm = 84
    public var beatsPerBar = 4
    public var subdivision = BeatSubdivision.beat
    public var accents = [true, false, false, false]
    public var volume = 0.6
    public init() {}
    public mutating func setBeats(_ count: Int) {
        beatsPerBar = min(12, max(1, count))
        accents = Array((accents + [Bool](repeating: false, count: 12)).prefix(beatsPerBar))
    }
    public func validated() throws -> Self {
        guard (20...300).contains(bpm), (1...12).contains(beatsPerBar), accents.count == beatsPerBar, volume.isFinite,
            (0...1).contains(volume)
        else { throw MusicError.invalid("Choose 20–300 bpm, 1–12 beats per bar, and a volume from 0–100%.") }
        return self
    }
}
public struct MetronomePosition: Equatable, Sendable {
    public var bar: Int
    public var beat: Int
    public var subdivision: Int
    public var progress: Double
}
public struct MetronomePattern: Sendable {
    public var settings: MetronomeSettings
    public var sampleRate: Double
    public var frameCount: Int
    public var duration: Double { Double(frameCount) / sampleRate }
    public init(_ settings: MetronomeSettings, sampleRate: Double = 44100) throws {
        self.settings = try settings.validated()
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate) else {
            throw MusicError.invalid("Unsupported metronome sample rate.")
        }
        self.sampleRate = sampleRate
        frameCount = Int((Double(settings.beatsPerBar) * 60 / Double(settings.bpm) * sampleRate).rounded())
    }
    public var pulseFrames: [Int] {
        (0..<settings.beatsPerBar * settings.subdivision.count).map {
            Int((Double($0) * Double(frameCount) / Double(settings.beatsPerBar * settings.subdivision.count)).rounded())
        }
    }
    public func position(sampleTime: Int64) -> MetronomePosition {
        let elapsed = max(0, sampleTime)
        let frame = Int(elapsed % Int64(frameCount))
        let beatFloat = Double(frame) * Double(settings.beatsPerBar) / Double(frameCount)
        let pulse = pulseFrames.lastIndex(where: { $0 <= frame }) ?? 0
        return MetronomePosition(
            bar: Int(elapsed / Int64(frameCount)), beat: pulse / settings.subdivision.count,
            subdivision: pulse % settings.subdivision.count, progress: beatFloat - floor(beatFloat))
    }
    /// One exact bar, looped by the audio device. Each click is synthesised at
    /// its sample offset; UI timers do not trigger the sound.
    public func render() -> [Float] {
        var output = [Float](repeating: 0, count: frameCount)
        for (pulse, start) in pulseFrames.enumerated() {
            let downbeat = pulse % settings.subdivision.count == 0
            let accented = downbeat && settings.accents[pulse / settings.subdivision.count]
            let frequency = accented ? 1900.0 : downbeat ? 1300 : 850
            let gain = (accented ? 0.65 : downbeat ? 0.46 : 0.23) * settings.volume
            let length = min(Int(sampleRate * 0.035), frameCount - start)
            guard length > 0 else { continue }
            for index in 0..<length {
                let time = Double(index) / sampleRate
                let envelope = min(1, time / 0.0008) * exp(-time * 170)
                let click = sin(2 * Double.pi * frequency * time) + 0.22 * sin(2 * Double.pi * frequency * 1.73 * time)
                output[start + index] += Float(click * envelope * gain)
            }
        }
        return output
    }
}
public struct TapTempo: Sendable {
    private var taps: [Double] = []
    public init() {}
    public mutating func tap(at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        if let previous = taps.last {
            if time <= previous || time - previous > 3.5 {
                taps = [time]
                return nil
            }
            if time - previous < 0.15 { return nil }
        }
        taps.append(time)
        taps = Array(taps.suffix(7))
        guard taps.count >= 2 else { return nil }
        let intervals = zip(taps.dropFirst(), taps).map { $0.0 - $0.1 }.filter { (0.2...3).contains($0) }
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let consistent = intervals.filter { abs($0 - median) <= median * 0.2 }
        return min(300, max(20, Int((60 / (consistent.reduce(0, +) / Double(consistent.count))).rounded())))
    }
}

public enum TunerMode: String, Codable, CaseIterable, Sendable {
    case chromatic = "Chromatic"
    case guitar = "Guitar strings"
}
public struct TunerSettings: Codable, Equatable, Sendable {
    public var referenceA4 = 440.0
    public var mode = TunerMode.guitar
    public var includeCapo = false
    public init() {}
    public func validated() throws -> Self {
        guard referenceA4.isFinite, (430...450).contains(referenceA4) else {
            throw MusicError.invalid("Choose an A4 reference from 430–450 Hz.")
        }
        return self
    }
}
public struct TunerReading: Equatable, Sendable {
    public var frequency: Double
    public var heardMidi: Int
    public var targetMidi: Int
    public var cents: Double
    public var isInTune: Bool { abs(cents) <= 5 }
    public var targetFrequency: Double { frequency / pow(2, cents / 1200) }
    public static func frequency(midi: Int, referenceA4: Double = 440) -> Double {
        referenceA4 * pow(2, Double(midi - 69) / 12)
    }
    public init?(frequency: Double, confidence: Double, referenceA4: Double = 440, target: Int? = nil) {
        guard frequency.isFinite, (25...4500).contains(frequency), confidence.isFinite, (0.82...1).contains(confidence),
            referenceA4.isFinite, (430...450).contains(referenceA4)
        else { return nil }
        let midi = 69 + 12 * log2(frequency / referenceA4)
        heardMidi = Int(midi.rounded())
        targetMidi = target ?? heardMidi
        guard (0...127).contains(targetMidi) else { return nil }
        self.frequency = frequency
        cents = (midi - Double(targetMidi)) * 100
    }
    public static func closestTarget(frequency: Double, targets: [Int], referenceA4: Double) -> Int? {
        guard frequency.isFinite, frequency > 0, referenceA4.isFinite, referenceA4 > 0 else { return nil }
        let midi = 69 + 12 * log2(frequency / referenceA4)
        return targets.min { abs(Double($0) - midi) < abs(Double($1) - midi) }
    }
}
public struct TunerSmoother: Sendable {
    private var history: [Double] = []
    private var previous: TunerReading?
    private var reference = 440.0
    public init() {}
    public mutating func reset() {
        history = []
        previous = nil
    }
    public mutating func update(_ pitch: DetectedPitch?, referenceA4: Double, target: Int?) -> TunerReading? {
        guard let pitch,
            let raw = TunerReading(
                frequency: pitch.frequency, confidence: pitch.confidence, referenceA4: referenceA4, target: target)
        else {
            reset()
            return nil
        }
        if raw.targetMidi != previous?.targetMidi || reference != referenceA4
            || abs(raw.cents - (previous?.cents ?? raw.cents)) > 80
        {
            history = []
        }
        reference = referenceA4
        history.append(raw.frequency)
        history = Array(history.suffix(5))
        let sorted = history.sorted()
        let reading = TunerReading(
            frequency: sorted[sorted.count / 2], confidence: pitch.confidence, referenceA4: referenceA4, target: target)
        previous = reading
        return reading
    }
}
