// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Combine
import MusicCore
import XCTest

@testable import Cadence

@MainActor private final class MicrophoneFixture: MicrophoneInput {
    var handler: MicrophoneBufferHandler?
    var starts = 0
    var stops = 0
    var tuner = false
    var refuse = false
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func start(forTuner: Bool, receive: @escaping MicrophoneBufferHandler) throws {
        starts += 1
        if refuse { throw MusicError.invalid("Input disconnected") }
        tuner = forTuner
        handler = receive
    }
    func stop() {
        stops += 1
        handler = nil
    }
}

private actor PermissionGate {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
    func request() async -> Bool {
        calls += 1
        let id = calls
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func answer(_ id: Int, _ allowed: Bool) { pending.removeValue(forKey: id)?.resume(returning: allowed) }
}

final class MicrophoneTests: XCTestCase {
    /// Allocate the non-Sendable AVFoundation buffer on the callback's own thread.
    /// Only the Sendable callback and musical values cross the task boundary.
    private static func emit(
        _ handler: @escaping MicrophoneBufferHandler, midi: Int?, rate: Double = 12000, frames: Int = 2048
    ) async {
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = buffer.floatChannelData![0]
            let frequency = midi.map { 440 * pow(2, Double($0 - 69) / 12) }
            for i in 0..<frames {
                channel[i] = frequency.map { Float(0.3 * sin(2 * .pi * $0 * Double(i) / rate)) } ?? 0
            }
            handler(buffer, AVAudioTime(sampleTime: 0, atRate: rate))
        }.value
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Microphone callback did not arrive")
        throw MusicError.invalid("Synthetic microphone callback timed out")
    }
    @MainActor private func waitFor(_ gate: PermissionGate, calls: Int) async throws {
        for _ in 0..<100 {
            if await gate.calls >= calls { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Permission request did not arrive")
        throw MusicError.invalid("Injected permission request timed out")
    }

    @MainActor func testPermissionRefusalNeverStartsAnInputAndRetryCanSucceed() async {
        let input = MicrophoneFixture()
        let denied = Microphone(input: input, permission: { false })
        await denied.start(transcribe: true)
        XCTAssertFalse(denied.listening)
        XCTAssertFalse(denied.transcribing)
        XCTAssertEqual(input.starts, 0)
        XCTAssertTrue(denied.error?.contains("Privacy & Security") == true)
        let allowed = Microphone(input: input, permission: { true })
        await allowed.start(forTuner: true)
        XCTAssertTrue(allowed.listening)
        XCTAssertTrue(input.tuner)
        XCTAssertNil(allowed.error)
        allowed.stop()
        XCTAssertNil(input.handler)
    }

    @MainActor func testCancelledStartDoesNotAskForPermission() async {
        let input = MicrophoneFixture()
        let microphone = Microphone(
            input: input,
            permission: {
                XCTFail("Cancelled start prompted")
                return true
            })
        let task = Task { await microphone.start() }
        task.cancel()
        await task.value
        XCTAssertFalse(microphone.listening)
        XCTAssertEqual(input.starts, 0)
    }

    @MainActor func testStoppingWhilePermissionIsPendingRejectsItsLateGrant() async throws {
        let input = MicrophoneFixture()
        let gate = PermissionGate()
        let microphone = Microphone(input: input, permission: { await gate.request() })
        let task = Task { await microphone.start() }
        try await waitFor(gate, calls: 1)
        microphone.stop()
        await gate.answer(1, true)
        await task.value
        XCTAssertFalse(microphone.listening)
        XCTAssertEqual(input.starts, 0)
        XCTAssertNil(microphone.error)
    }

    @MainActor func testOlderPermissionRefusalCannotStopOrAnnotateNewCapture() async throws {
        let input = MicrophoneFixture()
        let gate = PermissionGate()
        let microphone = Microphone(input: input, permission: { await gate.request() })
        let old = Task { await microphone.start() }
        try await waitFor(gate, calls: 1)
        let current = Task { await microphone.start(forTuner: true) }
        try await waitFor(gate, calls: 2)
        await gate.answer(2, true)
        await current.value
        await gate.answer(1, false)
        await old.value
        XCTAssertTrue(microphone.listening)
        XCTAssertNil(microphone.error)
        XCTAssertEqual(input.starts, 1)
        microphone.stop()
    }

    @MainActor func testDeviceStartFailureCleansUpWithoutClaimingCapture() async {
        let input = MicrophoneFixture()
        input.refuse = true
        let microphone = Microphone(input: input, permission: { true })
        await microphone.start(transcribe: true)
        XCTAssertFalse(microphone.listening)
        XCTAssertFalse(microphone.transcribing)
        XCTAssertNil(input.handler)
        XCTAssertGreaterThanOrEqual(input.stops, 2)
        XCTAssertTrue(microphone.error?.contains("Input disconnected") == true)
        input.refuse = false
        await microphone.start()
        XCTAssertTrue(microphone.listening)
        XCTAssertNil(microphone.error)
        microphone.stop()
    }

    @MainActor func testBackgroundBufferPublishesOnMainActorAndStoppedCallbackIsIgnored() async throws {
        let input = MicrophoneFixture()
        let microphone = Microphone(input: input, permission: { true })
        var heard: [Int] = []
        let subscription = microphone.detections.sink { pitch, _ in
            MainActor.preconditionIsolated()
            if let pitch { heard.append(pitch.midi) }
        }
        defer {
            subscription.cancel()
            microphone.stop()
        }
        await microphone.start()
        let stale = try XCTUnwrap(input.handler)
        // Exercise real-rate downsampling as well as a small tuner-rate block.
        // Large full-rate tuner autocorrelation work is a performance test,
        // not the synchronisation deadline of this instrumented actor test.
        await Self.emit(stale, midi: 69, rate: 48000, frames: 8192)
        try await waitFor { heard == [69] }
        microphone.stop()
        XCTAssertNil(microphone.pitch)
        await microphone.start(forTuner: true)
        let current = try XCTUnwrap(input.handler)
        await Self.emit(stale, midi: 60)
        await Self.emit(current, midi: 72)
        try await waitFor { heard.count == 2 }
        XCTAssertEqual(heard, [69, 72])
        XCTAssertEqual(microphone.pitch?.midi, 72)
    }

    @MainActor func testHeldPitchNeedsTimeAndSilenceClearsIt() async throws {
        let input = MicrophoneFixture()
        let microphone = Microphone(input: input, permission: { true }, now: { input.date })
        var count = 0
        let subscription = microphone.detections.sink { _ in count += 1 }
        defer {
            subscription.cancel()
            microphone.stop()
        }
        await microphone.start(forTuner: true)
        let handler = try XCTUnwrap(input.handler)
        await Self.emit(handler, midi: 69)
        try await waitFor { count == 1 }
        XCTAssertNil(microphone.heldPitch)
        input.date.addTimeInterval(0.7)
        await Self.emit(handler, midi: 69)
        try await waitFor { count == 2 }
        XCTAssertEqual(microphone.heldPitch, 69)
        input.date.addTimeInterval(0.3)
        await Self.emit(handler, midi: nil)
        try await waitFor { count == 3 }
        XCTAssertNil(microphone.pitch)
        XCTAssertNil(microphone.heldPitch)
    }

    @MainActor func testTranscriptionRetainsQuantizedNotesAndStopFinalizesLastNote() async throws {
        let input = MicrophoneFixture()
        let microphone = Microphone(input: input, permission: { true }, now: { input.date })
        var count = 0
        let subscription = microphone.detections.sink { _ in count += 1 }
        defer {
            subscription.cancel()
            microphone.stop()
        }
        await microphone.start(transcribe: true, tempo: 90)
        let handler = try XCTUnwrap(input.handler)
        for (index, note) in [69, 69, 72, 72].enumerated() {
            input.date.addTimeInterval(0.2)
            await Self.emit(handler, midi: note)
            try await waitFor { count == index + 1 }
        }
        input.date.addTimeInterval(0.5)
        microphone.stop()
        XCTAssertFalse(microphone.transcribing)
        XCTAssertEqual(microphone.recorded.map(\.midi), [69, 72])
        for note in microphone.recorded {
            XCTAssertGreaterThan(note.duration, 0)
            XCTAssertEqual(note.start * 4, (note.start * 4).rounded())
            XCTAssertEqual(note.duration * 4, (note.duration * 4).rounded())
        }
    }
}
