// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Keep the preferred workspace on larger screens and fit its initial geometry
/// to smaller displays. The workspace already scrolls its music.
struct WorkspaceWindowLayout {
    static let preferredMinimum = CGSize(width: 1120, height: 760)
    static let preferredInitial = CGSize(width: 1350, height: 980)
    let minimum: CGSize
    let initial: CGSize

    static func fitting(_ visibleScreen: CGSize?) -> Self {
        guard let visibleScreen,
            visibleScreen.width.isFinite, visibleScreen.height.isFinite,
            visibleScreen.width > 0, visibleScreen.height > 0
        else { return Self(minimum: preferredMinimum, initial: preferredInitial) }
        // Reserve room for system window chrome instead of requiring a content
        // minimum that is already larger than the entire available display.
        let content = CGSize(width: max(1, visibleScreen.width - 20), height: max(1, visibleScreen.height - 40))
        func fit(_ size: CGSize) -> CGSize {
            CGSize(width: min(size.width, content.width), height: min(size.height, content.height))
        }
        return Self(minimum: fit(preferredMinimum), initial: fit(preferredInitial))
    }
}
