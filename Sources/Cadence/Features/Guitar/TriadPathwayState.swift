// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class TriadInput: ObservableObject {
    struct Pending {
        var expected: TriadSession
        var action: TriadAction
        var date: Date
    }
    @Published var pending: Pending?
    @Published var error: String?
    @Published var feedback: String?
    @Published private(set) var listening = false
    @Published private(set) var notes: [Int] = []
    private var capture = SungPhraseCapture()
    private var expected: TriadSession?
    func pause() {
        listening = false
        expected = nil
        capture = SungPhraseCapture()
    }
    func arm(_ state: AppState) {
        guard pending == nil, let current = state.triadPractice.active, current.stage == .ear,
            state.triadCurrent(current.material)
        else { return }
        state.audio.stop()
        pause()
        notes = []
        error = nil
        expected = current
        listening = true
    }
    func receive(_ pitch: DetectedPitch?, at time: Double, state: AppState) {
        guard listening else { return }
        guard expected == state.triadPractice.active, let expected, state.triadCurrent(expected.material),
            state.destination == .practice, state.practicePage == .triads, !state.audio.isPlaying,
            !state.audio.isPreparing
        else {
            pause()
            state.microphone.stop()
            return
        }
        let safe = pitch.flatMap {
            $0.frequency.isFinite && (10...20000).contains($0.frequency) && $0.confidence.isFinite ? $0 : nil
        }
        capture.receive(midi: safe?.midi, cents: safe?.cents ?? 0, confidence: safe?.confidence ?? 0, at: time)
        notes = capture.notes
        if notes.count >= 2 {
            pause()
            state.microphone.stop()
        }
    }
    func submit(_ action: TriadAction, state: AppState) {
        guard pending == nil, let current = state.triadPractice.active else { return }
        pending = Pending(expected: current, action: action, date: Date())
        pause()
        state.microphone.stop()
        save(state)
    }
    func save(_ state: AppState) {
        guard let pending else { return }
        do {
            let attempt = try state.saveTriadAction(pending)
            feedback =
                attempt.outcome == .incorrect
                ? (attempt.input == .microphone
                    ? "Those pitches differ. Listen again, then pluck each note separately and let it ring."
                    : "Try the lowest sounding note. The inversion is named for that note’s role in the chord.") : nil
            self.pending = nil
            error = nil
            notes = []
        } catch { self.error = error.localizedDescription }
    }
    func discard() {
        pending = nil
        pause()
        notes = []
        error = nil
        feedback = nil
    }
}
extension AppState {
    func triadCurrent(_ material: TriadMaterial) -> Bool {
        libraryPieces.first { $0.id == material.pieceID }.map { material.current(in: $0) } ?? false
    }
    func showTriads() {
        showPracticeHome()
        practicePage = .triads
    }
    func beginTriads(piece: LibraryPiece, scope: PassageScope, group: Int) throws {
        guard triadInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending guitar answer first.")
        }
        guard let current = libraryPieces.first(where: { $0.id == piece.id }) else {
            throw MusicError.invalid("This source piece is no longer in your library.")
        }
        let material = try TriadMaterial(piece: current, scope: scope, tuning: tuning, capo: capo, group: group)
        if let previous = triadPractice.sessions.first(where: { $0.material.id == material.id }) {
            try resumeTriads(previous.id)
            return
        }
        guard triadPractice.sessions.count < 100 else {
            throw MusicError.invalid("The guitar pathway collection is full. Existing sessions are preserved.")
        }
        let session = TriadSession(material: material)
        var snapshot = practiceState
        var book = triadPractice
        book.sessions.append(session)
        book.activeID = session.id
        snapshot.triads = book
        try commitPractice(snapshot)
        triadInput.discard()
        showTriads()
    }
    func resumeTriads(_ id: UUID, restart: Bool = false) throws {
        guard triadInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending guitar answer first.")
        }
        guard let index = triadPractice.sessions.firstIndex(where: { $0.id == id }),
            triadCurrent(triadPractice.sessions[index].material)
        else {
            throw MusicError.invalid("This source changed or needs review. Choose it again to build a new pathway.")
        }
        var snapshot = practiceState
        var book = triadPractice
        if restart { book.sessions[index].restart() }
        book.activeID = book.sessions[index].id
        snapshot.triads = book
        try commitPractice(snapshot)
        triadInput.discard()
        showTriads()
    }
    func saveTriadAction(_ pending: TriadInput.Pending) throws -> PracticeAttempt {
        guard let index = triadPractice.sessions.firstIndex(where: { $0.id == pending.expected.id }),
            triadPractice.active == pending.expected, triadCurrent(pending.expected.material)
        else { throw MusicError.invalid("The source or session changed. Discard this answer and reopen the passage.") }
        var snapshot = practiceState
        var book = triadPractice
        let attempt = try book.sessions[index].apply(pending.action, now: pending.date)
        snapshot.journal.append(attempt)
        snapshot.triads = book
        try commitPractice(snapshot)
        return attempt
    }
    func openTriadAnswer() throws {
        guard triadInput.pending == nil, let session = triadPractice.active,
            [.create, .complete].contains(session.stage), triadCurrent(session.material)
        else { throw MusicError.invalid("Open the creative step of a current pathway first.") }
        // The document owns its source reference; finding it again is idempotent
        // even if practice saving failed after the score was written.
        let document: EditorDocument
        if let existing = editor.documents.first(where: { $0.triadSource?.id == session.material.id }) {
            document = existing
        } else {
            guard editor.documents.count < 100 else { throw MusicError.invalid("The composition library is full.") }
            document = try session.material.answerDocument()
            var scores = editor
            scores.documents.append(document)
            scores.activeID = document.id
            try commitScores(scores)
        }
        triadInput.pause()
        audio.stop()
        microphone.stop()
        returnToCompose(document.id)
    }
}
