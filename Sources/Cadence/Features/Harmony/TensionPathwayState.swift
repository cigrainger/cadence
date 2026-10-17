// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class TensionInput: ObservableObject {
    struct Pending {
        var expected: TensionSession
        var action: TensionAction
        var date = Date()
    }
    @Published var pending: Pending?
    @Published var error: String?
    @Published var feedback: String?
    @Published private(set) var listening = false
    @Published private(set) var notes: [Int] = []
    private var capture = MIDIStepCapture()
    private var expected: TensionSession?
    func pause() {
        listening = false
        expected = nil
        capture.reset()
        notes = []
    }
    func arm(_ state: AppState) {
        guard pending == nil, let session = state.tensionPractice.active, session.skill == .playing, !session.completed,
            session.instrument == .piano, state.tensionCurrent(session.source)
        else { return }
        state.audio.stop()
        pause()
        capture.reset(held: state.midi.keyboard.downNotes)
        expected = session
        listening = true
        error = nil
    }
    func receive(_ update: MIDIUpdate, state: AppState) {
        guard listening else { return }
        guard expected == state.tensionPractice.active, let expected, state.tensionCurrent(expected.source),
            state.destination == .practice, state.practicePage == .tension, !state.audio.isPlaying,
            !state.audio.isPreparing
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
        if let played = capture.receive(update.message, state: update.keyboard) {
            guard played.count == 1 else {
                pause()
                error = "Play one note at a time, releasing each before the next. Start again when ready."
                return
            }
            notes += played
            if notes.count == 2 {
                let answer = notes
                submit(.midi(answer), state: state)
            }
        }
    }
    func submit(_ action: TensionAction, state: AppState) {
        guard pending == nil, let expected = state.tensionPractice.active else { return }
        pending = Pending(expected: expected, action: action)
        pause()
        save(state)
    }
    func save(_ state: AppState) {
        guard let pending else { return }
        do {
            let result = try state.saveTensionAction(pending)
            feedback =
                result?.outcome == .incorrect
                ? "Try that relationship again. This retry stays marked as supported practice." : nil
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
    func tensionCurrent(_ source: TensionSource) -> Bool {
        libraryPieces.first { $0.id == source.pieceID }.map { source.current(in: $0) } ?? false
    }
    func showTension() {
        showPracticeHome()
        practicePage = .tension
    }
    func beginTensionExample(instrument: EditorInstrument) throws {
        var example = try TensionSource.example()
        let fingerprint = LibraryPiece(source: .score(example)).fingerprint
        let matching = editor.documents.first { LibraryPiece(source: .score($0)).fingerprint == fingerprint }
        if let matching {
            example = matching
        } else {
            guard editor.documents.count < 100 else { throw MusicError.invalid("The composition library is full.") }
            // Preserve a learner's edited example and all its source links.
            if editor.documents.contains(where: { $0.id == example.id }) { example.id = UUID() }
            var scores = editor
            scores.documents.append(example)
            try commitScores(scores)
        }
        guard let piece = libraryPieces.first(where: { $0.id == "score:" + example.id.uuidString }) else { return }
        try beginTension(
            piece: piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 3), tonic: Pitch(0),
            instrument: instrument)
    }
    func beginTension(piece: LibraryPiece, scope: PassageScope, tonic: Pitch, instrument: EditorInstrument) throws {
        guard tensionInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending theory answer first.")
        }
        guard let current = libraryPieces.first(where: { $0.id == piece.id }) else {
            throw MusicError.invalid("This piece is no longer in the library.")
        }
        let source = try TensionSource(piece: current, scope: scope, tonic: tonic)
        var snapshot = practiceState
        var book = tensionPractice
        if let previous = book.sessions.first(where: { $0.source.id == source.id && $0.instrument == instrument }) {
            book.activeID = previous.id
        } else {
            guard book.sessions.count < 100 else { throw MusicError.invalid("The theory pathway collection is full.") }
            let session = TensionSession(source: source, instrument: instrument)
            book.sessions.append(session)
            book.activeID = session.id
        }
        snapshot.tension = book
        try commitPractice(snapshot)
        tensionInput.discard()
        showTension()
    }
    func resumeTension(_ id: UUID, skill: TheorySkill? = nil) throws {
        guard tensionInput.pending == nil, let index = tensionPractice.sessions.firstIndex(where: { $0.id == id }),
            tensionCurrent(tensionPractice.sessions[index].source)
        else { throw MusicError.invalid("Save any pending answer, then reopen this lesson from the current score.") }
        var snapshot = practiceState
        var book = tensionPractice
        if let skill { book.sessions[index].beginReview(skill) }
        book.activeID = book.sessions[index].id
        snapshot.tension = book
        try commitPractice(snapshot)
        tensionInput.discard()
        showTension()
    }
    @discardableResult func saveTensionAction(_ pending: TensionInput.Pending) throws -> PracticeAttempt? {
        guard tensionPractice.active == pending.expected,
            let index = tensionPractice.sessions.firstIndex(where: { $0.id == pending.expected.id }),
            tensionCurrent(pending.expected.source)
        else {
            throw MusicError.invalid(
                "The source or session changed. Discard this answer and reopen the current passage.")
        }
        var snapshot = practiceState
        var book = tensionPractice
        var evidence = try book.sessions[index].apply(pending.action, now: pending.date)
        if case .creation = pending.action {
            guard let ending = tensionEnding(pending.expected), ending.events.contains(where: { !$0.isRest }) else {
                throw MusicError.invalid("Write some music in your alternative ending before saving the reflection.")
            }
            try libraryWorkspace.saveScores()
            evidence?.scoreID = ending.id
        }
        if let evidence { snapshot.journal.append(evidence) }
        snapshot.tension = book
        try commitPractice(snapshot)
        return evidence
    }
    func tensionEnding(_ session: TensionSession) -> EditorDocument? {
        editor.documents.first { $0.tensionSource?.id == session.source.id && $0.instrument == session.instrument }
    }
    func openTensionEnding() throws {
        guard tensionInput.pending == nil, let session = tensionPractice.active,
            session.skill == .creating || session.completed, tensionCurrent(session.source)
        else { throw MusicError.invalid("Open the creative step of a current lesson first.") }
        let document: EditorDocument
        if let existing = tensionEnding(session) {
            document = existing
        } else {
            guard editor.documents.count < 100 else { throw MusicError.invalid("The composition library is full.") }
            document = try session.source.answerDocument(instrument: session.instrument)
            var scores = editor
            scores.documents.append(document)
            try commitScores(scores)
        }
        tensionInput.pause()
        audio.stop()
        returnToCompose(document.id)
    }
    func savedAnalysis(_ piece: LibraryPiece) -> ScoreAnalysis? {
        tensionPractice.analyses.first { $0.pieceID == piece.id && $0.fingerprint == piece.fingerprint }
    }
    func saveHarmonicReading(
        piece: LibraryPiece, scope: PassageScope, item: HarmonicAnnotation, expected: HarmonicAnnotation?
    ) throws {
        guard let current = libraryPieces.first(where: { $0.id == piece.id }), current.fingerprint == piece.fingerprint,
            try HarmonyTheory.anchors(piece: current, scope: scope).contains(item.anchor)
        else {
            throw MusicError.invalid(
                "This chord or its reviewed source has changed. Reopen the analysis before saving.")
        }
        var analysis = savedAnalysis(current) ?? ScoreAnalysis(piece: current)
        guard analysis.annotations.first(where: { $0.id == item.id }) == expected else {
            throw MusicError.invalid("This reading changed while you were editing. Reopen it before saving.")
        }
        try analysis.set(item)
        var snapshot = practiceState
        var book = tensionPractice
        if let index = book.analyses.firstIndex(where: { $0.id == analysis.id }) {
            book.analyses[index] = analysis
        } else {
            guard book.analyses.count < 200 else {
                throw MusicError.invalid("The analysis notebook is full. Existing readings are preserved.")
            }
            book.analyses.append(analysis)
        }
        snapshot.tension = book
        try commitPractice(snapshot)
    }
}
