// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PracticeToolsTests: XCTestCase {
    func testClickFramesAndBarLengthAtAwkwardTempo() throws {
        var settings = MetronomeSettings()
        settings.bpm = 107
        settings.setBeats(3)
        settings.subdivision = .triplets
        let pattern = try MetronomePattern(settings)
        XCTAssertEqual(pattern.frameCount, Int((3 * 60.0 / 107 * 44100).rounded()))
        XCTAssertEqual(pattern.pulseFrames.count, 9)
        let ideal = 60.0 / 107 / 3 * 44100
        for (index, frame) in pattern.pulseFrames.enumerated() {
            XCTAssertLessThan(abs(Double(frame) - Double(index) * ideal), 1.1)
        }
    }
    func testAudioClockWrapsWithoutAccumulatedTimerGap() throws {
        let pattern = try MetronomePattern(MetronomeSettings())
        let head = pattern.position(sampleTime: Int64(pattern.frameCount) * 1000 + Int64(pattern.pulseFrames[2]))
        XCTAssertEqual(head.bar, 1000)
        XCTAssertEqual(head.beat, 2)
        XCTAssertEqual(head.subdivision, 0)
        XCTAssertEqual(pattern.position(sampleTime: Int64(pattern.frameCount) - 1).beat, 3)
        XCTAssertEqual(pattern.position(sampleTime: Int64(pattern.frameCount)).beat, 0)
    }
    func testEverySubdivisionHasItsOwnClickAndAccentStrength() throws {
        var settings = MetronomeSettings()
        settings.bpm = 60
        settings.subdivision = .sixteenths
        settings.volume = 1
        let pattern = try MetronomePattern(settings)
        let samples = pattern.render()
        XCTAssertEqual(samples.count, pattern.frameCount)
        func peak(_ pulse: Int) -> Float {
            samples[pattern.pulseFrames[pulse]..<pattern.pulseFrames[pulse] + 1000].map { abs($0) }.max()!
        }
        XCTAssertGreaterThan(peak(0), peak(4))
        XCTAssertGreaterThan(peak(4), peak(1))
        XCTAssertEqual(samples[pattern.pulseFrames[1] - 100], 0)
        settings.volume = 0
        XCTAssertTrue(try MetronomePattern(settings).render().allSatisfy { $0 == 0 })
    }
    func testAccentsResizeAndPreferencesRoundTrip() throws {
        var settings = MetronomeSettings()
        settings.setBeats(7)
        settings.accents[3] = true
        settings.setBeats(3)
        XCTAssertEqual(settings.accents, [true, false, false])
        XCTAssertEqual(settings.beatsPerBar, 3)
        XCTAssertEqual(try JSONDecoder().decode(MetronomeSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.bpm = 301
        XCTAssertThrowsError(try MetronomePattern(settings))
        settings.bpm = 84
        settings.volume = .nan
        XCTAssertThrowsError(try settings.validated())
    }
    func testTapTempoRejectsBounceAndResetsAfterPause() {
        var taps = TapTempo()
        XCTAssertNil(taps.tap(at: 1))
        XCTAssertEqual(taps.tap(at: 1.5), 120)
        XCTAssertNil(taps.tap(at: 1.51))
        XCTAssertEqual(taps.tap(at: 2.01), 119)
        XCTAssertEqual(taps.tap(at: 2.49), 121)
        XCTAssertNil(taps.tap(at: 10))
        XCTAssertEqual(taps.tap(at: 11), 60)
        XCTAssertNil(taps.tap(at: 9))
    }
    func testCalibrationSharpFlatAndOctaveAreIndependent() throws {
        let centred = try XCTUnwrap(TunerReading(frequency: 442, confidence: 0.95, referenceA4: 442))
        XCTAssertEqual(centred.targetMidi, 69)
        XCTAssertEqual(centred.cents, 0, accuracy: 0.00001)
        XCTAssertTrue(centred.isInTune)
        let sharp = try XCTUnwrap(TunerReading(frequency: 442, confidence: 0.95, referenceA4: 440))
        XCTAssertGreaterThan(sharp.cents, 5)
        XCTAssertFalse(sharp.isInTune)
        let flat = try XCTUnwrap(TunerReading(frequency: 440 * pow(2, -10.0 / 1200), confidence: 0.95, target: 69))
        XCTAssertEqual(flat.cents, -10, accuracy: 0.0001)
        let octave = try XCTUnwrap(TunerReading(frequency: 220, confidence: 0.95, target: 45))
        XCTAssertEqual(octave.cents, 1200, accuracy: 0.0001)
        XCTAssertFalse(octave.isInTune)
    }
    func testAlternateTuningTargetsUseActualOctaves() {
        let targets = [38, 45, 50, 55, 59, 64]
        XCTAssertEqual(TunerReading.closestTarget(frequency: 73.416, targets: targets, referenceA4: 440), 38)
        XCTAssertEqual(TunerReading.closestTarget(frequency: 329.628, targets: targets, referenceA4: 440), 64)
        XCTAssertEqual(TunerReading.frequency(midi: 69, referenceA4: 442), 442)
        XCTAssertEqual(TunerReading.frequency(midi: 45), 110, accuracy: 0.00001)
    }
    func testUnreliableOrInvalidReadingsStayEmpty() {
        for frequency in [0, -1, Double.nan, Double.infinity, 25000] {
            XCTAssertNil(TunerReading(frequency: frequency, confidence: 0.99))
        }
        XCTAssertNil(TunerReading(frequency: 440, confidence: 0.5))
        XCTAssertNil(TunerReading(frequency: 440, confidence: 0.99, referenceA4: 200))
        XCTAssertNil(TunerReading(frequency: 440, confidence: 0.99, target: 500))
    }
    func testMedianFilterDoesNotCarryStalePitchAcrossSilenceOrTargetChanges() throws {
        var filter = TunerSmoother()
        for frequency in [110.0, 110.1, 109.9, 112] {
            _ = filter.update(DetectedPitch(frequency: frequency, confidence: 0.99), referenceA4: 440, target: 45)
        }
        let smoothed = try XCTUnwrap(
            filter.update(DetectedPitch(frequency: 110, confidence: 0.99), referenceA4: 440, target: 45))
        XCTAssertEqual(smoothed.frequency, 110, accuracy: 0.01)
        XCTAssertNil(filter.update(nil, referenceA4: 440, target: 45))
        let changed = try XCTUnwrap(
            filter.update(DetectedPitch(frequency: 220, confidence: 0.99), referenceA4: 440, target: 57))
        XCTAssertEqual(changed.targetMidi, 57)
        XCTAssertEqual(changed.cents, 0, accuracy: 0.0001)
    }
    func testTunerRangeDetectsLowGuitarAndPianoNotes() throws {
        let rate = 48000.0
        for frequency in [27.5, 41.2034, 73.4162, 82.4069, 110, 261.6256, 440, 442, 1318.51, 2093.0, 4186.009] {
            let samples = (0..<8192).map { index -> Float in
                let time = Double(index) / rate
                return Float(0.3 * sin(2 * Double.pi * frequency * time) + 0.07 * sin(4 * Double.pi * frequency * time))
            }
            let detected = try XCTUnwrap(
                PitchDetector.detect(samples, sampleRate: rate, frequencyRange: 25...4500), "\(frequency) Hz")
            let cents = 1200 * log2(detected.frequency / frequency)
            XCTAssertLessThan(abs(cents), 5, "\(frequency) Hz, deviation \(cents) cents")
        }
        XCTAssertNil(
            PitchDetector.detect([Float](repeating: 0, count: 8192), sampleRate: rate, frequencyRange: 25...4500))
    }
}
