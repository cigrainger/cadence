// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

/// Opt-in observations, not universal latency promises. Run on the same machine
/// and toolchain when comparing changes; the normal regression suite skips these.
final class PerformanceSmokeTests: XCTestCase {
    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["CADENCE_BENCHMARK"] == "1" else {
            throw XCTSkip("Run CADENCE_BENCHMARK=1 swift test --filter PerformanceSmokeTests")
        }
    }
    func testVoicingsAcrossAllRoots() throws {
        try enabled()
        measure {
            for root in Pitch.roots {
                XCTAssertFalse(Guitar.voicings(root: root, quality: .dominant7, tuning: Tuning.presets[0]).isEmpty)
            }
        }
    }
    func testFullLengthScoreRoundTrip() throws {
        try enabled()
        var document = EditorDocument.pianoExample
        try document.insertBars(at: document.barCount, count: 124)
        measure {
            do {
                let data = Data(try EditorXML.encode(document).utf8)
                let decoded = try EditorXML.decode(data)
                XCTAssertEqual(decoded.barCount, 128)
            } catch { XCTFail(error.localizedDescription) }
        }
    }
}
