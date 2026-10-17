// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class SongOpeningInput: ObservableObject {
    struct Pending {
        var journey: SongJourney
        var notes: [Int]
        var input: PracticeInput
        var assisted: Bool
        var verifiedFrom: [Int]?
        var id = UUID()
        var date = Date()
    }
    @Published private(set) var listening = false
    @Published private(set) var verifiedFrom: [Int]?
    @Published private(set) var pending: Pending?
    @Published var hint = false
    @Published var message: String?
    private var capture = MIDIStepCapture()

    func listen(held: Set<Int>) {
        guard pending == nil else { return }
        capture.reset(held: held)
        verifiedFrom = nil
        listening = true
        message = "Play C4–E4–G4, release, then find a nearby F major chord."
    }
    func pause() {
        listening = false
        verifiedFrom = nil
        capture.reset(held: [])
    }
    func receive(_ update: MIDIUpdate, state: AppState, journey: SongJourney) {
        guard listening, pending == nil, state.destination == .practice, state.practicePage == .songJourney,
            !state.audio.isPlaying, !state.audio.isPreparing
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
        if let notes = capture.receive(update.message, state: update.keyboard) {
            if verifiedFrom == nil {
                if notes.sorted() == journey.openingPrompt.from {
                    verifiedFrom = notes.sorted()
                    message = "Starting shape checked. Now find a nearby F major chord."
                } else {
                    message = "First play the starting shape C4–E4–G4, then release it."
                }
            } else {
                submit(notes, input: .midi, journey: journey, state: state)
            }
        }
    }
    func submit(_ notes: [Int], input: PracticeInput, journey: SongJourney, state: AppState) {
        guard pending == nil else { return }
        pending = .init(journey: journey, notes: notes, input: input, assisted: hint, verifiedFrom: verifiedFrom)
        listening = false
        save(state: state)
    }
    func save(state: AppState) {
        guard let pending else { return }
        do {
            try state.saveSongOpening(
                pending.journey, notes: pending.notes, input: pending.input,
                assisted: pending.assisted, verifiedFrom: pending.verifiedFrom, id: pending.id, now: pending.date)
            message = pending.journey.openingPrompt.judge(pending.notes).message
            self.pending = nil
            pause()
        } catch { message = error.localizedDescription }
    }
    func discard() {
        pending = nil
        message = nil
        pause()
    }
}
