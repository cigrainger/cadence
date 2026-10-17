// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Renderer/domain assertions establish readiness. Only scheduled UI actions
/// need a framing budget; static screens no longer inherit an eight-second nap.
/// Manual snapshots keep their conservative legacy delay.
enum SnapshotFraming {
    static func delay(arguments: [String]) -> Double {
        if arguments.contains("--song-ax") { return 30 }
        guard arguments.contains("--snapshot-requirements") else { return 10 }
        let actions: Set<String> = [
            "--reharm-detail", "--band-preview", "--study-bottom", "--practice-bottom", "--study-instrument",
            "--course-bottom", "--pathway-bottom", "--instruments", "--editor-live-edit",
            "--workspace-editor-roundtrip",
            "--harmony-sheet", "--tension-editor-guard", "--pdf-import-wizard", "--smooth-setup", "--tension-reading",
            "--midi-entry-check", "--pdf-review-check",
        ]
        return actions.isDisjoint(with: arguments) ? 0.6 : 3.5
    }
}
