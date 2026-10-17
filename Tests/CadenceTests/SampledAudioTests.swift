// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class SampledAudioTests: XCTestCase {
    func testCancellationReachesDetachedSoundPreparation() async throws {
        let began = expectation(description: "Rendering began")
        let ended = expectation(description: "Rendering cancelled")
        let task = Task {
            try await AudioRenderTask.run {
                began.fulfill()
                defer { ended.fulfill() }
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                try Task.checkCancellation()
                return true
            }
        }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation should throw")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [ended], timeout: 2)
    }
    @MainActor func testNaturalAudioCompletionAndStopHaveDifferentSignals() async throws {
        let audio = AudioPlayer()
        audio.play(Score(tempo: 300, beatsPerBar: 1, notes: []))
        let id = audio.playbackID
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if audio.completedPlayback != nil || audio.error != nil { break }
        }
        XCTAssertNil(audio.error)
        XCTAssertEqual(audio.completedPlayback, id)
        audio.stop()
        XCTAssertNil(audio.completedPlayback)
    }
    func testPianoPitchCalibrationAndDistinctInstrumentSamples() throws {
        let score = Score(tempo: 120, notes: [ScoreNote(midi: 69, start: 0, duration: 2)])
        let piano = try SampledAudio.render(score)
        let tuned = try SampledAudio.render(score, referenceA4: 442)
        let electric = try SampledAudio.render(
            lanes: [BandLane(.electricPiano, notes: score.notes)], tempo: 120, endBeat: 4)
        XCTAssertGreaterThan(piano.map(abs).max() ?? 0, 0.001)
        XCTAssertNotEqual(piano, electric)
        let first = try XCTUnwrap(PitchDetector.detect(Array(piano[4096..<8192]), sampleRate: 44100))
        let second = try XCTUnwrap(PitchDetector.detect(Array(tuned[4096..<8192]), sampleRate: 44100))
        XCTAssertEqual(first.frequency, 440, accuracy: 4)
        XCTAssertGreaterThan(second.frequency, first.frequency + 0.5)
    }
    func testAllBandProgramsRenderAndExactCycleLength() throws {
        for voice in BandVoice.allCases {
            let data = try SampledAudio.render(
                lanes: [BandLane(voice, notes: [ScoreNote(midi: voice == .drums ? 38 : 48, start: 0, duration: 1)])],
                tempo: 120, endBeat: 2, tail: 0)
            XCTAssertEqual(data.count, 44100)
            XCTAssertTrue(data.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(data.map(abs).max() ?? 0, 0.001)
        }
        let plan = GrooveArrangement(tempo: 160, loops: 1)
        let data = try SampledAudio.render(lanes: plan.lanes(), tempo: plan.tempo, endBeat: plan.endBeat)
        XCTAssertEqual(data.count, Int(((plan.endBeat * 60 / 160 + 0.35) * 44100).rounded()))
        XCTAssertLessThanOrEqual(data.map(abs).max() ?? 0, 0.9201)
    }
    func testStudySpeedRangeSupportsSlowAndFastExactLoops() throws {
        for tempo in [5.0, 450.0] {
            let data = try SampledAudio.render(Score(tempo: tempo, notes: []), exactBeats: 0.25)
            XCTAssertEqual(data.count, Int((0.25 * 60 / tempo * 44100).rounded()))
            XCTAssertTrue(data.allSatisfy { $0 == 0 })
        }
        XCTAssertThrowsError(try SampledAudio.render(Score(tempo: 451, notes: [])))
    }
    func testMissingBankAndUnsafeDurationFailExplicitly() throws {
        XCTAssertThrowsError(try SampledAudio.render(lanes: [], tempo: 0, endBeat: 4))
        XCTAssertThrowsError(try SampledAudio.render(lanes: [], tempo: 120, endBeat: .infinity))
        XCTAssertThrowsError(
            try SampledAudio.render(
                lanes: [BandLane(.piano, notes: [])], tempo: 120, endBeat: 1,
                bank: URL(fileURLWithPath: "/missing-cadence-bank.sf2")))
    }
}
