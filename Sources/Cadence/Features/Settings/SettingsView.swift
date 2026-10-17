// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

private enum SettingsTab: Hashable { case general, ai, midi, about }

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: SettingsTab = .general
    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(SettingsTab.general)
            VStack(alignment: .leading, spacing: 16) {
                settingsHeading("Your MIDI keyboard", subtitle: "USB and other inputs available through macOS MIDI.")
                Card(title: "Keyboard input", padding: 18, spacing: 12) { MIDIConnectionView(midi: state.midi) }
                Text(
                    "Choose a keyboard input. Compose can write notes and chords on key release. Practice → Play chords checks chord tones and inversions. Writing and checking are enabled explicitly in those screens."
                ).font(.callout).foregroundStyle(.secondary)
                Text(
                    "Sustain is tracked separately from physical keys. Clear held notes resets a stuck input. MIDI stays on this Mac."
                ).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(18).tabItem { Label("MIDI", systemImage: "pianokeys") }.tag(SettingsTab.midi)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
            AIConnectionSettings().tabItem { Label("AI coach", systemImage: "sparkles") }.tag(SettingsTab.ai)
        }
        .padding(20).frame(width: 620, height: 570)
        .background(Color.canvas).foregroundStyle(Color.ink).tint(.moss).buttonStyle(.cadence).preferredColorScheme(
            .light
        )
        .onChange(of: state.preferences) { _, _ in state.saveSoon() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.save()
        }
        .onAppear {
            if state.isPreview && CommandLine.arguments.contains("--settings") { tab = .ai }
            if state.isPreview && CommandLine.arguments.contains("--midi-settings") { tab = .midi }
            if state.isPreview && CommandLine.arguments.contains("--general-settings") { tab = .general }
            if state.isPreview && CommandLine.arguments.contains("--about-settings") { tab = .about }
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeading("Make yourself at home", subtitle: "Small preferences for the way you learn.")
            Card(title: "Instrument display", spacing: 16) {
                preference(
                    "Left-handed guitar", detail: "Mirror the fretboard and chord diagrams.", isOn: $state.leftHanded)
                Divider()
                preference(
                    "Show scale degrees", detail: "Label scale notes by their place in the key.",
                    isOn: $state.showDegrees)
            }
            Card(title: "Practice", spacing: 16) {
                preference(
                    "Show practice points", detail: "Keep a gentle record of your practice. Every exercise stays open.",
                    isOn: $state.showRewards)
                Divider()
                preference(
                    "Show solfège for singing", detail: "Movable Do, with Do-based minor: Do, Re, Me…",
                    isOn: $state.showSolfege)
            }
            Label("Preferences are saved automatically on this Mac.", systemImage: "internaldrive").font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(18)
    }
    private func preference(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(title)
        }
    }
}

private func settingsHeading(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 22, weight: .medium, design: .serif))
        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

private struct AIConnectionSettings: View {
    @EnvironmentObject private var ai: AISettings
    @State private var keyDraft = ""
    @State private var feedback = ""
    @State private var feedbackIsError = false
    @State private var modelTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeading("Your AI connection", subtitle: "Bring your own OpenRouter key. Choose your own model.")
            Card(title: "OpenRouter", padding: 18, spacing: 12) {
                HStack {
                    Label(
                        ai.hasSavedKey ? "Key saved in macOS Keychain" : "No key saved",
                        systemImage: ai.hasSavedKey ? "lock.fill" : "key"
                    )
                    .font(.system(size: 12)).foregroundStyle(ai.hasSavedKey ? Color.moss : .secondary)
                    Spacer()
                    Link("Get an API key ↗", destination: URL(string: "https://openrouter.ai/settings/keys")!).font(
                        .caption)
                }
                HStack(spacing: 10) {
                    SecureField(
                        ai.hasSavedKey ? "Paste a new key to replace the saved key" : "Paste your OpenRouter API key",
                        text: $keyDraft
                    )
                    .textFieldStyle(.roundedBorder).accessibilityLabel("OpenRouter API key")
                    Button(ai.hasSavedKey ? "Replace key" : "Save key") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Text("The saved key is kept out of your conversations.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if ai.hasSavedKey { Button("Remove key") { removeKey() }.font(.caption) }
                }
                if let error = ai.credentialError {
                    Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
                }
                if !feedback.isEmpty {
                    Text(feedback).font(.caption).foregroundStyle(feedbackIsError ? Color.clay : .moss).textSelection(
                        .enabled)
                }
            }
            Card(title: "Model", padding: 18, spacing: 10) {
                TextField("OpenRouter model ID", text: $ai.model).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("OpenRouter model ID")
                HStack(spacing: 10) {
                    if !ai.models.isEmpty {
                        ChoiceMenu(
                            title: "AI model", selection: $ai.model, options: ai.models.map(\.id),
                            label: { id in ai.models.first { $0.id == id }?.name ?? (id.isEmpty ? "Choose a model" : id)
                            })
                    } else {
                        Text("Enter a model ID, or load the model list.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    if ai.loadingModels { ProgressView().controlSize(.small) }
                    Button(ai.models.isEmpty ? "Load models" : "Refresh models") {
                        modelTask = Task { await ai.loadModels() }
                    }.disabled(ai.loadingModels)
                }
                if !ai.modelStatus.isEmpty {
                    Text(ai.modelStatus).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("You choose when to connect", systemImage: "hand.raised").font(.system(size: 12, weight: .medium))
                Text(
                    "When you send a question, your recent conversation, pathway brief or included pathway, and selected musical context go to OpenRouter and the model provider. Requests use your account’s credits. Theory, playback, and practice work offline."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 2)
            Spacer(minLength: 0)
        }.padding(18)
            .onAppear { ai.refreshKeyStatus() }
            .onDisappear {
                keyDraft = ""
                modelTask?.cancel()
            }
    }
    private func saveKey() {
        do {
            try ai.saveKey(keyDraft)
            keyDraft = ""
            feedback = "Key saved. You can return to the coach."
            feedbackIsError = false
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }
    private func removeKey() {
        do {
            try ai.saveKey("")
            keyDraft = ""
            feedback = "Saved key removed from Keychain."
            feedbackIsError = false
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }
}
