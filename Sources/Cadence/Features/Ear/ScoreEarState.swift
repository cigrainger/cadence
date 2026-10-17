// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func scoreEarCurrent(_ material: ScoreEarMaterial) -> Bool {
        libraryPieces.first(where: { $0.id == material.pieceID }).map { material.isCurrent(in: $0) } ?? false
    }
    func openScoreEar(_ material: ScoreEarMaterial, now: Date = Date()) throws {
        guard scoreEarCurrent(material) else {
            throw MusicError.invalid(
                "This score or its review status changed. Review a fresh passage from the library; the old history is preserved."
            )
        }
        if let pending = scoreEarInput.pending {
            guard pending.expected.opening.material?.id == material.id,
                scoreEarPractice.active?.id == pending.expected.id
            else {
                throw MusicError.invalid("Save or discard the pending passage action before opening another session.")
            }
        } else {
            var copy = practiceState
            var book = scoreEarPractice
            try book.open(material, now: now)
            copy.scoreEar = book
            try commitPractice(copy)
        }
        audio.stop()
        microphone.stop()
        earInput.clearTake()
        scoreEarInput.clearTake()
        adaptiveInput.pause()
        practicePage = .scoreEar
        destination = .practice
    }
    func resumeScoreEarSession(_ id: UUID) throws {
        guard scoreEarPractice.sessions.contains(where: { $0.id == id }) else {
            throw MusicError.invalid("This saved session is unavailable.")
        }
        guard scoreEarInput.pending == nil || scoreEarInput.pending?.expected.id == id else {
            throw MusicError.invalid("Save or discard the pending passage action first.")
        }
        if scoreEarPractice.selectedID != id {
            var copy = practiceState
            var book = scoreEarPractice
            book.selectedID = id
            copy.scoreEar = book
            try commitPractice(copy)
        }
        audio.stop()
        microphone.stop()
        earInput.clearTake()
        scoreEarInput.clearTake()
        adaptiveInput.pause()
        practicePage = .scoreEar
        destination = .practice
    }
    func saveScoreEarEvent(_ pending: EarSessionInput.Pending) throws {
        guard let active = scoreEarPractice.active, let material = active.opening.material,
            scoreEarCurrent(material)
        else {
            throw MusicError.invalid(
                "The linked passage is changed, missing or no longer reviewed. Your previous history is preserved. Return to the library to review the new version."
            )
        }
        if active.events.contains(where: { $0.id == pending.event.id }) { return }
        guard active == pending.expected else {
            throw MusicError.invalid("This passage session changed. Discard the pending action before continuing.")
        }
        var session = active
        try session.append(pending.event)
        var copy = practiceState
        var book = scoreEarPractice
        if pending.event.kind == .answer, let result = try session.projection().results.last {
            copy.journal.append(result.attempt(sessionID: session.id))
            copy.history.record(result, sessionID: session.id)
        }
        if pending.event.kind == .accompaniment {
            var attempt = PracticeAttempt(
                sessionID: session.id, activityID: material.id + ":band",
                title: String((material.title + " · accompaniment").prefix(500)),
                skills: ["Playing with accompaniment"], input: .selfReport, outcome: .skipped, assisted: true,
                date: pending.event.date)
            attempt.id = pending.event.id
            attempt.pieceID = material.pieceID
            attempt.scoreFingerprint = material.fingerprint
            attempt.selectedChoice = "Opened a play-along; no performance or completion grade was inferred."
            copy.journal.append(attempt)
        }
        guard let index = book.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        book.sessions[index] = session
        copy.scoreEar = book
        try commitPractice(copy)
    }
    func scoreEarReview(_ material: ScoreEarMaterial) -> ReviewSchedule {
        var result =
            [PracticeInput.singing, .midi].compactMap {
                history.cards[EarPhrase(material: material).activity($0)]?.review
            }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.first ?? ReviewSchedule()
        // A return asks for recall after time away. Short practice remains open
        // in the library, but never masquerades as delayed recall in the queue.
        if let earliest = scoreEarPractice.returnDate(material.id) {
            result.due = max(result.due ?? earliest, earliest)
        }
        return result
    }
    var scoreEarLatest: [EarSession] {
        var seen = Set<String>()
        return scoreEarPractice.sessions.reversed().filter { session in
            guard let material = session.opening.material else { return false }
            return seen.insert(material.id).inserted
        }
    }
}
