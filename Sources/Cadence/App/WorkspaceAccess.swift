// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore

// Compatibility access for existing feature bindings. These are projections, not
// duplicated state; new workflows can depend on the relevant workspace directly.
extension AppState {
    var courses: CourseLibrary {
        get { courseWorkspace.library }
        set { courseWorkspace.library = newValue }
    }
    var history: PracticeProgress {
        get { practiceWorkspace.state.history }
        set { practiceWorkspace.state.history = newValue }
    }
    var journal: PracticeJournal {
        get { practiceWorkspace.state.journal }
        set { practiceWorkspace.state.journal = newValue }
    }
    var learning: LearningLibrary {
        get { practiceWorkspace.state.learning }
        set { practiceWorkspace.state.learning = newValue }
    }
    var smoothPractice: SmoothPractice {
        get { practiceWorkspace.state.smooth ?? SmoothPractice() }
        set { practiceWorkspace.state.smooth = newValue }
    }
    var earPractice: EarPractice {
        get { practiceWorkspace.state.ear ?? EarPractice() }
        set { practiceWorkspace.state.ear = newValue }
    }
    var scoreEarPractice: ScoreEarPractice {
        get { practiceWorkspace.state.scoreEar ?? ScoreEarPractice() }
        set { practiceWorkspace.state.scoreEar = newValue }
    }
    var rehearsals: PieceRehearsalBook {
        get { practiceWorkspace.state.rehearsal ?? PieceRehearsalBook() }
        set { practiceWorkspace.state.rehearsal = newValue }
    }
    var pianoTakes: PianoTakeBook {
        get { practiceWorkspace.state.pianoTakes ?? PianoTakeBook() }
        set { practiceWorkspace.state.pianoTakes = newValue }
    }
    var triadPractice: TriadPractice {
        get { practiceWorkspace.state.triads ?? TriadPractice() }
        set { practiceWorkspace.state.triads = newValue }
    }
    var tensionPractice: TensionPractice {
        get { practiceWorkspace.state.tension ?? TensionPractice() }
        set { practiceWorkspace.state.tension = newValue }
    }
    var reharmPractice: ReharmPractice {
        get { practiceWorkspace.state.reharm ?? ReharmPractice() }
        set { practiceWorkspace.state.reharm = newValue }
    }
    var editor: EditorLibrary {
        get { libraryWorkspace.editor }
        set { libraryWorkspace.editor = newValue }
    }
    var studies: StudyLibrary {
        get { libraryWorkspace.studies }
        set { libraryWorkspace.studies = newValue }
    }
    var notebook: PieceNotebook {
        get { libraryWorkspace.notebook }
        set { libraryWorkspace.notebook = newValue }
    }
}
