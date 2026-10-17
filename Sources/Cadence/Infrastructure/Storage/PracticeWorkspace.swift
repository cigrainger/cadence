// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import MusicCore

/// Owns the single practice snapshot: evidence and its derived review schedule
/// are published together, only after the same atomic write succeeds.
@MainActor final class PracticeWorkspace: ObservableObject {
    @Published var state = PracticeState()
    private let storage: WorkspaceStorage
    private let ephemeral: Bool

    init(storage: WorkspaceStorage, ephemeral: Bool = false) {
        self.storage = storage
        self.ephemeral = ephemeral
    }

    var loadError: String? { storage.practiceError }

    func load() { state = storage.loadPractice() }

    func save() throws {
        if !ephemeral { try storage.savePractice(state) }
    }

    func commit(_ candidate: PracticeState) throws {
        let validated = try candidate.validated()
        if !ephemeral { try storage.savePractice(validated) }
        state = validated
    }

    func record(_ attempt: PracticeAttempt) throws {
        guard attempt.valid else { throw MusicError.invalid("This practice result is invalid.") }
        var copy = state
        copy.journal.append(attempt)
        try commit(copy)
    }

    func record(
        _ attempt: PracticeAttempt, question: PracticeQuestion, correct: Bool,
        firstTry: Bool, revealed: Bool
    ) throws -> Int {
        guard attempt.valid else { throw MusicError.invalid("This practice result is invalid.") }
        var copy = state
        copy.journal.append(attempt)
        let reward = copy.history.record(
            question, correct: correct, firstTry: firstTry,
            revealed: revealed, now: attempt.date, episode: attempt.sessionID, input: attempt.input)
        try commit(copy)
        return reward
    }
}
