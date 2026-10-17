// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// WebKit numbers are external input. In particular, converting NaN or infinity
/// to an Int traps; a malformed layout must become a recoverable renderer error.
struct RendererLayout: Sendable {
    let height: CGFloat
    let milliseconds: Int
    let targets: Int
    init?(_ data: [String: Any], defaultHeight: Double) {
        let height = data["height"] as? Double ?? defaultHeight
        let time = data["milliseconds"] as? Double ?? 0
        let targets = data["targets"] as? Int ?? 0
        guard height.isFinite, time.isFinite, (0...600_000).contains(time), (0...1_000_000).contains(targets),
            data["height"] == nil || data["height"] is Double,
            data["milliseconds"] == nil || data["milliseconds"] is Double,
            data["targets"] == nil || data["targets"] is Int
        else { return nil }
        self.height = CGFloat(min(100_000, max(160, height)))
        milliseconds = Int(time.rounded())
        self.targets = targets
    }
}
