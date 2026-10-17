// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import MusicCore

@MainActor final class PlayAlongSession: CalibratedPracticeSession {
    @Published private(set) var plan: PlayAlongPlan?
    @Published var setup = PlayAlongSetup()
    var result: PlayAlongResult? {
        guard let plan, let pass = timing.result, pass.plan == plan.timed else { return nil }
        return PlayAlongResult(plan: plan, pass: pass)
    }
    var feedback: [LiveTimedNote] {
        guard let plan, !timing.calibration else { return [] }
        if let result { return result.pass.report.notes.map { LiveTimedNote(assessment: $0, settled: true) } }
        guard timing.active else { return [] }
        return TimedMatcher.live(
            plan.timed, attacks: timing.attacks, elapsed: timing.elapsed, offsetMS: timing.conditions.offsetMS)
    }
    @discardableResult func prepare(_ plan: PlayAlongPlan, held: Set<Int>) -> Bool {
        guard plan.valid else {
            timing.error = "This play-along passage is no longer valid."
            return false
        }
        guard timing.prepare(plan.timed, conditions: .init(input: .midi, click: false, offsetMS: offsetMS), held: held)
        else { return false }
        self.plan = plan
        return true
    }
    func start(_ plan: PlayAlongPlan, held: Set<Int>) {
        guard prepare(plan, held: held) else { return }
        let arrangement = plan.accompaniment
        timing.start(
            plan.timed, conditions: .init(input: .midi, click: false, offsetMS: offsetMS), held: held,
            render: {
                try SampledAudio.render(
                    lanes: arrangement.lanes(), tempo: Double(plan.setup.tempo), endBeat: arrangement.endBeat)
            })
    }
    func save(using commit: (PlayAlongResult) throws -> Void) {
        guard let plan else { return }
        timing.save { pass in
            let result = PlayAlongResult(plan: plan, pass: pass)
            guard result.valid else { throw MusicError.invalid("The saved passage does not match this pass.") }
            try commit(result)
        }
    }
}
