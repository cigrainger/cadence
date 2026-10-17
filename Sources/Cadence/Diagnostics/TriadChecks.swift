// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum TriadDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum TriadChecks {
    static func document() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 4, meter: .init(4, 4))
        doc.title = "A little journey home"
        doc.harmonies = try ["Dm7", "G7", "Cmaj7", "Cmaj7"].enumerated().map {
            EditorHarmony(bar: $0.offset, symbol: try ChordSymbol.parse($0.element))
        }
        return doc
    }
    static func preview(state: AppState) throws {
        let doc = try document()
        state.editor.documents.append(doc)
        try state.beginTriads(
            piece: .init(source: .score(doc)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3), group: 0)
        let args = CommandLine.arguments
        if ["--triad-connect", "--triad-ear", "--triad-create", "--triad-complete", "--triad-answer"].contains(
            where: args.contains)
        {
            while state.triadPractice.active?.stage == .find {
                let s = state.triadPractice.active!
                state.triadInput.submit(.inversion(s.material.route[s.cursor].inversion), state: state)
            }
        }
        if ["--triad-ear", "--triad-create", "--triad-complete", "--triad-answer"].contains(where: args.contains) {
            state.triadInput.submit(.connected, state: state)
        }
        if ["--triad-create", "--triad-complete", "--triad-answer"].contains(where: args.contains) {
            let notes = state.triadPractice.active!.material.earNotes
            state.triadInput.arm(state)
            for (i, note) in notes.enumerated() {
                for offset in [0.0, 0.2, 0.4] {
                    state.triadInput.receive(
                        DetectedPitch(frequency: 440 * pow(2, Double(note - 69) / 12), confidence: 0.99),
                        at: Double(i) + offset, state: state)
                }
            }
            guard state.triadInput.notes == notes else {
                throw MusicError.invalid("The virtual guitar pitches were not captured.")
            }
            state.triadInput.submit(.microphone(state.triadInput.notes), state: state)
        }
        if args.contains("--triad-complete") { state.triadInput.submit(.finish, state: state) }
        if args.contains("--triad-answer") { try state.openTriadAnswer() }
        var checks = [
            "sourceLinked": state.triadPractice.active?.material.current(in: .init(source: .score(doc))) == true,
            "validState": (try? state.practiceState.validated()) != nil,
            "separateEvidence": state.journal.attempts.allSatisfy(\.assisted),
            "noMicrophonePermissionNeeded": !state.microphone.listening,
        ]
        if args.contains("--triad-create") || args.contains("--triad-complete") || args.contains("--triad-answer") {
            checks["microphonePitchMatch"] =
                state.journal.attempts.last { $0.input == .microphone }?.outcome == .correct
        }
        if args.contains("--triad-answer") {
            checks["editableSourceLinkedAnswer"] =
                state.editor.active.triadSource?.pieceID == "score:" + doc.id.uuidString
                && state.editor.active.barCount == 2
        }
        if args.contains("--triad-complete") {
            checks["spacedSupportedReview"] = state.triadPractice.active?.review.lastGrade == .supported
        }
        TriadDiagnostics.checks = checks
    }
}
