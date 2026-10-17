// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import MusicCore

/// The editable library and its metadata, independent of navigation, audio and AI.
/// Editing drafts remain visible on failure; explicit commits publish only on success.
@MainActor final class LibraryWorkspace: ObservableObject {
    @Published var editor = EditorLibrary()
    @Published var studies = StudyLibrary()
    @Published var notebook = PieceNotebook()
    private let storage: WorkspaceStorage
    private let ephemeral: Bool

    init(storage: WorkspaceStorage, ephemeral: Bool = false) {
        self.storage = storage
        self.ephemeral = ephemeral
    }

    var pieces: [LibraryPiece] { LibraryPiece.catalog(scores: editor.documents, studies: studies.studies) }
    var editorError: String? { storage.editor.loadError }
    var studyError: String? { storage.studies.loadError }
    var notebookError: String? { storage.notebook.loadError }

    func load() {
        editor = storage.editor.load(default: EditorLibrary())
        if editorError != nil { editor.documents = [] }
        studies = storage.studies.load(default: StudyLibrary())
        notebook = storage.notebook.load(default: PieceNotebook())
    }

    func record(for piece: LibraryPiece) -> PieceRecord {
        notebook.records[piece.id] ?? PieceRecord(kind: piece.defaultKind)
    }

    func reconcile() {
        guard notebookError == nil else { return }
        notebook.reconcile(pieces)
    }

    func changePiece(_ id: String, _ change: (inout PieceRecord) -> Void) throws {
        if let notebookError { throw MusicError.invalid(notebookError) }
        guard pieces.contains(where: { $0.id == id }) else {
            throw MusicError.invalid("This piece is no longer available in the library.")
        }
        var copy = notebook
        copy.reconcile(pieces)
        guard var record = copy.records[id] else {
            throw MusicError.invalid("This piece is no longer available in the library.")
        }
        change(&record)
        copy.records[id] = record
        _ = try copy.validated()
        if !ephemeral { try storage.notebook.save(copy) }
        notebook = copy
    }

    func commitScores(_ candidate: EditorLibrary) throws {
        if let editorError { throw MusicError.invalid(editorError) }
        _ = try candidate.validated()
        if !ephemeral { try storage.editor.save(candidate) }
        editor = candidate
    }

    /// Commit before selecting a new composition; validation rejects duplicate identities.
    func addComposition(_ document: EditorDocument) throws {
        guard editor.documents.count < 100 else {
            throw MusicError.invalid("Cadence keeps up to 100 editable scores.")
        }
        var copy = editor
        copy.documents.append(document)
        copy.activeID = document.id
        try commitScores(copy)
        reconcile()
    }

    func saveScores() throws { if !ephemeral { try storage.editor.save(editor) } }
    func saveStudies() throws { if !ephemeral { try storage.studies.save(studies) } }
    func saveNotebook() throws {
        reconcile()
        if !ephemeral { try storage.notebook.save(notebook) }
    }
}
