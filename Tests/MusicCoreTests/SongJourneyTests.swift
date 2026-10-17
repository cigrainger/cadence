// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

final class SongJourneyTests: XCTestCase {
    private func fixture(_ instrument: EditorInstrument = .piano) throws -> (SongJourney, LibraryPiece) {
        let piece = LibraryPiece(source: .score(try SongJourneyExamples.score(instrument: instrument)))
        let other = LibraryPiece(source: .score(try SongJourneyExamples.score(instrument: instrument, transfer: true)))
        let scope = PieceScope(fromBar: 1, throughBar: 4, partID: "P1", partName: "Melody")
        return (
            SongJourney(
                material: try .init(piece: piece, scope: scope, staff: 1, voice: "1"),
                transfer: try .init(piece: other, scope: scope, staff: 1, voice: "1"), instrument: instrument), piece
        )
    }
    private func attempt(input: PracticeInput = .midi, assisted: Bool = false, outcome: PracticeOutcome = .correct)
        -> PracticeAttempt
    {
        PracticeAttempt(
            sessionID: UUID(), activityID: "fixture", title: "Example", skills: ["Playing"], input: input,
            outcome: outcome, assisted: assisted)
    }
    func testOriginalScoresKeepEightBarsAndBoundPracticeToFourOnBothInstruments() throws {
        for instrument in [EditorInstrument.piano, .guitar] {
            let (journey, piece) = try fixture(instrument)
            XCTAssertTrue(journey.valid)
            XCTAssertEqual(journey.material.scope.throughBar, 4)
            XCTAssertEqual(journey.material.chords.map { $0.symbol.label }, ["C", "F", "G", "C"])
            XCTAssertEqual(journey.transfer.chords.map { $0.symbol.label }, ["F", "B♭", "C", "F"])
            XCTAssertEqual(journey.material.melody.count, 8)
            guard case .score(let original) = piece.source else { return XCTFail() }
            XCTAssertEqual(original.barCount, 8)
            let arrangement = try journey.arrangement(piece: piece)
            XCTAssertEqual(arrangement.id, journey.compositionID)
            XCTAssertEqual(arrangement.barCount, 8)
            XCTAssertEqual(arrangement.responseSource?.material, journey.material)
            XCTAssertTrue(arrangement.events.allSatisfy(\.isRest))
            XCTAssertFalse(arrangement.responseSource!.isFinished(arrangement))
            XCTAssertEqual(arrangement.harmonies.count, 4)
        }
    }
    func testSourceIdentityMeterAndVersionCannotBeFaked() throws {
        var (journey, piece) = try fixture()
        journey.transfer = journey.material
        XCTAssertFalse(journey.valid)
        XCTAssertThrowsError(try journey.arrangement(piece: piece))
        journey = try fixture().0
        journey.version = 2
        XCTAssertFalse(journey.valid)
        journey.version = 1
        journey.material.beats = 12
        XCTAssertFalse(journey.valid)
        journey = try fixture().0
        journey.minutes = 7
        XCTAssertFalse(journey.valid)
    }
    func testPlannerExplainsOpeningDifficultyAndReservesCreativeTime() {
        let opening = SongLessonEvidence(attempts: [attempt(outcome: .incorrect)])
        for minutes in [10, 15, 25] {
            let items = SongSessionPlanner.session(
                minutes: minutes, opening: opening, evidence: [:], independentDue: false)
            XCTAssertEqual(items.map(\.lesson), [.changes, .arrange])
            XCTAssertEqual(items.map(\.minutes).reduce(0, +), minutes)
            XCTAssertTrue(items[0].reason.contains("opening"))
        }
    }
    func testSupportedAndOnScreenSuccessNeverCompletesInstrumentMilestones() {
        for item in [attempt(input: .choice), attempt(input: .selfReport), attempt(assisted: true)] {
            let evidence = SongLessonEvidence(attempts: [item])
            XCTAssertFalse(evidence.independentSuccess)
        }
        XCTAssertFalse(SongLessonEvidence(attempts: [attempt()], complete: false).independentSuccess)
        XCTAssertEqual(SongLessonEvidence(attempts: [attempt()], complete: false).label, "In progress")
    }
    func testLatestMissOverridesOlderSuccessAndIndependentReturnHasPriority() {
        var good = attempt()
        good.date = Date(timeIntervalSince1970: 100)
        var miss = attempt(outcome: .incorrect)
        miss.date = Date(timeIntervalSince1970: 200)
        let evidence: [SongLesson: SongLessonEvidence] = [
            .hear: .init(attempts: [good]), .groove: .init(attempts: [good, miss]),
        ]
        let session = SongSessionPlanner.session(
            minutes: 15, opening: .init(), evidence: evidence, independentDue: false)
        XCTAssertEqual(session[0].lesson, .groove)
        XCTAssertTrue(session[0].reason.contains("pitch and timing"))
        XCTAssertEqual(
            SongSessionPlanner.session(minutes: 15, opening: .init(), evidence: evidence, independentDue: true)[0]
                .lesson, .independent)
    }
    func testAllObservedSkillsLeadToCreationAndArtifactHasNoMasteryGrade() {
        let checked = SongLessonEvidence(attempts: [attempt()])
        let session = SongSessionPlanner.session(
            minutes: 25, opening: checked, evidence: [.hear: checked, .changes: checked, .groove: checked],
            independentDue: false)
        XCTAssertEqual(
            session,
            [
                .init(
                    lesson: .arrange, reason: "Use what you have explored in a musical choice of your own.", minutes: 25
                )
            ])
        let artifact = SongLessonEvidence(hasArtifact: true)
        XCTAssertEqual(artifact.label, "A version to keep")
        XCTAssertFalse(artifact.independentSuccess)
    }
    func testCourseMigrationRetainsJourneysAndRejectsFutureAndDuplicateContent() throws {
        let journey = try fixture().0
        var library = CourseLibrary()
        library.songJourneys = [journey]
        let data = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(CourseLibrary.self, from: data).songJourneys, [journey])
        library.songJourneys = [journey, journey]
        XCTAssertThrowsError(try library.validated())
        for version in [1, 2] {
            let data = Data("{\"schemaVersion\":\(version),\"books\":[],\"courses\":[],\"reflections\":{}}".utf8)
            let old = try JSONDecoder().decode(CourseLibrary.self, from: data)
            XCTAssertEqual(old.schemaVersion, 3)
            XCTAssertNil(old.songJourneys)
        }
    }
}

extension SongJourneyTests {
    func testLaterVoicingSuccessSupersedesAnOlderOpeningMiss() {
        var opening = attempt(outcome: .incorrect)
        opening.date = Date(timeIntervalSince1970: 100)
        var improvement = attempt()
        improvement.date = Date(timeIntervalSince1970: 200)
        let result = SongSessionPlanner.session(
            minutes: 15, opening: .init(attempts: [opening]),
            evidence: [.changes: .init(attempts: [improvement])], independentDue: false)
        XCTAssertEqual(result.first?.lesson, .hear)
        XCTAssertEqual(
            SongLessonEvidence(attempts: [attempt(input: .selfReport, outcome: .skipped)]).label, "Skipped · still open"
        )
    }
}

extension SongJourneyTests {
    func testArrangementKeepsTheGuitarSourcesTuningAndRejectsAnInstrumentMismatch() throws {
        var score = try SongJourneyExamples.score(instrument: .guitar)
        score.tuning = Tuning.presets[1]
        let piece = LibraryPiece(source: .score(try score.validated()))
        let other = LibraryPiece(source: .score(try SongJourneyExamples.score(instrument: .guitar, transfer: true)))
        let scope = PieceScope(fromBar: 1, throughBar: 4, partID: "P1", partName: "Melody")
        var journey = SongJourney(
            material: try .init(piece: piece, scope: scope, staff: 1, voice: "1"),
            transfer: try .init(piece: other, scope: scope, staff: 1, voice: "1"), instrument: .guitar)
        let arrangement = try journey.arrangement(piece: piece)
        XCTAssertEqual(arrangement.tuning, Tuning.presets[1])
        XCTAssertEqual(arrangement.barCount, 8)
        XCTAssertEqual(arrangement.responseSource?.material, journey.material)
        journey.instrument = .piano
        XCTAssertThrowsError(try journey.arrangement(piece: piece))
    }
}
