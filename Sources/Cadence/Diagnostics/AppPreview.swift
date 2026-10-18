// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func configurePreview() {
        let preview = isPreview
        if let argument = CommandLine.arguments.firstIndex(of: "--screen"), argument + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[argument + 1] {
            case "explore": destination = .explore
            case "library": destination = .library
            case "editor": destination = .editor
            case "tools": destination = .tools
            case "studies": destination = .studies
            case "chords": destination = .chords
            case "practice":
                destination = .practice
                practicePage = .exercises
            case "coach": destination = .plans
            default: break
            }
        }
        if preview && CommandLine.arguments.contains("--smooth-preview") {
            do { try SmoothPathwayChecks.preview(state: self) } catch {
                SmoothPathwayDiagnostics.checks["previewBuilt"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--adaptive-preview") {
            do { try AdaptiveSessionChecks.preview(state: self) } catch {
                AdaptiveSessionDiagnostics.checks["previewBuilt"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--course-preview") {
            try? CourseChecks.preview(state: self, ready: CommandLine.arguments.contains("--course-ready"))
        }
        if preview
            && (CommandLine.arguments.contains("--guided-practice-check")
                || (destination == .studies && CommandLine.arguments.contains("--timed-practice-check")))
        {
            editor.activeID = editor.documents.first { $0.instrument == .piano }?.id
            practiseEditor(editor.active, from: 0, through: 3)
            guidedStudyID = studies.active?.id
            if CommandLine.arguments.contains("--timed-practice-check"), let id = studies.active?.id {
                editStudy(id) { $0.staff = 1 }
                timedStudyID = id
            }
        }
        if preview && CommandLine.arguments.contains("--vision-compound") {
            let doc = VisionExamples.compound
            editor.documents.append(doc)
            editor.activeID = doc.id
        }
        if preview && CommandLine.arguments.contains("--poly-editor") {
            let doc: EditorDocument =
                CommandLine.arguments.contains("--piano-editor") ? .innerVoiceExample : .fingerstyleExample
            editor.documents.append(doc)
            editor.activeID = doc.id
        }
        if preview && !CommandLine.arguments.contains("--poly-editor")
            && CommandLine.arguments.contains("--piano-editor")
        {
            editor.activeID = editor.documents.first { $0.instrument == .piano }?.id
        }
        if preview && CommandLine.arguments.contains("--harmony-check") {
            var doc = EditorDocument.leadSheetExample
            if CommandLine.arguments.contains("--piano-editor") {
                doc = .pianoExample
                doc.harmonies = EditorDocument.leadSheetExample.harmonies
            }
            editor.documents.append(doc)
            editor.activeID = doc.id
        }
        if preview
            && (CommandLine.arguments.contains("--changes-check")
                || CommandLine.arguments.contains("--timed-changes-check"))
        {
            if CommandLine.arguments.contains("--changes-piece") {
                let doc = EditorDocument.leadSheetExample
                editor.documents.append(doc)
                editor.activeID = doc.id
                if let plan = try? ChangesSource(piece: LibraryPiece(source: .score(doc)), from: 0, through: 3).plan(
                    staff: 1)
                {
                    openChanges(plan)
                }
            } else {
                openChanges()
            }
            if CommandLine.arguments.contains("--timed-changes-check") { showTimedChanges = true }
        }
        if preview && CommandLine.arguments.contains("--long-editor") {
            var doc = editor.active
            if let copy = try? doc.excerpt(0...3) { try? doc.paste(copy, at: 4, inserting: true) }
            editor.replace(doc)
        }
        if preview && CommandLine.arguments.contains("--compound-editor"),
            var doc = try? EditorDocument.blank(instrument: editor.active.instrument, bars: 8, meter: EditorMeter(6, 8))
        {
            doc.title = "A little six-eight idea"
            for bar in 0..<8 {
                for staff in 1...doc.staffCount {
                    if let first = doc.inBar(bar, staff: staff).first {
                        try? doc.setRhythm(first.id, EditorRhythm(480, dotted: true))
                        try? doc.setPitch(first.id, midi: staff == 2 ? 48 : 60 + bar % 5)
                        if let second = doc.inBar(bar, staff: staff).last, second.id != first.id {
                            try? doc.setPitch(second.id, midi: staff == 2 ? 55 : 64 + bar % 5)
                        }
                    }
                }
            }
            editor.documents.append(doc)
            editor.activeID = doc.id
        }
        if preview && !CommandLine.arguments.contains("--guided-practice-check")
            && !CommandLine.arguments.contains("--timed-practice-check")
            && (destination == .studies || CommandLine.arguments.contains("--study-coach")
                || CommandLine.arguments.contains("--study-pathway"))
        {
            addExampleStudy()
            if CommandLine.arguments.contains("--study-mid"), let id = studies.active?.id {
                editStudy(id) {
                    $0.select(from: 1, through: 2)
                    $0.speed = 0.65
                }
            }
            if CommandLine.arguments.contains("--study-coach") {
                destination = .studies
                ask("How can I keep the bass ringing while playing this melody?", study: studies.active?.reference)
            }
            if CommandLine.arguments.contains("--study-pathway") {
                pendingStudyPathway = studies.active?.reference
                destination = .plans
            }
        }
        if preview && CommandLine.arguments.contains("--editor-focus") {
            editorPassageFocus = EditorPassageFocus(documentID: editor.active.id, from: 1, through: 2)
        }
        if preview && CommandLine.arguments.contains("--passage-practice") {
            practiseEditor(editor.active, from: 1, through: 2, speed: 0.75)
            if let study = studies.active {
                var book = PassagePracticeBook()
                var progress = book.progress(for: study)
                progress.targetBPM = 105
                try? progress.record(60, date: Date(timeIntervalSince1970: 1_791_889_200))
                try? progress.record(67.5, date: Date(timeIntervalSince1970: 1_791_975_600))
                book.set(progress)
                editStudy(study.id) { $0.practiceBook = book }
            }
        }
        if preview && CommandLine.arguments.contains("--pdf-batch-preview") { try? PDFBatchChecks.preview(state: self) }
        if preview && CommandLine.arguments.contains("--library-preview") { try? LibraryChecks.preview(state: self) }
        if preview && CommandLine.arguments.contains("--piece-pathway") { try? PiecePathwayChecks.preview(state: self) }
        if preview && CommandLine.arguments.contains("--no-solfege") { showSolfege = false }
        if preview && CommandLine.arguments.contains("--pathway") { learning = LearningPreview.library }
        if CommandLine.arguments.contains("--dorian") {
            root = Pitch(1)
            scale = .dorian
            comparison = .minor
        }
        if preview && CommandLine.arguments.contains("--course-score-review"), let course = courses.courses.first,
            let link = course.exercises.first
        {
            courseReturn = .init(courseID: course.id, lessonID: link.lessonID)
            editor.activeID = link.scoreID
            pdfReviewPage = editor.active.pdfSource?.page
            destination = .editor
        }
        if preview && CommandLine.arguments.contains("--reharm-preview") {
            do { try ReharmChecks.preview(state: self) } catch {
                ReharmDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--tension-preview") {
            do { try TensionChecks.preview(state: self) } catch {
                TensionDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--ear-daily-preview") {
            do { try EarDailyChecks.preview(self) } catch {
                EarDailyDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--microphone-phrase-preview") {
            do { try MicrophonePhraseChecks.preview(self) } catch {
                MicrophonePhraseDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--picking-preview") {
            do { try PickingChecks.preview(self) } catch {
                PickingDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--triad-preview") {
            do { try TriadChecks.preview(state: self) } catch {
                TriadDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--flow-preview") {
            do { try FlowPracticeChecks.preview(state: self) } catch {
                FlowPracticeDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--hands-preview") {
            do { try HandsTogetherChecks.preview(state: self) } catch {
                HandsTogetherDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--shape-preview") {
            do { try ShapePhraseChecks.preview(state: self) } catch {
                ShapePhraseDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--rehearsal-preview") {
            do { try PieceRehearsalChecks.preview(state: self) } catch {
                RehearsalDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--playalong-preview") {
            do { try PlayAlongChecks.preview(state: self) } catch {
                PlayAlongDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--score-ear-preview") {
            do { try ScoreEarChecks.preview(state: self) } catch {
                ScoreEarDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--ear-preview") {
            do { try EarPathwayChecks.preview(state: self) } catch {
                EarPathwayDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--groove-preview") {
            practicePage = .groove
            destination = .practice
        }
        if preview && CommandLine.arguments.contains("--practice-home") { showPracticeHome() }
        if preview && CommandLine.arguments.contains("--practice-adaptive") {
            try? showAdaptiveWorkspace(inPractice: true)
        }
        if preview && CommandLine.arguments.contains("--pdf-review-check") {
            var document = editor.active
            if let index = CommandLine.arguments.firstIndex(of: "--pdf-draft"), index + 1 < CommandLine.arguments.count,
                let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])),
                let imported = try? JSONDecoder().decode(EditorDocument.self, from: data).validated()
            {
                document = imported
            }
            if document.pdfSource == nil {
                document.pdfSource = PDFScoreSource(
                    filename: document.instrument == .guitar ? "Guitar reading study.pdf" : "Piano reading study.pdf",
                    page: 1, model: PDFImportModel.astra.rawValue, costUSD: 0.08,
                    warnings: [
                        "Compare the pitches, rhythms and ties with the original before marking this draft reviewed."
                    ])
            }
            if !editor.documents.contains(where: { $0.id == document.id }) { editor.documents.append(document) }
            editor.replace(document)
            editor.activeID = document.id
            destination = .editor
        }
        if preview && CommandLine.arguments.contains("--conversation") { openContextCoach() }
        if preview && CommandLine.arguments.contains("--song-preview") {
            do { try SongJourneyChecks.preview(state: self) } catch {
                SongJourneyDiagnostics.checks["built"] = false
                message = error.localizedDescription
            }
        }
        if preview && CommandLine.arguments.contains("--coach-panel") {
            if CommandLine.arguments.contains("--coach-piece"), let journey = selectedSongJourney,
                let piece = libraryPieces.first(where: { $0.id == journey.material.pieceID })
            {
                openLibraryPiece(piece)
            }
            openContextCoach()
        }
        if preview && CommandLine.arguments.contains("--workspace-editor-roundtrip"),
            let journey = selectedSongJourney,
            let piece = libraryPieces.first(where: { $0.id == journey.material.pieceID })
        {
            openLibraryPiece(piece)
        }
    }
}
