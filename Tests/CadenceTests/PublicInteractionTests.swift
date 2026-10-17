// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class PublicInteractionTests: XCTestCase {
    @MainActor func testOfflineSynthesisDoesNotClaimADevicePlaybackCheck() async throws {
        let report = try await AudioPlayer().verifyOutput(deviceOutput: false)
        XCTAssertNil(report["audioOutput"])
        XCTAssertEqual(report["expressionDynamics"] as? Bool, true)
        XCTAssertEqual(report["expressionStaccato"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(report["synthFrequency"] as? Double), 440, accuracy: 1)
    }
    @MainActor func testGlobalStopCancelsChordAndImprovisationPreparation() throws {
        let state = AppState(preview: true)
        defer {
            state.stopAllPlayback()
            state.midi.shutdown()
        }
        let plan = try TimedChangesPlan(changes: .example, mode: .guides, tempo: 80, loops: 1)
        XCTAssertTrue(state.timedChangesSession.prepare(plan, conditions: .init(), held: []))
        state.timedChangesSession.begin(at: 100)
        try state.beginReharmExample(instrument: .piano)
        for _ in 0..<3 { state.reharmInput.submit(.skip, state: state) }
        let session = try XCTUnwrap(state.reharmPractice.active)
        XCTAssertTrue(
            state.reharmTransport.prepareRecording(session, version: .substitute, tempo: 84, offsetMS: 0, held: []))
        XCTAssertTrue(state.reharmTransport.busy)
        state.microphone.listening = true  // Simulated input state; never requests microphone permission.
        state.stopAllPlayback()
        XCTAssertFalse(state.microphone.listening)
        XCTAssertFalse(state.timedChangesSession.busy)
        XCTAssertFalse(state.reharmTransport.busy)
        XCTAssertFalse(state.timedSession.busy)
        XCTAssertFalse(state.rehearsalSession.timing.busy)
        XCTAssertFalse(state.playAlongSession.timing.busy)
    }

    @MainActor func testResourceLookupSurvivesFeatureFolderOrganisation() {
        for path in [
            "ScoreViewer/index.html", "EditorViewer/index.html", "SoundBanks/TimGM6mb.sf2",
            "ImportExamples/pathway.epub",
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: AppResources.url(path).path), path)
        }
    }
}
