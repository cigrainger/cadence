// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class PickingInput: ObservableObject {
    struct Pending {
        var expected: PickingSession
        var action: PickingAction
        var date: Date
    }
    @Published var pending: Pending?
    @Published var error: String?
    @Published private(set) var frames: [PerformanceObservation] = []
    @Published private(set) var recording = false
    private var expected: PickingSession?
    func pause() {
        recording = false
        expected = nil
    }
    func arm(_ state: AppState) {
        guard pending == nil, let s = state.pickingPractice.active, s.stage == .chord, state.pickingCurrent(s.material)
        else { return }
        state.stopAllPlayback()
        frames = []
        expected = s
        recording = true
        error = nil
    }
    func receive(_ frame: PerformanceObservation, state: AppState) {
        guard recording else { return }
        guard expected == state.pickingPractice.active, state.practicePage == .picking, state.destination == .practice,
            let expected, state.pickingCurrent(expected.material), !state.audio.isPlaying, !state.audio.isPreparing
        else {
            pause()
            state.microphone.stop()
            return
        }
        guard frame.valid else { return }
        frames.append(frame)
        if frames.count >= 120 { finish(state) }
    }
    func finish(_ state: AppState) {
        guard recording, let expected, expected == state.pickingPractice.active,
            state.destination == .practice, state.practicePage == .picking, state.pickingCurrent(expected.material),
            !frames.isEmpty
        else {
            pause()
            state.microphone.stop()
            return
        }
        let shape = expected.material.frets[0]
        let string = shape.indices.first { shape[$0] >= 0 }!
        let take = MonophonicTake(
            target: expected.material.tuning.pitches[string] + expected.material.capo + shape[string], frames: frames)
        pause()
        state.microphone.stop()
        submit(.observation(take), state: state)
    }
    func submit(_ action: PickingAction, state: AppState) {
        guard pending == nil, let s = state.pickingPractice.active else { return }
        pause()
        state.microphone.stop()
        pending = .init(expected: s, action: action, date: Date())
        save(state)
    }
    func save(_ state: AppState) {
        guard let pending else { return }
        do {
            try state.savePickingAction(pending)
            self.pending = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func discard() {
        pause()
        pending = nil
        frames = []
        error = nil
    }
}
extension AppState {
    var pickingPractice: PickingPractice { practiceWorkspace.state.picking ?? PickingPractice() }
    func pickingCurrent(_ material: PickingMaterial) -> Bool {
        libraryPieces.first { $0.id == material.pieceID }.map { material.current(in: $0) } ?? false
    }
    func showPicking() {
        showPracticeHome()
        practicePage = .picking
    }
    func beginPicking(piece: LibraryPiece, scope: PassageScope, style: PickingStyle) throws {
        guard pickingInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending picking result first.")
        }
        guard let piece = libraryPieces.first(where: { $0.id == piece.id }) else {
            throw MusicError.invalid("The source is no longer in the library.")
        }
        let material = try PickingMaterial(piece: piece, scope: scope, tuning: tuning, capo: capo)
        var snapshot = practiceState
        var book = pickingPractice
        if let existing = book.sessions.first(where: { $0.material.id == material.id && $0.style == style }) {
            book.activeID = existing.id
        } else {
            guard book.sessions.count < 100 else { throw MusicError.invalid("The picking pathway collection is full.") }
            let session = PickingSession(material: material, style: style)
            book.sessions.append(session)
            book.activeID = session.id
        }
        snapshot.picking = book
        try commitPractice(snapshot)
        stopAllPlayback()
        pickingInput.discard()
        showPicking()
    }
    func savePickingAction(_ pending: PickingInput.Pending) throws {
        guard let index = pickingPractice.sessions.firstIndex(where: { $0.id == pending.expected.id }),
            pickingPractice.active == pending.expected, pickingCurrent(pending.expected.material)
        else {
            throw MusicError.invalid("The source or task changed. Discard this result and choose the current passage.")
        }
        var snapshot = practiceState
        var book = pickingPractice
        let attempt = try book.sessions[index].apply(pending.action, now: pending.date)
        snapshot.journal.append(attempt)
        snapshot.picking = book
        try commitPractice(snapshot)
    }
    func resumePicking(_ id: UUID, independent: Bool) throws {
        guard pickingInput.pending == nil, let index = pickingPractice.sessions.firstIndex(where: { $0.id == id }),
            pickingCurrent(pickingPractice.sessions[index].material)
        else { throw MusicError.invalid("Save pending work and review the current source before returning.") }
        var snapshot = practiceState
        var book = pickingPractice
        if independent { book.sessions[index].beginReturn() }
        book.activeID = id
        snapshot.picking = book
        try commitPractice(snapshot)
        stopAllPlayback()
        pickingInput.discard()
        showPicking()
    }
    func savePickingArrangement(style: PickingStyle, tempo: Int, backbeat: Bool) throws {
        guard pickingInput.pending == nil, let session = pickingPractice.active,
            [.create, .complete].contains(session.stage), pickingCurrent(session.material)
        else { throw MusicError.invalid("Open the creative step of a current picking pathway first.") }
        let document: EditorDocument
        if let existing = editor.documents.first(where: {
            $0.pickingSource?.id == session.material.id && $0.pickingStyle == style
        }) {
            document = existing
        } else {
            guard editor.documents.count < 100 else { throw MusicError.invalid("The composition library is full.") }
            document = try session.material.document(style: style, tempo: tempo, strongerBackbeat: backbeat)
            var scores = editor
            scores.documents.append(document)
            scores.activeID = document.id
            try commitScores(scores)
        }
        stopAllPlayback()
        returnToCompose(document.id)
    }
}
