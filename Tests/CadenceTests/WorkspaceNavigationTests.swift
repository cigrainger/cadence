// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class WorkspaceNavigationTests: XCTestCase {
    @MainActor private func state() -> AppState {
        let state = AppState(
            preview: true,
            storageOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        addTeardownBlock { await MainActor.run { state.midi.shutdown() } }
        return state
    }
    @MainActor func testEveryActivityHasOneOfFourWorkspacesAndFreshLearnHasNoInventedProgress() {
        let state = state()
        let destinations = WorkspaceSection.allCases.flatMap(\.destinations)
        XCTAssertEqual(WorkspaceSection.allCases.map(\.rawValue), ["Learn", "Library", "Studio", "Explore"])
        XCTAssertEqual(Set(destinations), Set(Destination.allCases))
        XCTAssertEqual(destinations.count, Destination.allCases.count)
        XCTAssertEqual(state.workspace, .learn)
        XCTAssertEqual(state.practicePage, .songJourney)
        XCTAssertNil(state.selectedSongJourney)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertFalse(state.midi.clientIsOpen, "Preview navigation must not open a real MIDI client")
    }
    @MainActor func testSectionsResumeTheirLastActivityWithoutResettingPractice() {
        let state = state()
        state.openPractice(.rhythm)
        state.navigateWorkspace(.studio)
        XCTAssertEqual(state.destination, .editor)
        state.navigate(to: .studies)
        state.navigateWorkspace(.explore)
        state.navigate(to: .chords)
        state.navigateWorkspace(.learn)
        XCTAssertEqual(state.practicePage, .exercises)
        XCTAssertEqual(state.practiceExercise, .rhythm)
        state.navigateWorkspace(.studio)
        XCTAssertEqual(state.destination, .studies)
        state.navigateWorkspace(.explore)
        XCTAssertEqual(state.destination, .chords)
        state.showSongHome()
        XCTAssertEqual(state.practicePage, .songJourney)
        state.showPracticeOverview()
        XCTAssertEqual(state.practicePage, .home)
    }
    @MainActor func testLibraryFiltersAndSelectedPieceSurviveOpeningTheFullScoreInStudio() throws {
        let state = state()
        let piece = try XCTUnwrap(state.libraryPieces.first)
        state.libraryBrowser.query = "my filter"
        state.libraryBrowser.category = .sheetMusic
        state.libraryBrowser.favorites = true
        state.librarySelection = piece.id
        state.openLibraryPiece(piece)
        XCTAssertEqual(state.workspace, .studio)
        if case .score = piece.source { XCTAssertTrue(state.editorPassageFocus?.wholePiece == true) }
        state.navigateWorkspace(.library)
        XCTAssertEqual(state.librarySelection, piece.id)
        XCTAssertEqual(state.libraryBrowser.query, "my filter")
        XCTAssertEqual(state.libraryBrowser.category, .sheetMusic)
        XCTAssertTrue(state.libraryBrowser.favorites)
    }
    @MainActor func testBookChaptersAndCoursesAreReachableWithoutChangingTheirLinks() throws {
        let state = state()
        let id = try CourseExamples.install(state: state)
        state.showCourse(id)
        XCTAssertEqual(state.destination, .books)
        XCTAssertEqual(state.workspace, .library)
        let lesson = state.courseLessonSelection
        state.showPathways()
        XCTAssertEqual(state.destination, .courses)
        XCTAssertEqual(state.workspace, .learn)
        state.navigateWorkspace(.library)
        XCTAssertEqual(state.destination, .books)
        XCTAssertEqual(state.courseSelection, id)
        XCTAssertEqual(state.courseLessonSelection, lesson)
    }
    @MainActor func testCoachOpensAlongsideTheCurrentPieceAndKeepsAnUnsentQuestion() throws {
        let state = state()
        state.destination = .editor
        let before = state.editor.active
        state.openContextCoach()
        let id = try XCTUnwrap(state.contextCoach.context?.id)
        XCTAssertEqual(state.destination, .editor)
        XCTAssertEqual(state.contextCoach.context?.snapshot?.pieceID, "score:" + before.id.uuidString)
        state.contextCoach.draft = "An unsent question"
        state.contextCoach.presented = false
        state.navigateWorkspace(.explore)
        state.openContextCoach()
        XCTAssertNotEqual(state.contextCoach.context?.id, id)
        state.contextCoach.draft = "Another question"
        state.navigateWorkspace(.studio)
        state.openContextCoach()
        XCTAssertEqual(state.contextCoach.context?.id, id)
        XCTAssertEqual(state.contextCoach.draft, "An unsent question")
        XCTAssertEqual(state.editor.active, before)
        XCTAssertTrue(state.contextCoach.lines.isEmpty)
    }
    @MainActor func testChangedScoreGetsANewCoachContextAndPreviewCannotSend() throws {
        let state = state()
        state.destination = .editor
        let before = state.currentCoachContext
        var score = state.editor.active
        try score.setPitch(score.events[0].id, midi: 63)
        state.editor.replace(score)
        XCTAssertNotEqual(state.currentCoachContext.id, before.id)
        state.openContextCoach()
        state.contextCoach.draft = "Do not send from previews"
        state.sendContextQuestion()
        XCTAssertFalse(state.contextCoach.reply.busy)
        XCTAssertTrue(state.contextCoach.reply.error?.contains("never sends") == true)
    }
    @MainActor func testReceivedReplyKeepsItsOriginalPieceAndVersionAfterNavigationAndEdits() throws {
        let state = state()
        state.destination = .editor
        let context = state.currentCoachContext
        let snapshot = try XCTUnwrap(context.snapshot)
        let exchange = PieceExchange(snapshot: snapshot, model: "fixture", question: "A question", answer: "An answer")
        let reply = ContextCoachReply(
            context: context, question: exchange.question, answer: exchange.answer, exchange: exchange)
        var score = state.editor.active
        try score.setPitch(score.events[0].id, midi: 63)
        state.editor.replace(score)
        state.navigateWorkspace(.explore)
        try state.saveContextReply(reply)
        try state.saveContextReply(reply)
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == snapshot.pieceID })
        XCTAssertEqual(state.pieceRecord(piece).conversation, [exchange])
        XCTAssertNotEqual(exchange.fingerprint, piece.fingerprint)
        var library = state.editor
        library.documents.removeAll { "score:" + $0.id.uuidString == snapshot.pieceID }
        try state.libraryWorkspace.commitScores(library)
        XCTAssertThrowsError(try state.saveContextReply(reply))
    }
    @MainActor func testPieceRequestsAndPlanRequestsHaveWorkspaceLifetimes() {
        let state = state()
        let id = state.libraryPieces.first!.id
        let pieceRequest = state.pieceCoachSession(id)
        state.navigateWorkspace(.studio)
        state.navigateWorkspace(.library)
        XCTAssertTrue(pieceRequest === state.pieceCoachSession(id))
        let planRequest = state.learningPlanRequest
        state.navigate(to: .plans)
        state.navigateWorkspace(.explore)
        XCTAssertTrue(planRequest === state.learningPlanRequest)
    }
    @MainActor func testCoachUsesTheFocusedPassageInsteadOfAnUnrelatedGlobalKey() throws {
        let state = state()
        state.destination = .editor
        let score = state.editor.active
        state.editorLocations[score.id] = EditorLocation(
            selectedID: score.events.first?.id, pitchID: nil, from: 1, through: 2, wholePiece: false,
            session: EditorSession(), writing: false, rhythm: EditorRhythm(), octave: 4)
        let snapshot = try XCTUnwrap(state.currentCoachContext.snapshot)
        XCTAssertEqual(snapshot.scope.fromBar, 2)
        XCTAssertEqual(snapshot.scope.throughBar, 3)
        XCTAssertEqual(snapshot.pieceID, "score:" + score.id.uuidString)
    }
    @MainActor func testExplicitShowInLibraryRevealsAPieceHiddenByRetainedFilters() throws {
        let state = state()
        let piece = try XCTUnwrap(state.libraryPieces.first)
        state.libraryBrowser.query = "A nonmatching search"
        state.libraryBrowser.favorites = true
        XCTAssertFalse(state.libraryBrowser.matches(piece, record: state.pieceRecord(piece)))
        state.showLibraryPiece(piece.id)
        XCTAssertEqual(state.librarySelection, piece.id)
        XCTAssertEqual(state.workspace, .library)
        XCTAssertTrue(state.libraryBrowser.matches(piece, record: state.pieceRecord(piece)))
    }
    @MainActor func testJourneyCoachKeepsItsPartAfterTheLibrarySelectionChanges() throws {
        let state = state()
        let xml = try EditorXML.encode(SongJourneyExamples.score(instrument: .piano))
        let start = try XCTUnwrap(xml.range(of: "<part id=\"P1\">"))
        let end = try XCTUnwrap(xml.range(of: "</part>", range: start.lowerBound..<xml.endIndex))
        let second = String(xml[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: "<part id=\"P1\">", with: "<part id=\"P2\">")
        let multipart = xml.replacingOccurrences(
            of: "</part-list>",
            with: "<score-part id=\"P2\"><part-name>Second piano</part-name></score-part></part-list>"
        ).replacingOccurrences(of: "</score-partwise>", with: second + "</score-partwise>")
        var study = MusicStudy(document: try StudyImport.read(Data(multipart.utf8)), filename: "original.musicxml")
        study.selectPart("P2")
        state.studies.add(study)
        try state.startSongJourney(instrument: .piano, pieceID: "study:" + study.id.uuidString)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        state.studies.studies[0].selectPart("P1")
        try state.validateSongJourney(journey)
        let context = state.songCoachContext(journey, lesson: .hear)
        XCTAssertEqual(context.snapshot?.scope.partID, "P2")
        XCTAssertEqual(context.snapshot?.reference.partName, "Second piano")
        XCTAssertEqual(
            state.pieceCoachContext(
                try XCTUnwrap(state.libraryPieces.first { $0.id == journey.material.pieceID }), partID: "P2"
            ).subtitle, "Bars 1–4 · Second piano")
    }
}
