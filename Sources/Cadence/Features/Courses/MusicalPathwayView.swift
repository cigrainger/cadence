// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct CourseLibraryView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !state.showAdaptiveSession && (state.learningShelf != "Pathways" || state.musicalPathwayStep == nil) {
                Picker("Learning library", selection: $state.learningShelf) {
                    Text("Pathways").tag("Pathways")
                    Text("Book chapters").tag("Book chapters")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 290)
            }
            if state.learningShelf == "Pathways" { MusicalPathwaysView() } else { BookChaptersView() }
        }
    }
}

struct MusicalPathwaysView: View {
    @EnvironmentObject private var state: AppState
    @State private var setup = CommandLine.arguments.contains("--smooth-setup")
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let pathway = state.selectedMusicalPathway {
                if state.showAdaptiveSession, state.smoothPractice.active?.pathwayID == pathway.id {
                    AdaptiveSessionView(input: state.adaptiveInput, midi: state.midi, audio: state.audio)
                } else if let step = pathway.steps.first(where: { $0.id == state.musicalPathwayStep }) {
                    MusicalPathwayLessonView(pathway: pathway, step: step).id(step.id)
                } else {
                    overview(pathway)
                }
            } else {
                hero(
                    title: "Make chord changes\nsound smooth",
                    subtitle: "A small journey from a shape under your fingers to a phrase of your own.")
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Two books. One musical goal.").font(.system(size: 24, weight: .medium, design: .serif))
                        Text(
                            "Explore inversions with Rikky Rooksby, then guide-tone movement with Mark Levine. Play four original studies, revisit what needs care, and write four bars of your own."
                        ).font(.callout).foregroundStyle(.secondary)
                        Label("Piano · five open steps · 10–25 minute sessions", systemImage: "pianokeys").font(
                            .caption
                        ).foregroundStyle(Color.moss)
                        Button("Use my books to begin", systemImage: "book.pages") { setup = true }.buttonStyle(
                            .cadencePrimary
                        ).controlSize(.large)
                        Text("Your EPUB and PDF stay in your local library. This pathway works without an AI request.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 13) {
                        benefit("ear", "Hear the movement", "Listen before you play.")
                        benefit("hand.draw", "Find a comfortable change", "Practise one transition, then a phrase.")
                        benefit("pencil.and.outline", "Make it yours", "Keep something you wrote.")
                    }.padding(22).frame(width: 320).background(
                        .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
        }.sheet(isPresented: $setup) { SmoothPathwaySetupView() }
    }
    private func hero(title: String, subtitle: String) -> some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 12) {
                Text("A MUSICAL PATHWAY").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(
                    .white.opacity(0.7))
                Text(title).font(.system(size: 33, weight: .medium, design: .serif)).fixedSize(
                    horizontal: false, vertical: true)
                Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.85)).frame(
                    maxWidth: 530, alignment: .leading)
            }
            Spacer(minLength: 0)
            VoiceLeadingMotif().frame(width: 235, height: 120).accessibilityLabel(
                "Dm7, G7 and C major seventh connected by small note movements")
        }.foregroundStyle(.white).padding(28).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.moss, in: RoundedRectangle(cornerRadius: 22))
    }
    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.moss).frame(width: 23)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func overview(_ pathway: MusicalPathway) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            hero(title: pathway.title, subtitle: pathway.goal)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A session that follows your playing").font(.system(size: 23, weight: .medium, design: .serif))
                    Text("Check in · explore voicings · try a new key · make a phrase").font(.callout).foregroundStyle(
                        .secondary)
                    Text("Original Cadence exercises · your place is saved · MIDI or on-screen keys").font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    state.smoothPractice.active?.pathwayID == pathway.id
                        && state.smoothPractice.active?.phase != .summary ? "Resume session" : "Begin session",
                    systemImage: "play.fill"
                ) { perform { try state.openAdaptiveSession(pathway.id) } }.buttonStyle(.cadencePrimary).controlSize(
                    .large)
            }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 16))
            if state.hasMissingPathwayStudies(pathway) {
                HStack {
                    Text("The pathway is saved, but some original studies are missing.").font(.callout)
                    Spacer()
                    Button("Restore missing studies") { perform { try state.repairSmoothScores(pathway) } }
                }.padding(16).background(Color.clay.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Today, at your pace").font(.system(size: 24, weight: .medium, design: .serif))
                    Text("A little remembering, a useful next step, and room to make music.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(
                    "Time",
                    selection: Binding(
                        get: { pathway.minutes },
                        set: { value in perform { try state.changeMusicalPathway(pathway.id) { $0.minutes = value } } })
                ) { ForEach([10, 15, 25], id: \.self) { Text("\($0) min").tag($0) } }.pickerStyle(.segmented)
                    .labelsHidden().frame(width: 190)
            }
            HStack {
                Text("My focus").font(.caption).foregroundStyle(.secondary)
                ChoiceMenu(
                    title: "My focus",
                    selection: Binding(
                        get: { pathway.focus },
                        set: { value in perform { try state.changeMusicalPathway(pathway.id) { $0.focus = value } } }),
                    options: PathwayFocus.allCases, label: { $0.rawValue }
                ).frame(width: 250)
                Spacer()
                Text("Suggested time · no countdown").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(state.musicalSession(pathway)) { item in
                    if let step = pathway.steps.first(where: { $0.id == item.stepID }) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(item.label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                                    .foregroundStyle(Color.moss)
                                Spacer()
                                Text("\(item.minutes) min").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(step.title).font(.system(size: 20, weight: .medium, design: .serif)).fixedSize(
                                horizontal: false, vertical: true)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary).fixedSize(
                                horizontal: false, vertical: true)
                            if let evidenceID = item.evidenceID {
                                Button("Start review", systemImage: "arrow.right") {
                                    perform {
                                        try state.openMusicalReview(
                                            pathwayID: pathway.id, stepID: step.id, evidenceID: evidenceID)
                                    }
                                }.controlSize(.small)
                                Button("Read the lesson") { state.openMusicalStep(step) }.buttonStyle(.plain).font(
                                    .caption
                                ).foregroundStyle(Color.moss)
                            } else {
                                Button("Open activity", systemImage: "arrow.right") { state.openMusicalStep(step) }
                                    .controlSize(.small)
                            }
                        }.padding(18).frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading).background(
                            .white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16)
                        ).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
                    }
                }
            }
            HStack {
                Text("Your route through the music").font(.system(size: 23, weight: .medium, design: .serif))
                Spacer()
                Text("Every step stays open").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(pathway.steps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        state.openMusicalStep(step)
                    } label: {
                        HStack(spacing: 16) {
                            Text(String(format: "%02d", index + 1)).font(.system(size: 18, design: .serif))
                                .foregroundStyle(Color.moss).frame(width: 42, height: 42).background(
                                    Color.moss.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).fontWeight(.medium)
                                Text(step.role.rawValue + " · " + sourceTitle(step)).font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Spacer()
                            Text(status(step, pathway: pathway)).font(.caption).foregroundStyle(Color.moss)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(15).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if index < pathway.steps.count - 1 { Divider().padding(.leading, 74) }
                }
            }.background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            Text(
                "Reviews use your recorded attempts on these exact studies. A reflection, a supported attempt and a timed performance remain different kinds of evidence."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func sourceTitle(_ step: MusicalPathway.Step) -> String {
        guard let (course, _) = try? state.pathwayLesson(step), let book = try? state.courseBook(course) else {
            return "Source unavailable"
        }
        return book.author.isEmpty ? book.title : book.author
    }
    private func status(_ step: MusicalPathway.Step, pathway: MusicalPathway) -> String {
        if step.role == .compose { return pathway.compositionID == nil ? "Your blank page" : "Your composition" }
        guard let o = state.musicalObservations(pathway).first(where: { $0.stepID == step.id }) else {
            return "Explore"
        }
        if let e = o.evidence.first { return e.mode == .timed ? "Timed practice recorded" : "Practice recorded" }
        return o.ready ? "Ready to practise" : "Read & review"
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct VoiceLeadingMotif: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Dm7")
                Spacer()
                Text("G7")
                Spacer()
                Text("Cmaj7")
            }.font(.system(size: 16, weight: .medium, design: .serif))
            Canvas { context, size in
                let xs: [CGFloat] = [15, size.width / 2, size.width - 15]
                for ys: [CGFloat] in [[20, 28, 28], [60, 60, 68]] {
                    var path = Path()
                    path.move(to: CGPoint(x: xs[0], y: ys[0]))
                    for i in 1...2 { path.addLine(to: CGPoint(x: xs[i], y: ys[i])) }
                    context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 2)
                    for i in 0...2 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: xs[i] - 5, y: ys[i] - 5, width: 10, height: 10)),
                            with: .color(.white.opacity(0.9)))
                    }
                }
            }.frame(height: 78)
            Text("Small movements. A connected phrase.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
        }
    }
}
