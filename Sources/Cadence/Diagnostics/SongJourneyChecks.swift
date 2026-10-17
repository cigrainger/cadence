// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum SongJourneyDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum EditorNavigationDiagnostics {
    static var original: EditorDocument?
    static var expected: EditorDocument?
    static var selection: UUID?
}

/// Original preview state for the external accessibility runner. Preview data
/// is ephemeral; the runner never opens the learner's library or credentials.
@MainActor enum SongJourneyChecks {
    static func preview(state: AppState) throws {
        _ = try state.startSongJourney(
            instrument: CommandLine.arguments.contains("--song-guitar") ? .guitar : .piano)
        guard let journey = state.selectedSongJourney else {
            throw MusicError.invalid("The original pathway is missing.")
        }
        if !CommandLine.arguments.contains("--song-opening") {
            try state.saveSongOpening(
                journey, notes: journey.openingPrompt.solutions[0], input: .choice,
                assisted: false, verifiedFrom: nil, id: UUID())
        }
        state.songLesson = .changes
        SongJourneyDiagnostics.checks = [
            "sourceLinked": state.scoreEarCurrent(journey.material),
            "eightBarSource": state.libraryPieces.contains { piece in
                guard piece.id == journey.material.pieceID, case .score(let score) = piece.source else { return false }
                return score.barCount == 8
            }, "openMilestones": SongLesson.allCases.count == 5, "noPaidRequests": state.contextCoach.lines.isEmpty,
        ]
        if CommandLine.arguments.contains("--song-arrangement") {
            try state.openSongActivity(.arrange, journey: journey)
        }
    }
}
