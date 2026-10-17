// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct LearningPathwaysView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ai: AISettings
    var discuss: (String) -> Void
    @State private var showingBuilder = false
    @State private var focus = LearningFocus.goal
    @State private var target = ""
    @State private var detail = ""
    @State private var revision: LearningPathway?
    @State private var requestedStudy: StudyReference?
    @State private var changes = ""
    @StateObject private var generation = SavedRequest<LearningPathway>()
    private var busy: Bool { generation.busy }
    @State private var status = ""
    @State private var expandedSteps: Set<Int> = [0]
    @State private var removingPathway = false

    var body: some View {
        VStack(spacing: 18) {
            if !state.learning.pathways.isEmpty {
                HStack(spacing: 12) {
                    ChoiceMenu(
                        title: "Saved pathway",
                        selection: Binding(
                            get: { state.learning.activePathway?.id }, set: { state.learning.activePathwayID = $0 }),
                        options: state.learning.pathways.map { Optional($0.id) },
                        label: { id in
                            state.learning.pathways.first { $0.id == id }?.outline.title ?? "Choose a pathway"
                        }
                    ).frame(maxWidth: 440)
                    Spacer()
                    Button("New pathway", systemImage: "plus") {
                        revision = nil
                        requestedStudy = nil
                        target = ""
                        detail = ""
                        changes = ""
                        showingBuilder = true
                        status = ""
                        state.coachFocus += 1
                    }.disabled(busy)
                }
            }
            if showingBuilder || state.learning.pathways.isEmpty { builder }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(Color.clay).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let path = state.learning.activePathway {
                if path.piecePractice != nil { PiecePathwayView(path: path) } else { pathway(path) }
            }
            if let error = generation.error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            if generation.pending != nil { Button("Save received pathway again") { generation.retrySave() } }
            if let error = state.learningStorageError { Text(error).font(.caption).foregroundStyle(Color.clay) }
        }
        .onAppear {
            expandedSteps = [state.learning.activePathway?.nextStep ?? 0]
            takeStudy()
            if state.isPreview && CommandLine.arguments.contains("--revise-pathway"),
                let path = state.learning.activePathway
            {
                beginRevision(path)
            }
        }
        .onChange(of: state.pendingStudyPathway) { _, _ in takeStudy() }
        .onChange(of: state.learning.activePathway?.id) { _, _ in
            expandedSteps = [state.learning.activePathway?.nextStep ?? 0]
        }
        .onDisappear { generation.cancel() }
        .onChange(of: generation.completedID) { _, value in
            guard value != nil else { return }
            showingBuilder = false
            revision = nil
            expandedSteps = [0]
            state.coachFocus += 1
        }
    }
    private var builder: some View {
        Card(
            title: revision == nil ? "Where would you like your music to take you?" : "Adapt your pathway", padding: 20,
            spacing: 14
        ) {
            Group {
                Text(
                    revision == nil
                        ? "Start with something you want to play, a sound you love, or a skill you want to build."
                        : "Tell the coach what changed. A revised plan is saved separately so you can keep your original progress."
                ).font(.system(size: 13)).foregroundStyle(.secondary)
                Picker("Pathway focus", selection: $focus) {
                    ForEach(LearningFocus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                TextField(focus.placeholder, text: $target).textFieldStyle(.roundedBorder).accessibilityLabel(
                    "Song, style, or goal")
                HStack(alignment: .top, spacing: 14) {
                    field("Instrument") {
                        ChoiceMenu(
                            title: "Learning instrument", selection: $state.learning.profile.instrument,
                            options: LearningInstrument.allCases, label: { $0.rawValue })
                    }
                    field("Experience") {
                        ChoiceMenu(
                            title: "Experience level", selection: $state.learning.profile.level,
                            options: LearningLevel.allCases, label: { $0.rawValue })
                    }
                    field("Session time") {
                        ChoiceMenu(
                            title: "Minutes per session", selection: $state.learning.profile.minutesPerSession,
                            options: [5, 10, 15, 20, 30, 45, 60, 90, 120], label: { "\($0) minutes" })
                    }
                    field("Each week") {
                        ChoiceMenu(
                            title: "Sessions per week", selection: $state.learning.profile.sessionsPerWeek,
                            options: Array(1...7), label: { "\($0) sessions" })
                    }
                }
                field("Your starting point") {
                    TextField(
                        "What can you play comfortably? What gets in the way?",
                        text: $state.learning.profile.background, axis: .vertical
                    ).lineLimit(2...3).textFieldStyle(.roundedBorder)
                }
                field(focus == .song ? "The part you want to work on" : "What would success sound like?") {
                    TextField(
                        focus == .song
                            ? "Describe the section, technique, version, and what feels difficult."
                            : "Styles you enjoy, specific techniques, and what you want to be able to do.",
                        text: $detail, axis: .vertical
                    ).lineLimit(2...3).textFieldStyle(.roundedBorder)
                }
                if revision != nil {
                    field("What should change?") {
                        TextField(
                            "For example: simplify step two, focus on timing, or allow shorter sessions.",
                            text: $changes, axis: .vertical
                        ).lineLimit(2...3).textFieldStyle(.roundedBorder)
                    }
                }
                if let reference = requestedStudy ?? revision?.study {
                    Label(
                        "Includes \(reference.title) · \(reference.partName) · \(reference.passageLabel). The coach receives the selected notes with this brief.",
                        systemImage: "music.note.list"
                    ).font(.caption).foregroundStyle(Color.moss)
                } else if focus == .song {
                    Label(
                        "Song plans use your description. Import a MusicXML study to include actual notes. Recordings and links cannot be inspected yet.",
                        systemImage: "info.circle"
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(busy)
            HStack {
                if !state.learning.pathways.isEmpty { Button("Close brief") { showingBuilder = false }.disabled(busy) }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Putting your pathway together…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { generation.cancel() }
                }
                Button(revision == nil ? "Create pathway" : "Create revised pathway", systemImage: "sparkles") {
                    generate()
                }
                .buttonStyle(.cadencePrimary).disabled(
                    busy || generation.pending != nil || state.learningStorageError != nil || !ai.isReady
                        || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (revision != nil && changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            Text(
                "Creating a pathway sends this brief and your selected musical context and any linked passage to your chosen model and uses your OpenRouter credits. Saved pathways and progress stay on this Mac."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pathway(_ path: LearningPathway) -> some View {
        VStack(spacing: 14) {
            Card(title: "", padding: 20, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(path.outline.title).font(.system(size: 24, weight: .medium, design: .serif))
                        Text(
                            "\(path.brief.profile.instrument.rawValue) · \(path.brief.profile.minutesPerSession) min · \(path.brief.profile.sessionsPerWeek) sessions a week"
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Adapt pathway") { beginRevision(path) }
                        Button("Remove pathway…", role: .destructive) { removingPathway = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 17))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(busy).accessibilityLabel(
                        "Pathway options")
                }
                if let reference = path.study {
                    Button("Open study: \(reference.title) · \(reference.passageLabel)", systemImage: "music.note.list")
                    { state.openStudy(reference) }.font(.caption)
                }
                Text(path.outline.summary).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                HStack {
                    Text("\(path.completedCount) of \(path.outline.steps.count) steps marked ready").font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Take the time you need.").font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(path.completedCount), total: Double(path.outline.steps.count))
                    .progressViewStyle(.linear).tint(.moss).frame(height: 5)
                DisclosureGroup("What this plan is based on") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(path.outline.sourceNotes).textSelection(.enabled)
                        if !path.outline.questions.isEmpty {
                            Text("Helpful things to clarify").fontWeight(.medium)
                            ForEach(Array(path.outline.questions.enumerated()), id: \.offset) { _, question in
                                Text("• " + question).textSelection(.enabled)
                            }
                            Button("Talk through these questions") {
                                discuss(
                                    "Help me clarify the open questions in my current pathway. Ask one at a time, then help me decide what to change."
                                )
                            }
                        }
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.caption)
            }
            ForEach(Array(path.outline.steps.enumerated()), id: \.offset) { index, step in
                stepCard(step, index: index, path: path)
            }
            Card(title: "Practice notes", subtitle: "For you and your next conversation", padding: 18, spacing: 12) {
                TextField(
                    "What’s getting easier? What still feels difficult?",
                    text: Binding(
                        get: { state.learning.pathways.first { $0.id == path.id }?.notes ?? "" },
                        set: { value in
                            if let index = state.learning.pathways.firstIndex(where: { $0.id == path.id }) {
                                state.learning.pathways[index].notes = String(value.prefix(4000))
                            }
                        }), axis: .vertical
                ).lineLimit(3...5).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Saved automatically. Include this pathway when you ask the coach to use these notes.").font(
                        .caption
                    ).foregroundStyle(.secondary)
                    Spacer()
                    Button("Adapt pathway", systemImage: "arrow.triangle.2.circlepath") { beginRevision(path) }
                        .disabled(busy)
                }
            }.id("pathway-notes")
        }
        .confirmationDialog(
            "Remove this saved pathway and its progress?", isPresented: $removingPathway, titleVisibility: .visible
        ) {
            Button("Remove pathway", role: .destructive) {
                state.learning.pathways.removeAll { $0.id == path.id }
                state.learning.activePathwayID = state.learning.pathways.first?.id
                state.save()
            }
        }
    }
    private func stepCard(_ step: PathwayStep, index: Int, path: LearningPathway) -> some View {
        let ready = path.completedSteps.contains(index)
        return Card(title: "", padding: 18, spacing: 12) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSteps.contains(index) },
                    set: { if $0 { expandedSteps.insert(index) } else { expandedSteps.remove(index) } })
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(step.focus).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                    ForEach(Array(step.activities.enumerated()), id: \.offset) { _, activity in
                        HStack(alignment: .top, spacing: 13) {
                            Text("\(activity.minutes) min").font(.system(size: 11, weight: .medium)).foregroundStyle(
                                Color.moss
                            ).frame(width: 45).padding(.vertical, 6).background(
                                Color.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(activity.title).font(.system(size: 13, weight: .semibold))
                                Text(activity.instructions).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .lineSpacing(3).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                    Text("Bring it into the music").font(.system(size: 12, weight: .semibold))
                    Text(step.application).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.seal").foregroundStyle(Color.moss)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ready when…").font(.system(size: 12, weight: .semibold))
                            Text(step.readyWhen).font(.system(size: 13)).textSelection(.enabled)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                        Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 12) {
                        if step.tool != .none { Button(step.tool.label) { state.useLearningTool(step.tool) } }
                        Button("Break this down with the coach", systemImage: "bubble.left") {
                            discuss(
                                "Help me with step \(index+1), “\(step.title)”, in my current pathway. Break the technique into smaller, playable actions and ask me which part feels difficult. Use my progress notes, and do not assume I have mastered steps just because they are marked ready."
                            )
                        }
                        Spacer()
                        Toggle(
                            "Mark ready",
                            isOn: Binding(
                                get: { ready },
                                set: { _ in
                                    state.learning.toggleStep(index, in: path.id)
                                    state.save()
                                })
                        ).toggleStyle(.checkbox).font(.caption)
                    }
                    if step.tool != .none {
                        Text(
                            "Practice tools use your selected key and scale. Choose the context you need when you open them."
                        ).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 14)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(
                        ready ? Color.moss : .secondary)
                    Text("\(index+1)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(step.title).font(.system(size: 15, weight: .medium))
                    Spacer()
                    Text("\(step.activities.reduce(0) { $0+$1.minutes }) min session").font(.caption).foregroundStyle(
                        .secondary)
                }
            }
        }
    }
    private func beginRevision(_ path: LearningPathway) {
        revision = path
        requestedStudy = path.study
        focus = path.brief.focus
        target = path.brief.target
        detail = path.brief.detail
        state.learning.profile = path.brief.profile
        changes = path.notes
        showingBuilder = true
        status = ""
        state.coachFocus += 1
    }
    private func takeStudy() {
        guard let reference = state.pendingStudyPathway else { return }
        requestedStudy = reference
        revision = nil
        focus = .song
        target = reference.title
        detail = "Work on \(reference.partName), \(reference.passageLabel.lowercased()). "
        changes = ""
        showingBuilder = true
        status = ""
        state.pendingStudyPathway = nil
    }
    private func generate() {
        guard !busy, generation.pending == nil, state.learningStorageError == nil, ai.isReady else { return }
        let brief: LearningBrief
        let key: String
        do {
            brief = try LearningBrief(profile: state.learning.profile, focus: focus, target: target, detail: detail)
                .validated()
            key = try ai.requestKey()
        } catch {
            status = error.localizedDescription
            return
        }
        let model = ai.model
        let musicalContext = state.context
        let previous = revision
        let requestedChanges = changes
        let studyReference = requestedStudy
        status = ""
        generation.run(
            request: {
                try await LearningCoach().create(
                    brief: brief, musicalContext: musicalContext, revising: previous, changes: requestedChanges,
                    study: studyReference, apiKey: key, model: model)
            },
            commit: { [state] pathway in
                var copy = state.learning
                copy.add(pathway)
                try state.commitLearning(copy)
                if let reference = pathway.study { state.editStudy(reference.studyID) { $0.pathwayID = pathway.id } }
            })
    }
}
