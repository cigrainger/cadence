// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Combine
import Foundation
import MusicCore

@MainActor final class Microphone: ObservableObject {
    let detections = PassthroughSubject<(DetectedPitch?, Double), Never>()
    @Published var listening = false
    @Published var pitch: DetectedPitch?
    @Published var error: String?
    @Published var recorded: [ScoreNote] = []
    @Published var transcribing = false
    private let input: any MicrophoneInput
    private let permission: @Sendable () async -> Bool
    private let now: @MainActor () -> Date
    private let queue = DispatchQueue(label: "cadence.pitch", qos: .userInitiated)
    private var started = Date()
    private var tempo = 90.0
    private var stableMidi: Int?
    private var stableCount = 0
    private var activeMidi: Int?
    private var activeStart = 0.0
    private var lastHeard = Date.distantPast
    private var heldSince: Date?
    private var heldMidi: Int?
    @Published var heldPitch: Int?
    private var epoch = UUID()
    init(
        input: (any MicrophoneInput)? = nil,
        permission: @escaping @Sendable () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.input = input ?? SystemMicrophoneInput()
        self.permission = permission
        self.now = now
    }

    func start(transcribe: Bool = false, tempo: Double = 90, forTuner: Bool = false) async {
        stop()
        error = nil
        guard !Task.isCancelled else { return }
        let pending = epoch
        let allowed = await permission()
        guard pending == epoch, !Task.isCancelled else { return }
        guard allowed else {
            error = "Microphone access is off. Enable Cadence in System Settings → Privacy & Security → Microphone."
            return
        }
        self.tempo = tempo
        transcribing = transcribe
        recorded = []
        started = now()
        do {
            try input.start(forTuner: forTuner, receive: makeBufferHandler(forTuner: forTuner))
            listening = true
        } catch {
            stop()
            self.error = "Microphone could not start: \(error.localizedDescription)"
        }
    }

    private func makeBufferHandler(forTuner: Bool) -> MicrophoneBufferHandler {
        let token = epoch
        let analysisRange = forTuner ? 25.0...4500.0 : 65.0...1300.0
        let analysisQueue = queue
        // AVFoundation invokes this on its render thread. Copy samples before
        // leaving the callback; only immutable values reach the analysis queue.
        return { @Sendable [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            // Downsample with averaging to keep pitch analysis away from the audio callback.
            let factor = max(1, Int(buffer.format.sampleRate / (forTuner ? 48000 : 12000)))
            var samples: [Float] = []
            let count = Int(buffer.frameLength)
            if count >= factor {
                for index in stride(from: 0, to: count - factor + 1, by: factor) {
                    var sum: Float = 0
                    for j in 0..<factor { sum += channel[index + j] }
                    samples.append(sum / Float(factor))
                }
            }
            let rate = buffer.format.sampleRate / Double(factor)
            analysisQueue.async { [weak self, samples] in
                let detection = PitchDetector.detect(samples, sampleRate: rate, frequencyRange: analysisRange)
                Task { @MainActor in
                    guard self?.epoch == token else { return }
                    self?.receive(detection)
                }
            }
        }
    }
    func stop() {
        if activeMidi != nil { finishNote(at: now().timeIntervalSince(started) * tempo / 60) }
        epoch = UUID()
        input.stop()
        listening = false
        transcribing = false
        pitch = nil
        heldPitch = nil
        stableMidi = nil
        activeMidi = nil
        stableCount = 0
        heldSince = nil
        heldMidi = nil
    }
    func resetHold() {
        heldSince = nil
        heldMidi = nil
        heldPitch = nil
    }
    private func receive(_ detection: DetectedPitch?) {
        pitch = detection
        detections.send((detection, PracticeClock.now()))
        let now = now()
        let beat = now.timeIntervalSince(started) * tempo / 60
        guard let detection, detection.confidence > 0.85 else {
            if now.timeIntervalSince(lastHeard) > 0.18 {
                finishNote(at: beat)
                stableCount = 0
                stableMidi = nil
                resetHold()
            }
            return
        }
        lastHeard = now
        let midi = detection.midi
        if abs(detection.cents) < 35 {
            if heldMidi != midi {
                heldMidi = midi
                heldSince = now
                heldPitch = nil
            }
            if now.timeIntervalSince(heldSince ?? now) >= 0.65 { heldPitch = midi }
        } else {
            resetHold()
        }
        if stableMidi == midi {
            stableCount += 1
        } else {
            stableMidi = midi
            stableCount = 1
        }
        guard transcribing, stableCount >= 2 else { return }
        if activeMidi != midi {
            finishNote(at: beat)
            activeMidi = midi
            activeStart = max(0, beat - 0.1)
        }
    }
    private func finishNote(at end: Double) {
        guard transcribing, let midi = activeMidi else {
            activeMidi = nil
            return
        }
        let duration = end - activeStart
        if duration > 0.12 {
            let start = (activeStart * 4).rounded() / 4
            recorded.append(ScoreNote(midi: midi, start: start, duration: max(0.25, (duration * 4).rounded() / 4)))
        }
        activeMidi = nil
    }
}
