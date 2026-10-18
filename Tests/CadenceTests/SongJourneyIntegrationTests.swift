// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class SongJourneyIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(storageOverride: folder)
        addTeardownBlock { await MainActor.run { state.midi.shutdown() } }
        return state
    }
    @MainActor func testJourneyRestartsAtMapWithoutDuplicatingOriginalScores() throws {
        let state = try fixture()
        let id = try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        XCTAssertEqual(journey.id, id)
        let source = try XCTUnwrap(state.libraryPieces.first { $0.id == journey.material.pieceID })
        XCTAssertEqual(state.pieceRecord(source).kind, .example)
        XCTAssertEqual(state.pieceRecord(source).composer, "Cadence")
        XCTAssertEqual(state.practicePage, .songJourney)
        let count = state.editor.documents.count
        XCTAssertEqual(try state.startSongJourney(instrument: .piano), id)
        XCTAssertEqual(state.editor.documents.count, count)
        let reopened = AppState(storageOverride: state.storage)
        defer { reopened.midi.shutdown() }
        XCTAssertEqual(reopened.selectedSongJourney, journey)
        XCTAssertEqual(reopened.practicePage, .songJourney)
        XCTAssertEqual(reopened.songSession(journey).first?.lesson, .hear)
        let piece = try XCTUnwrap(reopened.libraryPieces.first { $0.id == journey.material.pieceID })
        reopened.openLibraryPiece(piece)
        XCTAssertEqual(reopened.editorPassageFocus?.wholePiece, true)
        XCTAssertEqual(reopened.editor.active.barCount, 8)
    }
    @MainActor func testOpeningRequiresObservedMIDIStartAndSaveFailureRetainsPendingAnswer() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let notes = try XCTUnwrap(journey.openingPrompt.solutions.first)
        XCTAssertThrowsError(
            try state.saveSongOpening(
                journey, notes: notes, input: .midi, assisted: false, verifiedFrom: nil, id: UUID()))
        XCTAssertTrue(state.songOpening(journey).attempts.isEmpty)
        try state.practiceWorkspace.save()
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try Data("external edit".utf8).write(to: url)
        state.songInput.submit(notes, input: .choice, journey: journey, state: state)
        XCTAssertNotNil(state.songInput.pending)
        XCTAssertThrowsError(try state.startSongJourney(instrument: .guitar))
        XCTAssertTrue(state.songOpening(journey).attempts.isEmpty)
        state.openSongJourney(journey.id)
        XCTAssertNotNil(state.songInput.pending)
        try bytes.write(to: url)
        state.songInput.save(state: state)
        state.songInput.save(state: state)
        XCTAssertEqual(state.songOpening(journey).attempts.count, 1)
        XCTAssertFalse(state.songOpening(journey).independentSuccess)
        XCTAssertNil(state.songInput.pending)
        XCTAssertEqual(state.songOpening(journey).label, "On-screen check")
    }
    @MainActor func testOpeningMissAdaptsToChangesAndHintedRetryStaysSupported() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        try state.saveSongOpening(
            journey, notes: [60, 64, 67], input: .choice, assisted: false, verifiedFrom: nil, id: UUID())
        XCTAssertEqual(state.songSession(journey).first?.lesson, .changes)
        let id = UUID()
        try state.saveSongOpening(
            journey, notes: journey.openingPrompt.solutions[0], input: .midi, assisted: true,
            verifiedFrom: journey.openingPrompt.from, id: id)
        try state.saveSongOpening(
            journey, notes: journey.openingPrompt.solutions[0], input: .midi, assisted: true,
            verifiedFrom: journey.openingPrompt.from, id: id)
        XCTAssertEqual(state.songOpening(journey).attempts.count, 2)
        XCTAssertEqual(state.songOpening(journey).label, "With support")
    }
    @MainActor func testCourseCommitFailureKeepsPublishedPathwayUnchangedAndRetryHasNoDuplicateScores() throws {
        let state = try fixture()
        try state.courseWorkspace.save()
        let bytes = try Data(contentsOf: state.stores.courses.url)
        try Data("changed elsewhere".utf8).write(to: state.stores.courses.url)
        XCTAssertThrowsError(try state.startSongJourney(instrument: .piano))
        XCTAssertTrue(state.songJourneys.isEmpty)
        XCTAssertNil(state.songJourneyID)
        let count = state.editor.documents.count
        try bytes.write(to: state.stores.courses.url)
        try state.startSongJourney(instrument: .piano)
        XCTAssertEqual(state.editor.documents.count, count)
    }
    @MainActor func testSourceEditInvalidatesRecommendationsWithoutErasingHistory() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        try state.saveSongOpening(
            journey, notes: [60, 64, 67], input: .choice, assisted: false, verifiedFrom: nil, id: UUID())
        let originalAttempts = state.journal.attempts
        var copy = state.editor
        let index = try XCTUnwrap(copy.documents.firstIndex { "score:" + $0.id.uuidString == journey.material.pieceID })
        copy.documents[index].events[0].pitches = [EditorPitch(66)]
        try state.libraryWorkspace.commitScores(copy)
        XCTAssertThrowsError(try state.openSongActivity(.hear, journey: journey))
        XCTAssertTrue(state.songEvidence(journey).isEmpty)
        XCTAssertEqual(state.journal.attempts, originalAttempts)
    }
    @MainActor func testEightBarArrangementIsLinkedRepeatSafeAndFinishesOnlyAfterCurrentVersionIsHeard() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        try state.openSongActivity(.arrange, journey: journey)
        XCTAssertEqual(state.editor.active.id, journey.compositionID)
        XCTAssertEqual(state.editor.active.barCount, 8)
        let count = state.editor.documents.count
        try state.openSongActivity(.arrange, journey: journey)
        XCTAssertEqual(state.editor.documents.count, count)
        XCTAssertThrowsError(try state.finishCreativeAnswer(journey.compositionID, listenedFingerprint: ""))
        var copy = state.editor
        let index = try XCTUnwrap(copy.documents.firstIndex { $0.id == journey.compositionID })
        copy.documents[index].events[0].pitches = [EditorPitch(64)]
        try state.libraryWorkspace.commitScores(copy)
        let fingerprint = LibraryPiece(source: .score(copy.documents[index])).fingerprint
        try state.finishCreativeAnswer(journey.compositionID, listenedFingerprint: fingerprint)
        XCTAssertTrue(state.songEvidence(journey)[.arrange]!.hasArtifact)
        XCTAssertFalse(state.songEvidence(journey)[.arrange]!.independentSuccess)
        copy = state.editor
        copy.documents[index].events[0].pitches = [EditorPitch(65)]
        try state.libraryWorkspace.commitScores(copy)
        XCTAssertFalse(state.songEvidence(journey)[.arrange]!.hasArtifact)
    }
    @MainActor func testGuitarJourneyAndActivityAdaptersPreserveFullScoreAndPrepareCoachWithoutSending() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .guitar)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        try state.openSongActivity(.hear, journey: journey)
        XCTAssertEqual(state.practicePage, .earDaily)
        try state.openSongActivity(.changes, journey: journey)
        XCTAssertEqual(state.destination, .chords)
        XCTAssertEqual(state.changesPlan.pieceID, journey.material.pieceID)
        try state.openSongActivity(.groove, journey: journey)
        XCTAssertEqual(state.practicePage, .playAlong)
        try state.openSongActivity(.independent, journey: journey)
        XCTAssertEqual(state.playAlongMaterial?.pieceID, journey.transfer.pieceID)
        XCTAssertFalse(state.playAlongSession.setup.guide)
        XCTAssertTrue(state.songEvidence(journey)[.independent]!.attempts.isEmpty)
        XCTAssertEqual(state.songReturnDate(journey), journey.created.addingTimeInterval(86400))
        state.coachForSong(journey, lesson: .arrange)
        XCTAssertTrue(state.contextCoach.presented)
        XCTAssertTrue(state.contextCoach.draft.contains("eight"))
        XCTAssertTrue(state.contextCoach.lines.isEmpty)
        state.openSongJourney(journey.id)
        state.showPracticeHome()
        XCTAssertEqual(state.practicePage, .songJourney)
        XCTAssertThrowsError(try state.setSongMinutes(2, journey: journey))
        try state.setSongMinutes(25, journey: journey)
        XCTAssertEqual(state.selectedSongJourney?.minutes, 25)
    }
}

extension SongJourneyIntegrationTests {
    @MainActor func testVirtualMIDIRequiresReleaseAndDisconnectCannotSubmitAnAnswer() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let input = state.songInput
        var keys = MIDIKeyboardState()
        func send(_ message: MIDIMessage) {
            keys.receive(message)
            input.receive(.init(message: message, keyboard: keys), state: state, journey: journey)
        }
        func chord(_ notes: [Int]) {
            for note in notes { send(.noteOn(channel: 0, note: note, velocity: 90)) }
            for note in notes { send(.noteOff(channel: 0, note: note)) }
        }
        input.listen(held: [])
        chord([60, 64, 67])
        XCTAssertEqual(input.verifiedFrom, [60, 64, 67])
        chord(journey.openingPrompt.solutions[0])
        XCTAssertEqual(state.songOpening(journey).attempts.count, 1)
        XCTAssertTrue(state.songOpening(journey).independentSuccess)
        input.listen(held: [])
        chord([60, 64, 67])
        send(.reset)
        chord(journey.openingPrompt.solutions[0])
        XCTAssertEqual(state.songOpening(journey).attempts.count, 1)
        XCTAssertFalse(input.listening)
    }
    @MainActor func testIndependentReturnRequiresAnotherPieceTimeAwayAndUnassistedTiming() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        func save(_ material: ScoreEarMaterial, at date: Date, guide: Bool = false) throws {
            var setup = PlayAlongSetup()
            setup.guide = guide
            let plan = try state.playAlongPlan(material, setup: setup)
            let result = PlayAlongResult(
                plan: plan,
                pass: .init(
                    date: date, plan: plan.timed,
                    conditions: .init(input: .midi, click: false),
                    attacks: plan.timed.targets.map {
                        .init(seconds: $0.beat * plan.timed.secondsPerBeat, pitch: $0.pitch)
                    }))
            try state.savePlayAlong(result)
        }
        try save(journey.transfer, at: journey.created.addingTimeInterval(30))
        XCTAssertTrue(state.songEvidence(journey)[.independent]!.attempts.isEmpty)
        try save(journey.material, at: journey.created.addingTimeInterval(60))
        XCTAssertTrue(state.songEvidence(journey)[.groove]!.independentSuccess)
        XCTAssertTrue(state.songEvidence(journey)[.independent]!.attempts.isEmpty)
        let later = state.songReturnDate(journey).addingTimeInterval(1)
        XCTAssertEqual(state.songSession(journey, now: later).first?.lesson, .independent)
        try save(journey.transfer, at: later, guide: true)
        XCTAssertFalse(state.songEvidence(journey)[.independent]!.independentSuccess)
        try save(journey.transfer, at: later.addingTimeInterval(60))
        XCTAssertTrue(state.songEvidence(journey)[.independent]!.independentSuccess)
        XCTAssertNotEqual(state.songSession(journey, now: later.addingTimeInterval(3600)).first?.lesson, .independent)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertTrue(restored.songEvidence(journey)[.independent]!.independentSuccess)
    }
    @MainActor func testOneChordCannotCompleteAWholeProgressionAndRecognitionIsSeparate() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        var practice = try ChangesPractice(plan: state.songChanges(journey), mode: .complete)
        var first = true
        while !practice.finished {
            let notes = practice.targets[practice.cursor].pianoVoicings()[0]
            let attempt = try practice.answer(notes)
            XCTAssertTrue(state.recordAttempt(attempt))
            try practice.accept(attempt)
            if first {
                XCTAssertFalse(state.songEvidence(journey)[.changes]!.independentSuccess)
                first = false
            }
        }
        XCTAssertTrue(state.songEvidence(journey)[.changes]!.independentSuccess)
        let id = UUID()
        try state.saveSongExplanation(journey, answer: 4, id: id)
        try state.saveSongExplanation(journey, answer: 4, id: id)
        XCTAssertEqual(state.songExplanation(journey).attempts.count, 1)
        try state.saveSongExplanation(journey, answer: 0)
        XCTAssertEqual(state.songExplanation(journey).latest?.outcome, .correct)
        XCTAssertTrue(state.songExplanation(journey).latest!.assisted)
        XCTAssertTrue(state.songEvidence(journey)[.hear]!.attempts.isEmpty)
        XCTAssertThrowsError(try state.saveSongExplanation(journey, answer: 3))
    }
}

extension SongJourneyIntegrationTests {
    @MainActor func testReviewedLibraryMusicStartsTheSameJourneyAndUnsupportedMusicDoesNotCreateIt() throws {
        let state = try fixture()
        var score = try SongJourneyExamples.score(instrument: .piano)
        score.title = "My own eight-bar study"
        try state.libraryWorkspace.addComposition(score)
        let pieceID = "score:" + score.id.uuidString
        try state.startSongJourney(instrument: .piano, pieceID: pieceID)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        XCTAssertEqual(journey.material.pieceID, pieceID)
        XCTAssertEqual(journey.material.title, score.title)
        let before = state.courses
        XCTAssertThrowsError(try state.startSongJourney(instrument: .guitar, pieceID: pieceID))
        XCTAssertThrowsError(try state.startSongJourney(instrument: .piano, pieceID: "missing"))
        var library = state.editor
        let index = try XCTUnwrap(library.documents.firstIndex { $0.id == score.id })
        library.documents[index].pdfSource = .init(filename: "Source.pdf", page: 1, model: "Original fixture")
        try state.libraryWorkspace.commitScores(library)
        XCTAssertThrowsError(try state.startSongJourney(instrument: .piano, pieceID: pieceID))
        XCTAssertEqual(state.courses, before)
        XCTAssertTrue(state.songSession(journey).isEmpty)
    }
    @MainActor func testChangingSessionDurationDoesNotInvalidateAMusicallyCurrentPendingAnswer() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let original = try XCTUnwrap(state.selectedSongJourney)
        try state.setSongMinutes(25, journey: original)
        try state.saveSongOpening(
            original, notes: original.openingPrompt.solutions[0], input: .choice,
            assisted: false, verifiedFrom: nil, id: UUID())
        XCTAssertEqual(state.songOpening(original).attempts.count, 1)
        XCTAssertEqual(state.songSession(state.selectedSongJourney!).map(\.minutes).reduce(0, +), 25)
    }
}

extension SongJourneyIntegrationTests {
    @MainActor func testUnstartedPathwayIsNotADelayedReturnAndRootDrillCannotCompleteVoicingWork() throws {
        let state = try fixture()
        try state.startSongJourney(instrument: .piano)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        XCTAssertEqual(state.songSession(journey, now: journey.created.addingTimeInterval(172800)).first?.lesson, .hear)
        var practice = try ChangesPractice(plan: state.songChanges(journey), mode: .roots)
        while !practice.finished {
            let attempt = try practice.answer(practice.targets[practice.cursor].pianoVoicings()[0])
            XCTAssertTrue(state.recordAttempt(attempt))
            try practice.accept(attempt)
        }
        XCTAssertFalse(state.songEvidence(journey)[.changes]!.independentSuccess)
        XCTAssertEqual(state.songEvidence(journey)[.changes]!.label, "In progress")
    }
}
