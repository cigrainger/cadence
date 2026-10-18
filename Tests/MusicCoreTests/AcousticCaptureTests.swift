// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

final class AcousticCaptureTests: XCTestCase {
    private let clock = 1234.5
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func tone(
        rate: Double = 48000, duration: Double = 0.30, onsets: [Double] = [0.083],
        frequency: Double = 220, amplitude: Double = 0.25, decay: Double? = nil
    ) -> [Float] {
        (0..<Int(rate * duration)).map { index in
            let time = Double(index) / rate
            let envelope = onsets.reduce(0.0) { sum, onset in
                guard time >= onset else { return sum }
                return sum + amplitude * (decay.map { exp(-(time - onset) / $0) } ?? 1)
            }
            return Float(envelope * sin(2 * .pi * frequency * time))
        }
    }

    private func analyze(_ samples: [Float], rate: Double = 48000, chunks: [Int] = [1024]) -> [AcousticAttack] {
        var analyzer = AcousticAnalyzer()
        var result: [AcousticAttack] = []
        var index = 0
        var block = 0
        while index < samples.count {
            let end = min(samples.count, index + chunks[block % chunks.count])
            result += analyzer.append(
                samples: Array(samples[index..<end]), sampleRate: rate, hostSeconds: clock + Double(index) / rate)
            index = end
            block += 1
        }
        result += analyzer.finish()
        return result
    }

    private func noise(count: Int, amplitude: Double) -> [Float] {
        var state: UInt64 = 0xCAD_EACE
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float((Double(state >> 32) / Double(UInt32.max) * 2 - 1) * amplitude)
        }
    }

    private func measure(_ observed: [Double], expected: [Double]? = nil) throws -> AcousticCalibration {
        try AcousticCalibration.measure(
            expected: expected ?? AcousticCalibration.pulseOffsets.map { clock + $0 }, observed: observed,
            routeID: "input:output:processing-v1", sampleRate: 48000, now: date)
    }

    func testAttackValueValidationAndRoundTrip() throws {
        let attack = AcousticAttack(
            hostSeconds: clock, frequency: 440 * pow(2, 23.0 / 1200), confidence: 0.98,
            rms: 0.12, clippedFraction: 0, onsetUncertaintyMS: 5)
        XCTAssertTrue(attack.valid)
        XCTAssertEqual(attack.midi, 69)
        XCTAssertEqual(try XCTUnwrap(attack.cents), 23, accuracy: 0.0001)
        XCTAssertEqual(try JSONDecoder().decode(AcousticAttack.self, from: JSONEncoder().encode(attack)), attack)
        var uncertain = attack
        uncertain.frequency = nil
        uncertain.confidence = 0
        XCTAssertTrue(uncertain.valid)
        XCTAssertNil(uncertain.midi)
        XCTAssertNil(uncertain.cents)
        for value in [Double.nan, .infinity, -1, 0, 1e300] {
            var bad = attack
            bad.frequency = value
            XCTAssertFalse(bad.valid)
            XCTAssertNil(bad.midi)
        }
        var bad = attack
        bad.detector = "unknown"
        XCTAssertFalse(bad.valid)
        bad = attack
        bad.onsetUncertaintyMS = .nan
        XCTAssertFalse(bad.valid)
        bad = attack
        bad.clippedFraction = 1.1
        XCTAssertFalse(bad.valid)
        bad = attack
        bad.hostSeconds = -1
        XCTAssertFalse(bad.valid)
    }

    func testSampleClockAndAllMeasurementsAreIndependentOfChunkBoundaries() throws {
        let long = tone(duration: 0.8, onsets: [0.083, 0.277, 0.491], decay: 0.065)
        let reference = analyze(long, chunks: [65536])
        for chunks in [[1], [17, 509, 3, 2048], [239, 1, 240, 241], [4096]] {
            let actual = analyze(long, chunks: chunks)
            XCTAssertEqual(actual.count, reference.count)
            for (a, b) in zip(actual, reference) {
                var normalized = a
                normalized.id = b.id
                XCTAssertEqual(normalized, b)
            }
        }
        XCTAssertEqual(reference.count, 3)
    }

    func testOptionalSampleClockMetadataValidationAndLegacyDecoding() throws {
        let attack = AcousticAttack(
            hostSeconds: clock, frequency: 220, confidence: 0.98, rms: 0.12, clippedFraction: 0,
            onsetUncertaintyMS: 10, sampleTime: 48_000_000, sampleRate: 48000)
        XCTAssertTrue(attack.valid)
        XCTAssertEqual(attack.sampleTime, 48_000_000)
        XCTAssertEqual(attack.sampleRate, 48000)
        let data = try JSONEncoder().encode(attack)
        XCTAssertEqual(try JSONDecoder().decode(AcousticAttack.self, from: data), attack)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "sampleTime")
        legacy.removeValue(forKey: "sampleRate")
        let decoded = try JSONDecoder().decode(
            AcousticAttack.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.valid)
        XCTAssertNil(decoded.sampleTime)
        XCTAssertNil(decoded.sampleRate)

        for sampleTime: Int64 in [0, 9_007_199_254_740_991] {
            var boundary = attack
            boundary.sampleTime = sampleTime
            XCTAssertTrue(boundary.valid)
        }
        for sampleTime: Int64 in [-1, 9_007_199_254_740_992, .max] {
            var bad = attack
            bad.sampleTime = sampleTime
            XCTAssertFalse(bad.valid)
        }
        for rate in [8000.0, 192000] {
            var boundary = attack
            boundary.sampleRate = rate
            XCTAssertTrue(boundary.valid)
        }
        for rate in [Double.nan, .infinity, -1, 7999, 192001] {
            var bad = attack
            bad.sampleRate = rate
            XCTAssertFalse(bad.valid)
        }
        let analyzed = try XCTUnwrap(analyze(tone()).first)
        XCTAssertNil(analyzed.sampleTime)
        XCTAssertNil(analyzed.sampleRate)
    }

    func testCleanOnsetsAreWithinTenMillisecondsAcrossFramePhasesAndRates() throws {
        // These adversarial offsets include exact boundaries and near-boundary first samples.
        for rate in [8000.0, 44100, 48000, 96000, 192000] {
            for onset in [0.080, 0.08498, 0.08731] {
                let attacks = analyze(tone(rate: rate, onsets: [onset]), rate: rate, chunks: [113, 2048, 1])
                XCTAssertEqual(attacks.count, 1, "rate \(rate), onset \(onset)")
                let attack = try XCTUnwrap(attacks.first)
                let errorMS = abs(attack.hostSeconds - clock - onset) * 1000
                XCTAssertLessThanOrEqual(errorMS, 10)
                XCTAssertLessThanOrEqual(errorMS, attack.onsetUncertaintyMS + 1000 / rate)
                XCTAssertGreaterThanOrEqual(attack.onsetUncertaintyMS, 5)
                XCTAssertTrue(attack.valid)
            }
        }
    }

    func testYINDeliveryDelayDoesNotBecomeOnsetAndFinishIsIdempotent() throws {
        let samples = tone(duration: 0.20)
        var analyzer = AcousticAnalyzer()
        let split = 5760  // 120 ms: attack has only 37 ms of sustain so far.
        XCTAssertTrue(analyzer.append(samples: Array(samples[..<split]), sampleRate: 48000, hostSeconds: clock).isEmpty)
        let result = analyzer.append(
            samples: Array(samples[split...]), sampleRate: 48000, hostSeconds: clock + Double(split) / 48000)
        let attack = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(attack.hostSeconds, clock + 0.083, accuracy: 0.010)
        XCTAssertEqual(try XCTUnwrap(attack.frequency), 220, accuracy: 1)
        XCTAssertTrue(analyzer.finish().isEmpty)
        XCTAssertTrue(analyzer.finish().isEmpty)
    }

    func testRepeatedSamePitchPlucksAreDetectedOverSustainedTails() throws {
        let onsets = [0.083, 0.281, 0.487, 0.699]
        let attacks = analyze(tone(duration: 1.1, onsets: onsets, decay: 0.075), chunks: [127, 4096])
        XCTAssertEqual(attacks.count, onsets.count)
        for (attack, onset) in zip(attacks, onsets) {
            XCTAssertEqual(attack.hostSeconds, clock + onset, accuracy: 0.010)
            XCTAssertEqual(attack.midi, 57)
        }
    }

    func testCalibrationPulseTrainWithThreeMillisecondFadesIsQualifiedAndMeasured() throws {
        let offsets = AcousticCalibration.pulseOffsets
        let rate = 48000.0
        let latency = 0.137
        let samples: [Float] = (0..<Int(rate * 6)).map { index in
            let time = Double(index) / rate
            let envelope = offsets.reduce(0.0) { sum, onset in
                let elapsed = time - onset - latency
                guard (0..<0.1).contains(elapsed) else { return sum }
                return sum + 0.2 * min(1, elapsed / 0.003, (0.1 - elapsed) / 0.003)
            }
            return Float(envelope * sin(2 * .pi * 1000 * time))
        }
        let attacks = analyze(samples, chunks: [113, 4096, 1])
        XCTAssertEqual(attacks.count, 8)
        for (attack, onset) in zip(attacks, offsets) {
            XCTAssertEqual(try XCTUnwrap(attack.frequency), 1000, accuracy: 5)
            XCTAssertGreaterThanOrEqual(attack.confidence, 0.90)
            XCTAssertLessThan(attack.clippedFraction, 0.01)
            XCTAssertLessThanOrEqual(attack.onsetUncertaintyMS, 10)
            XCTAssertEqual(attack.hostSeconds, clock + onset + latency, accuracy: 0.010)
        }
        let calibration = try measure(attacks.map(\.hostSeconds))
        XCTAssertEqual(calibration.offsetMS, latency * 1000, accuracy: 10)
        XCTAssertEqual(calibration.matchedPulses, 8)
    }

    func testBriefClicksAreRetainedWithoutPitchAndRefractoryMergesFastFlams() throws {
        var samples = Array(repeating: Float(0), count: 14400)
        for onset in [0.083, 0.113] {
            for index in Int(onset * 48000)..<Int((onset + 0.002) * 48000) { samples[index] = 0.2 }
        }
        let attacks = analyze(samples)
        XCTAssertEqual(attacks.count, 1)
        let attack = try XCTUnwrap(attacks.first)
        XCTAssertEqual(attack.hostSeconds, clock + 0.083, accuracy: 0.010)
        XCTAssertNil(attack.frequency)
        XCTAssertLessThan(attack.confidence, 0.85)
    }

    func testSustainedLowPitchDoesNotProducePeriodicFalseAttacks() throws {
        let attacks = analyze(tone(duration: 1.5, frequency: 82.4069), chunks: [509])
        XCTAssertEqual(attacks.count, 1)
        XCTAssertEqual(try XCTUnwrap(attacks.first?.frequency), 82.4069, accuracy: 0.5)
    }

    func testHarmonicGuitarPlucksWithBriefNoisyTransientsKeepFundamental() throws {
        let rate = 48000.0
        let onsets = [0.083, 0.317, 0.593]
        let transient = noise(count: 240, amplitude: 0.06)
        for frequency in [82.4069, 196, 329.6276] {
            let samples: [Float] = (0..<48000).map { index in
                let time = Double(index) / rate
                var value = 0.0
                for onset in onsets {
                    let elapsed = time - onset
                    guard elapsed >= 0 else { continue }
                    let phase = 2 * .pi * frequency * elapsed
                    let envelope = min(1, elapsed / 0.001) * exp(-elapsed / 0.10)
                    value += 0.2 * envelope * (sin(phase) + 0.4 * sin(phase * 2) + 0.15 * sin(phase * 3))
                    let transientIndex = Int(elapsed * rate)
                    if transientIndex < transient.count { value += Double(transient[transientIndex]) }
                }
                return Float(value)
            }
            let attacks = analyze(samples, chunks: [17, 509, 2048])
            XCTAssertEqual(attacks.count, onsets.count)
            for (attack, onset) in zip(attacks, onsets) {
                XCTAssertEqual(attack.hostSeconds, clock + onset, accuracy: 0.010)
                XCTAssertEqual(1200 * log2(try XCTUnwrap(attack.frequency) / frequency), 0, accuracy: 15)
                XCTAssertGreaterThanOrEqual(attack.confidence, 0.90)
            }
        }
    }

    func testCleanLowHighAndDetunedPitchesHaveStableEvidence() throws {
        for rate in [8000.0, 44100, 192000] {
            for frequency in [82.4069, 110, 329.6276, 1318.5102] {
                let attacks = analyze(tone(rate: rate, frequency: frequency), rate: rate)
                let attack = try XCTUnwrap(attacks.first)
                let measured = try XCTUnwrap(attack.frequency, "rate \(rate), frequency \(frequency)")
                XCTAssertEqual(1200 * log2(measured / frequency), 0, accuracy: 10, "rate \(rate), Hz \(frequency)")
                XCTAssertGreaterThan(attack.confidence, 0.85)
            }
        }
        let detuned = analyze(tone(frequency: 440 * pow(2, -28.0 / 1200)))
        XCTAssertEqual(try XCTUnwrap(detuned.first?.cents), -28, accuracy: 5)
    }

    func testSilenceAndStationaryQuietNoiseDoNotInventAttacks() {
        XCTAssertTrue(analyze(Array(repeating: 0, count: 48000)).isEmpty)
        XCTAssertTrue(analyze(noise(count: 48000, amplitude: 0.001)).isEmpty)
        XCTAssertTrue(analyze(noise(count: 48000, amplitude: 0.012)).isEmpty)
    }

    func testNoiseClippingDCPulseAndInsufficientSustainRetainUncertainCandidates() throws {
        let quiet = Array(repeating: Float(0), count: 4000)
        let noisy = quiet + noise(count: 8000, amplitude: 0.3)
        let clipped = tone(amplitude: 3).map { max(-1, min(1, $0)) }
        let dc = quiet + Array(repeating: Float(0.2), count: 8000)
        let short = tone(duration: 0.105)
        for samples in [noisy, clipped, dc, short] {
            let attacks = analyze(samples)
            XCTAssertEqual(attacks.count, 1)
            let attack = try XCTUnwrap(attacks.first)
            XCTAssertNil(attack.frequency)
            XCTAssertNil(attack.midi)
            XCTAssertLessThan(attack.confidence, 0.85)
            XCTAssertGreaterThanOrEqual(attack.onsetUncertaintyMS, 20)
            XCTAssertTrue(attack.valid)
        }
        XCTAssertGreaterThan(try XCTUnwrap(analyze(clipped).first).clippedFraction, 0.01)
    }

    func testOutOfRangePitchesDoNotGetReliableOctaveSubstitutes() throws {
        for frequency in [40.0, 2500, 3000, 15000] {
            let attack = try XCTUnwrap(analyze(tone(frequency: frequency)).first)
            XCTAssertNil(attack.frequency, "out-of-range \(frequency)")
            XCTAssertLessThan(attack.confidence, 0.85)
        }
        var alias = tone(rate: 192000, frequency: 17000, amplitude: 0.1)
        for index in alias.indices { alias[index] += 0.2 }
        // Supply genuine quiet before the DC-offset out-of-band signal.
        alias.replaceSubrange(0..<Int(192000 * 0.083), with: repeatElement(0, count: Int(192000 * 0.083)))
        XCTAssertNil(try XCTUnwrap(analyze(alias, rate: 192000).first).frequency)
    }

    func testInitialQuietIsRequiredButFirstCleanNoteAfterPreRollIsKept() throws {
        XCTAssertTrue(analyze(tone(onsets: [0])).isEmpty)
        XCTAssertEqual(analyze(tone(onsets: [0.025])).count, 1)
        var analyzer = AcousticAnalyzer()
        let samples = tone()
        _ = analyzer.append(samples: Array(samples[..<5760]), sampleRate: 48000, hostSeconds: clock)
        XCTAssertTrue(analyzer.append(samples: [], sampleRate: 48000, hostSeconds: clock + 0.12).isEmpty)
        let result = analyzer.append(samples: Array(samples[5760...]), sampleRate: 48000, hostSeconds: clock + 0.12)
        XCTAssertEqual(result.count, 1)
    }

    func testDiscontinuityOverlapAndRateChangesDiscardPendingEvidence() {
        for (rate, delta) in [(48000.0, 0.4), (48000, 0.10), (44100, 0.12)] {
            var analyzer = AcousticAnalyzer()
            let prefix = Array(tone()[..<5760])
            XCTAssertTrue(analyzer.append(samples: prefix, sampleRate: 48000, hostSeconds: clock).isEmpty)
            // Start with sound, not quiet: it cannot finish the old candidate or invent a new one.
            let sound = tone(rate: rate, duration: 0.16, onsets: [0])
            XCTAssertTrue(analyzer.append(samples: sound, sampleRate: rate, hostSeconds: clock + delta).isEmpty)
            XCTAssertTrue(analyzer.finish().isEmpty)
            XCTAssertEqual(analyze(tone()).count, 1)
        }
    }

    func testMalformedPCMClockRateAndBlockBoundsResetWithoutLeakingPendingAttack() {
        let cases: [([Float], Double, Double)] = [
            ([.nan], 48000, clock + 0.12), ([.infinity], 48000, clock + 0.12),
            ([1.001], 48000, clock + 0.12), ([0], .nan, clock + 0.12),
            ([0], 7999, clock + 0.12), ([0], 192001, clock + 0.12),
            ([0], 48000, .nan), ([0], 48000, -1), ([0], 48000, 1e200),
            (Array(repeating: 0, count: AcousticAnalyzer.maximumBlockSamples + 1), 48000, clock + 0.12),
        ]
        for (samples, rate, host) in cases {
            var analyzer = AcousticAnalyzer()
            _ = analyzer.append(samples: Array(tone()[..<5760]), sampleRate: 48000, hostSeconds: clock)
            XCTAssertTrue(analyzer.append(samples: samples, sampleRate: rate, hostSeconds: host).isEmpty)
            XCTAssertTrue(analyzer.finish().isEmpty)
            XCTAssertEqual(analyzer.append(samples: tone(), sampleRate: 48000, hostSeconds: clock + 2).count, 1)
        }
    }

    func testLongStreamAndCopiedAnalyzerKeepIndependentBoundedState() {
        var analyzer = AcousticAnalyzer()
        let quiet = Array(repeating: Float(0), count: 48000)
        for second in 0..<30 {
            XCTAssertTrue(
                analyzer.append(samples: quiet, sampleRate: 48000, hostSeconds: clock + Double(second)).isEmpty)
        }
        var copy = analyzer
        let signal = tone(onsets: [0.023])
        XCTAssertEqual(copy.append(samples: signal, sampleRate: 48000, hostSeconds: clock + 30).count, 1)
        XCTAssertTrue(analyzer.finish().isEmpty)
        XCTAssertTrue(copy.finish().isEmpty)
    }

    func testCalibrationUsesScheduledClockOffsetAndHonestResolutionFloor() throws {
        let expected = AcousticCalibration.pulseOffsets.map { clock + $0 }
        XCTAssertEqual(expected.count, 8)
        XCTAssertGreaterThanOrEqual(AcousticCalibration.pulseOffsets[0], 0.4)
        XCTAssertLessThanOrEqual(try XCTUnwrap(AcousticCalibration.pulseOffsets.last), 6)
        let jitter = [-0.002, 0.001, 0, 0.002, -0.001, 0, 0.001, -0.001]
        let observed = zip(expected, jitter).map { $0 + 0.137 + $1 }
        let calibration = try measure(observed)
        XCTAssertEqual(calibration.offsetMS, 137, accuracy: 0.01)
        XCTAssertEqual(calibration.jitterMS, 5)
        XCTAssertEqual(calibration.matchedPulses, 8)
        XCTAssertTrue(calibration.valid)
        XCTAssertTrue(calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date))
        XCTAssertEqual(
            try JSONDecoder().decode(AcousticCalibration.self, from: JSONEncoder().encode(calibration)), calibration)
    }

    func testCalibrationRejectsOutliersAndAllowsSixUniqueMissingPulseMatches() throws {
        let expected = AcousticCalibration.pulseOffsets.map { clock + $0 }
        var observed = expected.map { $0 + 0.101 }
        observed[2] += 0.087
        observed[6] -= 0.065
        let calibration = try measure(observed)
        XCTAssertEqual(calibration.offsetMS, 101, accuracy: 0.01)
        XCTAssertEqual(calibration.matchedPulses, 6)
        let missing = [0, 1, 3, 4, 6, 7].map { expected[$0] + 0.101 }
        XCTAssertEqual(try measure(missing).matchedPulses, 6)
        XCTAssertThrowsError(try measure(Array(missing.dropLast())))
    }

    func testCalibrationClockProvenanceGatesUsabilityWithoutChangingMeasuredJitter() throws {
        let observed = AcousticCalibration.pulseOffsets.map { clock + $0 + 0.137 }
        let measured = try measure(observed)
        XCTAssertNil(measured.clockEvidence)
        let evidence = AcousticClockEvidence(
            firstSampleTime: 48000, firstHostSeconds: clock, sampleRate: 48000, frameCount: 288000,
            maximumHostResidualMS: 5)
        var calibration = AcousticCalibration(
            routeID: measured.routeID, sampleRate: measured.sampleRate, offsetMS: measured.offsetMS,
            jitterMS: measured.jitterMS, date: measured.date, matchedPulses: measured.matchedPulses,
            clockEvidence: evidence)
        XCTAssertTrue(calibration.valid)
        XCTAssertTrue(calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date))
        XCTAssertEqual(calibration.jitterMS, measured.jitterMS)
        XCTAssertEqual(calibration.offsetMS, measured.offsetMS)
        XCTAssertEqual(
            try JSONDecoder().decode(AcousticCalibration.self, from: JSONEncoder().encode(calibration)), calibration)

        calibration.clockEvidence?.maximumHostResidualMS = 5.001
        XCTAssertTrue(calibration.valid)
        XCTAssertFalse(calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date))
        XCTAssertEqual(calibration.jitterMS, measured.jitterMS)
        calibration.clockEvidence = evidence
        calibration.clockEvidence?.frameCount = 0
        XCTAssertTrue(calibration.valid)
        XCTAssertFalse(calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date))
        calibration.clockEvidence = evidence
        calibration.clockEvidence?.sampleRate = 44100
        XCTAssertFalse(calibration.valid)
        XCTAssertFalse(calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date))
        calibration.clockEvidence = evidence
        calibration.clockEvidence?.version = "unknown"
        XCTAssertFalse(calibration.valid)
        calibration.clockEvidence = evidence
        calibration.clockEvidence?.maximumHostResidualMS = .nan
        XCTAssertFalse(calibration.valid)

        let data = try JSONEncoder().encode(measured)
        let legacy = try JSONDecoder().decode(AcousticCalibration.self, from: data)
        XCTAssertNil(legacy.clockEvidence)
        XCTAssertEqual(legacy, measured)
        XCTAssertTrue(legacy.usable(routeID: legacy.routeID, sampleRate: 48000, now: date))
    }

    func testCalibrationMADRejectsTwoNearbyBadPulsesWithoutPretendingTheyMatch() throws {
        let expected = AcousticCalibration.pulseOffsets.map { clock + $0 }
        var observed = expected.map { $0 + 0.150 }
        observed[1] += 0.016
        observed[5] -= 0.017
        let calibration = try measure(observed)
        XCTAssertEqual(calibration.matchedPulses, 6)
        XCTAssertEqual(calibration.offsetMS, 150, accuracy: 0.01)
    }

    func testCalibrationRejectsRegularBeatAliasAndCompetingLoopbackTrains() {
        let regular = (0..<8).map { clock + Double($0) * 0.5 }
        XCTAssertThrowsError(try measure(regular.map { $0 + 0.6 }, expected: regular)) { error in
            XCTAssertEqual(error as? AcousticCalibration.MeasurementError, .ambiguousSchedule)
        }
        let almostRegular = [0.0, 0.4, 0.8, 1.2, 1.6, 2.0, 2.4, 3.0].map { clock + $0 }
        XCTAssertThrowsError(try measure(almostRegular.map { $0 + 0.6 }, expected: almostRegular)) { error in
            XCTAssertEqual(error as? AcousticCalibration.MeasurementError, .ambiguousSchedule)
        }
        let expected = AcousticCalibration.pulseOffsets.map { clock + $0 }
        let competing = (expected.map { $0 + 0.080 } + expected.map { $0 + 0.170 }).sorted()
        XCTAssertThrowsError(try measure(competing)) { error in
            XCTAssertEqual(error as? AcousticCalibration.MeasurementError, .ambiguousMatches)
        }
        let doublets = (expected.map { $0 + 0.100 } + expected.map { $0 + 0.108 }).sorted()
        XCTAssertThrowsError(try measure(doublets))
    }

    func testCalibrationRefusesJitterNoMatchUnknownClockAndMalformedBounds() {
        let expected = AcousticCalibration.pulseOffsets.map { clock + $0 }
        let jitter = [-0.015, 0.015, -0.015, 0.015, -0.015, 0.015, -0.015, 0.015]
        XCTAssertThrowsError(try measure(zip(expected, jitter).map { $0 + 0.12 + $1 }))
        for observed in [
            expected.map { $0 - 10 }, expected.map { $0 + 10 }, Array(repeating: .nan, count: 8),
            Array(repeating: expected[0], count: 8), Array(repeating: 0, count: 65),
        ] {
            XCTAssertThrowsError(try measure(observed))
        }
        XCTAssertThrowsError(try measure(expected, expected: Array(expected.prefix(7))))
        XCTAssertThrowsError(
            try AcousticCalibration.measure(
                expected: expected, observed: expected, routeID: "", sampleRate: 48000, now: date))
        XCTAssertThrowsError(
            try AcousticCalibration.measure(
                expected: expected, observed: expected, routeID: "route", sampleRate: .infinity, now: date))
    }

    func testCalibrationOffsetBoundsExpiryRouteRateAndInvalidPersistence() throws {
        let expected = AcousticCalibration.pulseOffsets.map { clock + $0 }
        for offset in [0.0, 0.5] {
            XCTAssertEqual(try measure(expected.map { $0 + offset }).offsetMS, offset * 1000, accuracy: 0.001)
        }
        XCTAssertThrowsError(try measure(expected.map { $0 + 0.510 }))
        XCTAssertThrowsError(try measure(expected.map { $0 - 0.010 }))
        let calibration = try measure(expected.map { $0 + 0.120 })
        XCTAssertFalse(calibration.usable(routeID: "other", sampleRate: 48000, now: date))
        XCTAssertFalse(calibration.usable(routeID: calibration.routeID, sampleRate: 44100, now: date))
        XCTAssertFalse(
            calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date.addingTimeInterval(-1)))
        XCTAssertFalse(
            calibration.usable(routeID: calibration.routeID, sampleRate: 48000, now: date.addingTimeInterval(86401)))
        var bad = calibration
        bad.offsetMS = .nan
        XCTAssertFalse(bad.valid)
        bad = calibration
        bad.matchedPulses = 5
        XCTAssertFalse(bad.valid)
        bad = calibration
        bad.jitterMS = 11
        XCTAssertTrue(bad.valid)
        XCTAssertFalse(bad.usable(routeID: calibration.routeID, sampleRate: 48000, now: date))
    }
}
