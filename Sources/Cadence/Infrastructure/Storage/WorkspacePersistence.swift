// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
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
    var practiceState: PracticeState {
        PracticeState(
            history: history, journal: journal, learning: learning, smooth: smoothPractice, ear: earPractice,
            scoreEar: scoreEarPractice, rehearsal: rehearsals, pianoTakes: pianoTakes, triads: triadPractice,
            tension: tensionPractice, reharm: reharmPractice)
    }

    func loadWorkspace() {
        courses = stores.courses.load(default: CourseLibrary())
        editor = stores.editor.load(default: EditorLibrary())
        if editorStorageError != nil { editor.documents = [] }
        studies = stores.studies.load(default: StudyLibrary())
        notebook = stores.notebook.load(default: PieceNotebook())
        let practice = stores.loadPractice()
        history = practice.history
        journal = practice.journal
        learning = practice.learning
        smoothPractice = practice.smooth ?? SmoothPractice()
        earPractice = practice.ear ?? EarPractice()
        scoreEarPractice = practice.scoreEar ?? ScoreEarPractice()
        rehearsals = practice.rehearsal ?? PieceRehearsalBook()
        pianoTakes = practice.pianoTakes ?? PianoTakeBook()
        triadPractice = practice.triads ?? TriadPractice()
        tensionPractice = practice.tension ?? TensionPractice()
        reharmPractice = practice.reharm ?? ReharmPractice()
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
        attempt("practice") { try stores.savePractice(practiceState) }
        attempt("courses") { try stores.courses.save(courses) }
        attempt("preferences") { try stores.preferences.save(preferences) }
        attempt("studies") { try stores.studies.save(studies) }
        attempt("scores") { try stores.editor.save(editor) }
        attempt("library notes") {
            reconcileLibrary()
            try stores.notebook.save(notebook)
        }
        saveErrors = errors
        if !errors.isEmpty { message = errors.keys.sorted().compactMap { errors[$0] }.joined(separator: "\n") }
        return errors.isEmpty
    }

    func commitPractice(_ copy: PracticeState) throws {
        _ = try copy.validated()
        if !isPreview { try stores.savePractice(copy) }
        history = copy.history
        journal = copy.journal
        learning = copy.learning
        smoothPractice = copy.smooth ?? SmoothPractice()
        earPractice = copy.ear ?? EarPractice()
        scoreEarPractice = copy.scoreEar ?? ScoreEarPractice()
        rehearsals = copy.rehearsal ?? PieceRehearsalBook()
        pianoTakes = copy.pianoTakes ?? PianoTakeBook()
        triadPractice = copy.triads ?? TriadPractice()
        tensionPractice = copy.tension ?? TensionPractice()
        reharmPractice = copy.reharm ?? ReharmPractice()
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
            var copy = practiceState
            let attempt = questionAttempt(
                question, outcome: correct ? .correct : .incorrect, input: input,
                assisted: revealed || !firstTry, played: played,
                ordinal: ordinal ?? (firstTry ? 1 : 2), selectedChoice: selectedChoice)
            guard attempt.valid else { throw MusicError.invalid("This practice result is invalid.") }
            copy.journal.append(attempt)
            let reward = copy.history.record(
                question, correct: correct, firstTry: firstTry, revealed: revealed,
                now: attempt.date, episode: practiceSessionID, input: input)
            try commitPractice(copy)
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
            guard attempt.valid else { throw MusicError.invalid("This practice result is invalid.") }
            var copy = practiceState
            copy.journal.append(attempt)
            try commitPractice(copy)
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
