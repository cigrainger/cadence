// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import MusicCore
import os

struct AcousticCaptureResult: Sendable {
    var attacks: [AcousticAttack]
    var sampleRate: Double
    var blocks: Int
    var issue: String?
    var clockEvidence: AcousticClockEvidence?
}

private struct AcousticPCMBlock: Sendable {
    var samples: [Float]
    var rate: Double
    var host: Double
    var sample: Int64
}

private struct AcousticInputHealth: Sendable {
    var rate = 0.0
    var frames = 0
    var blocks = 0
    var analyzedBlocks = 0
    var maximumResidual = 0.0
    var firstHost: Double?
    var firstSample: Int64?
    var previousSample: Int64?
    var previousCount = 0
    var issue: String?
    var quietBefore: Double?
    var prerollFrames = 0
    var prerollEnergy = 0.0
}

/// The render callback only copies bounded PCM and clocks. A single consumer
/// preserves FIFO order; overflow and clock gaps invalidate a timing judgment.
@MainActor final class AcousticCapturePipe {
    private let channel: Int
    private let continuation: AsyncStream<AcousticPCMBlock>.Continuation
    private let health = OSAllocatedUnfairLock(initialState: AcousticInputHealth())
    private let task: Task<[AcousticAttack], Never>

    init(channel: Int = 0, level: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.channel = channel
        let (stream, continuation) = AsyncStream<AcousticPCMBlock>.makeStream(bufferingPolicy: .bufferingOldest(8))
        self.continuation = continuation
        let health = self.health
        task = Task.detached(priority: .userInitiated) {
            var analyzer = AcousticAnalyzer()
            var attacks: [AcousticAttack] = []
            var lastBlock: AcousticPCMBlock?
            func annotate(_ attacks: [AcousticAttack], block: AcousticPCMBlock) -> [AcousticAttack] {
                attacks.map { original in
                    var attack = original
                    let delta = ((attack.hostSeconds - block.host) * block.rate).rounded()
                    if delta.isFinite, abs(delta) < Double(Int32.max) {
                        let (sample, overflow) = block.sample.addingReportingOverflow(Int64(delta))
                        if !overflow {
                            attack.sampleTime = sample
                            attack.sampleRate = block.rate
                        }
                    }
                    attack.onsetUncertaintyMS = max(10, attack.onsetUncertaintyMS)
                    return attack
                }
            }
            for await block in stream {
                guard !Task.isCancelled else { break }
                var energy = 0.0
                var clipped = 0
                for sample in block.samples {
                    energy += Double(sample) * Double(sample)
                    if abs(sample) >= 0.99 { clipped += 1 }
                }
                let rms = sqrt(energy / Double(block.samples.count))
                level(rms)
                if Double(clipped) / Double(block.samples.count) >= 0.01 {
                    health.withLock { $0.issue = "The input clipped. Reduce the input gain and try again." }
                }
                health.withLock { state in
                    if let boundary = state.quietBefore {
                        let start = Int(
                            max(0, min(Double(block.samples.count), ceil((boundary - 0.10 - block.host) * block.rate))))
                        let end = Int(
                            max(0, min(Double(block.samples.count), ceil((boundary - 0.02 - block.host) * block.rate))))
                        if start < end {
                            for sample in block.samples[start..<end] {
                                state.prerollEnergy += Double(sample) * Double(sample)
                            }
                            state.prerollFrames += end - start
                        }
                    }
                }
                lastBlock = block
                attacks += annotate(
                    analyzer.append(samples: block.samples, sampleRate: block.rate, hostSeconds: block.host),
                    block: block)
                health.withLock { $0.analyzedBlocks += 1 }
                if attacks.count > 128 {
                    health.withLock {
                        $0.issue = "Too many attacks for a short single-note phrase. Try a quieter input."
                    }
                    attacks = Array(attacks.prefix(128))
                    continuation.finish()
                    break
                }
            }
            if !Task.isCancelled, let lastBlock { attacks += annotate(analyzer.finish(), block: lastBlock) }
            return Array(attacks.prefix(128))
        }
    }

    var analyzedBlocks: Int { health.withLock { $0.analyzedBlocks } }

    var handler: MicrophoneBufferHandler {
        let health = health
        let continuation = continuation
        let selectedChannel = channel
        return { @Sendable buffer, time in
            let count = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            guard (0..<64).contains(selectedChannel), selectedChannel < Int(buffer.format.channelCount) else {
                health.withLock {
                    $0.issue = "The selected input channel is unavailable. Choose the channel carrying your guitar."
                }
                return
            }
            guard (1...65536).contains(count), rate.isFinite, (8000...192000).contains(rate),
                let channel = buffer.floatChannelData?[selectedChannel], time.isHostTimeValid, time.isSampleTimeValid,
                abs(time.sampleRate - rate) <= 0.01
            else {
                health.withLock { $0.issue = "The microphone did not provide a usable sample clock." }
                return
            }
            let host = AVAudioTime.seconds(forHostTime: time.hostTime)
            guard host.isFinite else { return }
            let sample = time.sampleTime
            let mapped = health.withLock { state -> Double? in
                guard state.frames <= Int(rate * 35) - count else {
                    state.issue = "The capture exceeded its bounded phrase duration. Start a shorter pass."
                    return nil
                }
                if state.rate != 0 && state.rate != rate {
                    state.issue = "The input sample rate changed. Calibrate the new route and try again."
                    return nil
                }
                if state.firstHost == nil {
                    state.firstHost = host
                    state.firstSample = sample
                }
                let (distance, overflow) = sample.subtractingReportingOverflow(state.firstSample!)
                guard !overflow, distance >= 0, Double(distance) <= rate * 35,
                    !sample.addingReportingOverflow(Int64(count)).overflow
                else {
                    state.issue = "The input sample counter overflowed. Start a new pass."
                    return nil
                }
                // One hardware anchor maps contiguous sample positions to the host
                // clock. Supplied block host times must agree within the uncertainty
                // allowance; queue delivery time never participates in this mapping.
                let mappedHost = state.firstHost! + Double(distance) / rate
                state.maximumResidual = max(state.maximumResidual, abs(host - mappedHost) * 1000)
                if state.maximumResidual > 5 {
                    state.issue = "The input host clock drifted. This take cannot establish timing."
                }
                if let previous = state.previousSample,
                    sample.subtractingReportingOverflow(previous).overflow
                        || sample.subtractingReportingOverflow(previous).partialValue != Int64(state.previousCount)
                {
                    state.issue = "Input samples were interrupted. This take cannot establish timing."
                }
                state.rate = rate
                state.frames += count
                state.blocks += 1
                state.previousSample = sample
                state.previousCount = count
                return mappedHost
            }
            guard let mapped else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: count))
            guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
                health.withLock { $0.issue = "The input exceeded its usable range. Reduce gain and try again." }
                return
            }
            switch continuation.yield(.init(samples: samples, rate: rate, host: mapped, sample: sample)) {
            case .dropped:
                health.withLock { $0.issue = "Audio analysis fell behind. Close other audio work and try again." }
            case .terminated:
                health.withLock { $0.issue = "Input arrived after capture ended. This take cannot establish timing." }
            case .enqueued: break
            @unknown default:
                health.withLock { $0.issue = "The audio queue could not retain this input." }
            }
        }
    }

    /// A quiet input window immediately before the phrase excludes a count-in
    /// tail from being graded as a weak or missing first guitar note.
    func requireQuiet(before host: Double) {
        guard host.isFinite else { return }
        health.withLock {
            $0.quietBefore = host
            $0.prerollFrames = 0
            $0.prerollEnergy = 0
        }
    }

    func finish() async -> AcousticCaptureResult {
        continuation.finish()
        let attacks = await task.value
        let state = health.withLock { state in
            if state.analyzedBlocks != state.blocks {
                state.issue = state.issue ?? "Audio blocks were not completely analysed. Start a new pass."
            }
            if state.quietBefore != nil,
                state.prerollFrames < Int(state.rate * 0.070)
                    || sqrt(state.prerollEnergy / Double(max(1, state.prerollFrames))) > 0.004
            {
                state.issue =
                    state.issue
                    ?? "The count-in or background sound had not cleared before the phrase. Use a quieter setup and try again."
            }
            return state
        }
        let evidence = state.firstHost.flatMap { host in
            state.firstSample.map { sample in
                AcousticClockEvidence(
                    firstSampleTime: sample, firstHostSeconds: host, sampleRate: state.rate,
                    frameCount: state.frames, maximumHostResidualMS: min(5000, state.maximumResidual),
                    inputChannel: channel)
            }
        }
        return .init(
            attacks: attacks, sampleRate: state.rate, blocks: state.blocks,
            issue: state.issue ?? (state.blocks == 0 ? "No timestamped microphone audio was received." : nil),
            clockEvidence: evidence)
    }

    func cancel() {
        continuation.finish()
        task.cancel()
    }
}
