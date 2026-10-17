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
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(state).environmentObject(state.aiSettings).frame(
                minWidth: 1120, minHeight: 760
            )
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                state.save()
                state.midi.shutdown()
            }
        }.defaultSize(width: 1350, height: 980).windowStyle(.hiddenTitleBar)
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
                    ForEach(Array(Destination.allCases.enumerated()), id: \.offset) { index, destination in
                        Button(destination.rawValue) { state.navigate(to: destination) }.keyboardShortcut(
                            KeyEquivalent(Character(String(index + 1))))
                    }
                }
            }
        Settings {
            SettingsView().environmentObject(state).environmentObject(state.aiSettings)
        }.windowResizability(.contentSize)
    }
}
