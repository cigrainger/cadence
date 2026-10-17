// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class AdaptiveSessionInput: ObservableObject {
    struct Pending {
        var expected: SmoothSession
        var notes: [Int]
        var input: PracticeInput
        var skipped: Bool
        var verifiedFrom: [Int]? = nil
        var id = UUID()
        var date = Date()
    }
    @Published private(set) var listening = false
    @Published private(set) var pending: Pending?
    @Published var error: String?
    @Published private(set) var verifiedFrom: [Int]?
    @Published private(set) var preparationMessage: String?
    private var capture = MIDIStepCapture()
    var waitingForRelease: Bool { capture.waitingForRelease }
    func pause(held: Set<Int> = []) {
        listening = false
        capture.reset(held: held)
        verifiedFrom = nil
        preparationMessage = nil
    }
    func listen(held: Set<Int>) {
        guard pending == nil else { return }
        capture.reset(held: held)
        verifiedFrom = nil
        preparationMessage = nil
        listening = true
    }
    func receive(_ update: MIDIUpdate, state: AppState, active: Bool) {
        guard active, !state.audio.isPlaying, !state.audio.isPreparing else {
            pause(held: update.keyboard.downNotes)
            return
        }
        guard listening, pending == nil, state.smoothPractice.active?.current != nil,
            state.smoothPractice.active?.awaitingAdvance == false
        else { return }
        if update.message == .reset {
            pause(held: update.keyboard.downNotes)
            return
        }
        if case .control(_, let number, _) = update.message, number == 120 || number == 123 {
            pause(held: update.keyboard.downNotes)
            return
        }
        if let notes = capture.receive(update.message, state: update.keyboard) { checkKeyboard(notes, state: state) }
    }
    func checkKeyboard(_ notes: [Int], state: AppState) {
        guard pending == nil, let session = state.smoothPractice.active, let prompt = session.current,
            !session.awaitingAdvance
        else { return }
        if verifiedFrom == nil {
            if notes.sorted() == prompt.from {
                verifiedFrom = prompt.from
                preparationMessage = "Starting shape checked. Now play the next chord."
                error = nil
            } else {
                preparationMessage = "First find the starting shape shown in the score, in those octaves."
            }
        } else {
            submit(notes, state: state, input: .midi)
        }
    }
    func checkHeld(_ notes: [Int], state: AppState) {
        // Explicit held-key checking takes over from release capture, so the
        // eventual release cannot also submit the starting shape as an answer.
        listening = false
        capture.reset(held: Set(notes))
        checkKeyboard(notes, state: state)
    }
    func submit(_ notes: [Int], state: AppState, input: PracticeInput, skipped: Bool = false) {
        guard pending == nil, let session = state.smoothPractice.active, session.current != nil,
            !session.awaitingAdvance
        else { return }
        guard input != .midi || skipped || verifiedFrom == session.current?.from else {
            error = "Play and check the starting shape first."
            return
        }
        pending = .init(expected: session, notes: notes, input: input, skipped: skipped, verifiedFrom: verifiedFrom)
        pause(held: state.midi.keyboard.downNotes)
        save(state: state)
    }
    func save(state: AppState) {
        guard let pending else { return }
        do {
            try state.saveAdaptiveAnswer(pending)
            self.pending = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
    func discard() {
        pending = nil
        error = nil
        pause()
    }
}

extension AppState {
    func openAdaptiveSession(_ pathwayID: UUID, fromPractice: Bool = false) throws {
        guard adaptiveInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending keyboard answer first.")
        }
        guard let pathway = courses.musicalPathways?.first(where: { $0.id == pathwayID }),
            pathway.recipe == SmoothChangesRecipe.identifier
        else { throw MusicError.invalid("This session belongs to the smooth-changes pathway.") }
        if smoothPractice.active == nil || smoothPractice.active?.phase == .summary {
            var snapshot = practiceState
            var book = smoothPractice
            let prompts = (0...2).map { SmoothSession.focusPrompt($0) }
            let due = ReviewQueue.ordered(
                Array(prompts.enumerated()),
                review: { history.cards[$0.element.reviewID() + ":midi"]?.review ?? ReviewSchedule() },
                order: { $0.offset < $1.offset })
            let focus = due.first?.offset ?? 0
            let reason =
                due.first.flatMap { history.cards[$0.element.reviewID() + ":midi"] }.map {
                    $0.review.reason() + ". We can revisit " + prompts[focus].title + "."
                } ?? "Begin with a familiar change, then choose what needs care."
            let candidates = (book.completed + [book.active].compactMap { $0 }).filter { $0.pathwayID == pathwayID }
                .flatMap(\.responses).filter { !$0.skipped }
            let dueResponses = ReviewQueue.ordered(
                candidates,
                review: {
                    history.cards[$0.attempt(sessionID: UUID(), pathwayID: pathwayID).activityID]?.review
                        ?? ReviewSchedule()
                }, order: { $0.date < $1.date })
            let review = dueResponses.first?.prompt
            try book.begin(
                SmoothSession(
                    pathwayID: pathwayID, minutes: pathway.minutes, focusIndex: focus, focusReason: reason,
                    openingReview: review, openingReviewInput: dueResponses.first?.input))
            snapshot.smooth = book
            try commitPractice(snapshot)
        }
        guard smoothPractice.active?.pathwayID == pathwayID else {
            throw MusicError.invalid("Resume the current session from its pathway first.")
        }
        try showAdaptiveWorkspace(inPractice: fromPractice)
    }
    func changeAdaptiveSession(_ action: (inout SmoothSession) throws -> Void) throws {
        guard adaptiveInput.pending == nil, var session = smoothPractice.active else {
            throw MusicError.invalid("Save or discard the pending answer before changing the session.")
        }
        try action(&session)
        _ = try session.validated()
        var snapshot = practiceState
        var book = smoothPractice
        book.active = session
        snapshot.smooth = book
        try commitPractice(snapshot)
        adaptiveInput.pause(held: midi.keyboard.downNotes)
    }
    func saveAdaptiveAnswer(_ pending: AdaptiveSessionInput.Pending) throws {
        guard let active = smoothPractice.active else { throw MusicError.invalid("This session is no longer open.") }
        // Save-only retries keep the same answer ID; navigation or a stale callback
        // cannot write an answer against another prompt.
        if active.responses.contains(where: { $0.id == pending.id }) { return }
        guard active == pending.expected,
            courses.musicalPathways?.contains(where: {
                $0.id == active.pathwayID && $0.recipe == SmoothChangesRecipe.identifier
            }) == true
        else {
            throw MusicError.invalid("The session changed. Discard this pending answer and resume the current prompt.")
        }
        guard pending.input != .midi || pending.skipped || pending.verifiedFrom == active.current?.from else {
            throw MusicError.invalid("The MIDI starting shape was not checked for this answer.")
        }
        var next = active
        let response = try next.answer(
            pending.notes, now: pending.date, skipped: pending.skipped, input: pending.input, id: pending.id)
        let attempt = response.attempt(sessionID: next.id, pathwayID: next.pathwayID)
        var snapshot = practiceState
        var book = smoothPractice
        snapshot.journal.append(attempt)
        try snapshot.history.record(response, sessionID: next.id, pathwayID: next.pathwayID)
        book.active = next
        snapshot.smooth = book
        try commitPractice(snapshot)
    }
    func finishAdaptiveSession(reflection: String, includeComposition: Bool) throws {
        guard let session = smoothPractice.active,
            let pathway = courses.musicalPathways?.first(where: { $0.id == session.pathwayID })
        else { throw MusicError.invalid("This pathway is unavailable.") }
        var score: EditorDocument?
        if includeComposition {
            guard let id = pathway.compositionID, let document = editor.documents.first(where: { $0.id == id }),
                document.events.contains(where: { !$0.pitches.isEmpty }),
                !reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MusicError.invalid(
                    "Add music to your composition, listen back and describe a choice before finishing with it.")
            }
            try libraryWorkspace.saveScores()
            score = document
        }
        try changeAdaptiveSession {
            try $0.finish(
                reflection: reflection, compositionID: score?.id,
                fingerprint: score.map { LibraryPiece(source: .score($0)).fingerprint })
        }
    }
    func adaptiveComposition() -> EditorDocument? {
        guard let session = smoothPractice.active,
            let id = courses.musicalPathways?.first(where: { $0.id == session.pathwayID })?.compositionID
        else { return nil }
        return editor.documents.first { $0.id == id }
    }
}
