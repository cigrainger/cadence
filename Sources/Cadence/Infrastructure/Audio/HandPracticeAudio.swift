// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore

/// The count-in, click and partner share one buffer and the existing calibrated
/// audible origin. A display timer never schedules the other hand's notes.
enum HandPracticeAudio {
    static func render(_ plan: TimedPracticePlan, click: Bool, partner: Score?, flowPulse: FlowPulse? = nil) throws
        -> [Float]
    {
        var output = try TimedClickTrack.render(plan, click: click, flowPulse: flowPulse)
        guard let partner else { return output }
        guard partner.tempo == Double(plan.tempo),
            partner.notes.allSatisfy({ $0.start >= 0 && $0.start + $0.duration <= plan.length + 0.00001 })
        else {
            throw MusicError.invalid("The partner part must fit this exact practice timeline.")
        }
        let piano = try SampledAudio.render(partner, exactBeats: plan.length)
        let offset = Int((plan.countIn * 44100).rounded())
        for i in piano.indices where offset + i < output.count {
            output[offset + i] = min(0.98, max(-0.98, output[offset + i] + piano[i] * 0.65))
        }
        return output
    }
}
