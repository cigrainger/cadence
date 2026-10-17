// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

/// Retains a completed pass until its journal and review schedule have both been saved.
@MainActor final class TimedChangesSession: ObservableObject {
    @Published private(set) var plan: TimedChangesPlan?
    @Published private(set) var conditions = ChangesTimingConditions()
    @Published private(set) var active = false
    @Published private(set) var preparing = false
    @Published private(set) var demonstration = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var events: [ChordKeyEvent] = []
    @Published private(set) var result: TimedChangesResult?
    @Published private(set) var saved = false
    @Published var error: String?
    private var epoch = UUID()
    private var origin = 0.0
    private var timer: Timer?
    private let output = TimedAudio()
    private let clock: () -> Double
    var busy: Bool { active || preparing }
    var hasUnsavedResult: Bool { result != nil && !saved }
    var countInRemaining: Int {
        guard let plan else { return 0 }
        return max(0, Int(ceil(-elapsed / plan.secondsPerBeat)))
    }
    init(clock: @escaping () -> Double = PracticeClock.now) { self.clock = clock }

    func start(
        _ plan: TimedChangesPlan, conditions: ChangesTimingConditions, held: Set<Int>, demonstration: Bool = false
    ) {
        guard prepare(plan, conditions: conditions, held: held, demonstration: demonstration) else { return }
        preparing = true
        let token = epoch
        output.start(render: {
            try ChangesAudioTrack.render(plan, conditions: conditions, demonstration: demonstration)
        }) { [weak self] response in
            guard let self, self.epoch == token else { return }
            switch response {
            case .success(let audibleStart):
                self.begin(at: audibleStart + plan.countIn)
                let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            case .failure(let error):
                self.cancel()
                self.error = "Count-in failed: " + error.localizedDescription
            }
        }
    }
    @discardableResult func prepare(
        _ plan: TimedChangesPlan, conditions: ChangesTimingConditions, held: Set<Int>, demonstration: Bool = false
    ) -> Bool {
        guard !hasUnsavedResult else {
            error = "Save or discard the completed pass before starting another."
            return false
        }
        cancel()
        guard plan.valid, conditions.valid else {
            error = "Choose a supported passage and timing setup."
            return false
        }
        guard held.isEmpty || demonstration else {
            error = "Release the piano keys before starting the count-in."
            return false
        }
        self.plan = plan
        self.conditions = conditions
        self.demonstration = demonstration
        events = []
        result = nil
        saved = false
        error = nil
        return true
    }
    func begin(at passageOrigin: Double) {
        guard plan != nil, passageOrigin.isFinite else { return }
        origin = passageOrigin
        preparing = false
        active = true
        elapsed = clock() - origin
    }
    func cancel(_ reason: String? = nil) {
        epoch = UUID()
        output.stop()
        timer?.invalidate()
        timer = nil
        active = false
        preparing = false
        if let reason { error = reason }
    }
    func receive(_ update: MIDIUpdate) {
        guard busy, !demonstration else { return }
        if update.message == .reset {
            cancel("Keyboard reset. Start again with a fresh count-in.")
            return
        }
        if case .control(_, let number, _) = update.message, number == 120 || number == 123 {
            cancel("Keyboard notes were reset. Start a fresh count-in.")
            return
        }
        guard active, let plan, update.timestamp.isFinite else { return }
        let seconds = update.timestamp - origin - Double(conditions.offsetMS) / 1000
        guard seconds >= -plan.countIn - 0.25, seconds <= plan.duration + 0.5 else { return }
        let event: ChordKeyEvent
        switch update.message {
        case .noteOn(let channel, let note, let velocity):
            guard (0...127).contains(velocity) else { return }
            event = ChordKeyEvent(
                seconds: seconds, note: note, channel: channel, down: velocity > 0,
                arrivalTimestamp: update.arrivalTimestamp)
        case .noteOff(let channel, let note):
            event = ChordKeyEvent(
                seconds: seconds, note: note, channel: channel, down: false, arrivalTimestamp: update.arrivalTimestamp)
        default: return  // Pedal does not alter the physical key set being assessed.
        }
        guard event.valid else { return }
        guard events.count < 4096 else {
            cancel("Too many input events. Check the keyboard connection, then start again.")
            return
        }
        events.append(event)
    }
    func tick() {
        guard active, let plan else { return }
        elapsed = clock() - origin
        guard elapsed >= plan.duration + 0.8 else { return }
        cancel()
        guard !demonstration else { return }
        let result = TimedChangesResult(plan: plan, conditions: conditions, events: events)
        guard result.valid else {
            error = "This pass could not be assessed. Try a fresh count-in."
            return
        }
        self.result = result
    }
    func save(using commit: (TimedChangesResult) throws -> Void) {
        guard let result, !saved else { return }
        do {
            try commit(result)
            saved = true
            error = nil
        } catch {
            self.error = "Your pass is still here. Try saving again. " + error.localizedDescription
        }
    }
    func discard() {
        cancel()
        result = nil
        saved = false
        error = nil
    }
}
