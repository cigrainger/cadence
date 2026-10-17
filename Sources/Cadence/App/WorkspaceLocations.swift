// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

@MainActor final class LibraryBrowserState: ObservableObject {
    @Published var category: PieceKind?
    @Published var query = ""
    @Published var favorites = false
    @Published var order = "Recently opened"
    var locations: [String: PieceNotebookLocation] = [:]
    func matches(_ piece: LibraryPiece, record: PieceRecord) -> Bool {
        (category == nil || record.kind == category) && (!favorites || record.favorite)
            && (query.isEmpty
                || (piece.title + " " + record.composer + " " + record.tags + " " + piece.instrument)
                    .localizedCaseInsensitiveContains(query))
    }
    func reveal(_ piece: LibraryPiece, record: PieceRecord) {
        guard !matches(piece, record: record) else { return }
        category = nil
        query = ""
        favorites = false
    }
}

struct PieceNotebookLocation {
    var tab: String
    var from: Int
    var through: Int
    var partID: String
    var prompt: String
    var includeProfile: Bool
    var analysisID: UUID?
}

/// Transient editing position and undo history. The document itself stays in
/// LibraryWorkspace; navigation must never publish another score copy.
struct EditorLocation {
    var selectedID: UUID?
    var pitchID: UUID?
    var from: Int
    var through: Int
    var wholePiece: Bool
    var session: EditorSession
    var writing: Bool
    var rhythm: EditorRhythm
    var octave: Int
}

struct LearningPlanDraft {
    var showingBuilder: Bool
    var focus: LearningFocus
    var target: String
    var detail: String
    var revision: LearningPathway?
    var requestedStudy: StudyReference?
    var changes: String
    var status: String
    var expandedSteps: Set<Int>
    var completedID: UUID?
}
