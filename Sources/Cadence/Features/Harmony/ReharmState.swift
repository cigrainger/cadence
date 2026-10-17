// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class ReharmInput: ObservableObject {
    struct Pending {
        var expected: ReharmSession
        var action: ReharmAction
        var date = Date()
    }
    @Published var pending: Pending?
    @Published var error: String?
    @Published var feedback: String?
    @Published private(set) var listening = false
    @Published private(set) var groups: [[Int]] = []
    private var capture = MIDIStepCapture()
    private var expected: ReharmSession?
    func pause() {
        listening = false
        expected = nil
        capture.reset()
        groups = []
    }
    func arm(_ state: AppState) {
        guard pending == nil, state.reharmTransport.pending == nil, let s = state.reharmPractice.active,
            s.skill == .playing, !s.completed, s.instrument == .piano, state.reharmCurrent(s.source)
        else { return }
        state.audio.stop()
        state.reharmTransport.stop()
        pause()
        capture.reset(held: state.midi.keyboard.downNotes)
        expected = s
        listening = true
        error = nil
    }
    func receive(_ update: MIDIUpdate, state: AppState) {
        guard listening else { return }
        guard expected == state.reharmPractice.active, let expected, state.reharmCurrent(expected.source),
            state.destination == .practice, state.practicePage == .reharm, !state.audio.isPlaying,
            !state.audio.isPreparing, !state.reharmTransport.busy
        else {
            pause()
            return
        }
        if update.message == .reset {
            pause()
            return
        }
        if case .control(_, let n, _) = update.message, n == 120 || n == 123 {
            pause()
            return
        }
        if let notes = capture.receive(update.message, state: update.keyboard) {
            guard notes.count <= 8 else {
                pause()
                error = "Use up to eight keys for each guide-tone pair, releasing before the next change."
                return
            }
            groups.append(notes)
            if groups.count == expected.source.changes.count { submit(.guides(groups), state: state) }
        }
    }
    func submit(_ action: ReharmAction, state: AppState) {
        guard pending == nil, !state.reharmTransport.busy, state.reharmTransport.pending == nil,
            let expected = state.reharmPractice.active
        else { return }
        pending = .init(expected: expected, action: action)
        pause()
        save(state)
    }
    func save(_ state: AppState) {
        guard let pending else { return }
        do {
            let result = try state.saveReharmAction(pending)
            feedback =
                result?.outcome == .incorrect
                ? "Try the relationship again. This retry stays marked as supported practice." : nil
            self.pending = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func discard() {
        pending = nil
        error = nil
        feedback = nil
        pause()
    }
}

extension AppState {
    func reharmCurrent(_ source: ReharmSource) -> Bool {
        libraryPieces.first { $0.id == source.pieceID }.map { source.current(in: $0) } ?? false
    }
    func showReharm() {
        showPracticeHome()
        practicePage = .reharm
    }
    func beginReharmExample(instrument: EditorInstrument) throws {
        try requireReharmIdle()
        var example = try ReharmSource.example()
        let fingerprint = LibraryPiece(source: .score(example)).fingerprint
        if let matching = editor.documents.first(where: { LibraryPiece(source: .score($0)).fingerprint == fingerprint })
        {
            example = matching
        } else {
            guard editor.documents.count < 100 else { throw MusicError.invalid("The composition library is full.") }
            if editor.documents.contains(where: { $0.id == example.id }) { example.id = UUID() }
            var scores = editor
            scores.documents.append(example)
            try commitScores(scores)
        }
        guard let piece = libraryPieces.first(where: { $0.id == "score:" + example.id.uuidString }) else { return }
        try beginReharm(
            piece: piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 3), tonic: Pitch(0),
            instrument: instrument)
    }
    func beginReharm(piece: LibraryPiece, scope: PassageScope, tonic: Pitch, instrument: EditorInstrument) throws {
        try requireReharmIdle()
        guard let current = libraryPieces.first(where: { $0.id == piece.id }) else {
            throw MusicError.invalid("This piece is no longer in the library.")
        }
        let source = try ReharmSource(piece: current, scope: scope, tonic: tonic)
        // Check that a full editable alternative is possible before teaching a
        // lesson whose creative step would otherwise fail halfway through.
        _ = try source.alternative(in: current)
        var snapshot = practiceState
        var book = reharmPractice
        if let previous = book.sessions.first(where: { $0.source.id == source.id && $0.instrument == instrument }) {
            book.activeID = previous.id
        } else {
            guard book.sessions.count < 100 else { throw MusicError.invalid("The jazz study collection is full.") }
            let session = ReharmSession(source: source, instrument: instrument)
            book.sessions.append(session)
            book.activeID = session.id
        }
        snapshot.reharm = book
        try commitPractice(snapshot)
        reharmInput.discard()
        showReharm()
    }
    func requireReharmIdle() throws {
        guard reharmInput.pending == nil, reharmTransport.pending == nil, !reharmTransport.busy else {
            throw MusicError.invalid(
                "Stop playback, then save or discard your pending jazz answer or improvisation first.")
        }
    }
    func resumeReharm(_ id: UUID, skill: TheorySkill? = nil) throws {
        try requireReharmIdle()
        guard let index = reharmPractice.sessions.firstIndex(where: { $0.id == id }),
            reharmCurrent(reharmPractice.sessions[index].source)
        else { throw MusicError.invalid("Reopen this jazz study from its current, reviewed score.") }
        var snapshot = practiceState
        var book = reharmPractice
        if let skill { book.sessions[index].beginReview(skill) }
        book.activeID = book.sessions[index].id
        snapshot.reharm = book
        try commitPractice(snapshot)
        reharmInput.discard()
        showReharm()
    }
    @discardableResult func saveReharmAction(_ pending: ReharmInput.Pending) throws -> PracticeAttempt? {
        guard reharmPractice.active == pending.expected,
            let index = reharmPractice.sessions.firstIndex(where: { $0.id == pending.expected.id }),
            reharmCurrent(pending.expected.source)
        else {
            throw MusicError.invalid("The source or study changed. Discard this answer and reopen the current passage.")
        }
        var snapshot = practiceState
        var book = reharmPractice
        var evidence = try book.sessions[index].apply(pending.action, now: pending.date)
        if case .creation = pending.action {
            guard let alternative = reharmAlternative(pending.expected.source) else {
                throw MusicError.invalid("Save your reharmonisation before finishing.")
            }
            if pending.expected.instrument == .piano {
                guard
                    book.takes.contains(where: {
                        $0.sessionID == pending.expected.id && $0.source == pending.expected.source && $0.listened
                    })
                else {
                    throw MusicError.invalid(
                        "Record, save and listen through an improvisation in this session before reflecting.")
                }
            }
            if !isPreview { try stores.editor.save(editor) }
            evidence?.scoreID = alternative.id
        }
        if let evidence { snapshot.journal.append(evidence) }
        snapshot.reharm = book
        try commitPractice(snapshot)
        return evidence
    }
    func reharmAlternative(_ source: ReharmSource) -> EditorDocument? {
        editor.documents.first { $0.reharmSource?.id == source.id }
    }
    @discardableResult func saveReharmAlternative() throws -> EditorDocument {
        try requireReharmIdle()
        guard let session = reharmPractice.active, reharmCurrent(session.source),
            let piece = libraryPieces.first(where: { $0.id == session.source.pieceID })
        else { throw MusicError.invalid("Open a current jazz study first.") }
        if let existing = reharmAlternative(session.source) { return existing }
        guard editor.documents.count < 100 else {
            throw MusicError.invalid("The score library is full. Your existing compositions are preserved.")
        }
        let document = try session.source.alternative(in: piece)
        var scores = editor
        scores.documents.append(document)
        try commitScores(scores)
        return document
    }
    func saveReharmTake() throws {
        guard let take = reharmTransport.pending, let expected = reharmTransport.expected,
            reharmPractice.active == expected, take.sessionID == expected.id, take.source == expected.source,
            reharmCurrent(take.source)
        else {
            throw MusicError.invalid(
                "The source or session changed. This recording remains available to discard; it cannot be attached to different music."
            )
        }
        var snapshot = practiceState
        var book = reharmPractice
        try book.append(take)
        snapshot.reharm = book
        try commitPractice(snapshot)
        reharmTransport.acceptSaved()
    }
    func markReharmTakeListened(_ id: UUID) throws {
        guard reharmTransport.completedTakeID == id, let index = reharmPractice.takes.firstIndex(where: { $0.id == id })
        else { return }
        var snapshot = practiceState
        snapshot.reharm?.takes[index].listened = true
        try commitPractice(snapshot)
    }
    func deleteReharmTake(_ id: UUID) throws {
        try requireReharmIdle()
        var snapshot = practiceState
        snapshot.reharm?.takes.removeAll { $0.id == id }
        try commitPractice(snapshot)
    }
}
