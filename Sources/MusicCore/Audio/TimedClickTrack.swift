// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum TimedClickTrack {
    /// One buffer contains the whole count-in and passage. No timer schedules clicks.
    public static func render(
        _ plan: TimedPracticePlan, click: Bool, demonstration: Bool = false, sampleRate: Double = 44100,
        flowPulse: FlowPulse? = nil
    ) throws -> [Float] {
        guard plan.valid, flowPulse.map({ $0.click == click }) ?? true, sampleRate.isFinite,
            (8000...96000).contains(sampleRate)
        else { throw MusicError.invalid("Invalid timed audio plan.") }
        return try render(
            tempo: plan.tempo, beatsPerBar: plan.beatsPerBar, length: plan.length, click: click,
            demonstrationBeats: demonstration ? plan.onsetBeats : [], sampleRate: sampleRate, flowPulse: flowPulse)
    }
    public static func render(
        tempo: Int, beatsPerBar: Int, length: Double, click: Bool, demonstrationBeats: [Double] = [],
        sampleRate: Double = 44100, flowPulse: FlowPulse? = nil
    ) throws -> [Float] {
        guard (40...160).contains(tempo), (2...4).contains(beatsPerBar), length.isFinite, length > 0,
            length * 60 / Double(tempo) <= 90, sampleRate.isFinite, (8000...96000).contains(sampleRate)
        else { throw MusicError.invalid("Invalid count-in timeline.") }
        let secondsPerBeat = 60 / Double(tempo)
        let countIn = Double(beatsPerBar) * secondsPerBeat
        let duration = length * secondsPerBeat
        let demonstration = !demonstrationBeats.isEmpty
        var output = [Float](repeating: 0, count: Int(((countIn + duration + 0.6) * sampleRate).rounded()))
        func pulse(_ seconds: Double, frequency: Double, gain: Double) {
            let start = Int((seconds * sampleRate).rounded())
            let count = Int(sampleRate * 0.035)
            for n in 0..<count where start + n < output.count {
                let time = Double(n) / sampleRate
                output[start + n] += Float(
                    sin(2 * .pi * frequency * time) * min(1, time / 0.001) * exp(-time * 150) * gain)
            }
        }
        for beat in 0..<beatsPerBar {
            pulse(Double(beat) * secondsPerBeat, frequency: beat == 0 ? 1800 : 1200, gain: 0.5)
        }
        if click {
            for beat in 0..<Int(ceil(length)) where flowPulse?.sounds(at: beat, beatsPerBar: beatsPerBar) ?? true {
                pulse(
                    countIn + Double(beat) * secondsPerBeat, frequency: beat % beatsPerBar == 0 ? 1800 : 1200,
                    gain: demonstration ? 0.15 : 0.3)
            }
        }
        if demonstration {
            for beat in demonstrationBeats { pulse(countIn + beat * secondsPerBeat, frequency: 650, gain: 0.7) }
        }
        return output
    }
}
