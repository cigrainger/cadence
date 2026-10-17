// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AppKit
import Combine
import MusicCore

/// Shared timing calibration for every source-linked MIDI practice workspace.
@MainActor class CalibratedPracticeSession: ObservableObject {
    let timing: TimedPracticeSession
    @Published private(set) var offsetMS = 0
    @Published private(set) var calibrated = false
    private var subscriptions = Set<AnyCancellable>()
    private var connection: AnyCancellable?
    init(clock: @escaping () -> Double = PracticeClock.now) {
        timing = TimedPracticeSession(clock: clock)
        timing.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange).receive(on: RunLoop.main).sink {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateTiming("Audio output changed. Check timing again before your next pass.")
            }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).receive(
            on: RunLoop.main
        ).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateTiming("The Mac went to sleep. Check timing again before your next pass.")
            }
        }.store(in: &subscriptions)
    }
    func connect(_ midi: MIDIKeyboard) {
        guard connection == nil else { return }
        connection = midi.$connectionRevision.dropFirst().sink { [weak self] _ in
            self?.invalidateTiming("Keyboard connection changed. Check timing again before your next pass.")
        }
    }
    func invalidateTiming(_ reason: String? = nil) {
        timing.cancel(reason)
        timing.clearCalibration()
        offsetMS = 0
        calibrated = false
    }
    func applyCalibration() {
        guard !timing.busy, !timing.hasUnsavedResult, let report = timing.calibrationReport,
            !timing.attacks.contains(where: \.arrivalTimestamp), let delta = report.calibrationOffsetMS,
            (-250...250).contains(timing.conditions.offsetMS + delta)
        else { return }
        offsetMS = timing.conditions.offsetMS + delta
        calibrated = true
    }
    func calibrate(held: Set<Int>) {
        timing.start(
            .calibration(), conditions: .init(input: .midi, click: true, offsetMS: offsetMS), held: held,
            calibration: true)
    }
}
