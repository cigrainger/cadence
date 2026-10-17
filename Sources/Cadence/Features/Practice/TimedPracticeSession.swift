// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

/// Owned by AppState so a failed save survives leaving the practice view.
@MainActor final class TimedPracticeSession: ObservableObject {
    @Published private(set) var plan: TimedPracticePlan?
    @Published private(set) var conditions = TimedConditions()
    @Published private(set) var active = false
    @Published private(set) var preparing = false
    @Published private(set) var demonstration = false
    @Published private(set) var calibration = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var attacks: [TimedAttack] = []
    @Published private(set) var result: TimedPracticeResult?
    @Published private(set) var calibrationReport: TimedReport?
    @Published private(set) var saved = false
    @Published var error: String?
    private(set) var pianoRecording: PianoRecording?
    private var pianoEvents: [PianoEvent] = []
    private var recordPiano = false
    private var epoch = UUID()
    private var origin: Double = 0
    private var physical: Set<Int> = []
    private var timer: Timer?
    private let output = TimedAudio()
    private let clock: () -> Double
    var hasUnsavedResult: Bool { result != nil && !saved }
    var busy: Bool { active || preparing }
    var countInRemaining: Int {
        guard let plan else { return 0 }
        return max(0, Int(ceil(-elapsed / plan.secondsPerBeat)))
    }
    init(clock: @escaping () -> Double = PracticeClock.now) { self.clock = clock }

    func start(
        _ plan: TimedPracticePlan, conditions: TimedConditions, held: Set<Int>, demonstration: Bool = false,
        calibration: Bool = false, recordPiano: Bool = false, render: (@Sendable () throws -> [Float])? = nil
    ) {
        guard
            prepare(
                plan, conditions: conditions, held: held, demonstration: demonstration, calibration: calibration,
                recordPiano: recordPiano)
        else { return }
        preparing = true
        let token = epoch
        let ready: (Result<Double, Error>) -> Void = { [weak self] response in
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
        if let render {
            output.start(render: render, ready: ready)
        } else {
            output.start(plan, click: conditions.click, demonstration: demonstration, ready: ready)
        }
    }
    @discardableResult func prepare(
        _ plan: TimedPracticePlan, conditions: TimedConditions, held: Set<Int>, demonstration: Bool = false,
        calibration: Bool = false, recordPiano: Bool = false
    ) -> Bool {
        guard !hasUnsavedResult else {
            error = "Save or discard the completed pass before starting another."
            return false
        }
        cancel()
        guard plan.valid, conditions.valid, plan.rhythmOnly || conditions.input == .midi,
            calibration == (plan.rhythmID == "calibration")
        else {
            error = "Choose a supported passage and timing setup."
            return false
        }
        guard held.isEmpty || conditions.input == .space || demonstration else {
            error = "Release the piano keys before starting the count-in."
            return false
        }
        self.recordPiano = recordPiano && !plan.rhythmOnly && !demonstration && !calibration
        pianoRecording = nil
        pianoEvents = []
        self.plan = plan
        self.conditions = conditions
        self.demonstration = demonstration
        self.calibration = calibration
        result = nil
        saved = false
        calibrationReport = nil
        attacks = []
        physical = []
        error = nil
        return true
    }
    /// Injected origin/clock make tests independent of wall-clock time and audio hardware.
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
        physical = []
        if let reason { error = reason }
    }
    func receive(_ update: MIDIUpdate) {
        guard busy, conditions.input == .midi else { return }
        if update.message == .reset {
            cancel("The keyboard was reset. Start again with a fresh count-in.")
            return
        }
        if case .control(_, let number, _) = update.message, number == 120 || number == 123 {
            cancel("The keyboard stopped its notes. Start again when ready.")
            return
        }
        if preparing, recordPiano {
            switch update.message {
            case .noteOn(_, _, let velocity) where velocity > 0, .control(_, 64, let velocity) where velocity >= 64:
                cancel("Wait for the count-in before pressing a key or the sustain pedal, then try again.")
                return
            default: break
            }
        }
        if active, recordPiano, let plan {
            let time = update.timestamp - origin - Double(conditions.offsetMS) / 1000
            if time >= -plan.countIn - 0.5, time <= plan.duration + 0.4,
                let event = PianoEvent(update.message, seconds: time, arrivalTimestamp: update.arrivalTimestamp)
            {
                guard pianoEvents.count < 8192 else {
                    cancel("Too many piano events arrived. Check the MIDI input and try again.")
                    return
                }
                pianoEvents.append(event)
            }
        }
        defer { physical = update.keyboard.downNotes }
        if case .noteOn(let channel, let note, let velocity) = update.message,
            (0...15).contains(channel), (1...127).contains(velocity), (0...127).contains(note), !physical.contains(note)
        {
            attack(at: update.timestamp, pitch: note, arrivalTimestamp: update.arrivalTimestamp)
        }
    }
    func attack(at timestamp: Double, pitch: Int = 60, arrivalTimestamp: Bool = false) {
        guard active, !demonstration, let plan, timestamp.isFinite else { return }
        let time = timestamp - origin - Double(conditions.offsetMS) / 1000
        // Keep a short early/late margin, never count the preceding count-in beats.
        guard time >= -min(0.4, plan.secondsPerBeat * 0.49), time <= plan.duration + 0.4 else { return }
        guard attacks.count < 2048 else {
            cancel("Too many input events arrived. Restart after checking the MIDI input.")
            return
        }
        let attack = TimedAttack(seconds: time, pitch: pitch, arrivalTimestamp: arrivalTimestamp)
        guard attack.valid else { return }
        attacks.append(attack)
    }
    func tick() {
        guard active, let plan else { return }
        elapsed = clock() - origin
        // Allow queued native events to arrive before finalizing their source timestamps.
        guard elapsed >= plan.duration + 0.8 else { return }
        cancel()
        if demonstration { return }
        if calibration {
            calibrationReport = try? TimedMatcher.assess(plan, attacks: attacks)
            return
        }
        let result = TimedPracticeResult(plan: plan, conditions: conditions, attacks: attacks)
        guard result.valid else {
            error = "This pass could not be assessed. Try a fresh count-in."
            return
        }
        if recordPiano { pianoRecording = PianoRecording(events: pianoEvents, end: plan.duration + 0.4) }
        self.result = result
    }
    func save(using commit: (TimedPracticeResult) throws -> Void) {
        guard let result, !saved else { return }
        do {
            try commit(result)
            saved = true
            error = nil
        } catch {
            self.error = "This pass is still here. Try saving again. " + error.localizedDescription
        }
    }
    func clearCalibration() { calibrationReport = nil }
    func discard() {
        cancel()
        pianoRecording = nil
        pianoEvents = []
        result = nil
        saved = false
        error = nil
    }
}
