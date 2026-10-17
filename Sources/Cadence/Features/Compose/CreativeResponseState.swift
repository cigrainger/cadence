// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func creativeAnswer(_ materialID: String) -> EditorDocument? {
        editor.documents.first { $0.responseSource?.material.id == materialID }
    }
    @discardableResult func openCreativeAnswer(_ sessionID: UUID) throws -> UUID {
        guard scoreEarInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending practice action first.")
        }
        guard let session = scoreEarPractice.sessions.first(where: { $0.id == sessionID }),
            let material = session.opening.material, [.review, .complete].contains(try session.projection().stage)
        else {
            throw MusicError.invalid(
                "Finish the singing and keyboard checks before writing your answer. You can skip a check.")
        }
        let scoreID: UUID
        if let existing = creativeAnswer(material.id) {
            scoreID = existing.id
        } else {
            guard let piece = libraryPieces.first(where: { $0.id == material.pieceID }), scoreEarCurrent(material)
            else { throw MusicError.invalid("Review the source passage again before starting an answer.") }
            guard editor.documents.count < 100 else {
                throw MusicError.invalid("The score library is full. Your existing compositions are preserved.")
            }
            let score = try CreativeResponse(material: material, sessionID: sessionID).makeDocument(piece: piece)
            var copy = editor
            copy.documents.append(score)
            copy.activeID = score.id
            try commitScores(copy)
            scoreID = score.id
        }
        earInput.clearTake()
        scoreEarInput.clearTake()
        returnToCompose(scoreID)
        return scoreID
    }
    func commitScores(_ copy: EditorLibrary) throws {
        _ = try copy.validated()
        if !isPreview { try stores.editor.save(copy) }
        editor = copy
        reconcileLibrary()
        saveErrors.removeValue(forKey: "scores")
    }
    func finishCreativeAnswer(_ id: UUID, listenedFingerprint: String, now: Date = Date()) throws {
        guard let index = editor.documents.firstIndex(where: { $0.id == id }),
            editor.documents[index].responseSource != nil,
            editor.documents[index].events.contains(where: { !$0.pitches.isEmpty })
        else { throw MusicError.invalid("Add a few notes to your answer, then listen to it.") }
        let score = editor.documents[index]
        guard listenedFingerprint == LibraryPiece(source: .score(score)).fingerprint else {
            throw MusicError.invalid("Listen to your latest changes before saving the finished answer.")
        }
        var copy = editor
        copy.documents[index].responseSource?.listenedFingerprint = listenedFingerprint
        copy.documents[index].responseSource?.savedAt = now
        try commitScores(copy)
    }
}
