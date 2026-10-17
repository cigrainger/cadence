// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AppKit
import MusicCore
import XCTest

@testable import Cadence

final class CalibrationNotificationTests: XCTestCase {
    @MainActor func testBackgroundAudioChangeInvalidatesCalibrationOnTheOwnerActor() async throws {
        let notifications = NotificationCenter()
        let workspace = NotificationCenter()
        var clock = 100.0
        let session = CalibratedPracticeSession(
            clock: { clock }, notifications: notifications, workspaceNotifications: workspace)
        let plan = TimedPracticePlan.calibration()
        XCTAssertTrue(session.timing.prepare(plan, conditions: .init(), held: [], calibration: true))
        session.timing.begin(at: clock)
        for target in plan.targets {
            session.timing.attack(at: 100 + target.beat * plan.secondsPerBeat + 0.07)
        }
        clock += plan.duration + 1
        session.timing.tick()
        session.applyCalibration()
        XCTAssertTrue(session.calibrated)
        XCTAssertEqual(session.offsetMS, 70)
        await Task.detached { notifications.post(name: .AVAudioEngineConfigurationChange, object: nil) }.value
        for _ in 0..<100 {
            if !session.calibrated { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(session.calibrated)
        XCTAssertEqual(session.offsetMS, 0)
        XCTAssertNil(session.timing.calibrationReport)
    }

    @MainActor func testBackgroundSleepNotificationCancelsAnActivePass() async throws {
        let notifications = NotificationCenter()
        let workspace = NotificationCenter()
        let session = CalibratedPracticeSession(notifications: notifications, workspaceNotifications: workspace)
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        XCTAssertTrue(session.timing.prepare(plan, conditions: .init(), held: []))
        session.timing.begin(at: PracticeClock.now())
        XCTAssertTrue(session.timing.active)
        await Task.detached { workspace.post(name: NSWorkspace.willSleepNotification, object: nil) }.value
        for _ in 0..<100 {
            if !session.timing.active { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(session.timing.active)
        XCTAssertFalse(session.timing.busy)
        XCTAssertFalse(session.calibrated)
    }
}
