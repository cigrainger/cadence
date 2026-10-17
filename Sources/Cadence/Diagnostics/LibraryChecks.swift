// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum LibraryDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum LibraryChecks {
    static func outline() -> PieceAnalysisOutline {
        PieceAnalysisOutline(
            summary:
                "A short melody is a good place to connect reading, pulse and comfortable movement. Use these four bars to listen for an even line, then focus on the change of subdivision in bar 3.",
            observations: [
                PieceObservation(
                    title: "A steady line, then a change of subdivision",
                    detail:
                        "The opening bars move in quarter notes. Bar 3 introduces a triplet group: keep the underlying pulse steady while fitting three equal notes into its span.",
                    fromBar: 1, throughBar: 3)
            ],
            practice: [
                PiecePracticeStep(
                    title: "Give the triplet room",
                    instructions:
                        "Listen to bar 3, tap the pulse, and sing its first three notes evenly. Then play it slowly before reconnecting it to bar 4.",
                    readyWhen: "The triplet feels even, and the following notes arrive without a rush.", fromBar: 3,
                    throughBar: 4)
            ],
            caveats: [
                "Preview example: this saved coaching text was authored locally for UI testing, not returned by a model.",
                "Check the editable draft against the original before relying on note-specific advice.",
            ])
    }
    static func preview(state: AppState) throws {
        var imported = EditorDocument.guitarExample
        imported.title = "Quiet steps · reading study"
        imported.pdfSource = PDFScoreSource(
            filename: "Original guitar reading study.pdf", page: 1, model: PDFImportModel.sol.rawValue,
            warnings: ["Check the original before marking this page reviewed."])
        var own = EditorDocument.pianoExample
        own.title = "An idea for a rainy evening"
        state.editor.documents += [imported, own]
        state.studies.add(try ComposePractice.make(imported, from: 2, through: 3))
        state.reconcileLibrary()
        let id = "score:" + imported.id.uuidString
        var record = state.notebook.records[id]!
        record.composer = "Cadence · original study"
        record.tags = "Reading, rhythm, guitar"
        record.goal = "Read a short melody fluently and keep triplets even."
        record.notes = "Start gently. Listen to bar 3 before playing it."
        record.favorite = true
        record.stage = .learning
        let snap = try PieceSnapshot(piece: LibraryPiece(source: .score(imported)), from: 0, through: 3)
        record.analyses = [
            SavedPieceAnalysis(snapshot: snap, model: "Local preview fixture", goal: record.goal, outline: outline())
        ]
        record.conversation = [
            PieceExchange(
                snapshot: snap, model: "Local preview fixture",
                question: "How can I stop rushing the triplet in bar 3?",
                answer:
                    "First tap the steady pulse and speak three evenly spaced syllables across the triplet's span. Sing those notes, then try the same motion on one comfortable string position.\n\nLoop bars 3–4 slowly enough that the first note after the triplet lands calmly. This is a local preview example, not a model response."
            )
        ]
        state.notebook.records[id] = record
        state.librarySelection = id
        state.destination = .library
        if CommandLine.arguments.contains("--library-stale") {
            try state.editor.documents[state.editor.documents.count - 2].setPitch(imported.events[0].id, midi: 61)
        }
        LibraryDiagnostics.checks["libraryGroupsExistingPieces"] =
            state.libraryPieces.count == state.editor.documents.count
        LibraryDiagnostics.checks["libraryPracticeCopyLinked"] =
            state.studies.studies.last?.sourceEditor?.scoreID == imported.id
    }
    static func wait(_ session: PieceCoachSession) async throws {
        let end = Date().addingTimeInterval(5)
        while session.busy && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !session.busy else {
            session.cancel()
            throw MusicError.invalid("The local library check did not finish.")
        }
    }
    static func verify(directory: URL) async throws -> [String: Bool] {
        let state = AppState(storageOverride: directory)
        state.reconcileLibrary()
        let score = state.editor.documents[0]
        let piece = LibraryPiece(source: .score(score))
        let snap = try PieceSnapshot(piece: piece, from: 0, through: 3)
        var checks = ["libraryExistingExamples": state.notebook.records.values.allSatisfy { $0.kind == .example }]
        try state.changePiece(piece.id) {
            $0.kind = .composition
            $0.favorite = true
            $0.goal = "Steady triplets"
            $0.notes = "Keep relaxed"
        }
        state.save()
        let reopened = AppState(storageOverride: directory)
        checks["libraryNotesPersist"] =
            reopened.notebook == state.notebook && reopened.notebook.records[piece.id]?.goal == "Steady triplets"
        state.practiseEditor(score, from: 1, through: 2)
        checks["libraryNoDuplicatePracticePiece"] = state.libraryPieces.count == state.editor.documents.count
        let session = PieceCoachSession()
        let analysis = SavedPieceAnalysis(
            snapshot: snap, model: "test-model", goal: "Steady triplets", outline: outline())
        session.run(state: state, pieceID: piece.id) { .analysis(analysis) }
        try await wait(session)
        checks["libraryAnalysisSavedToPiece"] =
            state.notebook.records[piece.id]?.analyses.last == analysis
            && state.notebook.records.filter { $0.key != piece.id }.values.allSatisfy { $0.analyses.isEmpty }
        let before = state.notebook
        session.run(state: state, pieceID: piece.id) {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .analysis(analysis)
        }
        await Task.yield()
        session.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        checks["libraryCancelledReplyNotSaved"] = state.notebook == before && !session.busy
        session.run(state: state, pieceID: piece.id) { throw MusicError.invalid("Fixture: provider failure") }
        try await wait(session)
        checks["libraryFailureKeepsPriorAnalysis"] = state.notebook == before && session.error != nil
        let exchange = PieceExchange(
            snapshot: snap, model: "test-model", question: "Help with bar 3",
            answer: "Try singing the subdivision first.")
        session.run(state: state, pieceID: piece.id) { .exchange(exchange) }
        try await wait(session)
        let reloaded = AppState(storageOverride: directory)
        checks["libraryConversationPersists"] = reloaded.notebook.records[piece.id]?.conversation.last == exchange
        state.openLibraryPiece(piece, from: 2, through: 3, practise: true)
        checks["libraryPracticeLinksUseBars"] =
            state.studies.active?.from == 2 && state.studies.active?.through == 3 && state.destination == .studies
        state.openLibraryPiece(piece, from: 1, through: 2)
        checks["libraryEditorLinksUseBars"] =
            state.editorPassageFocus?.from == 1 && state.editorPassageFocus?.through == 2
            && state.destination == .editor
        let url = directory.appendingPathComponent("library.json")
        let saved = try Data(contentsOf: url)
        let previous = state.notebook
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try state.changePiece(piece.id) { $0.notes = "Unsaved change" }
            checks["libraryFailedSaveAtomic"] = false
        } catch { checks["libraryFailedSaveAtomic"] = state.notebook == previous }
        let newReply = PieceExchange(
            snapshot: snap, model: "test", question: "A follow-up", answer: "Keep the pulse steady.")
        session.run(state: state, pieceID: piece.id) { .exchange(newReply) }
        try await wait(session)
        checks["libraryUnsavedReplyRetained"] = session.pending != nil && state.notebook == previous
        try FileManager.default.removeItem(at: url)
        try saved.write(to: url, options: .atomic)
        session.save(state: state)
        checks["libraryReplySavedWithoutNewRequest"] =
            session.pending == nil && state.notebook.records[piece.id]?.conversation.last == newReply
        let damaged = Data("{future-or-damaged-library}".utf8)
        try damaged.write(to: url, options: .atomic)
        let blocked = AppState(storageOverride: directory)
        blocked.save()
        let preserved = try Data(contentsOf: url)
        checks["libraryDamagedNotesPreserved"] = blocked.libraryStorageError != nil && preserved == damaged
        try saved.write(to: url, options: .atomic)
        state.midi.shutdown()
        reopened.midi.shutdown()
        reloaded.midi.shutdown()
        blocked.midi.shutdown()
        return checks
    }
}
