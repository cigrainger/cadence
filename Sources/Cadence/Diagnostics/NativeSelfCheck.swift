// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

/// Isolated command-line checks use fixture storage; ordinary launches never run them.
extension AppState {
    func runDiagnosticCommands() async {
        let state = self
        if let argument = CommandLine.arguments.firstIndex(of: "--selfcheck"),
            argument + 1 < CommandLine.arguments.count
        {
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
            var report: [String: Any] = [:]
            // Open MIDI before audio work, and keep the client until every
            // check ends. MIDIServer idling out can invalidate a process's
            // already-initialised CoreMIDI connection before its first client.
            let midiCheck = MIDIKeyboard(persistSelection: false)
            midiCheck.start()
            defer { midiCheck.shutdown() }
            do {
                let deviceOutput = !CommandLine.arguments.contains("--offline-audio")
                let skipped =
                    deviceOutput ? [] : ["audioOutput", "timedAudioScheduled", "metronomeOutput", "studyLoopOutput"]
                report = try await state.audio.verifyOutput(deviceOutput: deviceOutput)
                report["skippedChecks"] = skipped
                let sampled = try SampledAudio.render(
                    lanes: GrooveArrangement(tempo: 160, loops: 1).lanes(), tempo: 160, endBeat: 20)
                report["sampledBand"] =
                    sampled.count > 300000 && sampled.allSatisfy(\.isFinite) && sampled.contains { abs($0) > 0.01 }
                report["bundledSoundBank"] = SampledAudio.bankURL.path.contains(
                    ".app/Contents/Resources/SoundBanks/")
                let earState = AppState(preview: true)
                try EarPathwayChecks.preview(state: earState)
                report["earPathway"] = EarPathwayDiagnostics.checks.values.allSatisfy { $0 }
                EarPathwayDiagnostics.checks = [:]
                if deviceOutput { report["timedAudioScheduled"] = try await TimedAudio().verifyScheduledOutput() }
                let midiReport = try await midiCheck.verifyVirtualInput()
                for (key, value) in midiReport { report[key] = value }
                report["midiClientRetained"] = midiCheck.clientIsOpen
                let fixture = reportURL.deletingLastPathComponent().appendingPathComponent(
                    "cadence-fixture-\(UUID().uuidString)")
                let original = AppState(storageOverride: fixture)
                let pdfChecks = try PDFImportChecks.verify(directory: fixture.appendingPathComponent("pdf-import"))
                for (key, value) in pdfChecks { report[key] = value }
                let batchChecks = try await PDFBatchChecks.verify(
                    directory: fixture.appendingPathComponent("pdf-batch"))
                report["pdfBatchChecks"] = batchChecks
                report["pdfBatchPassed"] = batchChecks.values.allSatisfy { $0 }
                let libraryChecks = try await LibraryChecks.verify(
                    directory: fixture.appendingPathComponent("piece-library"))
                report["libraryChecks"] = libraryChecks
                report["libraryPassed"] = libraryChecks.values.allSatisfy { $0 }
                let pieceChecks = try PiecePathwayChecks.verify(
                    directory: fixture.appendingPathComponent("piece-pathways"))
                report["piecePathwayChecks"] = pieceChecks
                report["piecePathwayPassed"] = pieceChecks.values.allSatisfy { $0 }
                original.metronome.bpm = 107
                original.metronome.setBeats(3)
                original.metronome.subdivision = .triplets
                original.tuner.referenceA4 = 442
                original.root = Pitch(1)
                original.scale = .dorian
                original.capo = 2
                original.leftHanded = true
                original.showSolfege = false
                original.learning = LearningPreview.library
                original.addExampleStudy()
                try original.editor.documents[0].setFingering(
                    original.editor.documents[0].events[0].id,
                    pitchID: original.editor.documents[0].events[0].pitches[0].id, string: 4, fret: 3)
                let copiedBars = try original.editor.documents[0].excerpt(0...3)
                try original.editor.documents[0].paste(copiedBars, at: 4, inserting: true)
                try original.editor.documents[0].setMeter(EditorMeter(5, 4))
                original.editor.documents[0].minor = true
                original.editor.engine = "OpenSheetMusicDisplay"
                if let studyID = original.studies.active?.id, let pathID = original.learning.activePathway?.id {
                    original.attachStudy(studyID, to: pathID)
                }
                if let id = original.learning.activePathway?.id {
                    original.learning.toggleStep(0, in: id)
                    original.learning.pathways[0].notes = "Fixture: keep practising the chord change."
                }
                let question = QuestionFactory.deck(.functional, root: Pitch(1), scale: .major)[0]
                _ = original.record(question, correct: true, firstTry: true, revealed: false)
                original.save()
                let restored = AppState(storageOverride: fixture)
                report["persistence"] =
                    restored.root == Pitch(1) && restored.scale == .dorian && restored.capo == 2
                    && restored.leftHanded && restored.history.xp == 10
                if let reference = restored.learning.activePathway?.study {
                    restored.openStudy(reference)
                    report["studyPathwayNavigation"] =
                        restored.destination == .studies && restored.studies.active?.id == reference.studyID
                        && restored.studies.active?.from == reference.from
                        && restored.studies.active?.through == reference.through
                }
                report["studyPersistence"] =
                    restored.studies == original.studies && restored.studies.active != nil
                    && restored.learning.activePathway?.study != nil
                original.recordChord(
                    PlayedChord(root: Pitch(0), quality: .major), notes: [60, 64, 67], correct: true,
                    assisted: false)
                original.save()
                let journalRestored = AppState(storageOverride: fixture)
                report["practiceJournalPersistence"] =
                    journalRestored.journal == original.journal
                    && journalRestored.journal.attempts.last?.input == .midi
                let migrationFolder = fixture.appendingPathComponent("legacy-practice")
                try FileManager.default.createDirectory(at: migrationFolder, withIntermediateDirectories: true)
                try JSONEncoder().encode(original.history).write(
                    to: migrationFolder.appendingPathComponent("practice.json"))
                let oldJournal = AppState(storageOverride: migrationFolder)
                report["practiceJournalMigration"] =
                    oldJournal.journal.attempts.isEmpty && oldJournal.history.xp == original.history.xp
                let attemptsURL = migrationFolder.appendingPathComponent("attempts.json")
                let unknownHistory = Data(#"{"schemaVersion":99,"attempts":[]}"#.utf8)
                try unknownHistory.write(to: attemptsURL, options: .atomic)
                let futureJournal = AppState(storageOverride: migrationFolder)
                futureJournal.save()
                let preservedFutureHistory = try Data(contentsOf: attemptsURL)
                report["futurePracticeJournalPreserved"] =
                    futureJournal.journalStorageError != nil && preservedFutureHistory == unknownHistory
                let damagedHistory = Data("incomplete history".utf8)
                try damagedHistory.write(to: attemptsURL, options: .atomic)
                let damagedJournal = AppState(storageOverride: migrationFolder)
                damagedJournal.save()
                let preservedDamagedHistory = try Data(contentsOf: attemptsURL)
                report["damagedPracticeJournalPreserved"] =
                    damagedJournal.journalStorageError != nil && preservedDamagedHistory == damagedHistory
                report["editorPersistence"] = restored.editor == original.editor
                let editorURL = fixture.appendingPathComponent("editor.json")
                let oldLibrary = EditorLibrary()
                var oldEditor =
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldLibrary)) as! [String: Any]
                oldEditor["documents"] = (oldEditor["documents"] as! [[String: Any]]).map { value in
                    var doc = value
                    doc["schemaVersion"] = 1
                    doc.removeValue(forKey: "barCount")
                    doc.removeValue(forKey: "meter")
                    doc.removeValue(forKey: "minor")
                    return doc
                }
                try JSONSerialization.data(withJSONObject: oldEditor).write(to: editorURL, options: .atomic)
                let migratedEditor = AppState(storageOverride: fixture)
                report["editorMigration"] = migratedEditor.editor == oldLibrary
                let practiceFixture = fixture.appendingPathComponent("passage-practice")
                let practiceState = AppState(storageOverride: practiceFixture)
                let originalScore = practiceState.editor.active
                practiceState.practiseEditor(originalScore, from: 1, through: 2, speed: 0.75)
                let savedCopy = practiceState.studies.active!
                var book = PassagePracticeBook()
                var progress = book.progress(for: savedCopy)
                progress.targetBPM = 105
                try progress.record(67.5)
                book.set(progress)
                practiceState.editStudy(savedCopy.id) {
                    $0.practiceBook = book
                    $0.notes = "Keep the melody clear."
                }
                practiceState.practiseEditor(originalScore, from: 1, through: 2)
                report["passagePracticeBridge"] =
                    practiceState.studies.studies.count == 1 && practiceState.studies.active?.id == savedCopy.id
                    && practiceState.studies.active?.from == 1 && practiceState.studies.active?.through == 2
                    && practiceState.studies.active?.speed == 0.75 && practiceState.destination == .studies
                practiceState.save()
                let loadedPractice = AppState(storageOverride: practiceFixture)
                report["passagePracticePersistence"] =
                    loadedPractice.studies == practiceState.studies
                    && loadedPractice.studies.active?.practiceBook?.progress(for: savedCopy).bestBPM == 67.5
                let exactReference = loadedPractice.studies.active!.reference
                loadedPractice.ask("Help with this passage", study: exactReference)
                report["practiceCoachContext"] =
                    loadedPractice.contextCoach.context?.reference == exactReference.context
                    && exactReference.context.contains("Self-reported comfortable tempos: 67.5")
                    && loadedPractice.contextCoach.presented
                var changedScore = originalScore
                try changedScore.setPitch(changedScore.events[0].id, midi: 61)
                practiceState.editor.replace(changedScore)
                practiceState.practiseEditor(changedScore, from: 1, through: 2)
                report["passageSnapshots"] =
                    practiceState.studies.studies.count == 2
                    && practiceState.studies.studies.first(where: { $0.id == savedCopy.id })?.document
                        == savedCopy.document
                practiceState.returnToCompose(originalScore.id, from: 1, through: 2)
                report["returnToCompose"] =
                    practiceState.destination == .editor && practiceState.editor.active.id == originalScore.id
                    && practiceState.editorPassageFocus?.from == 1 && practiceState.editorPassageFocus?.through == 2
                report["practiceToolsPersistence"] =
                    restored.metronome == original.metronome && restored.tuner == original.tuner
                if deviceOutput {
                    report["metronomeOutput"] = try await state.audio.verifyMetronomeOutput()
                    report["studyLoopOutput"] = try await state.audio.verifyStudyOutput()
                }
                report["solfegePreference"] = !restored.showSolfege
                let preferenceURL = fixture.appendingPathComponent("preferences.json")
                var legacy =
                    try JSONSerialization.jsonObject(with: Data(contentsOf: preferenceURL)) as! [String: Any]
                legacy.removeValue(forKey: "showSolfege")
                legacy.removeValue(forKey: "metronome")
                legacy.removeValue(forKey: "tuner")
                try JSONSerialization.data(withJSONObject: legacy).write(to: preferenceURL, options: .atomic)
                let legacyState = AppState(storageOverride: fixture)
                report["solfegePreferenceMigration"] =
                    legacyState.showSolfege && legacyState.root == original.root
                    && legacyState.history.xp == original.history.xp
                report["practiceToolsMigration"] =
                    legacyState.metronome == MetronomeSettings() && legacyState.tuner == TunerSettings()
                report["navigation"] = Destination.allCases.count
                report["pathwayPersistence"] =
                    !original.learning.pathways.isEmpty && restored.learning == original.learning
                original.useLearningTool(.rhythm)
                report["pathwayPracticeLink"] =
                    original.destination == .practice && original.practiceExercise == .rhythm
                original.useLearningTool(.singIntervals)
                report["intervalPracticeLink"] =
                    original.destination == .practice && original.practiceExercise == .intervals
                let spaceTapChecks = try SpaceTapChecks.run()
                report["spaceTapChecks"] = spaceTapChecks
                report["spaceTapPassed"] = spaceTapChecks.values.allSatisfy { $0 }
                let settingsChecks = try SettingsSelfCheck.run()
                report["settings"] = settingsChecks
                report["passed"] =
                    [
                        "sampledBand", "bundledSoundBank", "earPathway", "piecePathwayPassed", "libraryPassed",
                        "pdfBatchPassed", "pdfSharedSourceSurvivesSaveFailure", "pdfFailedSaveCleansNewSource",
                        "pdfSourceSharedAcrossPages", "pdfSelectedPageOnly", "pdfPageBounds",
                        "pdfOriginalPreserved", "pdfImportStartsUnreviewed", "pdfImportPersistence",
                        "pdfImportVoices", "pdfFailedImportAtomic", "pdfImportedPracticeCopy",
                        "futurePracticeJournalPreserved", "damagedPracticeJournalPreserved", "virtualMIDINotes",
                        "virtualMIDIRelease", "midiDisconnectClearsNotes", "practiceJournalPersistence",
                        "practiceJournalMigration", "expressionDynamics", "expressionStaccato", "returnToCompose",
                        "passageSnapshots", "practiceCoachContext", "passagePracticePersistence",
                        "passagePracticeBridge", "editorMigration", "editorPersistence", "practiceToolsPersistence",
                        "metronomeOutput", "practiceToolsMigration", "studyPathwayNavigation", "studyPersistence",
                        "studyLoopOutput", "persistence", "audioOutput", "pathwayPersistence",
                        "pathwayPracticeLink", "solfegePreference", "solfegePreferenceMigration",
                        "intervalPracticeLink", "timedAudioScheduled", "virtualMIDITimestamps", "midiClientRetained",
                        "spaceTapPassed",
                    ].filter { !skipped.contains($0) }.allSatisfy { report[$0] as? Bool == true }
                    && settingsChecks.values.allSatisfy { $0 }
                try? FileManager.default.removeItem(at: fixture)
            } catch {
                report["passed"] = false
                report["error"] = error.localizedDescription
            }
            if let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            {
                try? data.write(to: reportURL)
            }
            NSApp.terminate(nil)
        }
    }
}
