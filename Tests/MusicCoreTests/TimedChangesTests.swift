// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class TimedChangesTests: XCTestCase {
    private func plan(_ mode: ChangesMode = .guides, loops: Int = 1) throws -> TimedChangesPlan {
        try TimedChangesPlan(changes: .example, mode: mode, tempo: 80, loops: loops)
    }
    private func source(
        _ symbols: [(Int, Int, String)], from: Int = 0, through: Int = 3, meter: EditorMeter = .init(4, 4)
    ) throws -> ChangesPlan {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 4, meter: meter)
        doc.harmonies = try symbols.map { EditorHarmony(bar: $0.0, tick: $0.1, symbol: try ChordSymbol.parse($0.2)) }
        return try ChangesSource(piece: LibraryPiece(source: .score(doc)), from: from, through: through).plan(staff: 1)
    }
    private func events(_ plan: TimedChangesPlan, shifts: [Int: Double] = [:]) throws -> [ChordKeyEvent] {
        var held = Set<Int>()
        var events: [ChordKeyEvent] = []
        for (i, cue) in plan.cues.enumerated() {
            let next = Set(try cue.target(plan.mode)?.pianoVoicings(previous: Array(held).sorted()).first ?? [])
            let seconds = cue.beat * plan.secondsPerBeat + (shifts[i] ?? 0)
            events += held.subtracting(next).map { .init(seconds: seconds, note: $0, down: false) }
            events += next.subtracting(held).map { .init(seconds: seconds, note: $0, down: true) }
            held = next
        }
        return events
    }
    func testFourBarExampleAndLoopBoundaryPreserveCommonTones() throws {
        let p = try plan(loops: 2)
        let input = try events(p)
        XCTAssertEqual(p.cues.map(\.beat), [0, 4, 8, 16, 20, 24])
        XCTAssertEqual(p.length, 32)
        XCTAssertEqual(p.countIn, 3)
        XCTAssertEqual(p.duration, 24)
        let report = try ChangesTimingMatcher.assess(p, events: input)
        XCTAssertTrue(report.clean)
        XCTAssertEqual(report.onTime, 6)
        // Two initial keys, then only the changing voice moves for each ii–V–I.
        XCTAssertEqual(input.filter(\.down).count, 8)
        XCTAssertEqual(p.cueIndex(at: -1), 0)
        XCTAssertEqual(p.cueIndex(at: 3.2), 1)
    }
    func testRootShellAndCompleteModesAcceptOctaveDoubling() throws {
        for mode in ChangesMode.allCases {
            let p = try plan(mode)
            let input = try events(p)
            XCTAssertTrue(try ChangesTimingMatcher.assess(p, events: input).clean)
        }
        let p = try plan(.roots)
        var input = try events(p)
        input += [.init(seconds: 0, note: 74, down: true), .init(seconds: 3, note: 74, down: false)]
        XCTAssertTrue(try ChangesTimingMatcher.assess(p, events: input).clean)
    }
    func testEarlyLateAndRecoveryDoNotCascade() throws {
        let p = try plan()
        let input = try events(p, shifts: [0: -0.2, 1: 0.18])
        let report = try ChangesTimingMatcher.assess(p, events: input)
        XCTAssertEqual(report.changes.map(\.timing), [.early, .late, .onTime])
        XCTAssertEqual(report.harmonicMatches, 3)
        XCTAssertEqual(report.recoveryCount, 1)
        XCTAssertEqual(report.difficultIndex, 0)
        XCTAssertEqual(report.changes[1].delta!, 0.18, accuracy: 0.00001)
    }
    func testRolledArrivalUsesCompletedShapeAndFleetingShapeDoesNotPass() throws {
        let p = try plan()
        let original = try events(p)
        var input = original
        let i = try XCTUnwrap(input.firstIndex { $0.down && $0.seconds == 0 })
        input[i].seconds = 0.08
        XCTAssertEqual(try ChangesTimingMatcher.assess(p, events: input).changes[0].delta!, 0.08, accuracy: 0.00001)
        input = original + [.init(seconds: 0.03, note: 54, down: true)]
        let report = try ChangesTimingMatcher.assess(p, events: input)
        XCTAssertFalse(report.changes[0].harmonyCorrect)
        XCTAssertGreaterThan(report.changes[0].strayPresses, 0)
    }
    func testHeldFromCountInIsEarlyAndSilenceIsMissing() throws {
        let p = try plan()
        let early = try events(p, shifts: [0: -2])
        XCTAssertEqual(try ChangesTimingMatcher.assess(p, events: early).changes[0].timing, .early)
        let missing = try ChangesTimingMatcher.assess(p, events: [])
        XCTAssertEqual(missing.harmonicMatches, 0)
        XCTAssertTrue(missing.changes.allSatisfy { !$0.missing.isEmpty })
    }
    func testSameHarmonyCanStayHeldAndNCRequiresRelease() throws {
        let base = try source([(0, 0, "Cmaj7"), (1, 0, "Cmaj7"), (2, 0, "N.C."), (3, 0, "Dm7")])
        let p = try TimedChangesPlan(changes: base, mode: .guides, loops: 1)
        let input = try events(p)
        let report = try ChangesTimingMatcher.assess(p, events: input)
        XCTAssertTrue(report.clean)
        XCTAssertEqual(report.changes[1].timing, .held)
        let withoutRelease = input.filter { !(!$0.down && $0.seconds == 6) }
        XCTAssertFalse(try ChangesTimingMatcher.assess(p, events: withoutRelease).changes[2].harmonyCorrect)
        let late = try events(p, shifts: [2: 0.2])
        XCTAssertEqual(try ChangesTimingMatcher.assess(p, events: late).changes[2].timing, .late)
    }
    func testMissingExtraAndSlashBassAreReportedSeparately() throws {
        let p = try TimedChangesPlan(changes: source([(0, 0, "Cmaj7/E")]), mode: .complete, loops: 1)
        let wrongBass = [48, 52, 55, 59].map { ChordKeyEvent(seconds: 0, note: $0, down: true) }
        let report = try ChangesTimingMatcher.assess(p, events: wrongBass)
        XCTAssertFalse(report.changes[0].bassCorrect)
        XCTAssertTrue(report.changes[0].missing.isEmpty)
        XCTAssertTrue(try ChangesTimingMatcher.assess(p, events: events(p)).clean)
        let g = try plan()
        let input = [ChordKeyEvent(seconds: 0, note: 53, down: true), .init(seconds: 0, note: 61, down: true)]
        let j = try ChangesTimingMatcher.assess(g, events: input).changes[0]
        XCTAssertEqual(j.missing, [0])
        XCTAssertEqual(j.extra, [1])
        XCTAssertEqual(j.strayPresses, 1)
    }
    func testTimestampOrderDuplicatesChannelsAndSimultaneousReplacement() throws {
        let p = try plan()
        let original = try events(p)
        XCTAssertTrue(try ChangesTimingMatcher.assess(p, events: original.reversed()).clean)
        XCTAssertTrue(try ChangesTimingMatcher.assess(p, events: original + original).clean)
        // A second channel keeps C down when channel zero releases it; this must block G7.
        var input = original + [.init(seconds: 0, note: 60, channel: 1, down: true)]
        XCTAssertFalse(try ChangesTimingMatcher.assess(p, events: input).changes[1].harmonyCorrect)
        input.append(.init(seconds: 3, note: 60, channel: 1, down: false))
        XCTAssertTrue(try ChangesTimingMatcher.assess(p, events: input).clean)
    }
    func testWindowBoundariesAndWrongKeyAfterMatchingStillCount() throws {
        let p = try plan()
        let edge = try ChangesTimingMatcher.assess(p, events: events(p, shifts: [0: 0.1, 1: -0.1]))
        XCTAssertTrue(edge.clean)
        let distant = try ChangesTimingMatcher.assess(p, events: events(p, shifts: [1: 0.7]))
        XCTAssertEqual(distant.changes[1].timing, .missed)
        XCTAssertEqual(distant.changes[2].timing, .onTime)
        let extra =
            try events(p) + [
                ChordKeyEvent(seconds: 0.15, note: 54, down: true), .init(seconds: 0.25, note: 54, down: false),
            ]
        let report = try ChangesTimingMatcher.assess(p, events: extra)
        XCTAssertTrue(report.changes[0].harmonyCorrect)
        XCTAssertFalse(report.changes[0].clean)
        XCTAssertEqual(report.changes[0].strayPresses, 1)
    }
    func testSourceCarryLeadingSilenceAndFocusedSelection() throws {
        let carried = try TimedChangesPlan(
            changes: source([(0, 0, "Dm7"), (2, 0, "G7")], from: 1, through: 3), mode: .guides, loops: 1)
        XCTAssertEqual(carried.cues.map(\.beat), [0, 4])
        XCTAssertEqual(carried.cues[0].bar, 1)
        let leading = try TimedChangesPlan(changes: source([(0, 480, "Dm7"), (2, 0, "G7")]), mode: .guides, loops: 1)
        XCTAssertTrue(leading.cues[0].isRest)
        XCTAssertEqual(leading.cues[1].beat, 1)
        XCTAssertTrue(try ChangesTimingMatcher.assess(leading, events: events(leading)).clean)
        let focused = try TimedChangesPlan(changes: .example, mode: .guides, loops: 2, focus: [1, 2])
        XCTAssertEqual(focused.cues.map(\.beat), [0, 4, 8, 12])
        XCTAssertEqual(focused.cues.map(\.bar), [1, 2, 1, 2])
        XCTAssertEqual(focused.loopLength, 8)
        let middle = try TimedChangesPlan(
            changes: source([(0, 0, "Dm7"), (0, 960, "G7"), (1, 0, "Cmaj7")]), mode: .guides, loops: 1, focus: [1, 1])
        XCTAssertEqual(middle.loopLength, 4)  // Whole source bar, not a displaced downbeat.
        XCTAssertEqual(middle.cues.map(\.beat), [0, 2])
        XCTAssertThrowsError(try TimedChangesPlan(changes: .example, mode: .guides, focus: [2, 1]))
        XCTAssertThrowsError(try TimedChangesPlan(changes: .example, mode: .guides, focus: [0, 9]))
    }
    func testUnsupportedMetersModesRatesAndDenseChangesFailExplicitly() throws {
        XCTAssertThrowsError(try TimedChangesPlan(changes: source([(0, 0, "C")]), mode: .guides))
        XCTAssertThrowsError(try TimedChangesPlan(changes: source([(0, 0, "Dm7")], meter: .init(6, 8)), mode: .guides))
        XCTAssertThrowsError(try TimedChangesPlan(changes: source([(0, 0, "Dm7"), (0, 120, "G7")]), mode: .guides))
        XCTAssertThrowsError(try TimedChangesPlan(changes: .example, mode: .roots, tempo: 0))
        XCTAssertThrowsError(try TimedChangesPlan(changes: .example, mode: .roots, tempo: 40, loops: 4))
        XCTAssertThrowsError(try TimedChangesPlan(changes: .example, mode: .roots, loops: 0))
        for meter in [EditorMeter(2, 4), EditorMeter(3, 4)] {
            XCTAssertTrue(
                try TimedChangesPlan(changes: source([(0, 0, "C")], meter: meter), mode: .roots, loops: 1).valid)
        }
    }
    func testMalformedResultsAndHistoryAreRejected() throws {
        let p = try plan()
        for event in [
            ChordKeyEvent(seconds: .nan, note: 60, down: true), .init(seconds: -7, note: 60, down: true),
            .init(seconds: 0, note: 128, down: true), .init(seconds: 0, note: 60, channel: 16, down: true),
            .init(seconds: p.duration + 0.6, note: 60, down: true),
        ] {
            XCTAssertThrowsError(try ChangesTimingMatcher.assess(p, events: [event]))
            XCTAssertFalse(TimedChangesResult(plan: p, conditions: .init(), events: [event]).valid)
        }
        XCTAssertThrowsError(
            try ChangesTimingMatcher.assess(
                p, events: Array(repeating: .init(seconds: 0, note: 60, down: true), count: 4097)))
        var broken = p
        broken.cues[1].beat = -1
        XCTAssertFalse(broken.valid)
        broken = p
        broken.fingerprint = "bad"
        XCTAssertFalse(broken.valid)
        broken = p
        broken.cues = []
        XCTAssertFalse(broken.valid)
        broken = p
        broken.cues[0].sourceIndex = 100
        XCTAssertFalse(broken.valid)
        var result = TimedChangesResult(plan: p, conditions: .init(), events: [])
        result.conditions.offsetMS = 251
        XCTAssertFalse(result.valid)
        result.conditions.offsetMS = 0
        result.date = Date(timeIntervalSince1970: .infinity)
        XCTAssertFalse(result.valid)
        var progress = PracticeProgress()
        progress.timedChanges = ["wrong-key": .init(result: .init(plan: p, conditions: .init(), events: []))]
        XCTAssertThrowsError(try progress.validated())
        progress.timedChanges = [p.identity(.init()): .init(result: .init(plan: p, conditions: .init(), events: []))]
        XCTAssertNoThrow(try progress.validated())
        var future = PracticeState()
        future.schemaVersion = 16
        XCTAssertThrowsError(try future.validated())
    }
    func testConditionsIdentitiesSupportGradesAndRoundTrip() throws {
        let p = try plan()
        let input = try events(p)
        var r = TimedChangesResult(plan: p, conditions: .init(), events: input)
        XCTAssertEqual(r.grade, .good)
        XCTAssertFalse(r.assisted)
        let id = r.practiceID
        r.conditions.bass = true
        XCTAssertEqual(r.grade, .supported)
        XCTAssertNotEqual(r.practiceID, id)
        r.conditions = .init(hints: true)
        XCTAssertEqual(r.grade, .supported)
        r.conditions = .init()
        r.events[0].arrivalTimestamp = true
        XCTAssertEqual(r.grade, .supported)
        r.events = []
        XCTAssertEqual(r.grade, .again)
        XCTAssertEqual(try JSONDecoder().decode(TimedChangesResult.self, from: JSONEncoder().encode(r)), r)
        XCTAssertTrue(r.evidence.contains("physical key sets"))
        XCTAssertTrue(r.evidence.contains("80 bpm"))
        let identities = [
            ChangesTimingConditions(), .init(click: false), .init(bass: true), .init(hints: true), .init(offsetMS: 50),
        ].map(p.identity)
        XCTAssertEqual(Set(identities).count, 5)
    }
    func testAudioCountInSilentPracticeBassDemoAndNC() throws {
        let p = try TimedChangesPlan(
            changes: source([(0, 0, "Dm7"), (1, 0, "N.C."), (2, 0, "G7")]), mode: .guides, loops: 1)
        let rate = 8000.0
        let start = Int(p.countIn * rate)
        let after = Int((p.countIn + 3.1) * rate)
        let quiet = try ChangesAudioTrack.render(p, conditions: .init(click: false), sampleRate: rate)
        XCTAssertTrue(quiet[..<start].contains { abs($0) > 0.1 })
        XCTAssertTrue(quiet[start...].allSatisfy { $0 == 0 })
        let bass = try ChangesAudioTrack.render(p, conditions: .init(click: false, bass: true), sampleRate: rate)
        XCTAssertTrue(bass[start..<(start + 800)].contains { abs($0) > 0.05 })
        XCTAssertTrue(bass[after..<(after + 800)].allSatisfy { $0 == 0 })
        let demo = try ChangesAudioTrack.render(
            p, conditions: .init(click: true, bass: true), demonstration: true, sampleRate: rate)
        XCTAssertTrue(demo.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
        XCTAssertNotEqual(demo, bass)
        XCTAssertThrowsError(try ChangesAudioTrack.render(p, conditions: .init(offsetMS: 300), sampleRate: rate))
        XCTAssertThrowsError(try ChangesAudioTrack.render(p, conditions: .init(), sampleRate: 0))
    }
}
