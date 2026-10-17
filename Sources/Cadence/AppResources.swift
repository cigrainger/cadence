// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The source fallback is used by package tests and `swift run`. Keep this file
/// at the target root so feature folders never affect resource discovery.
enum AppResources {
    static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)

    static func url(_ path: String) -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(path),
            FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        return sourceDirectory.appendingPathComponent(path)
    }
}
