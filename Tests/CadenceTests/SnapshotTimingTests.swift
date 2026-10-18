// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import Cadence

final class SnapshotTimingTests: XCTestCase {
    @MainActor func testSnapshotPhaseTimingIsMonotonicAndSeparateFromAssertionGroups() throws {
        SnapshotDiagnostics.mark("timing-first")
        SnapshotDiagnostics.mark("timing-second")
        let timing = try XCTUnwrap(SnapshotDiagnostics.report["snapshotTiming"] as? [String: Any])
        let phases = try XCTUnwrap(timing["phases"] as? [String: TimeInterval])
        let first = try XCTUnwrap(phases["timing-first"])
        let second = try XCTUnwrap(phases["timing-second"])
        let elapsed = try XCTUnwrap(timing["elapsedSeconds"] as? TimeInterval)
        XCTAssertTrue(first.isFinite && first >= 0)
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertGreaterThanOrEqual(elapsed, second)
    }
}
