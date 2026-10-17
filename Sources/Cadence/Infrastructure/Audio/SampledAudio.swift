// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import MusicCore

/// Offline rendering keeps file I/O off the audio callback and lets all band
/// parts share one sample clock. The shipped bank is an independently licensed asset.
enum SampledAudio {
    private struct Event {
        var frame: Int
        var lane: Int
        var channel: UInt8 = 0
        var note: UInt8
        var velocity: UInt8
        var on: Bool
        var controller: Bool = false
    }
    static var bankURL: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("SoundBanks/TimGM6mb.sf2")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return AppResources.sourceDirectory.appendingPathComponent("SoundBanks/TimGM6mb.sf2")
    }
    static func render(_ score: Score, exactBeats: Double? = nil, referenceA4: Double = 440) throws -> [Float] {
        var validation = score
        validation.tempo = 120
        _ = try validation.validated()
        return try render(
            lanes: [BandLane(.piano, notes: score.notes)], tempo: score.tempo, endBeat: exactBeats ?? score.length,
            tail: exactBeats == nil ? 0.35 : 0, referenceA4: referenceA4)
    }
    static func render(
        lanes: [BandLane], tempo: Double, endBeat: Double, tail: Double = 0.35, referenceA4: Double = 440,
        bank: URL? = nil
    ) throws -> [Float] {
        guard tempo.isFinite, (5...450).contains(tempo), endBeat.isFinite, endBeat > 0, endBeat * 60 / tempo <= 600,
            tail.isFinite, (0...1).contains(tail), referenceA4.isFinite, (430...450).contains(referenceA4),
            lanes.count <= 8
        else { throw MusicError.invalid("Invalid sampled playback settings.") }
        for lane in lanes { _ = try Score(tempo: 120, notes: lane.notes).validated() }
        let rate = 44100.0
        var events: [Event] = []
        for (index, lane) in lanes.enumerated() {
            for note in lane.notes where note.midi >= 0 {
                let start = Int((note.start * 60 / tempo * rate).rounded())
                let end = Int(
                    ((note.start + note.duration * (note.performance?.gate ?? 0.9)) * 60 / tempo * rate).rounded())
                events.append(
                    Event(
                        frame: start, lane: index, note: UInt8(note.midi),
                        velocity: UInt8(note.performance?.velocity ?? 80), on: true))
                events.append(
                    Event(frame: max(start + 1, end), lane: index, note: UInt8(note.midi), velocity: 0, on: false))
            }
        }
        events.sort { $0.frame == $1.frame ? (!$0.on && $1.on) : $0.frame < $1.frame }
        return try renderEvents(
            events, voices: lanes.map(\.voice), total: Int(((endBeat * 60 / tempo + tail) * rate).rounded()),
            referenceA4: referenceA4, bank: bank, normalize: true)
    }
    /// Replay the original MIDI stream. Sustain and releases are not flattened
    /// into synthetic durations; A/B takes use the same fixed gain.
    static func renderTake(_ recording: PianoRecording, bank: URL? = nil) throws -> [Float] {
        guard recording.valid else { throw MusicError.invalid("This piano recording is invalid.") }
        var events = recording.events.map { event in
            Event(
                frame: max(0, Int(((event.seconds - recording.start) * 44100).rounded())), lane: 0,
                channel: UInt8(event.channel),
                note: UInt8(event.kind == .sustain ? 64 : event.note), velocity: UInt8(event.value),
                on: event.kind == .press, controller: event.kind == .sustain)
        }
        let end = Int((recording.duration * 44100).rounded())
        // Stop cut-off notes/pedals at the recording boundary, then allow decay.
        for channel in 0..<16 {
            events.append(
                Event(frame: end, lane: 0, channel: UInt8(channel), note: 64, velocity: 0, on: false, controller: true))
            events.append(
                Event(frame: end, lane: 0, channel: UInt8(channel), note: 123, velocity: 0, on: false, controller: true)
            )
        }
        return try renderEvents(
            events, voices: [.piano], total: end + 15435, referenceA4: 440, bank: bank, normalize: false)
    }
    private static func renderEvents(
        _ events: [Event], voices: [BandVoice], total: Int, referenceA4: Double, bank: URL?, normalize: Bool
    ) throws -> [Float] {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)
        else { throw MusicError.invalid("Could not prepare sampled sound.") }
        try Task.checkCancellation()
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        var samplers: [AVAudioUnitSampler] = []
        for voice in voices {
            try Task.checkCancellation()
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: format)
            try sampler.loadSoundBankInstrument(
                at: bank ?? bankURL, program: UInt8(voice == .drums ? 0 : voice.rawValue),
                bankMSB: voice == .drums ? 0x78 : 0x79, bankLSB: 0)
            sampler.overallGain = voice == .drums ? -7 : -5
            sampler.globalTuning = Float(1200 * log2(referenceA4 / 440))
            samplers.append(sampler)
        }
        try engine.start()
        defer { engine.stop() }
        var output = [Float]()
        output.reserveCapacity(total)
        var cursor = 0
        var eventIndex = 0
        var noProgress = 0
        while cursor < total {
            try Task.checkCancellation()
            while eventIndex < events.count && events[eventIndex].frame <= cursor {
                let event = events[eventIndex]
                let sampler = samplers[event.lane]
                if event.controller {
                    sampler.sendController(event.note, withValue: event.velocity, onChannel: event.channel)
                } else if event.on {
                    sampler.startNote(event.note, withVelocity: event.velocity, onChannel: event.channel)
                } else {
                    sampler.stopNote(event.note, onChannel: event.channel)
                }
                eventIndex += 1
            }
            let next = eventIndex < events.count ? events[eventIndex].frame : total
            let count = min(1024, total - cursor, max(1, next - cursor))
            let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            guard status != .error, buffer.frameLength <= count else {
                throw MusicError.invalid("Sampled sound could not be rendered.")
            }
            if buffer.frameLength == 0 {
                noProgress += 1
                guard noProgress < 100 else { throw MusicError.invalid("Sampled sound did not start rendering.") }
                continue
            }
            noProgress = 0
            guard let samples = buffer.floatChannelData?[0] else {
                throw MusicError.invalid("No sampled audio channel.")
            }
            output.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            cursor += Int(buffer.frameLength)
        }
        guard output.allSatisfy(\.isFinite) else { throw MusicError.invalid("Invalid sampled audio output.") }
        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        if normalize, peak > 0.92 {
            let gain = 0.92 / peak
            for i in output.indices { output[i] *= gain }
        }
        if !normalize { for i in output.indices { output[i] = max(-0.92, min(0.92, output[i] * 0.6)) } }
        let fade = min(220, output.count)
        for i in 0..<fade { output[output.count - fade + i] *= Float(fade - i) / Float(fade) }
        return output
    }
}
