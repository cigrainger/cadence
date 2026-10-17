// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var rehearsalTakes: [PianoTake] {
        pianoTakes.takes.filter { $0.rehearsalKey == rehearsalKey }.sorted { $0.pass.date > $1.pass.date }
    }
    func showPhraseShaping(_ show: Bool) throws {
        guard !rehearsalSession.timing.busy, !rehearsalSession.takePlayer.busy else {
            throw MusicError.invalid("Finish playing before changing the workspace.")
        }
        if show, !rehearsalSession.timing.hasUnsavedResult, let record = currentRehearsal, record.stage == .review {
            // Seeing old corrective observations is support too, not just audio.
            try updateRehearsal(record.key) { try $0.expose() }
        }
        rehearsalSession.shaping = show
        if !rehearsalTakes.contains(where: { $0.id == rehearsalSession.selectedTakeID }) {
            rehearsalSession.selectedTakeID = rehearsalTakes.first?.id
        }
    }
    func playPianoTake(_ id: UUID) throws {
        guard !rehearsalSession.timing.busy, !rehearsalSession.timing.hasUnsavedResult,
            let take = rehearsalTakes.first(where: { $0.id == id }), let record = currentRehearsal,
            rehearsalCurrent(record), let piece = libraryPieces.first(where: { $0.id == record.pieceID }),
            RehearsalSource.current(take.pass.plan, in: piece)
        else {
            throw MusicError.invalid("Save the current pass and use a take linked to this unchanged, reviewed score.")
        }
        try updateRehearsal(record.key) { try $0.expose() }
        audio.stop()
        microphone.stop()
        rehearsalSession.takePlayer.play(take)
    }
    func finishPianoTakeListening(_ id: UUID, now: Date = Date()) throws {
        guard rehearsalSession.takePlayer.completedID == id,
            let index = pianoTakes.takes.firstIndex(where: { $0.id == id && $0.rehearsalKey == rehearsalKey })
        else { return }
        var copy = practiceState
        copy.pianoTakes?.takes[index].listenedAt = now
        try commitPractice(copy)
    }
    func reflectOnPianoTake(_ id: UUID, reflection: PhraseReflection, note: String) throws {
        guard let index = pianoTakes.takes.firstIndex(where: { $0.id == id && $0.rehearsalKey == rehearsalKey }),
            pianoTakes.takes[index].listenedAt != nil
        else { throw MusicError.invalid("Listen through this take before reflecting on it.") }
        guard note.count <= 1000 else { throw MusicError.invalid("Keep your listening note to 1,000 characters.") }
        var copy = practiceState
        copy.pianoTakes?.takes[index].reflection = reflection
        copy.pianoTakes?.takes[index].note = note
        try commitPractice(copy)
    }
    func deletePianoTake(_ id: UUID) throws {
        guard !rehearsalSession.takePlayer.busy, !rehearsalSession.timing.busy else {
            throw MusicError.invalid("Stop playback or recording before deleting a take.")
        }
        var copy = practiceState
        copy.pianoTakes?.takes.removeAll { $0.id == id }
        try commitPractice(copy)
        if rehearsalSession.selectedTakeID == id { rehearsalSession.selectedTakeID = rehearsalTakes.first?.id }
        if rehearsalSession.comparisonTakeID == id { rehearsalSession.comparisonTakeID = nil }
    }
}
