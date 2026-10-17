// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest

@testable import Cadence

final class WorkspaceWindowLayoutTests: XCTestCase {
    func testLargeDisplayRetainsPreferredWorkspace() {
        let layout = WorkspaceWindowLayout.fitting(CGSize(width: 1920, height: 1080))
        XCTAssertEqual(layout.minimum, WorkspaceWindowLayout.preferredMinimum)
        XCTAssertEqual(layout.initial, WorkspaceWindowLayout.preferredInitial)
    }
    func testSmallAndScaledDisplaysCanFitTheInitialWindowAndItsMinimum() {
        for screen in [CGSize(width: 1024, height: 744), CGSize(width: 800, height: 580), CGSize(width: 1, height: 1)] {
            let layout = WorkspaceWindowLayout.fitting(screen)
            for size in [layout.minimum, layout.initial] {
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, screen.width)
                XCTAssertLessThanOrEqual(size.height, screen.height)
            }
            XCTAssertLessThanOrEqual(layout.minimum.width, layout.initial.width)
            XCTAssertLessThanOrEqual(layout.minimum.height, layout.initial.height)
        }
    }
    func testAbsentAndInvalidScreensDoNotIntroduceInvalidWindowDimensions() {
        for screen: CGSize? in [
            nil, .zero, CGSize(width: -CGFloat.infinity, height: 800), CGSize(width: 1024, height: CGFloat.nan),
        ] {
            let layout = WorkspaceWindowLayout.fitting(screen)
            XCTAssertEqual(layout.minimum, WorkspaceWindowLayout.preferredMinimum)
            XCTAssertEqual(layout.initial, WorkspaceWindowLayout.preferredInitial)
        }
    }
}
