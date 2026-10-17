// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest

@testable import Cadence

final class SnapshotRequirementsTests: XCTestCase {
    private var fullStudy: SnapshotRequirements {
        SnapshotRequirements(
            scenario: "full-study", rendererFlags: ["offline", "cursorForward"],
            group: "scoreEarChecks", groupFlags: ["fullPieceOpened"])
    }

    func testCompletedFixtureCannotSubstituteForTheNotationView() {
        let fixture: [String: Any] = ["scoreEarChecks": ["fullPieceOpened": true]]
        XCTAssertEqual(fullStudy.missing(in: fixture), ["offline", "cursorForward", "renderer ready", "rendered SVG"])
        var ready = fixture
        ready.merge(["kind": "ready", "svgCount": 1, "offline": true, "cursorForward": true]) { _, new in new }
        XCTAssertTrue(fullStudy.missing(in: ready).isEmpty)
        ready["kind"] = "error"
        XCTAssertEqual(fullStudy.missing(in: ready), ["renderer ready"])
        ready["kind"] = "ready"
        ready["svgCount"] = 0
        XCTAssertEqual(fullStudy.missing(in: ready), ["rendered SVG"])
    }

    func testRendererCannotSubstituteForMissingOrFailedNativeChecks() {
        var ready: [String: Any] = ["kind": "ready", "svgCount": 1, "offline": true, "cursorForward": true]
        XCTAssertEqual(fullStudy.missing(in: ready), ["scoreEarChecks"])
        ready["scoreEarChecks"] = ["fullPieceOpened": false]
        XCTAssertEqual(fullStudy.missing(in: ready), ["scoreEarChecks.fullPieceOpened"])
        ready["scoreEarChecks"] = ["fullPieceOpened": true, "newRegression": false]
        XCTAssertEqual(fullStudy.missing(in: ready), ["scoreEarChecks.newRegression"])
        ready["scoreEarChecks"] = "invalid"
        XCTAssertEqual(fullStudy.missing(in: ready), ["scoreEarChecks"])
    }

    func testActivitiesWithoutNotationStillRequireTheirOwnResults() {
        let requirement = SnapshotRequirements(
            scenario: "song-pathway", rendererFlags: [], group: "songJourneyChecks", groupFlags: ["sourceLinked"])
        XCTAssertFalse(requirement.missing(in: [:]).isEmpty)
        XCTAssertTrue(requirement.missing(in: ["songJourneyChecks": ["sourceLinked": true]]).isEmpty)
    }

    func testReadinessRequestIsOptionalButInvalidOrOversizedRequestsFail() throws {
        XCTAssertNil(try SnapshotRequirements.read(arguments: ["Cadence", "--snapshot", "a.png"]))
        XCTAssertThrowsError(try SnapshotRequirements.read(arguments: ["--snapshot-requirements"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("requirements.json")
        let args = ["--snapshot-requirements", url.path]
        XCTAssertThrowsError(try SnapshotRequirements.read(arguments: args))
        try Data("incomplete".utf8).write(to: url)
        XCTAssertThrowsError(try SnapshotRequirements.read(arguments: args))
        try Data(repeating: 32, count: 32_769).write(to: url)
        XCTAssertThrowsError(try SnapshotRequirements.read(arguments: args))
        try JSONEncoder().encode(fullStudy).write(to: url)
        let decoded = try XCTUnwrap(SnapshotRequirements.read(arguments: args))
        XCTAssertEqual(decoded.scenario, "full-study")
        XCTAssertEqual(decoded.missing(in: [:]), fullStudy.missing(in: [:]))
    }
}

extension SnapshotRequirementsTests {
    func testFramingBudgetOnlyWaitsForScheduledUIActions() {
        XCTAssertEqual(
            SnapshotFraming.delay(arguments: ["--snapshot-requirements", "r.json", "--screen", "library"]), 0.6)
        for flag in [
            "--editor-live-edit", "--workspace-editor-roundtrip", "--reharm-detail", "--harmony-sheet",
            "--study-bottom",
        ] {
            XCTAssertGreaterThanOrEqual(
                SnapshotFraming.delay(arguments: ["--snapshot-requirements", "r.json", flag]), 3.5)
        }
        XCTAssertEqual(SnapshotFraming.delay(arguments: ["--song-ax"]), 30)
        XCTAssertEqual(SnapshotFraming.delay(arguments: ["--snapshot", "manual.png"]), 10)
    }
}
