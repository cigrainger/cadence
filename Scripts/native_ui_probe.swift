// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Foundation
import SwiftUI

/// Fail fast if the hosted session cannot present even a minimal SwiftUI scene.
/// No library, device, credential or Cadence application state is used here.
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
                index + 1 < CommandLine.arguments.count
            else { exit(1) }
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let report: [String: Any] = [
                "windows": NSApp.windows.count,
                "visibleWindows": NSApp.windows.filter(\.isVisible).count,
                "active": NSApp.isActive,
                "screens": NSScreen.screens.map { ["width": $0.frame.width, "height": $0.frame.height] },
                "visibleScreens": NSScreen.screens.map {
                    ["width": $0.visibleFrame.width, "height": $0.visibleFrame.height]
                },
            ]
            let data =
                (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            try? data.write(to: output)
            let passed = NSApp.windows.contains { $0.canBecomeMain && !$0.isSheet && $0.contentView != nil }
            var log = data
            log.append(Data((passed ? "\nSnapshot: complete\n" : "\nSwiftUI GUI host has no window\n").utf8))
            FileHandle.standardError.write(log)
            exit(passed ? 0 : 1)
        }
    }
}

@main struct NativeUIProbe: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    private var layout: WorkspaceWindowLayout {
        .fitting((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size)
    }
    var body: some Scene {
        WindowGroup {
            Text("Cadence native verification").frame(minWidth: layout.minimum.width, minHeight: layout.minimum.height)
        }.defaultSize(width: layout.initial.width, height: layout.initial.height).windowStyle(.hiddenTitleBar)
    }
}
