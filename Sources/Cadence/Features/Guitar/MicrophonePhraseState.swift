// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var microphonePhrases: MicrophonePhrasePractice { practiceWorkspace.state.microphonePhrases ?? .init() }

    func validateMicrophonePhrase(_ plan: MicrophonePhrasePlan) throws {
        guard let piece = libraryPieces.first(where: { $0.id == plan.material.pieceID }), plan.isCurrent(in: piece)
        else {
            throw MusicError.invalid(
                "This score changed or is no longer reviewed. Your earlier takes are kept; choose its current phrase.")
        }
    }

    func flushMicrophoneExposure() throws {
        guard microphonePhraseSession.retryExposureSave() else {
            throw MusicError.invalid(microphonePhraseSession.error ?? "Save interrupted practice before continuing.")
        }
    }

    func showMicrophonePhrases() {
        stopAllPlayback()
        practicePage = .microphonePhrase
        destination = .practice
    }

    func openMicrophonePhrase(_ material: ScoreEarMaterial) throws {
        guard !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Keep or discard the waiting microphone take before opening another phrase.")
        }
        guard let piece = libraryPieces.first(where: { $0.id == material.pieceID }) else {
            throw MusicError.invalid("This piece is no longer in the library.")
        }
        let plan = try MicrophonePhrasePlan(
            material: material, tempo: min(140, max(50, Int(material.tempo.rounded()))), source: piece)
        var copy = practiceState
        var book = microphonePhrases
        try book.open(plan)
        copy.microphonePhrases = book
        try commitPractice(copy)
        stopAllPlayback()
        try microphonePhraseSession.select(plan)
        practicePage = .microphonePhrase
        destination = .practice
    }

    func resumeMicrophonePhrase(_ id: String, independent: Bool = false) throws {
        guard !microphonePhraseSession.hasUnsavedTake,
            let progress = microphonePhrases.sessions.first(where: { $0.id == id })
        else { throw MusicError.invalid("Keep or discard pending work before resuming a saved phrase.") }
        try validateMicrophonePhrase(progress.sourcePlan)
        if independent {
            guard progress.baseline != nil, let available = microphonePhrases.returnDate(id), Date() >= available else {
                throw MusicError.invalid(
                    "Leave at least 20 hours after practice or a demonstration for an independent return. Guided practice is always open."
                )
            }
        }
        let plan = try progress.plan(
            tempo: (independent ? progress.baseline?.plan.tempo : progress.latest?.plan.tempo)
                ?? progress.sourcePlan.tempo,
            mode: independent ? .independent : .opening)
        var copy = practiceState
        var book = microphonePhrases
        try book.open(plan)
        copy.microphonePhrases = book
        try commitPractice(copy)
        stopAllPlayback()
        try microphonePhraseSession.select(plan)
        practicePage = .microphonePhrase
        destination = .practice
    }

    func saveMicrophoneTake(_ take: MicrophonePhraseTake) throws {
        var copy = practiceState
        var book = microphonePhrases
        if (try? validateMicrophonePhrase(take.plan)) != nil, !take.isArchivalOnly {
            let attempt = try book.record(take)
            if let attempt { copy.journal.append(attempt) }
        } else {
            var archived = take
            archived.archivalOnly = true
            try book.archive(archived)
        }
        copy.microphonePhrases = book
        try commitPractice(copy)
    }

    func noteMicrophonePractice(_ plan: MicrophonePhrasePlan, at date: Date) throws {
        var snapshot = practiceState
        var book = microphonePhrases
        try book.notePractice(materialID: plan.key, now: date)
        snapshot.microphonePhrases = book
        try commitPractice(snapshot)
    }

    func discardMicrophoneTake() throws {
        guard let take = microphonePhraseSession.pending else { return }
        var snapshot = practiceState
        var book = microphonePhrases
        try book.notePractice(materialID: take.plan.key, now: take.date)
        snapshot.microphonePhrases = book
        try commitPractice(snapshot)
        microphonePhraseSession.discard()
    }

    func startMicrophoneTake(_ plan: MicrophonePhrasePlan, pitchOnly: Bool) throws {
        guard !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Keep or discard the waiting take first.")
        }
        stopAllPlayback()
        try flushMicrophoneExposure()
        try validateMicrophonePhrase(plan)
        if plan.mode == .independent {
            guard let progress = microphonePhrases.sessions.first(where: { $0.id == plan.key }),
                let baseline = progress.baseline, plan.isFullPhrase, plan.tempo == baseline.plan.tempo,
                let available = microphonePhrases.returnDate(plan.key), Date() >= available
            else {
                throw MusicError.invalid("This independent return is not due yet. Use a guided pass today.")
            }
        }
        microphonePhraseSession.start(
            plan, microphone: microphone, pitchOnly: pitchOnly,
            interrupted: { [weak self] date in
                guard let self else { throw MusicError.invalid("This practice workspace closed.") }
                try noteMicrophonePractice(plan, at: date)
            }
        ) { [weak self] in
            guard let self else { throw MusicError.invalid("This practice workspace closed.") }
            try validateMicrophonePhrase(plan)
        }
    }

    func hearMicrophonePhrase(_ plan: MicrophonePhrasePlan, play: ((Score) -> Void)? = nil) throws {
        guard !microphonePhraseSession.busy, !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Finish or keep your take before hearing the guide.")
        }
        try flushMicrophoneExposure()
        try validateMicrophonePhrase(plan)
        var copy = practiceState
        var book = microphonePhrases
        try book.noteDemonstration(materialID: plan.key)
        copy.microphonePhrases = book
        try commitPractice(copy)
        stopAllPlayback()
        let guided = try plan.configured(mode: plan.mode == .independent ? .context : plan.mode)
        try microphonePhraseSession.select(guided)
        let start = Double(plan.fromBar - plan.material.scope.fromBar) * Double(plan.beatsPerBar)
        let end = start + plan.timed.length
        let notes = plan.material.melody.filter { $0.start >= start && $0.start < end }.map { source in
            var note = source
            note.start -= start
            return note
        }
        let score = Score(tempo: Double(plan.tempo), notes: notes)
        if let play { play(score) } else { audio.play(score) }
    }

    func addMicrophoneExample() throws {
        guard !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Keep or discard the waiting take first.")
        }
        let title = "A little room to answer"
        let document: EditorDocument
        if let existing = editor.documents.first(where: { $0.id == MicrophonePhraseExample.id }) {
            document = existing
        } else {
            document = try MicrophonePhraseExample.document()
            var scores = editor
            guard scores.documents.count < 100 else { throw MusicError.invalid("The composition library is full.") }
            scores.documents.append(document)
            try commitScores(scores)
        }
        let piece = LibraryPiece(source: .score(document))
        let material = try ScoreEarMaterial(
            piece: piece, scope: .init(fromBar: 1, throughBar: 4, partID: "P1", partName: title), staff: 1, voice: "1")
        try openMicrophonePhrase(material)
    }
}

/// Original, redistributable music. The stable ID makes the explicit example
/// action reopen the learner's copy rather than replacing their edits.
enum MicrophonePhraseExample {
    static let id = UUID(uuidString: "D571C1C7-D6DE-4A54-9398-140472C2A947")!
    static func document() throws -> EditorDocument {
        var score = try EditorDocument.blank(instrument: .guitar, bars: 4)
        score.id = id
        score.title = "A little room to answer"
        score.tempo = 80
        score.events = [52, 55, 57, 55, 53, 52, 50, 48].enumerated().map { index, midi in
            let string = score.tuning.pitches.indices.last { score.tuning.pitches[$0] <= midi }!
            return EditorEvent(
                bar: index / 2, rhythm: .init(960),
                pitches: [.init(midi, string: string, fret: midi - score.tuning.pitches[string])])
        }
        return try score.validated()
    }
}
