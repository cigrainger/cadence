// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class PieceRehearsalSession: CalibratedPracticeSession {
    @Published private(set) var recordID: UUID?
    @Published private(set) var key: String?
    @Published private(set) var stage: RehearsalStage?
    @Published private(set) var sourcePlan: TimedPracticePlan?
    @Published private(set) var exercise = RehearsalExercise.notes
    @Published var loopsRemaining = 0
    @Published var shaping = false
    @Published var partnerEnabled = true
    @Published var selectedTakeID: UUID?
    @Published var comparisonTakeID: UUID?
    var pianoPhrase: PianoPhrase?
    private(set) var flowSource: TimedPracticePlan?
    let takePlayer = PianoTakePlayer()
    private var takeSubscription: AnyCancellable?
    init(clock: @escaping () -> Double = PracticeClock.now) {
        super.init(clock: clock)
        takeSubscription = takePlayer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    override func invalidateTiming(_ reason: String? = nil) {
        takePlayer.stop()
        super.invalidateTiming(reason)
    }
    var feedback: [LiveTimedNote] {
        guard !timing.calibration, let plan = timing.plan, let source = sourcePlan?.source else { return [] }
        let raw: [LiveTimedNote]
        if let result = timing.result {
            raw = result.report.notes.map { LiveTimedNote(assessment: $0, settled: true) }
        } else if timing.active {
            raw = TimedMatcher.live(
                plan, attacks: timing.attacks, elapsed: timing.elapsed, offsetMS: timing.conditions.offsetMS)
        } else {
            return []
        }
        return raw.map { item in
            guard plan.rhythmOnly else { return item }
            var assessment = item.assessment
            assessment.target.bar += source.scope.from
            return LiveTimedNote(assessment: assessment, settled: item.settled)
        }
    }
    @discardableResult func prepare(
        _ record: PieceRehearsal, exercise: RehearsalExercise, tempo: Int, input: TimedInput, held: Set<Int>,
        pianoPhrase: PianoPhrase? = nil, playPartner: Bool = true
    ) throws -> TimedPracticePlan {
        guard record.stage != .complete else { throw MusicError.invalid("Choose a return or more practice first.") }
        let focused = record.stage == .focus
        let flow = focused ? record.flow : nil
        let tempo = flow?.tempo ?? tempo
        let playPartner = flow?.partner ?? playPartner
        guard !focused || (40...record.opening.tempo).contains(tempo) else {
            throw MusicError.invalid("Keep focused practice at or below your opening tempo.")
        }
        let plan =
            focused
            ? try PieceRehearsal.exercisePlan(record.activePlan, exercise: exercise, tempo: tempo) : record.activePlan
        let conditions = TimedConditions(
            input: focused && exercise == .rhythm ? input : .midi, click: focused && (flow?.pulse.click ?? true),
            offsetMS: focused && exercise == .rhythm && input == .space ? 0 : offsetMS,
            partnerStaff: focused && playPartner ? PianoHands.partner(in: record.activePlan, exercise: exercise) : nil,
            flowPulse: flow?.pulse)
        guard pianoPhrase.map({ $0.valid && $0.plan == plan }) ?? true else {
            throw MusicError.invalid("The piano recording must match this exact practice passage.")
        }
        if exercise == .connected && focused {
            guard let pianoPhrase, !pianoPhrase.joins.isEmpty else {
                throw MusicError.invalid(
                    "Choose a single piano melody with adjacent, distinct pitches and no written detachment for this exercise."
                )
            }
        }
        guard timing.prepare(plan, conditions: conditions, held: held, recordPiano: pianoPhrase != nil) else {
            throw MusicError.invalid(timing.error ?? "This exercise could not start.")
        }
        self.flowSource = flow?.plan
        self.pianoPhrase = pianoPhrase
        partnerEnabled = playPartner
        recordID = record.id
        key = record.key
        stage = record.stage
        sourcePlan = record.activePlan
        self.exercise = focused ? exercise : .notes
        return plan
    }
    func stop() {
        loopsRemaining = 0
        timing.cancel()
        takePlayer.stop()
    }
}
