// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var practicedConceptCount: Int { Set(history.cards.keys).union(journal.attempts.map(\.activityID)).count }
    var practicedDayCount: Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return Set(history.days).union(journal.attempts.map { formatter.string(from: $0.date) }).count
    }
    var storageWarnings: [String] {
        [
            editorStorageError, studyStorageError, libraryStorageError, stores.practiceError,
            stores.preferences.loadError, stores.courses.loadError,
        ]
        .compactMap { $0 } + saveErrors.keys.sorted().compactMap { saveErrors[$0] }
    }
    var storageStatus: String {
        storageWarnings.isEmpty ? "Stored on this Mac" : "Some work is not saved"
    }
    var practiceState: PracticeState { practiceWorkspace.state }

    func loadWorkspace() {
        courseWorkspace.load()
        libraryWorkspace.load()
        practiceWorkspace.load()
        let prefs = stores.preferences.load(default: preferences)
        root = prefs.root
        scale = prefs.scale
        quality = prefs.quality
        tuning = prefs.tuning
        capo = prefs.capo
        leftHanded = prefs.leftHanded
        showDegrees = prefs.showDegrees
        showRewards = prefs.showRewards
        comparison = prefs.comparison
        chordRoot = prefs.chordRoot
        showSolfege = prefs.showSolfege ?? true
        metronome = prefs.metronome ?? MetronomeSettings()
        tuner = prefs.tuner ?? TunerSettings()
        ScoreRevision.migrate(learning: &learning, notebook: &notebook, pieces: libraryPieces)
    }

    /// Each independent store gets a save attempt, even when another store fails.
    @discardableResult func save() -> Bool {
        guard !isPreview else { return true }
        var errors: [String: String] = [:]
        func attempt(_ name: String, _ action: () throws -> Void) {
            do { try action() } catch { errors[name] = "Could not save \(name): " + error.localizedDescription }
        }
        attempt("practice") { try practiceWorkspace.save() }
        attempt("courses") { try courseWorkspace.save() }
        attempt("preferences") { try stores.preferences.save(preferences) }
        attempt("studies") { try libraryWorkspace.saveStudies() }
        attempt("scores") { try libraryWorkspace.saveScores() }
        attempt("library notes") {
            try libraryWorkspace.saveNotebook()
        }
        saveErrors = errors
        if !errors.isEmpty { message = errors.keys.sorted().compactMap { errors[$0] }.joined(separator: "\n") }
        return errors.isEmpty
    }

    func commitPractice(_ copy: PracticeState) throws {
        try practiceWorkspace.commit(copy)
        saveErrors.removeValue(forKey: "practice")
    }

    func commitLearning(_ copy: LearningLibrary) throws {
        var snapshot = practiceState
        snapshot.learning = copy
        try commitPractice(snapshot)
    }

    func questionAttempt(
        _ question: PracticeQuestion, outcome: PracticeOutcome, input: PracticeInput,
        assisted: Bool, played: [Int], ordinal: Int?, selectedChoice: String?
    ) -> PracticeAttempt {
        PracticeAttempt(
            sessionID: practiceSessionID, activityID: question.id, title: question.title,
            skills: [question.exercise.rawValue], input: input, outcome: outcome,
            assisted: assisted, ordinal: ordinal, selectedChoice: selectedChoice,
            expectedChoice: input == .choice && question.choices.indices.contains(question.answer)
                ? question.choices[question.answer] : nil,
            keyPC: root.pc, played: played,
            target: question.exercise == .functional
                ? question.target.map { [$0] } ?? []
                : question.singingNotes.map { $0.map(\.midi) } ?? question.target.map { [$0] } ?? [])
    }

    /// A missing reward means the answer was not committed; the view keeps it open.
    func record(
        _ question: PracticeQuestion, correct: Bool, firstTry: Bool, revealed: Bool,
        input: PracticeInput = .choice, played: [Int] = [], ordinal: Int? = nil,
        selectedChoice: String? = nil
    ) -> Int? {
        do {
            let attempt = questionAttempt(
                question, outcome: correct ? .correct : .incorrect, input: input,
                assisted: revealed || !firstTry, played: played,
                ordinal: ordinal ?? (firstTry ? 1 : 2), selectedChoice: selectedChoice)
            let reward = try practiceWorkspace.record(
                attempt, question: question, correct: correct,
                firstTry: firstTry, revealed: revealed)
            saveErrors.removeValue(forKey: "practice")
            return reward
        } catch {
            saveErrors["practice"] = error.localizedDescription
            message =
                "This answer could not be saved. Try again after restoring access to your data. "
                + error.localizedDescription
            return nil
        }
    }

    @discardableResult func recordAttempt(_ attempt: PracticeAttempt) -> Bool {
        do {
            try practiceWorkspace.record(attempt)
            saveErrors.removeValue(forKey: "practice")
            return true
        } catch {
            saveErrors["practice"] = error.localizedDescription
            message = "This result could not be saved. " + error.localizedDescription
            return false
        }
    }

    @discardableResult func recordEvidence(
        _ question: PracticeQuestion, outcome: PracticeOutcome,
        input: PracticeInput = .choice, assisted: Bool = false,
        played: [Int] = [], ordinal: Int? = nil, selectedChoice: String? = nil
    ) -> Bool {
        recordAttempt(
            questionAttempt(
                question, outcome: outcome, input: input, assisted: assisted,
                played: played, ordinal: ordinal, selectedChoice: selectedChoice))
    }

    @discardableResult func recordChord(
        _ chord: PlayedChord, notes: [Int], correct: Bool, assisted: Bool, ordinal: Int = 1
    ) -> Bool {
        recordAttempt(
            PracticeAttempt(
                sessionID: practiceSessionID, activityID: chord.id,
                title: "\(chord.title) · \(chord.inversionLabel)",
                skills: ["Chord playing", chord.quality.rawValue, "Inversion \(chord.inversion)"],
                input: .midi, outcome: correct ? .correct : .incorrect, assisted: assisted,
                ordinal: ordinal, keyPC: chord.root.pc, played: notes, target: chord.reference))
    }
}
