// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct ContextCoachInspector: ViewModifier {
    @ObservedObject var session: ContextCoachSession
    func body(content: Content) -> some View {
        content.inspector(isPresented: $session.presented) {
            ContextCoachPanel(session: session)
                .inspectorColumnWidth(min: 330, ideal: 380, max: 460)
        }
    }
}

struct ContextCoachButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: ContextCoachSession
    var body: some View {
        Button {
            if session.presented { session.presented = false } else { state.openContextCoach() }
        } label: {
            HStack(spacing: 7) {
                if session.reply.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                Text("Coach")
            }
        }.accessibilityLabel(session.presented ? "Close coach" : "Ask the coach about this music")
            .accessibilityIdentifier("workspace.coach")
            .help("Ask about this music (⇧⌘K)")
    }
}

struct ContextCoachPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ai: AISettings
    @ObservedObject var session: ContextCoachSession
    @State private var showContext = false
    @State private var discardReply = false
    @FocusState private var questionFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Your coach", systemImage: "sparkles").font(.system(size: 16, weight: .medium, design: .serif))
                Spacer()
                Button {
                    session.presented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).accessibilityLabel("Close coach").accessibilityIdentifier("coach.close")
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        context
                        if !ai.isReady {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Bring your own model").font(.headline)
                                Text(
                                    "Add an OpenRouter key and choose a model in Settings. You can explore and practise without one."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                SettingsLink { Label("Open Settings", systemImage: "gearshape") }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if session.lines.isEmpty {
                            Text("A useful next step, close to the music.")
                                .font(.system(size: 21, weight: .medium, design: .serif))
                            Text(
                                "Ask about what you hear, what is under your fingers, or a choice in your arrangement."
                            )
                            .font(.callout).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                suggestion(
                                    "Help me hear the harmony",
                                    question:
                                        "Explain the harmony in this context. Suggest an audible comparison I can try.")
                                suggestion(
                                    "Break it into smaller steps",
                                    question:
                                        "Suggest one small practice step for this music, an easier alternative and a way to check it independently."
                                )
                                suggestion(
                                    "Make this sound like me",
                                    question:
                                        "Suggest two musical alternatives for my own version. Explain how they would change the sound, without claiming to have heard my playing."
                                )
                            }
                        }
                        ForEach(session.lines) { line in
                            VStack(alignment: .leading, spacing: 7) {
                                Eyebrow(text: line.role == "user" ? "YOU" : "YOUR COACH")
                                    .foregroundStyle(.secondary)
                                Text(.init(line.text)).font(.callout).lineSpacing(4).textSelection(.enabled)
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    line.role == "user" ? Color.canvas : Color.moss.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .id(line.id)
                        }
                        if session.reply.busy {
                            Label("Thinking about your question…", systemImage: "sparkles").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = session.reply.error {
                            Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
                                .accessibilityIdentifier("coach.error")
                        }
                        if session.reply.pending != nil {
                            Button("Save received reply again", systemImage: "externaldrive") {
                                session.reply.retrySave()
                            }
                            .accessibilityIdentifier("coach.retry-save")
                            HStack {
                                Button("Copy reply") {
                                    guard let reply = session.reply.pending else { return }
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(reply.answer, forType: .string)
                                }
                                Button("Discard reply…") { discardReply = true }
                            }.controlSize(.small)
                        }
                        Color.clear.frame(height: 1).id("coach-bottom")
                    }.padding(18)
                }
                .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("coach-bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask about this music…", text: $session.draft, axis: .vertical)
                    .lineLimit(3...7).textFieldStyle(.roundedBorder).disabled(session.locked)
                    .focused($questionFocused)
                    .accessibilityLabel("Question for the coach").accessibilityIdentifier("coach.question")
                HStack {
                    if session.reply.busy {
                        Button("Stop request") { session.reply.cancel() }
                    } else {
                        Button("Clear conversation") { session.clearConversation() }
                            .disabled(session.locked || session.lines.isEmpty)
                    }
                    Spacer()
                    Button("Send", systemImage: "arrow.up") { state.sendContextQuestion() }
                        .buttonStyle(.cadencePrimary)
                        .disabled(
                            !ai.isReady || session.locked
                                || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("coach.send")
                }.controlSize(.small)
                Text(
                    "Sends your question, recent conversation and the included context to your chosen model. Originals and recordings stay on this Mac. ZDR is required."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(
                    session.context?.snapshot == nil
                        ? "Conversation kept while Cadence is open." : "Replies are saved with this piece in Library."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16)
        }.background(Color.paper).foregroundStyle(Color.ink).tint(.moss).buttonStyle(.cadence)
            .onAppear { ai.checkKeyIfNeeded() }
            .onChange(of: questionFocused) { _, value in session.typing = value }
            .onDisappear { session.typing = false }
            .confirmationDialog("Discard the received reply?", isPresented: $discardReply) {
                Button("Discard unsaved reply", role: .destructive) { session.reply.discardPending() }
            } message: {
                Text(
                    "This reply has not been saved. Copy it first if you want to keep it. Discarding it does not make another model request."
                )
            }
    }
    private var context: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: "IN CONTEXT").foregroundStyle(Color.moss)
            Text(session.context?.title ?? "Your music").font(.headline)
            Text(session.context?.subtitle ?? "Choose some music to begin").font(.caption).foregroundStyle(.secondary)
            if let context = session.context {
                Toggle("Include this context", isOn: $session.includeContext).toggleStyle(.checkbox)
                    .font(.caption).disabled(session.locked).accessibilityIdentifier("coach.include-context")
                DisclosureGroup("What will be included", isExpanded: $showContext) {
                    Text(context.reference).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                }.font(.caption)
                Button("Use the music I’m viewing", systemImage: "arrow.triangle.2.circlepath") {
                    state.openContextCoach()
                }.disabled(session.locked).accessibilityIdentifier("coach.use-current")
                Text("This conversation keeps its original context until you change it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
    private func suggestion(_ title: String, question: String) -> some View {
        Button(title, systemImage: "arrow.up.left") {
            if session.draft.isEmpty { session.draft = question }
        }.font(.caption).disabled(session.locked || !session.draft.isEmpty)
    }
}
