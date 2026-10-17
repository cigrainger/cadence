// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct DetectedPitch: Sendable {
    public var frequency: Double
    public var confidence: Double
    public init(frequency: Double, confidence: Double) {
        self.frequency = frequency
        self.confidence = confidence
    }
    public var midiFloat: Double { 69 + 12 * log2(frequency / 440) }
    public var midi: Int { Int(midiFloat.rounded()) }
    public var cents: Double { (midiFloat - midiFloat.rounded()) * 100 }
}

public enum PitchDetector {
    /// YIN cumulative mean normalised difference, for one clean note at a time.
    public static func detect(_ samples: [Float], sampleRate: Double, frequencyRange: ClosedRange<Double> = 65...1300)
        -> DetectedPitch?
    {
        guard samples.count >= 512, sampleRate.isFinite, sampleRate > 0, sampleRate <= 384000,
            frequencyRange.lowerBound.isFinite, frequencyRange.upperBound.isFinite, frequencyRange.lowerBound >= 10,
            frequencyRange.upperBound <= 20000, frequencyRange.upperBound >= frequencyRange.lowerBound
        else { return nil }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms > 0.006 else { return nil }
        let maximum = min(samples.count / 2 - 1, Int(sampleRate / frequencyRange.lowerBound))
        let minimum = max(2, Int(sampleRate / frequencyRange.upperBound))
        guard maximum > minimum else { return nil }
        let window = samples.count - maximum
        var difference = [Double](repeating: 0, count: maximum + 1)
        for lag in 1...maximum {
            var sum = 0.0
            for i in 0..<window {
                let delta = Double(samples[i] - samples[i + lag])
                sum += delta * delta
            }
            difference[lag] = sum
        }
        var cumulative = 0.0
        for lag in 1...maximum {
            cumulative += difference[lag]
            difference[lag] = cumulative > 0 ? difference[lag] * Double(lag) / cumulative : 1
        }
        var lag = minimum
        while lag < maximum {
            if difference[lag] < 0.16 {
                while lag + 1 < maximum && difference[lag + 1] < difference[lag] { lag += 1 }
                let a = difference[lag - 1]
                let b = difference[lag]
                let c = difference[min(lag + 1, maximum)]
                let denominator = 2 * (2 * b - c - a)
                let adjusted = Double(lag) + (abs(denominator) > 1e-12 ? (c - a) / denominator : 0)
                return DetectedPitch(frequency: sampleRate / adjusted, confidence: max(0, 1 - b))
            }
            lag += 1
        }
        return nil
    }
}
