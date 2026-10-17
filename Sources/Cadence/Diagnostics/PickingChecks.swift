// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore

@MainActor enum PickingDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum PickingChecks {
    static func document() throws -> EditorDocument {
        var d = try EditorDocument.blank(instrument: .guitar, bars: 4, meter: .init(4, 4))
        d.title = "A small picking journey"
        d.harmonies = try ["C", "Am", "F", "G"].enumerated().map {
            try .init(bar: $0.offset, symbol: .parse($0.element))
        }
        return d
    }
    static func preview(_ state: AppState) throws {
        let d = try document()
        state.editor.documents.append(d)
        let args = CommandLine.arguments
        let style: PickingStyle =
            args.contains("--picking-classical")
            ? .classical : args.contains("--picking-strumming") ? .strumming : .travis
        try state.beginPicking(
            piece: .init(source: .score(d)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3), style: style)
        if args.contains("--picking-chord") { for _ in 0..<2 { state.pickingInput.submit(.tried, state: state) } }
        if args.contains("--picking-create") || args.contains("--picking-answer") {
            for _ in 0..<4 { state.pickingInput.submit(.tried, state: state) }
        }
        if args.contains("--picking-return") {
            for _ in 0..<5 { state.pickingInput.submit(.tried, state: state) }
            try state.resumePicking(state.pickingPractice.active!.id, independent: true)
        }
        if args.contains("--picking-answer") {
            try state.savePickingArrangement(style: style, tempo: 72, backbeat: true)
        }
        let material = state.pickingPractice.active!.material
        let generated = try material.document(style: style)
        PickingDiagnostics.checks = [
            "sourceLinked": material.current(in: .init(source: .score(d))),
            "validState": (try? state.practiceState.validated()) != nil,
            "playableTab": generated.playback().notes.count == generated.events.flatMap(\.pitches).count,
            "separateEvidence": state.journal.attempts.allSatisfy { $0.input == .selfReport },
            "localOnly": !state.microphone.listening && !state.audio.isPlaying,
        ]
    }
}
