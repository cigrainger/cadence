// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore

/// Real window/event routing needs the launched app host, rather than SwiftPM's
/// command-line XCTest host. Both production and instrumented self-checks run it.
@MainActor enum SpaceTapChecks {
    static func run() throws -> [String: Bool] {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        let view = NSView()
        window.contentView = view
        let capture = SpaceTapCapture.Coordinator()
        capture.view = view
        var timestamps: [Double] = []
        capture.tap = { timestamps.append($0) }
        defer {
            capture.remove()
            window.close()
            otherWindow.close()
        }
        func event(
            repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = [],
            key: UInt16 = 49, target: NSWindow? = nil, type: NSEvent.EventType = .keyDown
        ) throws -> NSEvent {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers, timestamp: 123.456,
                    windowNumber: (target ?? window).windowNumber, context: nil, characters: " ",
                    charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: key)
            else { throw MusicError.invalid("Could not create the native keyboard fixture") }
            return event
        }
        var checks = ["disabledPassesThrough": capture.process(try event(), appActive: true) != nil]
        capture.enabled = true
        checks["spaceUsesEventTimestamp"] =
            capture.process(try event(), appActive: true) == nil && timestamps == [123.456]
        checks["repeatConsumedWithoutTap"] =
            capture.process(try event(repeatKey: true), appActive: true) == nil && timestamps.count == 1
        checks["shortcutsPassThrough"] = true
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            if capture.process(try event(modifiers: modifier), appActive: true) == nil {
                checks["shortcutsPassThrough"] = false
            }
        }
        checks["otherKeysPassThrough"] = capture.process(try event(key: 0), appActive: true) != nil
        checks["keyUpPassesThrough"] = capture.process(try event(type: .keyUp), appActive: true) != nil
        checks["inactivePassesThrough"] = capture.process(try event(), appActive: false) != nil
        // A real second window checks ownership without an invalid WindowServer ID.
        checks["otherWindowPassesThrough"] =
            capture.process(try event(target: otherWindow), appActive: true) != nil
        capture.view = nil
        checks["detachedViewPassesThrough"] = capture.process(try event(), appActive: true) != nil
        capture.view = view
        let text = NSTextView()
        view.addSubview(text)
        let focused = window.makeFirstResponder(text)
        let typingEvent = try event()
        checks["typingPassesThrough"] =
            focused && window.firstResponder === text
            && capture.process(typingEvent, appActive: true) != nil && timestamps.count == 1
        capture.install()
        checks["monitorInstalled"] = capture.monitor != nil
        capture.remove()
        checks["monitorRemoved"] = capture.monitor == nil
        return checks
    }
}
