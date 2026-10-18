// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import MusicCore

enum PracticeClock {
    static func now() -> Double { seconds(mach_absolute_time()) }
    static func seconds(_ host: UInt64) -> Double { AVAudioTime.seconds(forHostTime: host) }
}

enum AudioClockReference { case estimatedAudible, scheduledRender }

/// Independent of display refresh. The returned origin is the estimated audible
/// output start, on the same host clock as CoreMIDI and AppKit event timestamps.
@MainActor final class TimedAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    init() {
        engine.attach(player)
        engine.connect(
            player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
    }
    func stop() {
        epoch = UUID()
        task?.cancel()
        task = nil
        player.stop()
    }
    func start(
        _ plan: TimedPracticePlan, click: Bool, demonstration: Bool, silent: Bool = false,
        ready: @escaping (Result<Double, Error>) -> Void
    ) {
        start(
            render: { try TimedClickTrack.render(plan, click: click, demonstration: demonstration) }, silent: silent,
            ready: ready)
    }
    func start(
        render: @escaping @Sendable () throws -> [Float], silent: Bool = false,
        reference: AudioClockReference = .estimatedAudible,
        ready: @escaping (Result<Double, Error>) -> Void
    ) {
        stop()
        let token = epoch
        task = Task { [self] in
            do {
                let samples = try await AudioRenderTask.run(render)
                guard !Task.isCancelled, token == epoch else { return }
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                    let channel = buffer.floatChannelData?[0]
                else {
                    throw MusicError.invalid("Could not prepare the count-in.")
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                if !engine.isRunning { try engine.start() }
                // Acoustic calibration measures the complete scheduled-render/input
                // relationship. Adding presentation latency there would correct twice.
                let latency = reference == .estimatedAudible ? player.outputPresentationLatency : 0
                guard latency.isFinite, (0...2).contains(latency) else {
                    throw MusicError.invalid("The audio output did not provide a usable timing reference.")
                }
                let renderStart = PracticeClock.now() + 0.2
                player.volume = silent ? 0 : 1
                AudioBufferSchedule.enqueue(buffer, on: player)
                player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: renderStart)))
                ready(.success(renderStart + latency))
            } catch {
                if token == epoch {
                    stop()
                    ready(.failure(error))
                }
            }
        }
    }
    func verifyScheduledOutput() async throws -> Bool {
        let earliest = PracticeClock.now()
        var start: Double?
        var failure: Error?
        self.start(.calibration(), click: true, demonstration: false, silent: true) {
            switch $0 {
            case .success(let time): start = time
            case .failure(let error): failure = error
            }
        }
        defer { stop() }
        // A bounded wait accommodates audio startup without relying on a fixed startup delay.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let failure { throw failure }
            if let start, PracticeClock.now() > start + 0.1,
                let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render)
            {
                return start >= earliest + 0.19 && engine.isRunning && player.isPlaying && time.sampleTime > 0
            }
        }
        return false
    }
}
