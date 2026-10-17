// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Combine
import Foundation
import MusicCore

@MainActor final class AudioPlayer: ObservableObject {
    @Published private(set) var completedPlayback: UUID?
    var playbackID: UUID { generation }
    @Published var isPlaying = false
    @Published var beat = 0.0
    @Published var studyPlayhead: StudyPlayhead?
    @Published var isPreparing = false
    @Published var metronomeSettings: MetronomeSettings?
    @Published var metronomePosition: MetronomePosition?
    var isMetronome: Bool { metronomeSettings != nil }
    @Published var error: String?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: Timer?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    init() {
        engine.attach(player)
        engine.connect(
            player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
    }
    func note(_ midi: Int) { note(midi, referenceA4: 440) }
    func note(_ midi: Int, referenceA4: Double) {
        guard referenceA4.isFinite, (430...450).contains(referenceA4) else {
            error = "Choose a reference from 430–450 Hz."
            return
        }
        play(Score(tempo: 100, notes: [ScoreNote(midi: midi, start: 0, duration: 1)]), referenceA4: referenceA4)
    }
    func chord(_ notes: [Int]) {
        play(Score(tempo: 80, notes: notes.map { ScoreNote(midi: $0, start: 0, duration: 2) }))
    }
    func verifyOutput() async throws -> [String: Any] {
        let samples = Self.render(Score(tempo: 120, notes: [ScoreNote(midi: 69, start: 0, duration: 1)]))
        guard let detection = PitchDetector.detect(Array(samples.prefix(4096)), sampleRate: 44100),
            abs(detection.frequency - 440) < 5
        else { throw MusicError.invalid("Synthesised note failed pitch verification.") }
        let calibrated = Self.render(
            Score(tempo: 120, notes: [ScoreNote(midi: 69, start: 0, duration: 1)]), referenceA4: 442)
        guard let calibratedPitch = PitchDetector.detect(Array(calibrated.prefix(4096)), sampleRate: 44100),
            abs(calibratedPitch.frequency - 442) < 1
        else { throw MusicError.invalid("Calibrated tuner reference failed pitch verification.") }
        var quiet = ScoreNote(midi: 69, start: 0, duration: 1)
        quiet.performance = NotePerformance(velocity: 44, gate: 0.9)
        var loud = quiet
        loud.performance = NotePerformance(velocity: 108, gate: 0.9)
        var short = loud
        short.performance = NotePerformance(velocity: 108, gate: 0.45)
        let quietSamples = Self.render(Score(tempo: 120, notes: [quiet]))
        let loudSamples = Self.render(Score(tempo: 120, notes: [loud]))
        let shortSamples = Self.render(Score(tempo: 120, notes: [short]))
        func energy(_ samples: [Float], _ range: Range<Int>) -> Double {
            samples[range].reduce(0) { $0 + Double($1 * $1) }
        }
        let dynamicGain = energy(loudSamples, 1000..<7000) / energy(quietSamples, 1000..<7000)
        let shortened = energy(shortSamples, 15000..<19000) < 0.00001 && energy(loudSamples, 15000..<19000) > 0.01
        guard dynamicGain > 4, shortened else { throw MusicError.invalid("Expression audio verification failed.") }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)
        else { throw MusicError.invalid("No audio buffer.") }
        silence.frameLength = 4410
        silence.floatChannelData?[0].initialize(repeating: 0, count: 4410)
        try engine.start()
        AudioBufferSchedule.enqueue(silence, on: player)
        player.play()
        let running = engine.isRunning && player.isPlaying
        try await Task.sleep(nanoseconds: 150_000_000)
        stop()
        guard running else { throw MusicError.invalid("Audio output did not start.") }
        return [
            "audioOutput": true, "expressionDynamics": dynamicGain > 4, "expressionStaccato": shortened,
            "synthFrequency": detection.frequency, "calibratedReferenceTone": calibratedPitch.frequency,
            "sampleRate": format.sampleRate,
        ]
    }
    func stop() {
        generation = UUID()
        completedPlayback = nil
        task?.cancel()
        task = nil
        player.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        beat = 0
        studyPlayhead = nil
        isPreparing = false
        metronomeSettings = nil
        metronomePosition = nil
    }
    func play(_ score: Score, referenceA4: Double = 440) {
        stop()
        error = nil
        guard score.length * 60 / score.tempo < 600 else {
            error = "Choose a passage under ten minutes for playback."
            return
        }
        isPreparing = true
        let token = generation
        task = Task { [self] in
            let samples: [Float]
            do {
                samples = try await AudioRenderTask.run { try SampledAudio.render(score, referenceA4: referenceA4) }
            } catch {
                guard token == self.generation else { return }
                self.isPreparing = false
                self.error = "Piano sound could not be prepared: " + error.localizedDescription
                return
            }
            guard !Task.isCancelled, token == self.generation else { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = buffer.floatChannelData?[0]
            else {
                self.isPreparing = false
                self.error = "Could not create audio output."
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                if let base = $0.baseAddress { channel.update(from: base, count: samples.count) }
            }
            do {
                if !self.engine.isRunning { try self.engine.start() }
                self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        if self?.generation == token {
                            self?.isPlaying = false
                            self?.timer?.invalidate()
                            self?.timer = nil
                            self?.completedPlayback = token
                        }
                    }
                }
                self.player.play()
                self.isPreparing = false
                self.isPlaying = true
                let start = Date()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.beat = Date().timeIntervalSince(start) * score.tempo / 60 }
                }
            } catch {
                self.isPreparing = false
                self.error = "Audio output failed: \(error.localizedDescription)"
            }
        }
    }
    func playStudy(_ plan: StudyPlaybackPlan, loop: Bool) {
        stop()
        error = nil
        isPreparing = true
        let token = generation
        task = Task { [self] in
            let samples: ([Float], [Float])
            do {
                samples = try await AudioRenderTask.run {
                    (
                        plan.introBeats > 0 ? try SampledAudio.render(plan.intro, exactBeats: plan.introBeats) : [],
                        try SampledAudio.render(plan.cycle, exactBeats: plan.cycleBeats)
                    )
                }
            } catch {
                guard token == generation else { return }
                isPreparing = false
                self.error = error.localizedDescription
                return
            }
            guard !Task.isCancelled, token == generation else { return }
            func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                    let channel = buffer.floatChannelData?[0]
                else { throw MusicError.invalid("Could not create study audio.") }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer {
                    if let base = $0.baseAddress { channel.update(from: base, count: samples.count) }
                }
                return buffer
            }
            do {
                if !engine.isRunning { try engine.start() }
                if !samples.0.isEmpty { AudioBufferSchedule.enqueue(try buffer(samples.0), on: player) }
                let cycle = try buffer(samples.1)
                if loop {
                    AudioBufferSchedule.enqueue(cycle, on: player, looping: true)
                } else {
                    player.scheduleBuffer(cycle, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor in
                            if self?.generation == token {
                                self?.stop()
                                self?.completedPlayback = token
                            }
                        }
                    }
                }
                player.play()
                isPreparing = false
                isPlaying = true
                studyPlayhead = plan.position(seconds: 0, loop: loop)
                let playbackTimer = Timer(timeInterval: 0.035, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token, let renderTime = self.player.lastRenderTime,
                            let time = self.player.playerTime(forNodeTime: renderTime)
                        else { return }
                        let position = plan.position(seconds: Double(time.sampleTime) / time.sampleRate, loop: loop)
                        self.studyPlayhead = position
                        self.beat = position.sourceBeat
                    }
                }
                timer = playbackTimer
                RunLoop.main.add(playbackTimer, forMode: .common)
            } catch {
                isPreparing = false
                self.error = "Study playback failed: " + error.localizedDescription
            }
        }
    }
    func verifyStudyOutput() async throws -> Bool {
        var study = MusicStudy(
            document: try StudyImport.read(Data(StudyExamples.smallSteps.utf8)), filename: "fixture.musicxml")
        study.select(from: 0, through: 0)
        study.countIn = false
        study.document.tempo = 300
        study.speed = 1.5
        // A silent native loop checks timing and cancellation without sounding notes.
        var plan = try StudyPlaybackPlan(study: study)
        plan.cycle.notes = []
        plan.cycleBeats = 0.25
        playStudy(plan, loop: true)
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if error != nil || (isPlaying && (studyPlayhead?.cycle ?? 0) >= 2 && !isPreparing) { break }
        }
        let passed = isPlaying && (studyPlayhead?.cycle ?? 0) >= 2 && !isPreparing
        stop()
        return passed && !isPlaying && studyPlayhead == nil
    }
    func playMetronome(_ settings: MetronomeSettings) {
        stop()
        error = nil
        let pattern: MetronomePattern
        do { pattern = try MetronomePattern(settings) } catch {
            self.error = error.localizedDescription
            return
        }
        metronomeSettings = settings
        isPreparing = true
        let token = generation
        task = Task { [self] in
            let samples = await Task.detached(priority: .userInitiated) { pattern.render() }.value
            guard !Task.isCancelled, generation == token else { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: pattern.sampleRate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = buffer.floatChannelData?[0]
            else {
                stop()
                self.error = "Could not create metronome output."
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                if let base = $0.baseAddress { channel.update(from: base, count: samples.count) }
            }
            do {
                if !engine.isRunning { try engine.start() }
                AudioBufferSchedule.enqueue(buffer, on: player, looping: true)
                player.play()
                isPlaying = true
                isPreparing = false
                metronomePosition = pattern.position(sampleTime: 0)
                let playbackTimer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token, let renderTime = self.player.lastRenderTime,
                            let time = self.player.playerTime(forNodeTime: renderTime)
                        else { return }
                        let head = pattern.position(sampleTime: time.sampleTime)
                        self.metronomePosition = head
                        self.beat = Double(head.beat) + head.progress
                    }
                }
                timer = playbackTimer
                RunLoop.main.add(playbackTimer, forMode: .common)
            } catch {
                stop()
                self.error = "Metronome output failed: " + error.localizedDescription
            }
        }
    }
    func verifyMetronomeOutput() async throws -> Bool {
        var settings = MetronomeSettings()
        settings.bpm = 300
        settings.setBeats(1)
        settings.subdivision = .sixteenths
        settings.volume = 0
        playMetronome(settings)
        try await Task.sleep(nanoseconds: 550_000_000)
        let passed = isMetronome && isPlaying && (metronomePosition?.bar ?? 0) >= 1
        stop()
        return passed && !isPlaying && metronomePosition == nil && !isMetronome
    }
    nonisolated private static func render(_ score: Score, exactBeats: Double? = nil, referenceA4: Double = 440)
        -> [Float]
    {
        let rate = 44100.0
        let secondsPerBeat = 60 / score.tempo
        let length = Int(((exactBeats ?? score.length) * secondsPerBeat + (exactBeats == nil ? 0.25 : 0)) * rate)
        var output = [Float](repeating: 0, count: max(1, length))
        for note in score.notes where note.midi >= 0 {
            let start = Int(note.start * secondsPerBeat * rate)
            let duration = note.duration * (note.performance?.gate ?? 1) * secondsPerBeat
            let releaseTime = note.performance == nil ? 0.12 : 0.025
            let gain = Double(note.performance?.velocity ?? 80) / 80
            let count = min(Int((duration + releaseTime) * rate), output.count - start)
            guard start >= 0, count > 0 else { continue }
            let f = referenceA4 * pow(2, Double(note.midi - 69) / 12)
            for i in 0..<count {
                let t = Double(i) / rate
                let attack = min(1, t / 0.008)
                let release = t < duration ? 1 : max(0, 1 - (t - duration) / releaseTime)
                let decay = 0.55 * exp(-2 * t) + 0.45 * exp(-0.35 * t)
                var signal = sin(2 * Double.pi * f * t)
                if f * 2 < rate / 2 { signal += 0.23 * sin(4 * Double.pi * f * t) * exp(-t * 2) }
                if f * 3 < rate / 2 { signal += 0.09 * sin(6 * Double.pi * f * t) * exp(-t * 3) }
                output[start + i] += Float(signal * attack * release * decay * 0.22 * gain)
            }
        }
        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0.9 { for i in output.indices { output[i] *= 0.9 / peak } }
        if exactBeats != nil {
            // Exact cycle length avoids accumulated pauses. Fade only the final
            // 5 ms to prevent clicks where a sustained note crosses the loop edge.
            let fade = min(output.count, 220)
            for index in 0..<fade { output[output.count - fade + index] *= Float(fade - index) / Float(fade) }
        }
        return output
    }
}

@MainActor final class Microphone: ObservableObject {
    let detections = PassthroughSubject<(DetectedPitch?, Double), Never>()
    @Published var listening = false
    @Published var pitch: DetectedPitch?
    @Published var error: String?
    @Published var recorded: [ScoreNote] = []
    @Published var transcribing = false
    private let engine = AVAudioEngine()
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
    private var tapInstalled = false

    func start(transcribe: Bool = false, tempo: Double = 90, forTuner: Bool = false) async {
        stop()
        error = nil
        let pending = epoch
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard pending == epoch, !Task.isCancelled else { return }
        guard allowed else {
            error = "Microphone access is off. Enable Cadence in System Settings → Privacy & Security → Microphone."
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "No microphone input is available."
            return
        }
        self.tempo = tempo
        transcribing = transcribe
        recorded = []
        started = Date()
        let token = epoch
        let analysisRange = forTuner ? 25.0...4500.0 : 65.0...1300.0
        input.installTap(onBus: 0, bufferSize: forTuner ? 8192 : 4096, format: format) { [weak self] buffer, _ in
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
            self?.queue.async { [weak self] in
                let detection = PitchDetector.detect(samples, sampleRate: rate, frequencyRange: analysisRange)
                Task { @MainActor in
                    guard self?.epoch == token else { return }
                    self?.receive(detection)
                }
            }
        }
        tapInstalled = true
        do {
            try engine.start()
            listening = true
        } catch {
            stop()
            self.error = "Microphone could not start: \(error.localizedDescription)"
        }
    }
    func stop() {
        if activeMidi != nil { finishNote(at: Date().timeIntervalSince(started) * tempo / 60) }
        epoch = UUID()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        listening = false
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
        let now = Date()
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
