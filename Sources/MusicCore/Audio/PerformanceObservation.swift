// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A window observation, not an onset or a quantized MIDI note. Device clocks
/// survive queueing; callback delivery time never becomes a measured attack.
public struct PerformanceObservation: Codable, Equatable, Sendable {
    public var sampleTime: Int64?
    public var hostSeconds: Double?
    public var sampleRate: Double
    public var frameCount: Int
    public var rms: Double
    public var clippedFraction: Double
    public var frequency: Double?
    public var confidence: Double
    public var detector = "yin-window-v1"
    public init(
        sampleTime: Int64?, hostSeconds: Double?, sampleRate: Double, frameCount: Int,
        rms: Double, clippedFraction: Double, frequency: Double?, confidence: Double
    ) {
        self.sampleTime = sampleTime
        self.hostSeconds = hostSeconds
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.rms = rms
        self.clippedFraction = clippedFraction
        self.frequency = frequency
        self.confidence = confidence
    }
    public var valid: Bool {
        sampleRate.isFinite && (8000...384000).contains(sampleRate) && (1...65536).contains(frameCount)
            && rms.isFinite && (0...4).contains(rms) && clippedFraction.isFinite && (0...1).contains(clippedFraction)
            && (frequency.map { $0.isFinite && (10...20000).contains($0) } ?? true)
            && confidence.isFinite && (0...1).contains(confidence) && (hostSeconds?.isFinite ?? true)
            && detector == "yin-window-v1"
    }
    public var usable: Bool {
        valid && confidence.isFinite && (0.85...1).contains(confidence) && frequency != nil && rms >= 0.006
            && clippedFraction < 0.01 && (sampleTime != nil || hostSeconds != nil)
    }
}
public struct MonophonicTake: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var target: Int
    public var frames: [PerformanceObservation]
    public var date: Date
    public init(target: Int, frames: [PerformanceObservation], date: Date = Date()) {
        self.target = target
        self.frames = frames
        self.date = date
    }
    public var valid: Bool {
        (21...108).contains(target) && (1...300).contains(frames.count) && frames.allSatisfy(\.valid)
            && frames.allSatisfy {
                $0.confidence.isFinite && (0...1).contains($0.confidence) && $0.detector == "yin-window-v1"
                    && ($0.hostSeconds?.isFinite ?? true)
            }
            && date.timeIntervalSince1970.isFinite
    }
    public var usable: [PerformanceObservation] { frames.filter(\.usable) }
    public var orderedClock: Bool {
        guard frames.count > 1 else { return false }
        return zip(frames, frames.dropFirst()).allSatisfy { first, next in
            if let a = first.sampleTime, let b = next.sampleTime, first.sampleRate == next.sampleRate { return b > a }
            if let a = first.hostSeconds, let b = next.hostSeconds { return b > a }
            return false
        }
    }
    public var medianCents: Double? {
        guard valid, orderedClock, usable.count >= 4, usable.count * 2 >= frames.count else { return nil }
        let offsets = usable.compactMap(\.frequency).map { 1200 * log2($0 / (440 * pow(2, Double(target - 69) / 12))) }
            .sorted()
        let middle = offsets.count / 2
        return offsets.count.isMultiple(of: 2) ? (offsets[middle - 1] + offsets[middle]) / 2 : offsets[middle]
    }
    public var summary: String {
        guard valid else { return "Inconclusive: invalid observation data." }
        let pitch =
            medianCents.map { String(format: "Median pitch relative to the selected bass note: %+.0f cents.", $0) }
            ?? "Inconclusive: too few reliable, timestamped pitch windows. Try one clean sustained note in a quiet room."
        return
            "Local monophonic observation, YIN window v1. \(usable.count)/\(frames.count) usable windows. \(pitch) No onset alignment or microphone latency calibration; timing, finger identity, picking direction and polyphony were not assessed. RMS is signal level, not MIDI velocity. Confidence is a detector heuristic."
    }
}
