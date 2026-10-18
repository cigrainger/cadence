// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import MusicCore

typealias MicrophoneBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// Device ownership stays on the main actor; the buffer callback is explicitly
/// independent of it. Tests can exercise permission and callback races silently.
@MainActor protocol MicrophoneInput: AnyObject {
    var inputChannelCount: Int? { get }
    func start(forTuner: Bool, receive: @escaping MicrophoneBufferHandler) throws
    func stop()
}

extension MicrophoneInput { var inputChannelCount: Int? { nil } }

@MainActor final class SystemMicrophoneInput: MicrophoneInput {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    var inputChannelCount: Int? { Int(engine.inputNode.outputFormat(forBus: 0).channelCount) }

    func start(forTuner: Bool, receive: @escaping MicrophoneBufferHandler) throws {
        stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MusicError.invalid("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: forTuner ? 8192 : 4096, format: format, block: receive)
        tapInstalled = true
        do { try engine.start() } catch {
            stop()
            throw error
        }
    }
    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}
