// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

/// Storage ownership and migration are independent of navigation and SwiftUI views.
final class WorkspaceStorage {
    let directory: URL
    let editor: JSONFileStore<EditorLibrary>
    let studies: JSONFileStore<StudyLibrary>
    let notebook: JSONFileStore<PieceNotebook>
    let preferences: JSONFileStore<Preferences>
    let practice: JSONFileStore<PracticeState>
    let courses: JSONFileStore<CourseLibrary>
    private(set) var migrationError: String?

    init(directory: URL) {
        self.directory = directory
        courses = JSONFileStore(
            url: directory.appendingPathComponent("courses.json"), validate: { try $0.validated() },
            restore: { try $0.restored() })
        editor = JSONFileStore(
            url: directory.appendingPathComponent("editor.json"), validate: { try $0.validated() },
            restore: { try $0.restored() })
        studies = JSONFileStore(
            url: directory.appendingPathComponent("studies.json"), validate: { try $0.validated() },
            restore: { try $0.restored() })
        notebook = JSONFileStore(
            url: directory.appendingPathComponent("library.json"), validate: { try $0.validated() })
        preferences = JSONFileStore(
            url: directory.appendingPathComponent("preferences.json"), validate: { try $0.validated() })
        practice = JSONFileStore(
            url: directory.appendingPathComponent("practice-state.json"), validate: { try $0.validated() })
    }

    func loadPractice() -> PracticeState {
        if FileManager.default.fileExists(atPath: practice.url.path) {
            return practice.load(default: PracticeState())
        }
        let history = JSONFileStore<PracticeProgress>(
            url: directory.appendingPathComponent("practice.json"), validate: { try $0.validated() })
        let journal = JSONFileStore<PracticeJournal>(
            url: directory.appendingPathComponent("attempts.json"), validate: { try $0.restored() })
        let learning = JSONFileStore<LearningLibrary>(
            url: directory.appendingPathComponent("learning.json"), validate: { try $0.validated() })
        let legacy = PracticeState(
            history: history.load(default: PracticeProgress()),
            journal: journal.load(default: PracticeJournal()),
            learning: learning.load(default: LearningLibrary()))
        let errors = [history.loadError, journal.loadError, learning.loadError].compactMap { $0 }
        if !errors.isEmpty { migrationError = errors.joined(separator: "\n") }
        // Original migration inputs are never deleted or rewritten by this version.
        return practice.load(default: legacy)
    }

    var practiceError: String? { practice.loadError ?? migrationError }
    func savePractice(_ value: PracticeState) throws {
        if let practiceError { throw MusicError.invalid(practiceError) }
        try practice.save(value)
    }
}

extension Preferences {
    func validated() throws -> Self {
        guard (0..<7).contains(root.letter), (-2...2).contains(root.accidental),
            tuning.pitches.count == 6, tuning.pitches.allSatisfy({ (24...88).contains($0) }),
            (0...9).contains(capo)
        else { throw MusicError.invalid("The saved instrument preferences are invalid.") }
        if let chordRoot {
            guard (0..<7).contains(chordRoot.letter), (-2...2).contains(chordRoot.accidental) else {
                throw MusicError.invalid("The saved chord root is invalid.")
            }
        }
        if let metronome { _ = try metronome.validated() }
        if let tuner { _ = try tuner.validated() }
        return self
    }
}
