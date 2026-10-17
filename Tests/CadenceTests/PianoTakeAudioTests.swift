// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class PianoTakeAudioTests: XCTestCase {
    func recording(velocity: Int = 85, pedal: Bool = false, channel: Int = 0) -> PianoRecording {
        var events: [PianoEvent] = []
        func add(_ message: MIDIMessage, _ time: Double) { events.append(PianoEvent(message, seconds: time)!) }
        if pedal { add(.control(channel: channel, number: 64, value: 127), 0) }
        add(.noteOn(channel: channel, note: 69, velocity: velocity), 0.1)
        add(.noteOff(channel: channel, note: 69), 0.35)
        if pedal { add(.control(channel: channel, number: 64, value: 0), 1.4) }
        return .init(events: events, end: 1.8)
    }
    func energy(_ samples: [Float], from: Double, through: Double) -> Double {
        let range = Int(from * 44100)..<min(samples.count, Int(through * 44100))
        return samples[range].reduce(0) { $0 + Double($1 * $1) } / Double(range.count)
    }
    func testRecordedSustainChangesAudibleDecayAfterPhysicalRelease() throws {
        let dry = try SampledAudio.renderTake(recording())
        let sustained = try SampledAudio.renderTake(recording(pedal: true))
        XCTAssertEqual(dry.count, Int(1.8 * 44100) + 15435)
        XCTAssertEqual(dry.count, sustained.count)
        XCTAssertGreaterThan(energy(sustained, from: 0.8, through: 1.2), energy(dry, from: 0.8, through: 1.2) * 3)
        XCTAssertTrue(sustained.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(sustained.map(abs).max() ?? 1, 0.9201)
    }
    func testTakeComparisonKeepsVelocityContrastInsteadOfNormalizingEachTake() throws {
        let soft = try SampledAudio.renderTake(recording(velocity: 40))
        let strong = try SampledAudio.renderTake(recording(velocity: 110))
        XCTAssertGreaterThan(energy(strong, from: 0.12, through: 0.3), energy(soft, from: 0.12, through: 0.3) * 2)
        XCTAssertTrue(soft.prefix(4000).allSatisfy { abs($0) < 0.00001 })
    }
    func testPianoOnOtherMIDIChannelsAndRepeatedPedalledNotesRender() throws {
        var r = recording(pedal: true, channel: 3)
        let more = [
            PianoEvent(.noteOn(channel: 3, note: 69, velocity: 100), seconds: 0.7)!,
            PianoEvent(.noteOff(channel: 3, note: 69), seconds: 0.9)!,
        ]
        r = .init(events: r.events + more, end: r.end)
        let data = try SampledAudio.renderTake(r)
        XCTAssertGreaterThan(energy(data, from: 0.75, through: 0.85), 0.00001)
        XCTAssertTrue(data.allSatisfy(\.isFinite))
    }
    func testEmptyInvalidAndMissingBankHaveExplicitOutcomes() throws {
        XCTAssertTrue(try SampledAudio.renderTake(.init(events: [], end: 1)).allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try SampledAudio.renderTake(.init(events: [], end: .infinity)))
        XCTAssertThrowsError(try SampledAudio.renderTake(recording(), bank: URL(fileURLWithPath: "/missing-piano.sf2")))
    }
}
