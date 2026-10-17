// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class EarSessionInput: ObservableObject {
    let library: Bool
    init(library: Bool = false) { self.library = library }
    func active(_ state: AppState) -> EarSession? { library ? state.scoreEarPractice.active : state.earPractice.active }
    private func current(_ state: AppState) -> Bool {
        !library || active(state)?.opening.material.map { state.scoreEarCurrent($0) } == true
    }
    struct Pending {
        var expected: EarSession
        var event: EarEvent
    }
    @Published private(set) var pending: Pending?
    @Published private(set) var listening = false
    @Published private(set) var notes: [Int] = []
    @Published private(set) var invalidTake = false
    @Published var error: String?
    private var expected: EarSession?
    private var capturedFor: EarSession?
    private var keys = MIDIStepCapture()
    private var voice = SungPhraseCapture()
    var waitingForRelease: Bool { keys.waitingForRelease }
    func pause() {
        listening = false
        expected = nil
        keys.reset()
        voice = SungPhraseCapture()
    }
    func clearTake() {
        pause()
        notes = []
        invalidTake = false
        capturedFor = nil
    }
    func arm(state: AppState) {
        guard pending == nil, current(state), let session = active(state), let p = try? session.projection(),
            [.sing, .play].contains(p.stage), !p.awaitingAdvance
        else { return }
        pause()
        expected = session
        capturedFor = session
        notes = []
        error = nil
        invalidTake = false
        keys.reset(held: state.midi.keyboard.downNotes)
        listening = true
    }
    func receive(_ update: MIDIUpdate, state: AppState) {
        guard listening, expected == active(state), let p = try? expected?.projection(), p.stage == .play else {
            return
        }
        guard !state.audio.isPlaying, !state.audio.isPreparing, state.practicePage == (library ? .scoreEar : .ear),
            current(state), state.destination == .practice
        else {
            pause()
            return
        }
        if update.message == .reset {
            pause()
            return
        }
        if case .control(_, let number, _) = update.message, number == 120 || number == 123 {
            pause()
            return
        }
        if let gesture = keys.receive(update.message, state: update.keyboard) {
            guard gesture.count == 1 else {
                invalidTake = true
                error = "Play one note at a time. Clear this take and try again."
                pause()
                return
            }
            guard notes.count < 12 else {
                invalidTake = true
                error = "That take is long enough. Check it, or clear it."
                pause()
                return
            }
            notes += gesture
        }
    }
    func receivePitch(_ detection: DetectedPitch?, at time: Double, state: AppState) {
        guard listening, expected == active(state), let p = try? expected?.projection(), p.stage == .sing else {
            return
        }
        guard state.practicePage == (library ? .scoreEar : .ear), current(state), state.destination == .practice,
            !state.audio.isPlaying, !state.audio.isPreparing
        else {
            pause()
            return
        }
        voice.receive(
            midi: detection?.midi, cents: detection?.cents ?? 0, confidence: detection?.confidence ?? 0, at: time)
        notes = voice.notes
        if notes.count > 12 {
            invalidTake = true
            error = "That take contains more than 12 notes. Clear it and try again."
            pause()
        }
    }
    func submit(_ event: EarEvent, state: AppState, expected: EarSession? = nil) {
        guard pending == nil, let session = expected ?? active(state) else { return }
        guard event.kind != .answer || event.skipped || (!invalidTake && capturedFor == session) else {
            error = "Capture this phrase before checking it, or clear the invalid take."
            return
        }
        pending = Pending(expected: session, event: event)
        pause()
        state.microphone.stop()
        save(state: state)
    }
    func save(state: AppState) {
        guard let pending else { return }
        do {
            if library { try state.saveScoreEarEvent(pending) } else { try state.saveEarEvent(pending) }
            self.pending = nil
            error = nil
            clearTake()
        } catch { self.error = error.localizedDescription }
    }
    func discard() {
        pending = nil
        error = nil
        clearTake()
    }
}
extension AppState {
    func openEarPathway() {
        do {
            let finished = try earPractice.active?.projection().stage == .complete
            if earPractice.active == nil || finished {
                guard earInput.pending == nil else {
                    throw MusicError.invalid("Save the pending ear-training answer first.")
                }
                var snapshot = practiceState
                var book = earPractice
                if let previous = book.active {
                    book.completed.append(previous)
                    book.completed = Array(book.completed.suffix(20))
                }
                book.active = EarSession(phrase: EarPhrase.suggested(history: history))
                snapshot.ear = book
                try commitPractice(snapshot)
            }
            audio.stop()
            microphone.stop()
            earInput.clearTake()
            scoreEarInput.clearTake()
            adaptiveInput.pause()
            practicePage = .ear
            destination = .practice
        } catch { message = error.localizedDescription }
    }
    func saveEarEvent(_ pending: EarSessionInput.Pending) throws {
        guard let active = earPractice.active else {
            throw MusicError.invalid("This ear-training session is no longer open.")
        }
        if active.events.contains(where: { $0.id == pending.event.id }) { return }
        guard active == pending.expected else {
            throw MusicError.invalid("The phrase changed. Discard this pending action before continuing.")
        }
        var session = active
        try session.append(pending.event)
        var snapshot = practiceState
        var book = earPractice
        if pending.event.kind == .answer, let result = try session.projection().results.last {
            snapshot.journal.append(result.attempt(sessionID: session.id))
            snapshot.history.record(result, sessionID: session.id)
        }
        book.active = session
        snapshot.ear = book
        try commitPractice(snapshot)
    }
}
