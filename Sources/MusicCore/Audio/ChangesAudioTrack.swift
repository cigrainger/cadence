// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ChangesAudioTrack {
    public static func render(
        _ plan: TimedChangesPlan, conditions: ChangesTimingConditions, demonstration: Bool = false,
        sampleRate: Double = 44100
    ) throws -> [Float] {
        guard plan.valid, conditions.valid else { throw MusicError.invalid("Invalid chord accompaniment.") }
        var output = try TimedClickTrack.render(
            tempo: plan.tempo, beatsPerBar: plan.beatsPerBar, length: plan.length, click: conditions.click,
            sampleRate: sampleRate)
        func tone(_ note: Int, beat: Double, duration: Double, gain: Double) {
            let start = Int(((plan.countIn + beat * plan.secondsPerBeat) * sampleRate).rounded())
            let seconds = duration * plan.secondsPerBeat
            let count = Int(seconds * sampleRate)
            let frequency = 440 * pow(2, Double(note - 69) / 12)
            for i in 0..<count where start + i < output.count {
                let t = Double(i) / sampleRate
                let envelope = min(1, t / 0.008) * min(1, (seconds - t) / 0.045) * exp(-t * 2.5)
                let wave = sin(2 * .pi * frequency * t) + 0.24 * sin(4 * .pi * frequency * t)
                output[start + i] += Float(wave * envelope * gain)
            }
        }
        var previous: [Int] = []
        for (i, cue) in plan.cues.enumerated() {
            let end = i + 1 < plan.cues.count ? plan.cues[i + 1].beat : plan.length
            guard let target = try cue.target(plan.mode) else {
                previous = []
                continue
            }
            if conditions.bass, let pitch = cue.symbol.bass ?? cue.symbol.root {
                var beat = cue.beat
                while beat < end {
                    tone(36 + pitch.pc, beat: beat, duration: min(1.5, end - beat), gain: 0.28)
                    beat += 2
                }
            }
            if demonstration {
                let notes = target.pianoVoicings(previous: previous).first ?? []
                previous = notes
                for note in notes {
                    tone(
                        note, beat: cue.beat, duration: min(1.7, end - cue.beat),
                        gain: 0.35 / Double(max(1, notes.count)))
                }
            }
        }
        return output.map { min(0.98, max(-0.98, $0)) }
    }
}
