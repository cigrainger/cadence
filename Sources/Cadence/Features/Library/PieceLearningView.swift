// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct PieceLearningView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ai: AISettings
    let piece: LibraryPiece
    let snapshot: PieceSnapshot?
    @State private var creating = false
    @State private var instrument = LearningInstrument.guitar
    @State private var includeEvidence = true
    @StateObject private var generation = SavedRequest<LearningPathway>()
    private var busy: Bool { generation.busy }
    private var pending: LearningPathway? { generation.pending }
    @State private var error: String?
    private var paths: [LearningPathway] { state.learning.pathways.filter { $0.piecePractice?.pieceID == piece.id } }
    private var selected: LearningPathway? { paths.first { $0.id == state.learning.activePathwayID } ?? paths.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScoreEarSetupView(piece: piece, snapshot: snapshot)
            if let error = state.learningStorageError {
                Text(error).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true)
            }
            if !paths.isEmpty {
                HStack {
                    Picker(
                        "Pathway",
                        selection: Binding(get: { selected?.id }, set: { state.learning.activePathwayID = $0 })
                    ) {
                        ForEach(paths) {
                            Text(
                                $0.outline.title + " · " + $0.createdAt.formatted(date: .abbreviated, time: .shortened)
                            ).tag(Optional($0.id))
                        }
                    }
                    Button(creating ? "Close brief" : "New plan") { creating.toggle() }.disabled(busy)
                }.controlSize(.small)
            }
            if paths.isEmpty || creating {
                Card(title: "A pathway into this piece", padding: 18, spacing: 13) {
                    Text(
                        "Start with a local plan, or ask your model to tailor the passage work to your goal and recent difficulties. Every step stays open."
                    ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Instrument", selection: $instrument) {
                        ForEach(LearningInstrument.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Picker("Experience", selection: $state.learning.profile.level) {
                            ForEach(LearningLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Session", selection: $state.learning.profile.minutesPerSession) {
                            ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                        }.frame(width: 150)
                    }
                    TextField(
                        "Your starting point or current difficulty",
                        text: Binding(
                            get: { state.learning.profile.background },
                            set: { state.learning.profile.background = String($0.prefix(2000)) }), axis: .vertical
                    ).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    Text(
                        state.pieceRecord(piece).goal.isEmpty
                            ? "Add a goal in Overview to make this more personal."
                            : "Goal: " + state.pieceRecord(piece).goal
                    ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Include this piece’s practice results when tailoring with AI", isOn: $includeEvidence).font(
                        .caption
                    ).toggleStyle(.checkbox)
                    HStack {
                        Button("Create local plan", systemImage: "list.bullet.clipboard") { create(useAI: false) }
                            .disabled(snapshot == nil || busy || pending != nil || state.learningStorageError != nil)
                        Button("Tailor with AI", systemImage: "sparkles") { create(useAI: true) }.buttonStyle(
                            .cadencePrimary
                        ).disabled(
                            snapshot == nil || busy || pending != nil || !ai.isReady || state.isPreview
                                || state.learningStorageError != nil)
                        if busy {
                            ProgressView().controlSize(.small)
                            Button("Stop") { generation.cancel() }
                        }
                    }.controlSize(.small)
                    Text(
                        "Local plans need no key. AI sends the selected notes, piece goal and notes, starting point and optional recorded results to your Settings model with ZDR required. Original PDFs and audio stay on this Mac. No automatic paid retry; four-minute limit."
                    ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = generation.error ?? error {
                Text(error).font(.caption).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true)
            }
            if pending != nil {
                Button("Save received plan again") { generation.retrySave() }
                Text("Retries only the local save, without another model request.").font(.caption).foregroundStyle(
                    .secondary)
            }
            if let selected { PiecePathwayView(path: selected) }
        }
        .onAppear {
            if case .score(let score) = piece.source {
                instrument = score.instrument == .guitar ? .guitar : .piano
            } else {
                instrument =
                    piece.instrument.localizedCaseInsensitiveContains("piano")
                    ? .piano : state.learning.profile.instrument
            }
        }
        .onDisappear { generation.cancel() }
        .onChange(of: generation.completedID) { _, value in
            if value != nil {
                creating = false
                error = nil
            }
        }
    }
    private func create(useAI: Bool) {
        guard !busy, let snapshot else { return }
        let record = state.pieceRecord(piece)
        var profile = state.learning.profile
        profile.instrument = instrument
        error = nil
        if !useAI {
            do {
                let plan = try PiecePathwayFactory.make(
                    piece: piece, snapshot: snapshot, record: record, profile: profile)
                generation.accept(plan) { [state] in try state.savePiecePathway($0) }
            } catch { self.error = error.localizedDescription }
            return
        }
        do {
            let key = try ai.requestKey()
            let model = ai.model
            let evidence = includeEvidence ? state.piecePracticeEvidence(piece) : "Practice results not included."
            let context = String(
                (LearningBrief(profile: profile, target: piece.title).context
                    + "\nTailor the practice steps to this starting point and the following recorded evidence. Distinguish checked answers from self-reports; neither proves physical technique or mastery. If a concept is difficult, offer a smaller step.\n"
                    + evidence).prefix(8000))
            generation.run(
                request: {
                    let analysis = try await PieceCoach().analyse(
                        snapshot: snapshot, record: record, profile: context, apiKey: key, model: model)
                    return try PiecePathwayFactory.make(
                        piece: piece, snapshot: snapshot, record: record, profile: profile, analysis: analysis)
                }, commit: { [state] in try state.savePiecePathway($0) })
        } catch { self.error = error.localizedDescription }
    }

}

struct PiecePathwayView: View {
    @EnvironmentObject private var state: AppState
    let path: LearningPathway
    @State private var expanded: Set<Int> = [0]
    @State private var error: String?
    @State private var removing = false
    private var current: Bool { state.pathwayCurrent(path) }
    var body: some View {
        if let plan = path.piecePractice {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: path.outline.title, padding: 18, spacing: 12) {
                    Text(path.outline.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(plan.scope.label + " · " + plan.origin).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    if !current {
                        Text(
                            "The score has changed or is no longer in the library. This plan and its history are preserved. Create a new plan for the current music; its reviews will start fresh."
                        ).font(.callout).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true)
                    }
                    TimelineView(.periodic(from: Date(), by: 60)) { value in
                        let queue = plan.queue(now: value.date)
                        HStack {
                            if let next = queue.first {
                                Button("Continue · " + next.kind.rawValue, systemImage: "play.fill") {
                                    state.startPathwayTask(path.id, taskID: next.id)
                                }.buttonStyle(.cadencePrimary).disabled(!current)
                            } else {
                                Text(
                                    plan.paused
                                        ? "Reviews paused. Every exercise remains available."
                                        : "Nothing due right now. Explore any step, or come back later."
                                ).font(.callout).foregroundStyle(.secondary).fixedSize(
                                    horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Menu {
                                Button(plan.paused ? "Resume reviews" : "Pause reviews") {
                                    change { $0.piecePractice?.paused.toggle() }
                                }
                                Button("Open piece") { state.returnToPiecePathway(path) }
                                Button("Remove pathway…", role: .destructive) { removing = true }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        Text(
                            "\(plan.tasks.filter { $0.review.due.map { $0 <= value.date } ?? false }.count) ready to review · \(plan.tasks.filter { $0.review.encounters == 0 }.count) new exercises · \(path.completedCount)/\(path.outline.steps.count) stages marked ready by you"
                        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("How this adapts") {
                        Text(
                            "Misses return after about 10 minutes; supported answers after 20. Due reviews recalled comfortably spread to 1, 3, 7, 14, 30 and 60 days. Repeats in the same encounter count once, and early practice never pushes a review away. Passage ratings are self-reports; checked questions and MIDI answers are labelled separately. This is a simple practice schedule, not a mastery score."
                        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                        Text(path.outline.sourceNotes).font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }.font(.caption)
                }
                ForEach(Array(path.outline.steps.enumerated()), id: \.offset) { index, step in
                    Card(title: "", padding: 16, spacing: 10) {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expanded.contains(index) },
                                set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } })
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(step.focus).font(.callout).fixedSize(horizontal: false, vertical: true)
                                ForEach(plan.tasks.filter { $0.stage == index }) { task in
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(task.title).font(.callout).fontWeight(.medium)
                                            Text(
                                                task.scope.label + " · "
                                                    + (task.kind == .passage
                                                        ? "Your report"
                                                        : task.kind == .chord ? "MIDI check" : "Checked answer")
                                            ).font(.caption).foregroundStyle(.secondary)
                                            Text(task.review.reason()).font(.caption).foregroundStyle(
                                                task.review.lastGrade == .again ? Color.clay : .secondary
                                            ).fixedSize(horizontal: false, vertical: true)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Button(task.review.encounters == 0 ? "Begin" : "Practise") {
                                            state.startPathwayTask(path.id, taskID: task.id)
                                        }.disabled(!current)
                                    }.padding(10).background(Color.canvas, in: RoundedRectangle(cornerRadius: 9))
                                }
                                Text("Ready when: " + step.readyWhen).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Toggle(
                                    "I feel ready with this stage",
                                    isOn: Binding(
                                        get: { path.completedSteps.contains(index) },
                                        set: { _ in
                                            change { p in
                                                if p.completedSteps.contains(index) {
                                                    p.completedSteps.remove(index)
                                                } else {
                                                    p.completedSteps.insert(index)
                                                }
                                            }
                                        })
                                ).toggleStyle(.checkbox).font(.caption)
                            }.padding(.top, 12)
                        } label: {
                            Text("\(index+1). " + step.title).font(.system(size: 15, weight: .medium))
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(Color.clay).font(.caption) }
            }
            .onAppear { if let next = plan.queue().first { expanded.insert(next.stage) } }
            .confirmationDialog(
                "Remove this pathway and its review schedule?", isPresented: $removing, titleVisibility: .visible
            ) {
                Button("Remove pathway", role: .destructive) {
                    var copy = state.learning
                    copy.pathways.removeAll { $0.id == path.id }
                    do { try state.commitLearning(copy) } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text("Your score and detailed practice history are kept.")
            }
        }
    }
    private func change(_ action: (inout LearningPathway) -> Void) {
        var copy = state.learning
        guard let index = copy.pathways.firstIndex(where: { $0.id == path.id }) else { return }
        action(&copy.pathways[index])
        do {
            try state.commitLearning(copy)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct PieceReviewQueueView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        let paths = state.learning.pathways.filter { $0.piecePractice != nil }
        if !paths.isEmpty {
            TimelineView(.periodic(from: Date(), by: 60)) { time in
                let available = paths.filter { state.pathwayCurrent($0) && $0.piecePractice?.paused == false }
                let candidates = available.flatMap { path in (path.piecePractice?.tasks ?? []).map { (path, $0) } }
                let items = ReviewQueue.ordered(candidates, now: time.date, review: { $0.1.review }) { a, b in
                    if a.0.createdAt != b.0.createdAt { return a.0.createdAt < b.0.createdAt }
                    if a.1.stage != b.1.stage { return a.1.stage < b.1.stage }
                    let tasks = a.0.piecePractice?.tasks ?? []
                    return (tasks.firstIndex(where: { $0.id == a.1.id }) ?? 0)
                        < (tasks.firstIndex(where: { $0.id == b.1.id }) ?? 0)
                }
                Card(
                    title: "From your music", subtitle: "A little review, a little discovery", padding: 18, spacing: 12
                ) {
                    if items.isEmpty {
                        Text("Nothing due right now. Your pathways stay open in Library → Learn.").font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.1.title).font(.callout).fontWeight(.medium)
                                Text(
                                    (state.pieceForPathway(item.0)?.title ?? item.0.outline.title) + " · "
                                        + item.1.review.reason(now: time.date)
                                ).font(.caption).foregroundStyle(.secondary).fixedSize(
                                    horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Practise") { state.startPathwayTask(item.0.id, taskID: item.1.id) }
                        }
                    }
                    Text("Every exercise stays available. There are no streaks, penalties or locked stages.").font(
                        .caption
                    ).foregroundStyle(.secondary)
                }
            }
        }
    }
}
