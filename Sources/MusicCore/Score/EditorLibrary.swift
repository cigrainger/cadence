// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct EditorLibrary: Codable, Equatable, Sendable {
    public var schemaVersion: Int? = 1
    public var documents = [
        EditorDocument.guitarExample, EditorDocument.pianoExample, EditorDocument.fingerstyleExample,
        EditorDocument.innerVoiceExample,
    ]
    public var activeID: UUID?
    public var engine = "OpenSheetMusicDisplay"
    public init() {}
    public func restored() throws -> Self {
        guard schemaVersion == nil || schemaVersion == 1, documents.count <= 100,
            Set(documents.map(\.id)).count == documents.count
        else {
            throw MusicError.invalid("This score library is damaged or needs a newer Cadence.")
        }
        var copy = self
        copy.schemaVersion = 1
        copy.documents = try documents.map { document in
            var restored = document
            restored.recoverPDFQueue()
            return try restored.validated()
        }
        copy.engine = "OpenSheetMusicDisplay"  // Migrate the retired renderer preference without changing the score.
        return copy
    }
    public func validated() throws -> Self {
        guard schemaVersion == nil || schemaVersion == 1, documents.count <= 100,
            Set(documents.map(\.id)).count == documents.count
        else { throw MusicError.invalid("The score library is invalid.") }
        for document in documents { _ = try document.validated() }
        return self
    }
    public var active: EditorDocument { documents.first { $0.id == activeID } ?? documents.first ?? .guitarExample }
    public mutating func replace(_ document: EditorDocument) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = document }
        activeID = document.id
    }
}
