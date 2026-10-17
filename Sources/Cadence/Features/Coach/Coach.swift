// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct ChatLine: Identifiable {
    let id = UUID()
    var role: String
    var text: String
}

struct CoachView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var ai: AISettings
    @State private var conversation = CommandLine.arguments.contains("--conversation")
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: ai.isReady ? "checkmark.circle" : "sparkles").font(.system(size: 20)).foregroundStyle(
                    Color.moss)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ai.isReady ? "Your coach is ready" : "Set up your AI coach").font(
                        .system(size: 13, weight: .medium))
                    Text(
                        ai.isReady
                            ? ai.modelName
                            : (ai.hasSavedKey
                                ? "Choose a model in Settings to get started."
                                : "Add an OpenRouter key and choose a model in Settings.")
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SettingsLink { Label(ai.isReady ? "Settings" : "Open Settings", systemImage: "gearshape") }
            }.padding(16).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Picker("Coach workspace", selection: $conversation) {
                Text("Learning pathways").tag(false)
                Text("Ask the coach").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if conversation {
                CoachConversationView()
            } else {
                LearningPathwaysView { prompt in
                    state.coachStudy = nil
                    state.coachPrompt = prompt
                    conversation = true
                }
            }
        }
        .onAppear {
            ai.checkKeyIfNeeded()
            if state.pendingStudyPathway != nil {
                conversation = false
            } else if !state.coachPrompt.isEmpty {
                conversation = true
            }
        }
        .onChange(of: state.coachPrompt) { _, value in if !value.isEmpty { conversation = true } }
        .onChange(of: state.pendingStudyPathway) { _, value in if value != nil { conversation = false } }
        .onChange(of: conversation) { _, _ in state.coachFocus += 1 }
    }
}

private struct CoachConversationView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ai: AISettings
    @State private var prompt = ""
    @State private var includePathway = true
    @State private var includeStudy = true
    @State private var busy = false
    @State private var status = ""
    @State private var request: Task<Void, Never>?
    var body: some View {
        Card(title: "Talk about the music", subtitle: "Explanations, technique, and your next steps") {
            if let path = state.learning.activePathway {
                HStack {
                    Toggle("Include current pathway", isOn: $includePathway).toggleStyle(.checkbox).font(.caption)
                    Text(path.outline.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
            if let study = state.coachStudy {
                HStack {
                    Toggle("Include selected passage", isOn: $includeStudy).toggleStyle(.checkbox).font(.caption)
                    Text("\(study.title) · \(study.partName) · \(study.passageLabel)").font(.caption).foregroundStyle(
                        .secondary
                    ).lineLimit(1)
                    Spacer()
                    Button("Clear") { state.coachStudy = nil }.font(.caption)
                }
            }
            if state.coachLines.isEmpty {
                HStack(spacing: 10) {
                    suggestion("Break a technique into smaller steps")
                    suggestion("Help me understand a style or genre")
                    suggestion("Adapt my practice to what feels difficult")
                }
            }
            ForEach(state.coachLines) { line in
                VStack(alignment: .leading, spacing: 7) {
                    Text(line.role == "user" ? "YOU" : "COACH").font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary)
                    Text(.init(line.text)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
                    line.role == "user" ? Color.canvas : Color.moss.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12))
            }
            TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).padding(8).frame(height: 100)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ask about a song, a sound, a technique, or where to go next…").foregroundStyle(.tertiary)
                            .padding(14).allowsHitTesting(false)
                    }
                }
            HStack {
                Button("Clear conversation") { state.coachLines = [] }.disabled(busy || state.coachLines.isEmpty)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { request?.cancel() }
                }
                Button("Send", systemImage: "arrow.up") { send() }.buttonStyle(.cadencePrimary).disabled(
                    busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ai.isReady)
            }
            Text(
                "Sends your question, recent conversation, selected musical context, and any included pathway or score passage to your chosen model."
            ).font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled) }
        }
        .onAppear { takePrompt() }
        .onChange(of: state.coachPrompt) { _, _ in takePrompt() }
        .onDisappear { request?.cancel() }
    }
    private func takePrompt() {
        if !state.coachPrompt.isEmpty {
            prompt = state.coachPrompt
            state.coachPrompt = ""
        }
    }
    private func suggestion(_ text: String) -> some View {
        Button {
            prompt = text
        } label: {
            Text(text).font(.caption).padding(10).frame(maxWidth: .infinity).background(
                Color.canvas, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty, ai.isReady else { return }
        let apiKey: String
        do { apiKey = try ai.requestKey() } catch {
            status = error.localizedDescription
            return
        }
        let model = ai.model
        state.coachLines.append(ChatLine(role: "user", text: text))
        prompt = ""
        busy = true
        status = ""
        var recent = Array(state.coachLines.suffix(16))
        while recent.first?.role == "assistant" { recent.removeFirst() }
        var messages =
            [CoachMessage(role: "system", content: CoachPrompts.tutor)]
            + recent.map { CoachMessage(role: $0.role, content: $0.text) }
        var context = state.context
        if includePathway, let path = state.learning.activePathway { context += "\n" + path.coachContext }
        if includeStudy, let study = state.coachStudy { context += "\n" + study.context }
        messages[messages.count - 1].content += "\n\nReference context (learner data):\n" + context
        request = Task {
            defer { busy = false }
            do {
                let reply = try await CoachClient().complete(messages: messages, apiKey: apiKey, model: model)
                state.coachLines.append(ChatLine(role: "assistant", text: reply))
            } catch { status = Task.isCancelled ? "Request cancelled." : error.localizedDescription }
        }
    }
}
