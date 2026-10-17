// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The launch driver supplies the same assertions it checks after capture.
/// A fast domain fixture alone cannot establish that its score has rendered.
struct SnapshotRequirements: Codable {
    let scenario: String
    let rendererFlags: [String]
    let group: String?
    let groupFlags: [String]

    static func read(arguments: [String]) throws -> Self? {
        guard let index = arguments.firstIndex(of: "--snapshot-requirements") else { return nil }
        guard index + 1 < arguments.count else { throw CocoaError(.fileReadCorruptFile) }
        let url = URL(fileURLWithPath: arguments[index + 1])
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_768 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func missing(in report: [String: Any]) -> [String] {
        var result = rendererFlags.filter { report[$0] as? Bool != true }
        if !rendererFlags.isEmpty {
            if report["kind"] as? String != "ready" { result.append("renderer ready") }
            if (report["svgCount"] as? Int ?? 0) <= 0 { result.append("rendered SVG") }
        }
        if let group {
            if let checks = report[group] as? [String: Bool] {
                result += groupFlags.filter { checks[$0] != true }.map { group + "." + $0 }
                result += checks.keys.sorted().filter { checks[$0] == false && !groupFlags.contains($0) }
                    .map { group + "." + $0 }
            } else {
                result.append(group)
            }
        }
        return result
    }
}
