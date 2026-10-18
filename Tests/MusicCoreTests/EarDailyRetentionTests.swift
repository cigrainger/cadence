// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class EarDailyRetentionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = 1000.0
    private let route = "daily-retention-fixture"

    private func document() throws -> EditorDocument {
        let events = (0..<4).flatMap { bar in
            [52 + bar * 2, 55 + bar * 2].map { midi in
                let position = Guitar.positions(midi: midi, tuning: Tuning.presets[0], capo: 0).min {
                    $0.fret < $1.fret
                }!
                return EditorEvent(
                    bar: bar, rhythm: EditorRhythm(960),
                    pitches: [EditorPitch(midi, string: position.string, fret: position.fret)])
            }
        }
        return try EditorDocument(title: "A little space to return", instrument: .guitar, events: events).validated()
    }

    private func plan(
        _ document: EditorDocument? = nil, from: Int = 1, through: Int = 4
    ) throws -> MicrophonePhrasePlan {
        let document = try document ?? self.document()
        let piece = LibraryPiece(source: .score(document))
        let material = try ScoreEarMaterial(
            piece: piece, scope: .init(fromBar: from, throughBar: through, partID: "P1", partName: "Guitar"),
            staff: 1, voice: "1")
        return try MicrophonePhrasePlan(material: material, source: piece)
    }

    private func daily(_ stage: EarDailyStage, material: ScoreEarMaterial) throws -> EarDailySession {
        var session = try EarDailySession(
            journeyID: UUID(), material: material, instrument: .guitar, mode: .learning, now: date)
        if stage == .hear { return session }
        try session.heard(now: date)
        if stage == .imagine { return session }
        try session.imagined(now: date)
        if stage == .play { return session }
        try session.record(attemptID: UUID(), now: date)
        if stage == .review { return session }
        try session.beginAnswer(now: date)
        if stage == .create { return session }
        try session.finish(now: date)
        return session
    }

    private func take(
        _ plan: MicrophonePhrasePlan, at date: Date, calibrated: Bool = false
    ) -> MicrophonePhraseTake {
        let mapping = AcousticClockEvidence(
            firstSampleTime: 4800, firstHostSeconds: origin - 0.5, sampleRate: 48000,
            frameCount: Int(ceil((plan.timed.duration + 2) * 48000)), maximumHostResidualMS: 2)
        let calibration = AcousticCalibration(
            routeID: route, sampleRate: 48000, offsetMS: 120, jitterMS: 5, date: date, matchedPulses: 8,
            clockEvidence: AcousticClockEvidence(
                firstSampleTime: 4800, firstHostSeconds: origin - 100, sampleRate: 48000,
                frameCount: 384000, maximumHostResidualMS: 2))
        let attacks = plan.timed.targets.map { target in
            let host = origin + target.beat * plan.timed.secondsPerBeat + (calibrated ? 0.120 : 0)
            var attack = AcousticAttack(
                hostSeconds: host, frequency: 440 * pow(2, Double(target.pitch - 69) / 12),
                confidence: 0.98, rms: 0.1, clippedFraction: 0, onsetUncertaintyMS: 10)
            attack.sampleTime = mapping.sampleTime(at: host)
            attack.sampleRate = mapping.sampleRate
            return attack
        }
        return MicrophonePhraseTake(
            date: date, plan: plan, originHostSeconds: origin, calibration: calibrated ? calibration : nil,
            routeID: route, sampleRate: 48000, attacks: attacks, clock: .sharedHost, clockEvidence: mapping)
    }

    func testArchivePreservesEveryIncompleteStageAndSelectedCompletedSession() throws {
        let material = try plan().material
        let incomplete = try [EarDailyStage.hear, .imagine, .play, .review, .create].map {
            try daily($0, material: material)
        }
        let first = try daily(.complete, material: material)
        let selected = try daily(.complete, material: material)
        let last = try daily(.complete, material: material)
        var book = EarDailyPractice()
        book.sessions = [first] + incomplete + [selected, last]
        book.selectedID = selected.id

        XCTAssertEqual(try book.archiveCompleted(), [first, last])
        XCTAssertEqual(book.sessions, incomplete + [selected])
        XCTAssertEqual(book.active, selected)
        XCTAssertEqual(try book.archiveCompleted(), [])
        XCTAssertNoThrow(try book.validated())

        book.selectedID = incomplete[0].id
        XCTAssertEqual(try book.archiveCompleted(), [selected])
        XCTAssertEqual(book.sessions, incomplete)
        XCTAssertEqual(book.active, incomplete[0])
    }

    func testArchiveCanRetireAllCompletedSessionsWithoutASelection() throws {
        var book = EarDailyPractice()
        let completed = try daily(.complete, material: plan().material)
        book.sessions = [completed]
        XCTAssertEqual(try book.archiveCompleted(), [completed])
        XCTAssertTrue(book.sessions.isEmpty)
        XCTAssertNil(book.selectedID)
        XCTAssertNoThrow(try book.validated())
    }

    func testExplicitArchiveReopensDailyCapacityWithoutSilentEviction() throws {
        let material = try plan().material
        var book = EarDailyPractice()
        for _ in 0..<32 { try book.open(daily(.complete, material: material)) }
        let selected = try XCTUnwrap(book.active)
        let next = try daily(.hear, material: material)
        let full = book
        XCTAssertThrowsError(try book.open(next))
        XCTAssertEqual(book, full)

        let retired = try book.archiveCompleted()
        XCTAssertEqual(retired, Array(full.sessions.dropLast()))
        XCTAssertEqual(book.sessions, [selected])
        try book.open(next)
        XCTAssertEqual(book.sessions, [selected, next])
        XCTAssertEqual(book.active, next)
    }

    func testArchiveRejectsInvalidCollectionWithoutMutation() throws {
        let session = try daily(.complete, material: plan().material)
        var book = EarDailyPractice()
        book.sessions = [session]
        book.selectedID = UUID()
        let invalidSelection = book
        XCTAssertThrowsError(try book.archiveCompleted())
        XCTAssertEqual(book, invalidSelection)

        book.selectedID = nil
        book.sessions.append(session)
        let duplicate = book
        XCTAssertThrowsError(try book.archiveCompleted())
        XCTAssertEqual(book, duplicate)
    }

    func testRetirementReturnsFullRecordsAndRetainsEachSourcesLatestExposure() throws {
        let first = try plan()
        let second = try plan()
        let early = take(first, at: date)
        var latest = take(first, at: date.addingTimeInterval(10))
        latest.disputedTargets = [0]
        latest.signalIssue = "Synthetic uncertain capture"
        let other = take(second, at: date.addingTimeInterval(20))
        var book = MicrophonePhrasePractice()
        try book.open(first)
        _ = try book.record(early)
        _ = try book.record(latest)
        try book.open(second)
        _ = try book.record(other)
        let reviews = book.sessions.map(\.review)
        let firstDue = book.returnDate(first.key)
        let secondDue = book.returnDate(second.key)

        let retired = try book.retirePitchOnlyTakes([early.id, latest.id, other.id])
        XCTAssertEqual(retired, [early, latest, other])
        XCTAssertEqual(retired[1].attacks, latest.attacks)
        XCTAssertEqual(retired[1].disputedTargets, [0])
        XCTAssertEqual(retired[1].signalIssue, latest.signalIssue)
        XCTAssertTrue(book.sessions.allSatisfy { $0.takes.isEmpty })
        XCTAssertEqual(book.sessions[0].unkeptPracticeDates, [latest.date])
        XCTAssertEqual(book.sessions[1].unkeptPracticeDates, [other.date])
        XCTAssertEqual(book.returnDate(first.key), firstDue)
        XCTAssertEqual(book.returnDate(second.key), secondDue)
        XCTAssertEqual(book.sessions.map(\.review), reviews)
        XCTAssertEqual(book.selectedID, second.key)
        XCTAssertNoThrow(try book.validated())
    }

    func testRetirementPreservesCutoffAcrossOverlappingScopes() throws {
        let document = try document()
        let first = try plan(document, from: 1, through: 2)
        let overlap = try plan(document, from: 2, through: 3)
        let early = take(first, at: date)
        let later = take(overlap, at: date.addingTimeInterval(30))
        var book = MicrophonePhrasePractice()
        try book.open(first)
        _ = try book.record(early)
        try book.open(overlap)
        _ = try book.record(later)
        let cutoff = later.date.addingTimeInterval(20 * 3600)

        XCTAssertEqual(try book.retirePitchOnlyTakes([early.id, later.id]), [early, later])
        XCTAssertEqual(book.returnDate(first.key), cutoff)
        XCTAssertEqual(book.returnDate(overlap.key), cutoff)
        XCTAssertNoThrow(try book.validated())
    }

    func testPitchOnlyRetirementKeepsBaselineIndependentEvidenceAndTimedReview() throws {
        let plan = try plan()
        let baseline = take(plan, at: date, calibrated: true)
        let independent = take(
            try plan.whole(mode: .independent), at: date.addingTimeInterval(86400), calibrated: true)
        let pitchOnly = take(plan, at: date.addingTimeInterval(2 * 86400))
        var book = MicrophonePhrasePractice()
        try book.open(plan)
        for take in [baseline, independent, pitchOnly] { _ = try book.record(take) }
        let review = try XCTUnwrap(book.active?.review)
        let cutoff = book.returnDate(plan.key)
        XCTAssertTrue(baseline.report.conclusive)
        XCTAssertTrue(independent.report.conclusive)
        XCTAssertFalse(pitchOnly.report.conclusive)

        XCTAssertEqual(try book.retirePitchOnlyTakes([pitchOnly.id]), [pitchOnly])
        XCTAssertEqual(book.active?.takes, [baseline, independent])
        XCTAssertEqual(book.active?.baseline, baseline)
        XCTAssertEqual(book.active?.review, review)
        XCTAssertEqual(book.returnDate(plan.key), cutoff)
        XCTAssertNoThrow(try book.validated())
    }

    func testCalibratedAndIndependentRequestsRejectWholeMixedSetAtomically() throws {
        let plan = try plan()
        let baseline = take(plan, at: date, calibrated: true)
        var uncertain = take(plan, at: date.addingTimeInterval(1), calibrated: true)
        uncertain.disputedTargets = [0]
        let independent = take(try plan.whole(mode: .independent), at: date.addingTimeInterval(86400))
        let removable = take(plan, at: date.addingTimeInterval(2 * 86400))
        var book = MicrophonePhrasePractice()
        try book.open(plan)
        for take in [baseline, uncertain, independent, removable] { _ = try book.record(take) }
        XCTAssertFalse(uncertain.report.conclusive)
        XCTAssertNil(independent.calibration)
        XCTAssertFalse(independent.report.conclusive)
        let before = book

        for protected in [baseline, uncertain, independent] {
            XCTAssertThrowsError(try book.retirePitchOnlyTakes([protected.id]))
            XCTAssertEqual(book, before)
            XCTAssertThrowsError(try book.retirePitchOnlyTakes([removable.id, protected.id]))
            XCTAssertEqual(book, before)
        }
    }

    func testUnknownRequestsAndInvalidCollectionAreAtomicEvenForEmptyRequest() throws {
        let plan = try plan()
        let take = take(plan, at: date)
        var book = MicrophonePhrasePractice()
        try book.open(plan)
        _ = try book.record(take)
        let before = book
        XCTAssertEqual(try book.retirePitchOnlyTakes([]), [])
        XCTAssertEqual(book, before)
        XCTAssertThrowsError(try book.retirePitchOnlyTakes([UUID()]))
        XCTAssertEqual(book, before)
        XCTAssertThrowsError(try book.retirePitchOnlyTakes([take.id, UUID()]))
        XCTAssertEqual(book, before)

        book.sessions[0].takes.append(take)
        let duplicate = book
        XCTAssertThrowsError(try book.retirePitchOnlyTakes([take.id]))
        XCTAssertEqual(book, duplicate)
        XCTAssertThrowsError(try book.retirePitchOnlyTakes([]))
        XCTAssertEqual(book, duplicate)
    }

    func testExplicitPitchOnlyRetirementReopensCapacityAndKeepsUnrequestedTake() throws {
        let plan = try plan()
        var book = MicrophonePhrasePractice()
        try book.open(plan)
        let takes = (0..<16).map { take(plan, at: date.addingTimeInterval(Double($0))) }
        for take in takes { _ = try book.record(take) }
        let next = take(plan, at: date.addingTimeInterval(16))
        let full = book
        XCTAssertThrowsError(try book.record(next))
        XCTAssertEqual(book, full)

        let requested = Array(takes.dropLast())
        XCTAssertEqual(try book.retirePitchOnlyTakes(Set(requested.map(\.id))), requested)
        XCTAssertEqual(book.active?.takes, [takes[15]])
        _ = try book.record(next)
        XCTAssertEqual(book.active?.takes, [takes[15], next])
        XCTAssertNoThrow(try book.validated())
    }
}
