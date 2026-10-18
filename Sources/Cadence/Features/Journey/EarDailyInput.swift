// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import Foundation
import MusicCore

/// Holds a received MIDI answer across disk failure. Navigation stops capture;
/// only an explicit discard can remove a pending answer.
@MainActor final class EarDailyInput: ObservableObject {
    struct Pending {
        var session: EarDailySession
        var attempt: PracticeAttempt
    }
    @Published private(set) var listening = false
    @Published private(set) var notes: [Int] = []
    @Published private(set) var pending: Pending?
    @Published var error: String?
    private var expected: EarDailySession?
    private var keys = MIDIStepCapture()

    func pause() {
        listening = false
        expected = nil
        keys.reset()
    }
    func arm(state: AppState, now: Date = Date()) throws {
        guard pending == nil, let session = state.earDailySession, session.instrument == .piano,
            session.stage == .play, !state.contextCoach.typing
        else { throw MusicError.invalid("Save the waiting answer, then return to the playing step.") }
        state.stopAllPlayback()
        try state.updateEarDaily(session.id) { try $0.beganAttempt(now: now) }
        expected = state.earDailySession
        keys.reset(held: state.midi.keyboard.downNotes)
        notes = []
        error = nil
        listening = true
        if state.isPreview, CommandLine.arguments.contains("--daily-ax") { EarDailyChecks.fillMIDI(state) }
    }
    func receive(_ update: MIDIUpdate, state: AppState, active: Bool = true) {
        guard listening, pending == nil, let expected, expected == state.earDailySession,
            state.destination == .practice, state.practicePage == .earDaily,
            !state.audio.isPlaying, !state.audio.isPreparing, !state.contextCoach.typing,
            active, state.scoreEarCurrent(expected.material)
        else {
            pause()
            return
        }
        if update.message == .reset {
            pause()
            notes = []
            error = "The keyboard disconnected. Reconnect and start a fresh take."
            return
        }
        if case .control(_, let number, _) = update.message, number == 120 || number == 123 {
            pause()
            notes = []
            error = "The keyboard reset. Start a fresh take."
            return
        }
        if let gesture = keys.receive(update.message, state: update.keyboard) {
            guard gesture.count == 1, notes.count < 13 else {
                pause()
                notes = []
                error = "Play one note at a time. Start a fresh take after releasing the keys."
                return
            }
            notes += gesture
        }
    }
    func submit(state: AppState, now: Date = Date()) {
        guard pending == nil, listening, let expected, expected == state.earDailySession else {
            error = "Start a fresh MIDI take before checking it."
            return
        }
        guard !keys.waitingForRelease, keys.notes.isEmpty else {
            error = "Release the last note before checking this take."
            return
        }
        do {
            let attempt = try expected.midiAttempt(notes: notes, now: now)
            pending = .init(session: expected, attempt: attempt)
            pause()
            save(state: state)
        } catch { self.error = error.localizedDescription }
    }
    func save(state: AppState) {
        guard let pending else { return }
        do {
            try state.saveEarDailyAttempt(pending.attempt, expected: pending.session)
            self.pending = nil
            notes = []
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func discard() {
        pending = nil
        notes = []
        error = nil
        pause()
    }
}
