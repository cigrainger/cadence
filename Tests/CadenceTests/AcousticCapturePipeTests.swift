// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import MusicCore
import XCTest

@testable import Cadence

enum AcousticTestAudio {
    static func signal(
        duration: Double, onsets: [(Double, Double)], rate: Double = 12000, gain: Double = 0.25,
        length: Double = 0.18
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        for (time, frequency) in onsets {
            let start = Int((time * rate).rounded())
            for frame in 0..<Int(length * rate) where start + frame >= 0 && start + frame < samples.count {
                let t = Double(frame) / rate
                let envelope = min(1, t / 0.003) * min(1, (length - t) / 0.012)
                samples[start + frame] += Float(gain * envelope * sin(2 * .pi * frequency * t))
            }
        }
        return samples
    }

    static func emit(
        _ handler: @escaping MicrophoneBufferHandler, samples: [Float], rate: Double = 12000,
        host: Double?, sample: Int64, timeRate: Double? = nil
    ) async {
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
            }
            let time =
                host.map {
                    AVAudioTime(
                        hostTime: AVAudioTime.hostTime(forSeconds: $0), sampleTime: sample,
                        atRate: timeRate ?? rate)
                } ?? AVAudioTime(sampleTime: sample, atRate: rate)
            handler(buffer, time)
        }.value
    }

    static func feed(
        _ handler: @escaping MicrophoneBufferHandler, samples: [Float], rate: Double = 12000,
        host: Double = 100, jitter: @Sendable (Int) -> Double = { _ in 0 }
    ) async throws {
        for (block, start) in stride(from: 0, to: samples.count, by: 2048).enumerated() {
            let end = min(samples.count, start + 2048)
            await emit(
                handler, samples: Array(samples[start..<end]), rate: rate,
                host: host + Double(start) / rate + jitter(block), sample: Int64(start))
            // Let the single analysis consumer run; this tests timestamp jitter,
            // not deliberate FIFO overload (covered separately below).
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

final class AcousticCapturePipeTests: XCTestCase {
    @MainActor func testOriginalSampleMappingSurvivesHostJitterAndDeliveryDelay() async throws {
        let signal = AcousticTestAudio.signal(duration: 1.2, onsets: [(0.20, 110), (0.68, 220)])
        let pipe = AcousticCapturePipe()
        try await AcousticTestAudio.feed(
            pipe.handler, samples: signal, jitter: { $0 == 0 ? 0 : $0.isMultiple(of: 2) ? 0.004 : -0.004 })
        let result = await pipe.finish()
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.attacks.count, 2)
        XCTAssertEqual(result.clockEvidence?.maximumHostResidualMS ?? 0, 4, accuracy: 0.001)
        XCTAssertTrue(result.clockEvidence?.usable == true)
        for (attack, onset) in zip(result.attacks, [0.20, 0.68]) {
            XCTAssertEqual(attack.hostSeconds, 100 + onset, accuracy: 0.010)
            XCTAssertEqual(attack.sampleTime ?? -1, Int64(((attack.hostSeconds - 100) * 12000).rounded()))
            XCTAssertEqual(attack.sampleRate, 12000)
            XCTAssertGreaterThanOrEqual(attack.onsetUncertaintyMS, 10)
            XCTAssertEqual(result.clockEvidence?.sampleTime(at: attack.hostSeconds), attack.sampleTime)
        }
    }

    @MainActor func testCumulativeDriftIsStickyEvenWhenAdjacentDifferencesAreSmall() async throws {
        let pipe = AcousticCapturePipe()
        let signal = AcousticTestAudio.signal(duration: 1.5, onsets: [(0.2, 110), (0.8, 220)])
        try await AcousticTestAudio.feed(pipe.handler, samples: signal, jitter: { Double($0) * 0.001 })
        let result = await pipe.finish()
        XCTAssertTrue(result.issue?.contains("drifted") == true)
        XCTAssertGreaterThan(result.clockEvidence?.maximumHostResidualMS ?? 0, 5)
        XCTAssertFalse(result.clockEvidence?.usable ?? true)
    }

    @MainActor func testMissingSampleAndMissingHostClockNeverBecomeReliableTiming() async {
        let pipe = AcousticCapturePipe()
        let quiet = [Float](repeating: 0, count: 2048)
        await AcousticTestAudio.emit(pipe.handler, samples: quiet, host: 100, sample: 0)
        await AcousticTestAudio.emit(pipe.handler, samples: quiet, host: 100 + 2049.0 / 12000, sample: 2049)
        let gap = await pipe.finish()
        XCTAssertTrue(gap.issue?.contains("interrupted") == true)
        let unknown = AcousticCapturePipe()
        await AcousticTestAudio.emit(unknown.handler, samples: quiet, host: nil, sample: 0)
        let result = await unknown.finish()
        XCTAssertTrue(result.issue?.contains("sample clock") == true)
        XCTAssertNil(result.clockEvidence)
        XCTAssertTrue(result.attacks.isEmpty)
    }

    @MainActor func testClockRateDisagreementAndClippingAreExplicitSignalIssues() async throws {
        let wrongRate = AcousticCapturePipe()
        await AcousticTestAudio.emit(
            wrongRate.handler, samples: [Float](repeating: 0, count: 2048),
            host: 100, sample: 0, timeRate: 48000)
        let mismatch = await wrongRate.finish()
        XCTAssertNotNil(mismatch.issue)
        let clipped = AcousticCapturePipe()
        let signal = AcousticTestAudio.signal(duration: 0.6, onsets: [(0.2, 110)], gain: 1.4).map {
            min(1, max(-1, $0))
        }
        try await AcousticTestAudio.feed(clipped.handler, samples: signal)
        let result = await clipped.finish()
        XCTAssertTrue(result.issue?.contains("clipped") == true)
    }

    @MainActor func testSelectedUSBChannelDoesNotDownmixAndMissingChannelAbstains() async throws {
        let pipe = AcousticCapturePipe(channel: 1)
        let handler = pipe.handler
        let samples = AcousticTestAudio.signal(duration: 0.8, onsets: [(0.2, 220)])
        for start in stride(from: 0, to: samples.count, by: 2048) {
            let chunk = Array(samples[start..<min(samples.count, start + 2048)])
            await Task.detached {
                let format = AVAudioFormat(standardFormatWithSampleRate: 12000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))!
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                for i in chunk.indices {
                    buffer.floatChannelData![0][i] = 0.9  // other channel must not influence the capture
                    buffer.floatChannelData![1][i] = chunk[i]
                }
                handler(
                    buffer,
                    AVAudioTime(
                        hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(start) / 12000),
                        sampleTime: Int64(start), atRate: 12000))
            }.value
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let result = await pipe.finish()
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.attacks.compactMap(\.midi), [57])
        XCTAssertEqual(result.clockEvidence?.inputChannel, 1)
        let absent = AcousticCapturePipe(channel: 2)
        await AcousticTestAudio.emit(absent.handler, samples: [Float](repeating: 0, count: 100), host: 100, sample: 0)
        let unavailable = await absent.finish()
        XCTAssertTrue(unavailable.issue?.contains("channel") == true)
        XCTAssertTrue(unavailable.attacks.isEmpty)
    }

    @MainActor func testOneOutOfRangeSampleCannotSilentlyResetAnalysis() async throws {
        let pipe = AcousticCapturePipe()
        var signal = AcousticTestAudio.signal(duration: 0.8, onsets: [(0.2, 110), (0.5, 220)])
        signal[2500] = 1.001
        try await AcousticTestAudio.feed(pipe.handler, samples: signal)
        let result = await pipe.finish()
        XCTAssertTrue(result.issue?.contains("usable range") == true)
    }

    @MainActor func testCountInTailOverQuietGuardAbstainsEvenWithLaterReliableNotes() async throws {
        let pipe = AcousticCapturePipe()
        pipe.requireQuiet(before: 100.5)
        let signal = AcousticTestAudio.signal(
            duration: 1.3, onsets: [(0.3, 1000), (0.51, 110), (0.9, 220)], gain: 0.08, length: 0.25)
        try await AcousticTestAudio.feed(pipe.handler, samples: signal)
        let result = await pipe.finish()
        XCTAssertTrue(result.issue?.contains("had not cleared") == true)
        XCTAssertFalse(result.attacks.isEmpty, "Later reliable notes do not erase count-in contamination")
        let quiet = AcousticCapturePipe()
        quiet.requireQuiet(before: 100.5)
        try await AcousticTestAudio.feed(
            quiet.handler, samples: AcousticTestAudio.signal(duration: 1, onsets: [(0.51, 110)]))
        let cleared = await quiet.finish()
        XCTAssertNil(cleared.issue)
    }

    @MainActor func testBoundedFIFOOverflowIsReportedEvenWithContinuousProducerClocks() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pipe = AcousticCapturePipe { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        let quiet = [Float](repeating: 0, count: 256)
        await AcousticTestAudio.emit(pipe.handler, samples: quiet, host: 100, sample: 0)
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 1) == .success)
            }
        }
        XCTAssertTrue(started)
        for index in 1...12 {
            await AcousticTestAudio.emit(
                pipe.handler, samples: quiet, host: 100 + Double(index * 256) / 12000,
                sample: Int64(index * 256))
        }
        for _ in 0..<20 { release.signal() }
        let result = await pipe.finish()
        XCTAssertTrue(result.issue?.contains("fell behind") == true)
        XCTAssertEqual(result.blocks, 13)
    }
}
