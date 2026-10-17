// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI
import WebKit
import XCTest

@testable import Cadence

@MainActor private final class RendererFixture {
    var height: CGFloat = 240
    var error: String? = "Old error"
    var metrics = ""
    var selected: [UUID] = []
    var editor: EditorRenderer {
        EditorRenderer(
            document: .pianoExample, engine: "OpenSheetMusicDisplay", from: 0, through: 3,
            select: { self.selected.append($0) }, height: .init(get: { self.height }, set: { self.height = $0 }),
            error: .init(get: { self.error }, set: { self.error = $0 }),
            metrics: .init(get: { self.metrics }, set: { self.metrics = $0 }))
    }
    func score() throws -> ScoreRenderer {
        let study = MusicStudy(
            document: try StudyImport.read(Data(StudyExamples.smallSteps.utf8)), filename: "Original.musicxml")
        return ScoreRenderer(
            study: study, height: .init(get: { self.height }, set: { self.height = $0 }),
            error: .init(get: { self.error }, set: { self.error = $0 }))
    }
}

final class RendererBridgeTests: XCTestCase {
    @MainActor func testAllNavigationDelegatesActuallyImplementTheWebKitSelectorInSwift6() throws {
        let fixture = RendererFixture()
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(fixture.editor.makeCoordinator().responds(to: selector))
        XCTAssertTrue(try fixture.score().makeCoordinator().responds(to: selector))
        XCTAssertTrue(EPUBReadingView.Coordinator().responds(to: selector))
    }

    func testNonfiniteOversizedAndWrongTypeLayoutValuesCannotReachIntegerConversion() {
        let invalid: [[String: Any]] = [
            ["height": Double.nan], ["height": Double.infinity], ["height": "not a number"],
            ["milliseconds": Double.nan], ["milliseconds": Double.infinity],
            ["milliseconds": -1.0], ["milliseconds": Double(Int.max)], ["milliseconds": "fast"],
            ["targets": -1], ["targets": Int.max], ["targets": "many"],
        ]
        for data in invalid {
            XCTAssertNil(RendererLayout(data, defaultHeight: 240))
        }
        XCTAssertEqual(RendererLayout(["height": 1.0], defaultHeight: 240)?.height, 160)
        XCTAssertEqual(RendererLayout(["height": 1_000_000.0], defaultHeight: 240)?.height, 100_000)
        XCTAssertEqual(RendererLayout([:], defaultHeight: 240)?.height, 240)
    }

    @MainActor func testEditorIgnoresSubframeMessagesAndUnknownSelections() throws {
        let fixture = RendererFixture()
        let bridge = fixture.editor.makeCoordinator()
        let event = try XCTUnwrap(bridge.parent.document.events.first)
        bridge.receive(["kind": "ready", "height": 900.0], isMainFrame: false)
        bridge.receive(["kind": "loaded"], isMainFrame: false)
        bridge.receive(["kind": "error", "message": "Injected"], isMainFrame: false)
        bridge.receive(["kind": "select", "id": event.id.uuidString], isMainFrame: false)
        XCTAssertEqual(fixture.height, 240)
        XCTAssertEqual(fixture.error, "Old error")
        XCTAssertFalse(bridge.loaded)
        XCTAssertTrue(fixture.selected.isEmpty)
        for id in ["malformed", UUID().uuidString] {
            bridge.receive(["kind": "select", "id": id], isMainFrame: true)
        }
        bridge.receive(["kind": "select", "id": event.id.uuidString], isMainFrame: true)
        XCTAssertEqual(fixture.selected, [event.id])
    }

    @MainActor func testEditorBadLayoutIsRecoverableAndValidReadyClearsItsError() {
        let fixture = RendererFixture()
        let bridge = fixture.editor.makeCoordinator()
        let previous = EditorDiagnostics.latest
        defer { EditorDiagnostics.latest = previous }
        bridge.receive(["kind": "ready", "milliseconds": Double.nan], isMainFrame: true)
        XCTAssertEqual(fixture.height, 240)
        XCTAssertTrue(fixture.error?.contains("invalid layout") == true)
        bridge.receive(["kind": "ready", "height": 330.0, "milliseconds": 12.7, "targets": 16], isMainFrame: true)
        XCTAssertEqual(fixture.height, 330)
        XCTAssertNil(fixture.error)
        XCTAssertEqual(fixture.metrics, "13 ms · 16 selectable positions")
        bridge.receive(["kind": "error", "message": String(repeating: "x", count: 3000)], isMainFrame: true)
        XCTAssertEqual(fixture.error?.count, 2000)
    }

    @MainActor func testScoreBridgeIgnoresSubframesAndRecoversFromMalformedLayout() throws {
        let fixture = RendererFixture()
        let bridge = try fixture.score().makeCoordinator()
        let previous = ScoreRendererDiagnostics.latest
        defer { ScoreRendererDiagnostics.latest = previous }
        bridge.receive(["kind": "loaded"], isMainFrame: false)
        bridge.receive(["kind": "error", "message": "Injected"], isMainFrame: false)
        XCTAssertFalse(bridge.loaded)
        XCTAssertEqual(fixture.error, "Old error")
        bridge.receive(["kind": "ready", "height": Double.infinity], isMainFrame: true)
        XCTAssertTrue(fixture.error?.contains("invalid layout") == true)
        bridge.receive(["kind": "ready", "height": 400.0], isMainFrame: true)
        XCTAssertEqual(fixture.height, 400)
        XCTAssertNil(fixture.error)
        bridge.receive(["kind": "error"], isMainFrame: true)
        XCTAssertEqual(fixture.error, "The score could not be displayed.")
        bridge.receive(["kind": "loaded"], isMainFrame: true)
        XCTAssertTrue(bridge.loaded)
    }
}
