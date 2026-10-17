// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class GrooveTests: XCTestCase {
    func testArrangementsHaveCountInBoundedPartsAndValidHarmony() throws {
        for style in GrooveStyle.allCases {
            for loops in 1...4 {
                let plan = GrooveArrangement(style: style, loops: loops)
                let lanes = try plan.lanes()
                XCTAssertEqual(lanes[2].notes.filter { $0.start < 4 }.count, 4)
                XCTAssertTrue(lanes[0].notes.allSatisfy { $0.start >= 4 })
                XCTAssertTrue(lanes.flatMap(\.notes).allSatisfy { $0.start + $0.duration <= plan.endBeat })
                for bar in 0..<4 {
                    let pitches = Set(
                        lanes[0].notes.filter { $0.start >= Double(4 + bar * 4) && $0.start < Double(8 + bar * 4) }.map
                        { $0.midi % 12 })
                    XCTAssertEqual(pitches, Set(GrooveArrangement.voicings[bar].map { $0 % 12 }))
                }
                XCTAssertNoThrow(try Score(tempo: plan.tempo, notes: lanes.flatMap(\.notes)).validated())
            }
        }
    }
    func testMutingNeverRemovesCountIn() throws {
        let lanes = try GrooveArrangement(piano: false, bass: false, drums: false).lanes()
        XCTAssertTrue(lanes[0].notes.isEmpty)
        XCTAssertTrue(lanes[1].notes.isEmpty)
        XCTAssertEqual(lanes[2].notes.count, 4)
    }
    func testSwingAndOffbeatsAreOnTheIntendedGrid() throws {
        let off = try GrooveArrangement(style: .offbeat).lanes()[0].notes
        XCTAssertTrue(off.allSatisfy { $0.start.truncatingRemainder(dividingBy: 1) == 0.5 })
        let swing = try GrooveArrangement(style: .swing).lanes()[2].notes
        XCTAssertTrue(swing.contains { abs($0.start - (4 + 2.0 / 3)) < 0.000001 })
        XCTAssertFalse(swing.contains { $0.start == 4.5 })
    }
    func testClockBoundariesAndInvalidInputs() throws {
        let p = GrooveArrangement(tempo: 60, loops: 1)
        XCTAssertNil(p.bar(at: -1))
        XCTAssertNil(p.bar(at: 3.99))
        XCTAssertEqual(p.bar(at: 4), 0)
        XCTAssertEqual(p.bar(at: 8), 1)
        XCTAssertNil(p.bar(at: 20))
        XCTAssertNil(p.bar(at: .nan))
        XCTAssertThrowsError(try GrooveArrangement(tempo: .nan).lanes())
        XCTAssertThrowsError(try GrooveArrangement(loops: 50).lanes())
    }
}
