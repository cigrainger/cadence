// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import WebKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static func snapshotEvent(_ message: String) {
        guard CommandLine.arguments.contains("--snapshot") else { return }
        FileHandle.standardError.write(Data("Snapshot lifecycle: \(message)\n".utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.snapshotEvent("application launched; screens=\(NSScreen.screens.map(\.visibleFrame))")
        NSApp.appearance = NSAppearance(named: .aqua)
        let preview =
            CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--selfcheck")

        // Wait for SwiftUI's scene before hiding a preview's Dock presence.
        // Launch notification timing alone does not establish window readiness.
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--selfcheck") ? .accessory : .regular)
        if !preview { NSApp.activate(ignoringOtherApps: true) }
        if CommandLine.arguments.contains("--snapshot") {
            Task { @MainActor in
                snapshotProgress("waiting for the SwiftUI window")
                for _ in 0..<50 {
                    if let window = NSApp.windows.first(where: {
                        $0.canBecomeMain && !$0.isSheet && $0.contentView != nil
                    }) {
                        window.orderFront(nil)
                        NSApp.setActivationPolicy(.accessory)
                        scheduleSnapshot(window)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                snapshotFailure("No SwiftUI window after five seconds; app windows: \(NSApp.windows.count)")
            }
        }
    }

    private var snapshotPhase = "launch"
    private func snapshotProgress(_ phase: String) {
        snapshotPhase = phase
        FileHandle.standardError.write(Data("Snapshot: \(phase)\n".utf8))
    }
    private func snapshotFailure(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Snapshot failed during \(snapshotPhase): \(message)\n".utf8))
        Darwin.exit(1)
    }
    private func scheduleSnapshot(_ launchWindow: NSWindow) {
        snapshotProgress("window ready: frame=\(launchWindow.frame), minimum=\(launchWindow.contentMinSize)")
        if let argument = CommandLine.arguments.firstIndex(of: "--width"),
            argument + 1 < CommandLine.arguments.count, let width = Double(CommandLine.arguments[argument + 1])
        {
            var height = 860.0
            if let argument = CommandLine.arguments.firstIndex(of: "--height"),
                argument + 1 < CommandLine.arguments.count,
                let requested = Double(CommandLine.arguments[argument + 1])
            {
                height = requested
            }
            launchWindow.setContentSize(NSSize(width: width, height: height))
        }
        // Let the existing sheet/scroll framing actions run first. Their delay
        // does not establish notation readiness under concurrent launch load.
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + (CommandLine.arguments.contains("--song-ax")
                    ? 30
                    : CommandLine.arguments.contains("--reharm-preview")
                        ? 8
                        : CommandLine.arguments.contains("--tension-preview")
                            ? 8
                            : CommandLine.arguments.contains("editor")
                                ? 10
                                : CommandLine.arguments.contains("--practice-adaptive")
                                    ? 8
                                    : CommandLine.arguments.contains("studies")
                                        || CommandLine.arguments.contains("library") ? 8 : 2)
        ) {
            Task { @MainActor in
                do {
                    let requirements = try SnapshotRequirements.read(arguments: CommandLine.arguments)
                    if let requirements {
                        self.snapshotProgress("waiting for \(requirements.scenario) assertions")
                        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                        var missing = requirements.missing(in: SnapshotDiagnostics.report)
                        while !missing.isEmpty, ContinuousClock.now < deadline {
                            try await Task.sleep(nanoseconds: 100_000_000)
                            missing = requirements.missing(in: SnapshotDiagnostics.report)
                        }
                        if !missing.isEmpty {
                            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
                                index + 1 < CommandLine.arguments.count
                            {
                                let sidecar = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                                    .deletingPathExtension().appendingPathExtension("json")
                                try SnapshotDiagnostics.write(to: sidecar)
                            }
                            self.snapshotFailure(
                                "Required assertions did not become ready: " + missing.joined(separator: ", "))
                        }
                    }
                } catch {
                    self.snapshotFailure("Invalid snapshot readiness request: \(error.localizedDescription)")
                }
                self.captureSnapshot(launchWindow)
            }
        }
    }
    private func captureSnapshot(_ launchWindow: NSWindow) {
        self.snapshotProgress("selecting the requested view")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            self.snapshotFailure("Capture did not finish within twenty seconds")
        }
        let settingsPreview = CommandLine.arguments.contains("--settings")
        let window =
            settingsPreview
            ? NSApp.windows.first {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" || $0.title == "Settings"
            }
            : (CommandLine.arguments.contains("--pdf-import-wizard")
                || CommandLine.arguments.contains("--harmony-sheet")
                || CommandLine.arguments.contains("--tension-reading")
                || CommandLine.arguments.contains("--tension-editor-guard")
                || CommandLine.arguments.contains("--smooth-setup"))
                ? NSApp.windows.first { $0.sheetParent != nil } ?? launchWindow : launchWindow
        guard let window, let content = window.contentView else {
            self.snapshotFailure("Requested window or content view is missing")
        }
        window.orderFront(nil)
        let view = settingsPreview ? (content.superview ?? content) : content
        view.layoutSubtreeIfNeeded()
        let rect = view.bounds
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            self.snapshotFailure("Requested view has invalid bounds")
        }
        self.snapshotProgress("caching view at \(Int(rect.width)) × \(Int(rect.height))")
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
            self.snapshotFailure("Could not allocate the view bitmap")
        }
        view.cacheDisplay(in: rect, to: rep)
        self.snapshotProgress("view cached")
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
            index + 1 < CommandLine.arguments.count
        else {
            self.snapshotFailure("Snapshot output path is missing")
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        @MainActor func save(_ images: [(WKWebView, NSImage)]) {
            self.snapshotProgress("writing snapshot and assertions")
            if !images.isEmpty {
                let composed = NSImage(size: rect.size)
                composed.lockFocus()
                rep.draw(in: rect)
                for (web, image) in images {
                    let frame = view.convert(web.bounds, from: web)
                    let y = view.isFlipped ? rect.height - frame.maxY : frame.minY
                    NSGraphicsContext.saveGraphicsState()
                    let visible = view.convert(web.visibleRect, from: web)
                    NSBezierPath(
                        rect: NSRect(
                            x: visible.minX, y: view.isFlipped ? rect.height - visible.maxY : visible.minY,
                            width: visible.width, height: visible.height)
                    ).addClip()
                    image.draw(in: NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
                    NSGraphicsContext.restoreGraphicsState()
                }
                composed.unlockFocus()
                if let tiff = composed.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                    let data = bitmap.representation(using: .png, properties: [:])
                {
                    try? data.write(to: destination)
                }
            } else if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: destination)
            }
            do {
                try SnapshotDiagnostics.write(to: destination.deletingPathExtension().appendingPathExtension("json"))
            } catch {
                self.snapshotFailure("Could not save assertions: \(error.localizedDescription)")
            }
            // A preview sheet can keep Cocoa's modal loop alive after
            // the files are saved. This process has no user state.
            self.snapshotProgress("complete")
            Darwin.exit(0)
        }
        @MainActor func findWebs(_ view: NSView) -> [WKWebView] {
            if let web = view as? WKWebView { return [web] }
            return view.subviews.flatMap { findWebs($0) }
        }
        let webs = findWebs(view).filter { !$0.visibleRect.isEmpty }
        self.snapshotProgress("capturing \(webs.count) visible notation views")
        Task { @MainActor in
            var images: [(WKWebView, NSImage)] = []
            for web in webs {
                let image: NSImage? = await withCheckedContinuation { continuation in
                    web.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
                }
                if let image { images.append((web, image)) }
            }
            save(images)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
