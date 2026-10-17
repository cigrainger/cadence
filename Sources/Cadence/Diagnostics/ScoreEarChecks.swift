// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum ScoreEarDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum ScoreEarChecks {
    /// Original music, never a user's library content, for reproducible UI checks.
    static func document() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .piano)
        doc.title = "An evening turn"
        doc.tempo = 84
        doc.events.removeAll { $0.staff == 1 }
        for (bar, notes) in [[62, 65], [67, 71], [72, 71], [67, 64]].enumerated() {
            doc.events += notes.map { EditorEvent(bar: bar, rhythm: EditorRhythm(960), pitches: [EditorPitch($0)]) }
        }
        doc.harmonies = try ["Dm7", "G7", "Cmaj7", "Cmaj7"].enumerated().map {
            EditorHarmony(bar: $0.offset, symbol: try ChordSymbol.parse($0.element))
        }
        return try doc.validated()
    }
    static func material(_ doc: EditorDocument) throws -> ScoreEarMaterial {
        try ScoreEarMaterial(
            piece: LibraryPiece(source: .score(doc)),
            scope: .init(fromBar: 1, throughBar: 4, partID: "P1", partName: "Piano"), staff: 1, voice: "1")
    }
    static func preview(state: AppState) throws {
        let doc = try document()
        let material = try material(doc)
        let earlier = Date().addingTimeInterval(-86400)
        state.editor.documents.append(doc)
        state.editor.activeID = doc.id
        try state.openScoreEar(material, now: earlier)
        let opening = state.scoreEarPractice
        func event(_ kind: EarEvent.Kind, notes: [Int] = [], date: Date = earlier) throws {
            guard let s = state.scoreEarPractice.active else { throw MusicError.invalid("Missing passage session.") }
            try state.saveScoreEarEvent(.init(expected: s, event: .init(kind, notes: notes, date: date)))
        }
        try event(.heard)
        try event(.imagined)
        try event(.answer, notes: material.melody.map(\.midi))
        try event(.next)
        state.scoreEarInput.arm(state: state)
        var keys = MIDIKeyboardState()
        for note in material.melody.map(\.midi) {
            for message in [MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note)]
            {
                keys.receive(message)
                state.scoreEarInput.receive(.init(message: message, keyboard: keys), state: state)
            }
        }
        var checks = ["capturedExactVoice": state.scoreEarInput.notes == material.melody.map(\.midi)]
        try event(.answer, notes: state.scoreEarInput.notes)
        try event(.next)
        let review = state.scoreEarPractice
        try event(.accompaniment)
        try event(.next)
        checks["sourceLinked"] = state.journal.attempts.allSatisfy {
            $0.pieceID == material.pieceID && $0.scoreFingerprint == material.fingerprint
        }
        checks["learningSupported"] = state.journal.checked.allSatisfy(\.assisted)
        checks["bandUngraded"] = state.journal.attempts.last?.outcome == .skipped
        checks["dueReturn"] = state.practiceReviews().contains { $0.id == material.id }
        try state.openScoreEar(material)
        let returning = state.scoreEarPractice
        checks["independentHidden"] =
            try state.scoreEarPractice.active?.projection().stage == .imagine
            && state.scoreEarPractice.active?.projection().assisted == false
        try event(.hint, date: Date())
        try event(.imagined, date: Date())
        let support = state.scoreEarPractice
        checks["hintSaved"] = try state.scoreEarPractice.active?.projection().assisted == true
        checks["validSnapshot"] = (try? state.practiceState.validated()) != nil
        checks["bandLanes"] = try ScoreAccompaniment(material: material, includeMelody: true).lanes().count == 4
        let args = CommandLine.arguments
        state.scoreEarPractice =
            args.contains("--score-ear-review")
            ? review
            : args.contains("--score-ear-return") ? returning : args.contains("--score-ear-solfege") ? support : opening
        if args.contains("--score-ear-setup") {
            state.libraryLearning = true
            state.showLibraryPiece(material.pieceID)
        } else {
            state.practicePage = .scoreEar
            state.destination = .practice
        }
        state.scoreEarInput.discard()
        if args.contains("--band-preview") {
            state.scoreEarPractice = review
            state.midi.installPreview()
            state.midi.previewInput([.noteOn(channel: 0, note: 71, velocity: 90)])
        }
        if args.contains("--creative-preview") {
            state.scoreEarPractice = review
            let answerID = try state.openCreativeAnswer(review.selectedID!)
            var answer = state.editor.active
            answer.events.removeAll { $0.staff == 1 }
            for (bar, notes) in [[64, 67], [65, 62], [64, 71], [72, 67]].enumerated() {
                answer.events += notes.map {
                    EditorEvent(bar: bar, rhythm: EditorRhythm(960), pitches: [EditorPitch($0)])
                }
            }
            state.editor.replace(answer)
            let fingerprint = LibraryPiece(source: .score(answer)).fingerprint
            try state.finishCreativeAnswer(answerID, listenedFingerprint: fingerprint)
            checks["creativeLinked"] = state.editor.active.responseSource?.material == material
            checks["creativeSaved"] = state.editor.active.responseSource?.isFinished(state.editor.active) == true
            checks["creativeIndependent"] = state.editor.documents.first(where: { $0.id == doc.id }) == doc
            if args.contains("--creative-library") { state.showLibraryPiece("score:" + answerID.uuidString) }
        }
        if args.contains("--full-piece-preview") {
            var long = doc
            long.id = UUID()
            long.title = "A longer conversation"
            try long.insertBars(at: 4, count: 20)
            state.editor.documents.append(long)
            if args.contains("--full-study") {
                let study = MusicStudy(
                    document: try StudyImport.read(Data(EditorXML.encode(long).utf8)), filename: "Full piece.musicxml")
                state.studies.add(study)
                state.openLibraryPiece(.init(source: .study(study)))
                checks["fullPieceOpened"] = state.studyWholePiece
            } else {
                state.openLibraryPiece(.init(source: .score(long)))
                checks["fullPieceOpened"] =
                    state.editorPassageFocus?.wholePiece == true && state.editor.active.barCount == 24
            }
        }
        ScoreEarDiagnostics.checks = checks
    }
}
