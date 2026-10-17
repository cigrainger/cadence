// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

/// Request and timeout tasks execute concurrently. Assertions observe one actor
/// instead of introducing a race in the transport's regression fixtures.
actor RequestProbe {
    private var count = 0
    private var cancelled = false
    func sent() { count += 1 }
    func cancellation(_ value: Bool) { cancelled = value }
    func assertCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(count, expected, file: file, line: line)
    }
    func assertCancelled(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(cancelled, file: file, line: line)
    }
}
