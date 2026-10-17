// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

final class PerformanceObservationTests: XCTestCase {
    func frame(frequency: Double? = 110, clip: Double = 0, clock: Bool = true) -> PerformanceObservation {
        .init(
            sampleTime: clock ? 96000 : nil, hostSeconds: nil, sampleRate: 48000, frameCount: 4096,
            rms: 0.1, clippedFraction: clip, frequency: frequency, confidence: 0.99)
    }
    func frames(_ sample: PerformanceObservation, count: Int = 5) -> [PerformanceObservation] {
        (0..<count).map { i in
            var frame = sample
            if frame.sampleTime != nil { frame.sampleTime = Int64(i * 4096) }
            return frame
        }
    }
    func testMeasuredPitchSummaryHasNoInventedTimingOrMechanics() {
        let take = MonophonicTake(target: 45, frames: frames(frame()))
        XCTAssertEqual(take.medianCents ?? 99, 0, accuracy: 0.01)
        XCTAssertTrue(
            take.summary.contains("timing, finger identity, picking direction and polyphony were not assessed"))
        let sharp = MonophonicTake(
            target: 45, frames: frames(frame(frequency: 110 * pow(2, 25.0 / 1200))))
        XCTAssertEqual(sharp.medianCents ?? 99, 25, accuracy: 0.01)
    }
    func testClippingUnknownClockSilenceAndTooLittleEvidenceAreInconclusive() {
        for sample in [frame(clip: 0.1), frame(clock: false), frame(frequency: nil)] {
            let take = MonophonicTake(target: 45, frames: frames(sample))
            XCTAssertNil(take.medianCents)
            XCTAssertTrue(take.summary.contains("Inconclusive"))
        }
        XCTAssertNil(MonophonicTake(target: 45, frames: [frame()]).medianCents)
    }
    func testInvalidNumbersAndBoundsAreRejectedBeforeSummary() throws {
        var sample = frame()
        sample.rms = .nan
        XCTAssertFalse(sample.valid)
        sample = frame(frequency: .infinity)
        XCTAssertFalse(sample.valid)
        sample = frame()
        sample.hostSeconds = .nan
        XCTAssertFalse(MonophonicTake(target: 45, frames: [sample]).valid)
        XCTAssertFalse(MonophonicTake(target: 999, frames: [frame()]).valid)
        XCTAssertFalse(MonophonicTake(target: 45, frames: Array(repeating: frame(), count: 301)).valid)
    }
}
