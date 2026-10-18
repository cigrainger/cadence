// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A monophonic attack candidate, including candidates for which pitch is inconclusive.
/// RMS is normalized signal level, not velocity; confidence is a heuristic, not a probability.
public struct AcousticAttack: Codable, Equatable, Sendable {
    public static let detectorVersion = "envelope-yin-attack-v1"
    public var id: UUID
    /// Original input sample clock in seconds, never analysis/queue delivery time.
    public var hostSeconds: Double
    /// Original onset sample position, populated by the parent from its validated
    /// sample/host mapping. The analyzer cannot infer the device's sample origin.
    public var sampleTime: Int64?
    public var sampleRate: Double?
    /// Sounding Hz; nil when there is insufficient stable monophonic evidence.
    public var frequency: Double?
    public var confidence: Double
    public var rms: Double
    public var clippedFraction: Double
    /// Envelope resolution plus conservative quality allowances, not a timing accuracy guarantee.
    public var onsetUncertaintyMS: Double
    public var detector: String

    public init(
        id: UUID = UUID(), hostSeconds: Double, frequency: Double?, confidence: Double, rms: Double,
        clippedFraction: Double, onsetUncertaintyMS: Double, detector: String = AcousticAttack.detectorVersion,
        sampleTime: Int64? = nil, sampleRate: Double? = nil
    ) {
        self.id = id
        self.hostSeconds = hostSeconds
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.frequency = frequency
        self.confidence = confidence
        self.rms = rms
        self.clippedFraction = clippedFraction
        self.onsetUncertaintyMS = onsetUncertaintyMS
        self.detector = detector
    }

    public var valid: Bool {
        hostSeconds.isFinite && hostSeconds >= 0
            // Keep sample positions exactly representable when mapped through Double.
            && (sampleTime.map { (0...9_007_199_254_740_991).contains($0) } ?? true)
            && (sampleRate.map { $0.isFinite && (8000...192000).contains($0) } ?? true)
            && (frequency.map { $0.isFinite && (80...1400).contains($0) } ?? true)
            && confidence.isFinite && (0...1).contains(confidence)
            && rms.isFinite && (0...1).contains(rms)
            && clippedFraction.isFinite && (0...1).contains(clippedFraction)
            && onsetUncertaintyMS.isFinite && (0.001...1000).contains(onsetUncertaintyMS)
            && detector == Self.detectorVersion
    }

    public var midi: Int? {
        guard valid, let frequency else { return nil }
        return Int((69 + 12 * log2(frequency / 440)).rounded())
    }

    public var cents: Double? {
        guard let midi, let frequency else { return nil }
        return (69 + 12 * log2(frequency / 440) - Double(midi)) * 100
    }
}

/// Pure streaming analysis for normalized mono PCM. Run on the parent's analysis queue,
/// never the realtime callback: two bounded YIN windows are evaluated per candidate.
///
/// Frames are anchored to sample indices, independent of append boundaries. A 5 ms RMS
/// envelope detects quiet-to-signal transitions and renewed energy above a decaying tail.
/// At least 20 ms of quiet/background is required after initialization or a reset. Soft
/// attacks, reverberation, tremolo, accompaniment and automatic gain can confuse this
/// amplitude-only onset detector; an 80 ms refractory period also merges faster attacks.
/// Pitch needs two agreeing sustain windows after the transient (about 80 ms delivery
/// delay). That delay never moves the onset. This is neither polyphonic analysis nor a
/// promise of 15 ms grading precision; device latency requires separate calibration.
public struct AcousticAnalyzer: Sendable {
    public static let maximumBlockSamples = 65_536
    private var rate = 0.0
    private var origin = 0.0
    private var sampleCount = 0
    private var frameSize = 0
    private var frame: [Float] = []
    private var noise = 0.0005
    private var envelope = 0.0
    private var previousRMS = 0.0
    private var quietSamples = 0
    private var hasQuiet = false
    private var armed = false
    private var lastAttack = -Double.infinity
    private var pending: Candidate?

    private struct Candidate: Sendable {
        var onset: Double
        var uncertainty: Double
        var noise: Double
        var samples: [Float]
    }

    public init() {}

    /// `hostSeconds` identifies the FIRST sample, in a known continuous input host clock.
    /// Empty blocks are no-ops. Invalid PCM/rates/clocks or blocks over 65,536 samples
    /// discard pending evidence and reset. Gaps, overlap and rate changes start a fresh
    /// segment requiring quiet again; no onset/pitch is joined across that boundary.
    public mutating func append(samples: [Float], sampleRate: Double, hostSeconds: Double) -> [AcousticAttack] {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), hostSeconds.isFinite,
            hostSeconds >= 0, hostSeconds.ulp <= 1 / sampleRate,
            samples.count <= Self.maximumBlockSamples,
            samples.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else {
            self = Self()
            return []
        }
        guard !samples.isEmpty else { return [] }
        if rate != 0 {
            let expected = origin + Double(sampleCount) / rate
            if rate != sampleRate || abs(hostSeconds - expected) > max(0.5 / rate, expected.ulp * 2) {
                self = Self()
            }
        }
        if rate == 0 {
            rate = sampleRate
            origin = hostSeconds
            frameSize = Int((sampleRate * 0.005).rounded())
        }
        guard sampleCount <= Int.max - samples.count else {
            self = Self()
            return []
        }
        var result: [AcousticAttack] = []
        for sample in samples {
            frame.append(sample)
            sampleCount += 1
            if frame.count == frameSize {
                result += consumeFrame()
                frame.removeAll(keepingCapacity: true)
            }
        }
        return result
    }

    /// Flushes the last partial frame and retains unfinished attacks; insufficient
    /// sustain has nil pitch.
    /// Idempotent; the next append starts a new segment.
    public mutating func finish() -> [AcousticAttack] {
        var result: [AcousticAttack] = []
        if !frame.isEmpty { result += consumeFrame() }
        if let pending { result.append(complete(pending)) }
        self = Self()
        return result
    }

    private mutating func consumeFrame() -> [AcousticAttack] {
        let level = sqrt(frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.count))
        let start = origin + Double(sampleCount - frame.count) / rate
        let quiet = level < max(0.0015, noise * 2.5)
        if quiet {
            quietSamples = min(quietSamples + frame.count, Int(rate * 0.030))
            if Double(quietSamples) / rate >= 0.020 {
                hasQuiet = true
                armed = true
            }
        } else {
            quietSamples = 0
        }
        // Learn background only below the active-signal threshold. During startup,
        // modest stationary room noise may establish a floor; loud initial audio abstains.
        if quiet || (!hasQuiet && level < 0.03) {
            noise = max(0.0001, noise * 0.9 + level * 0.1)
        }
        let rise = level > envelope * 1.8 && level > previousRMS * 1.2
        let attack =
            hasQuiet && level >= max(0.004, noise * 4)
            && (armed || rise) && start - lastAttack >= 0.080 - 0.5 / rate
        var result: [AcousticAttack] = []
        if attack {
            if let pending { result.append(complete(pending)) }
            pending = Candidate(
                onset: start, uncertainty: Double(frameSize) / rate * 1000,
                noise: noise, samples: [])
            armed = false
            lastAttack = start
        }
        if pending != nil {
            pending?.samples.append(contentsOf: frame)
            if let candidate = pending, Double(candidate.samples.count) / rate >= 0.080 {
                result.append(complete(candidate))
                pending = nil
            }
        }
        envelope = envelope * 0.75 + level * 0.25
        previousRMS = level
        return result
    }

    private func complete(_ candidate: Candidate) -> AcousticAttack {
        let samples = candidate.samples
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        let clipped = Double(samples.filter { abs($0) >= 0.999 }.count) / Double(samples.count)
        var frequency: Double?
        var confidence = 0.0
        if Double(samples.count) / rate >= 0.075, clipped < 0.01, rms >= max(0.006, candidate.noise * 5) {
            // Box averaging limits work at high input rates. This modest low-pass is
            // intended for clean monophonic input, not general-purpose resampling.
            let stride = max(1, Int(rate / 16000))
            let reducedRate = rate / Double(stride)
            var reduced: [Double] = []
            for start in Swift.stride(from: 0, through: samples.count - stride, by: stride) {
                var sum = 0.0
                for i in start..<(start + stride) { sum += Double(samples[i]) }
                reduced.append(sum / Double(stride))
            }
            let length = Int(reducedRate * 0.040)
            let first = Int(reducedRate * 0.012)
            let second = Int(reducedRate * 0.032)
            if second + length <= reduced.count,
                let a = Self.yin(Array(reduced[first..<(first + length)]), rate: reducedRate),
                let b = Self.yin(Array(reduced[second..<(second + length)]), rate: reducedRate),
                abs(1200 * log2(a.frequency / b.frequency)) <= 35
            {
                // Reject strongly out-of-band input before downsampling can turn it
                // into an apparently in-range subharmonic/alias.
                let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
                let crossings = zip(samples, samples.dropFirst()).filter {
                    (Double($0) >= mean) != (Double($1) >= mean)
                }.count
                if Double(crossings) / (Double(samples.count) / rate) <= 3600 {
                    frequency = sqrt(a.frequency * b.frequency)
                    confidence = min(a.confidence, b.confidence)
                }
            }
        }
        let uncertain = frequency == nil || clipped >= 0.01 || rms < candidate.noise * 5
        return AcousticAttack(
            hostSeconds: candidate.onset, frequency: frequency, confidence: confidence, rms: rms,
            clippedFraction: clipped,
            onsetUncertaintyMS: max(candidate.uncertainty, uncertain ? 20 : 5))
    }

    private static func yin(_ input: [Double], rate: Double) -> (frequency: Double, confidence: Double)? {
        let mean = input.reduce(0, +) / Double(input.count)
        let samples = input.map { $0 - mean }
        guard sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)) >= 0.004 else { return nil }
        let maximum = min(input.count / 2 - 1, Int(rate / 75))
        let window = input.count - maximum
        var difference = [Double](repeating: 1, count: maximum + 1)
        var rawDifference = [Double](repeating: 0, count: maximum + 1)
        var cumulative = 0.0
        for lag in 1...maximum {
            var sum = 0.0
            for i in 0..<window {
                let delta = samples[i] - samples[i + lag]
                sum += delta * delta
            }
            rawDifference[lag] = sum
            cumulative += sum
            difference[lag] = cumulative > 1e-15 ? sum * Double(lag) / cumulative : 1
        }
        // Search from lag 2, including pitches above the supported range, so the
        // first high-frequency minimum is rejected rather than relabeled an octave down.
        var lag = 2
        while lag < maximum {
            if difference[lag] < 0.12 {
                while lag + 1 < maximum && difference[lag + 1] < difference[lag] { lag += 1 }
                // Refine the raw difference minimum: CMND normalization biases
                // parabolic interpolation when high notes have only a few samples/cycle.
                let a = rawDifference[lag - 1]
                let b = rawDifference[lag]
                let c = rawDifference[min(lag + 1, maximum)]
                let denominator = 2 * (2 * b - a - c)
                let period = Double(lag) + (abs(denominator) > 1e-12 ? (c - a) / denominator : 0)
                let frequency = rate / period
                guard (80...1400).contains(frequency) else { return nil }
                return (frequency, max(0, min(1, 1 - difference[lag])))
            }
            lag += 1
        }
        return nil
    }
}

/// Measured acoustic loopback only: observed INPUT onsets minus SCHEDULED OUTPUT
/// timestamps from the same host-clock origin that the parent uses for phrase count-in.
/// Unknown/mixed clock origins must abstain before calling measure; numbers alone
/// cannot prove clock identity. The parent must qualify isolated loopback pulses
/// (for example by template), not human taps, room events or unqualified attack candidates.
public struct AcousticCalibration: Codable, Equatable, Sendable {
    public static let pulseOffsets: [Double] = [0.50, 1.03, 1.74, 2.35, 3.22, 3.68, 4.47, 5.41]
    public var routeID: String
    public var sampleRate: Double
    public var offsetMS: Double
    /// Robust spread with a 5 ms envelope-resolution floor; not total device uncertainty.
    public var jitterMS: Double
    public var date: Date
    public var matchedPulses: Int
    /// Parent-supplied provenance for actual loopback capture. Mapping allowance
    /// is separate from measured jitter; nil preserves legacy/synthetic records.
    public var clockEvidence: AcousticClockEvidence?

    public init(
        routeID: String, sampleRate: Double, offsetMS: Double, jitterMS: Double, date: Date, matchedPulses: Int,
        clockEvidence: AcousticClockEvidence? = nil
    ) {
        self.routeID = routeID
        self.sampleRate = sampleRate
        self.offsetMS = offsetMS
        self.jitterMS = jitterMS
        self.date = date
        self.matchedPulses = matchedPulses
        self.clockEvidence = clockEvidence
    }

    public var valid: Bool {
        !routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && routeID.utf8.count <= 256
            && sampleRate.isFinite && (8000...192000).contains(sampleRate)
            && offsetMS.isFinite && (0...500).contains(offsetMS)
            && jitterMS.isFinite && (0...500).contains(jitterMS)
            && date.timeIntervalSince1970.isFinite && (6...8).contains(matchedPulses)
            && (clockEvidence.map { $0.valid && $0.sampleRate == sampleRate } ?? true)
    }

    /// Conservatively expires after 24 hours. Route identity must include changes to
    /// relevant processing/buffering; a matching device name alone is insufficient.
    public func usable(routeID: String, sampleRate: Double, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return valid && self.routeID == routeID && self.sampleRate == sampleRate && jitterMS <= 10
            && age.isFinite && (0...86400).contains(age)
            && (clockEvidence?.usable ?? true)
    }

    public enum MeasurementError: Error, LocalizedError, Equatable, Sendable {
        case invalidInput
        case ambiguousSchedule
        case insufficientMatches
        case ambiguousMatches
        case excessiveJitter
        public var errorDescription: String? {
            switch self {
            case .invalidInput:
                "The microphone timing reference could not be validated. Check the current audio route and try again."
            case .ambiguousSchedule:
                "The loopback pulse schedule was ambiguous. Start a new timing check."
            case .insufficientMatches:
                "Too few loopback tones came through clearly. Let the current microphone hear the speakers in a quiet room, or choose pitch-only practice."
            case .ambiguousMatches:
                "Other sounds made the loopback tones ambiguous. Stay silent, turn off monitoring and try the timing check again."
            case .excessiveJitter:
                "Loopback timing varied too much for a reliable comparison. Try a quieter room or a stable wired audio route."
            }
        }
    }

    /// Exactly eight strictly increasing, separated expected onsets, and 6...64
    /// strictly increasing qualified observations. Missing pulses/outliers are allowed.
    /// Periodic schedules are rejected: a whole-beat delay could otherwise alias a
    /// plausible offset even with apparently excellent residuals.
    public static func measure(
        expected: [Double], observed: [Double], routeID: String, sampleRate: Double, now: Date
    ) throws -> Self {
        let prototype = Self(
            routeID: routeID, sampleRate: sampleRate, offsetMS: 0, jitterMS: 5, date: now, matchedPulses: 8)
        guard prototype.valid, expected.count == 8, (6...64).contains(observed.count),
            (expected + observed).allSatisfy({ $0.isFinite && $0 >= 0 && $0.ulp <= 0.0001 }),
            zip(expected, expected.dropFirst()).allSatisfy({ $1 - $0 >= 0.30 }),
            expected[7] - expected[0] <= 6,
            zip(observed, observed.dropFirst()).allSatisfy({ $1 - $0 >= 0.001 })
        else { throw MeasurementError.invalidInput }
        var separations: [Double] = []
        for first in 0..<7 {
            for second in (first + 1)..<8 { separations.append(expected[second] - expected[first]) }
        }
        // Reject even partially periodic schedules when translating them could
        // align six pulses. Otherwise a true delay beyond 500 ms could masquerade
        // as a small offset with missing leading/trailing beats.
        guard
            !separations.contains(where: { shift in
                separations.filter { abs($0 - shift) <= 0.040 }.count >= 6
            })
        else {
            throw MeasurementError.ambiguousSchedule
        }

        struct Fit {
            var offset: Double
            var jitter: Double
            var count: Int
        }
        var fits: [Fit] = []
        // At most 512 hypotheses. Each matching pass is bounded (8 x 64), with
        // unique observations per pulse; close competing observations are abstentions.
        for pulse in expected {
            for onset in observed {
                let hypothesis = onset - pulse
                guard (0...0.5).contains(hypothesis) else { continue }
                var offsets: [Double] = []
                for scheduled in expected {
                    let matches = observed.filter { abs($0 - scheduled - hypothesis) <= 0.020 }
                    if matches.count == 1 { offsets.append(matches[0] - scheduled) }
                }
                guard offsets.count >= 6 else { continue }
                let center = median(offsets)
                let mad = median(offsets.map { abs($0 - center) }) * 1.4826
                let radius = min(0.020, max(0.003, mad * 3))
                let inliers = offsets.filter { abs($0 - center) <= radius }
                guard inliers.count >= 6 else { continue }
                let offset = median(inliers)
                guard (0...0.5).contains(offset) else { continue }
                let robustSpread = median(inliers.map { abs($0 - offset) }) * 1.4826
                let rms = sqrt(inliers.reduce(0) { $0 + pow($1 - offset, 2) } / Double(inliers.count))
                fits.append(Fit(offset: offset, jitter: max(0.005, robustSpread, rms), count: inliers.count))
            }
        }
        guard
            let best = fits.sorted(by: {
                $0.count == $1.count ? $0.jitter < $1.jitter : $0.count > $1.count
            }).first
        else { throw MeasurementError.insufficientMatches }
        guard best.jitter <= 0.010 else { throw MeasurementError.excessiveJitter }
        guard !fits.contains(where: { $0.jitter <= 0.010 && abs($0.offset - best.offset) > 0.020 }) else {
            throw MeasurementError.ambiguousMatches
        }
        return Self(
            routeID: routeID, sampleRate: sampleRate, offsetMS: best.offset * 1000,
            jitterMS: best.jitter * 1000, date: now, matchedPulses: best.count)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
