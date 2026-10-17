// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum ReharmDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum ReharmChecks {
    static func preview(state: AppState) throws {
        let args = CommandLine.arguments
        let guitar = args.contains("--reharm-guitar")
        state.midi.installPreview()
        try state.beginReharmExample(instrument: guitar ? .guitar : .piano)
        let s = state.reharmPractice.active!
        let original = state.libraryPieces.first { $0.id == s.source.pieceID }!
        if [
            "--reharm-explain", "--reharm-play", "--reharm-create", "--reharm-pending", "--reharm-takes",
            "--reharm-complete", "--reharm-ending", "--reharm-review",
        ].contains(where: args.contains) {
            state.reharmInput.submit(.heard(0), state: state)
            state.reharmInput.submit(.heard(1), state: state)
            state.reharmInput.submit(.hearing(state.reharmPractice.active!.substituteSlot), state: state)
        }
        if [
            "--reharm-play", "--reharm-create", "--reharm-pending", "--reharm-takes", "--reharm-complete",
            "--reharm-ending", "--reharm-review",
        ].contains(where: args.contains) {
            state.reharmInput.submit(.explanation(0), state: state)
        }
        if [
            "--reharm-create", "--reharm-pending", "--reharm-takes", "--reharm-complete", "--reharm-ending",
            "--reharm-review",
        ].contains(where: args.contains) {
            if guitar {
                state.reharmInput.submit(.guitarReport, state: state)
            } else {
                state.reharmInput.arm(state)
                var keys = MIDIKeyboardState()
                for pair in try s.source.guideVoicings(.substitute) {
                    let messages =
                        pair.map { MIDIMessage.noteOn(channel: 0, note: $0, velocity: 80) }
                        + pair.map { .noteOff(channel: 0, note: $0) }
                    for message in messages {
                        keys.receive(message)
                        state.reharmInput.receive(.init(message: message, keyboard: keys), state: state)
                    }
                }
            }
        }
        if ["--reharm-pending", "--reharm-takes", "--reharm-complete", "--reharm-ending", "--reharm-review"].contains(
            where: args.contains)
        {
            let document = try state.saveReharmAlternative()
            if args.contains("--reharm-ending") {
                state.returnToCompose(document.id)
            } else {
                let session = state.reharmPractice.active!
                let transport = state.reharmTransport
                guard transport.prepareRecording(session, version: .substitute, tempo: 84, offsetMS: 0, held: []) else {
                    throw MusicError.invalid("Preview could not prepare MIDI capture.")
                }
                transport.begin(at: 0, record: true)
                var keys = MIDIKeyboardState()
                for (i, note) in [65, 64, 65, 71, 64, 67, 71, 72].enumerated() {
                    for (time, message) in [
                        (Double(i) * 1.1 + 0.2, MIDIMessage.noteOn(channel: 0, note: note, velocity: 78 + i)),
                        (Double(i) * 1.1 + 0.8, .noteOff(channel: 0, note: note)),
                    ] {
                        keys.receive(message)
                        transport.receive(.init(message: message, keyboard: keys, timestamp: time), state: state)
                    }
                }
                transport.tick()
                guard transport.pending?.valid == true else {
                    throw MusicError.invalid("Preview MIDI recording did not finish.")
                }
                if !args.contains("--reharm-pending") {
                    try state.saveReharmTake()
                    let take = state.reharmPractice.takes.last!
                    transport.replay(take, over: .original)
                    transport.begin(at: 0, record: false)
                    transport.tick()
                    try state.markReharmTakeListened(take.id)
                    if args.contains("--reharm-complete") || args.contains("--reharm-review") {
                        state.reharmInput.submit(
                            .creation("I kept the rhythmic idea, then landed on E as the bass reached C."), state: state
                        )
                    }
                }
            }
        }
        if args.contains("--reharm-review") { try state.resumeReharm(state.reharmPractice.active!.id, skill: .playing) }
        guard state.reharmInput.pending == nil else {
            throw MusicError.invalid(state.reharmInput.error ?? "Preview answer could not save.")
        }
        var checks = [
            "sourceLinked": state.reharmPractice.active?.source.current(in: original) == true,
            "validState": (try? state.practiceState.validated()) != nil,
            "sourceUnchanged": state.libraryPieces.first { $0.id == original.id }?.fingerprint == original.fingerprint,
            "sharedGuideTones": try s.source.guideVoicings(.original) == s.source.guideVoicings(.substitute),
        ]
        if args.contains("--reharm-ending") || args.contains("--reharm-takes") || args.contains("--reharm-complete") {
            checks["savedFullAlternative"] = state.reharmAlternative(s.source)?.barCount == original.bars
        }
        if args.contains("--reharm-takes") || args.contains("--reharm-complete") {
            checks["recordedAndListened"] = state.reharmPractice.takes.last?.listened == true
        }
        if args.contains("--reharm-pending") {
            checks["pendingTakeRetained"] = state.reharmTransport.pending?.valid == true
        }
        if args.contains("--reharm-complete") {
            checks["fourReviews"] = state.reharmPractice.active?.reviews.count == 4
        }
        if args.contains("--reharm-review") {
            checks["independentReturn"] =
                state.reharmPractice.active?.independent == true && state.reharmPractice.active?.assisted == false
        }
        ReharmDiagnostics.checks = checks
    }
}
