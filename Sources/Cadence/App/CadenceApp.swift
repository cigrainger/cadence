// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import MusicCore
import SwiftUI
import WebKit

@main struct CadenceApp: App {
    @StateObject private var state = AppState(
        preview: CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--selfcheck")
    )
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var windowLayout: WorkspaceWindowLayout {
        .fitting((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size)
    }
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(state).environmentObject(state.aiSettings).frame(
                minWidth: windowLayout.minimum.width, minHeight: windowLayout.minimum.height
            )
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                state.save()
                state.midi.shutdown()
            }
        }.defaultSize(width: windowLayout.initial.width, height: windowLayout.initial.height).windowStyle(
            .hiddenTitleBar
        )
        .commands {
            CommandGroup(after: .newItem) {
                Button("Save progress") { state.save() }.keyboardShortcut("s")
                Button("Stop playback") {
                    state.stopAllPlayback()
                }.keyboardShortcut(".")
            }
            CommandGroup(replacing: .help) {
                Button("Cadence Guide") {
                    NSWorkspace.shared.open(URL(string: "https://cigrainger.github.io/cadence/docs/")!)
                }
            }
            CommandMenu("Navigate") {
                Button("Ask the coach") { state.openContextCoach() }.keyboardShortcut(
                    "k", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.offset) { index, section in
                    Button(section.rawValue) { state.navigateWorkspace(section) }.keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))))
                }
            }
        }
        Settings {
            SettingsView().environmentObject(state).environmentObject(state.aiSettings)
        }.windowResizability(.contentSize)
    }
}
