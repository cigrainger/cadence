// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct PracticeWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        switch state.practicePage {
        case .home: PracticeHomeView(input: state.adaptiveInput)
        case .reharm: ReharmPathwayView(input: state.reharmInput, transport: state.reharmTransport, midi: state.midi)
        case .tension: TensionPathwayView(input: state.tensionInput, audio: state.audio, midi: state.midi)
        case .triads: TriadPathwayView(input: state.triadInput, microphone: state.microphone, audio: state.audio)
        case .rehearsal: PieceRehearsalView(session: state.rehearsalSession, midi: state.midi, audio: state.audio)
        case .playAlong:
            if let material = state.playAlongMaterial {
                VStack(alignment: .leading, spacing: 16) {
                    Button("Practice home", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                        .foregroundStyle(Color.moss)
                    PlayAlongView(material: material, session: state.playAlongSession, midi: state.midi)
                }
            }
        case .scoreEar:
            EarPathwayView(
                input: state.scoreEarInput, midi: state.midi, audio: state.audio, microphone: state.microphone)
        case .ear:
            EarPathwayView(input: state.earInput, midi: state.midi, audio: state.audio, microphone: state.microphone)
        case .groove: GrooveLabView()
        case .adaptive: AdaptiveSessionView(input: state.adaptiveInput, midi: state.midi, audio: state.audio)
        case .exercises:
            VStack(alignment: .leading, spacing: 18) {
                Button("Practice home", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                    .foregroundStyle(Color.moss)
                PracticeView(microphone: state.microphone, audio: state.audio)
            }
        }
    }
}

struct PracticeHomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var input: AdaptiveSessionInput
    init(input: AdaptiveSessionInput) { self.input = input }
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { time in
            let reviews = state.practiceReviews(now: time.date)
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Your practice room").foregroundStyle(Color.moss)
                        Text("A little music, today.").font(.system(size: 34, weight: .medium, design: .serif))
                    }
                    Spacer()
                    Button("All exercises", systemImage: "square.grid.2x2") { state.openPractice() }.controlSize(.large)
                }
                PendingPlayAlongView(session: state.playAlongSession)
                RehearsalResumeView(session: state.rehearsalSession)
                ScoreEarSavedView()
                TensionHomeCard()
                ReharmHomeCard()
                TriadHomeCard()
                if let pathway = state.homePathway { session(pathway) } else { firstSession }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        LearningSectionHeading(
                            title: "Bring it back",
                            detail: reviews.isEmpty ? "Spaced review" : "\(reviews.count) available")
                        reviewList(reviews, now: time.date)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        LearningSectionHeading(title: "Make it yours")
                        composition
                    }.frame(width: 285)
                }
                VStack(alignment: .leading, spacing: 14) {
                    LearningSectionHeading(title: "Follow your curiosity", detail: "Every activity stays open")
                    HStack(alignment: .top, spacing: 0) {
                        activity(
                            "Hear & sing",
                            subtitle: "Hear → imagine → sing → play.\nThree phrases, guided by your ears.", icon: "ear",
                            number: "01"
                        ) { state.openEarPathway() }
                        Divider().padding(.vertical, 12)
                        activity(
                            "Find the groove", subtitle: "Piano, bass and drums.\nFind your place in the band.",
                            icon: "metronome", number: "02"
                        ) { state.practicePage = .groove }
                        Divider().padding(.vertical, 12)
                        activity(
                            "Follow the changes", subtitle: "Dm7 → G7 → Cmaj7\nExplore shapes, then play.",
                            icon: "pianokeys", number: "03"
                        ) { state.openChanges() }
                    }.fixedSize(horizontal: false, vertical: true).background(
                        Color.paper, in: RoundedRectangle(cornerRadius: 12)
                    ).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                }
                HStack(spacing: 8) {
                    Image(systemName: "leaf").foregroundStyle(Color.moss)
                    Text(
                        state.practicedDayCount == 0
                            ? "A first attempt is a useful beginning."
                            : "\(state.practicedDayCount) \(state.practicedDayCount == 1 ? "day" : "days") with music · concepts explored: \(state.practicedConceptCount)"
                    )
                    Spacer()
                    Text("Your pace. Your music.")
                }.font(.caption).foregroundStyle(.secondary)
                PracticeHistoryView()
            }
        }
        .onAppear {
            if state.isPreview {
                PracticeHomeDiagnostics.checks = [
                    "homeVisible": state.practicePage == .home && state.destination == .practice
                ]
                if CommandLine.arguments.contains("--smooth-preview") {
                    PracticeHomeDiagnostics.checks["pathwayAvailable"] = state.homePathway != nil
                    PracticeHomeDiagnostics.checks["reviewAvailable"] = !state.practiceReviews().isEmpty
                } else {
                    PracticeHomeDiagnostics.checks["emptyStateHonest"] =
                        state.homePathway == nil && state.practiceReviews().isEmpty
                }
                if CommandLine.arguments.contains("--adaptive-preview") {
                    PracticeHomeDiagnostics.checks["sessionResumable"] = state.canResumeAdaptive
                }
            }
        }
    }
    private func session(_ pathway: MusicalPathway) -> some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 13) {
                Eyebrow(text: state.canResumeAdaptive ? "Continue your session" : "Suggested for you").opacity(0.8)
                Text(pathway.title).font(.system(size: 30, weight: .medium, design: .serif)).fixedSize(
                    horizontal: false, vertical: true)
                Text(
                    state.canResumeAdaptive
                        ? state.smoothPractice.active?.phase.title ?? pathway.goal
                        : "Keep a shared note. Move the other voices gently. Hear the connection."
                ).font(.system(size: 14)).opacity(0.9).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button(state.canResumeAdaptive ? "Continue session" : "Begin session", systemImage: "arrow.right") {
                        do { try state.beginHomeSession() } catch { state.message = error.localizedDescription }
                    }.controlSize(.large).tint(Color.paper).foregroundStyle(Color.ink).buttonStyle(.cadence)
                    Text("About \(pathway.minutes) min · piano").font(.caption).opacity(0.8)
                }.padding(.top, 4)
                if input.pending != nil {
                    Label(
                        "An answer is waiting to be saved. Continue to recover it.",
                        systemImage: "exclamationmark.circle"
                    ).font(.caption)
                } else {
                    Text(
                        state.canResumeAdaptive
                            ? "Your place and previous attempts are kept."
                            : "An opening check helps choose what to practise next."
                    ).font(.caption).opacity(0.8)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Dm7")
                    Spacer()
                    Text("G7")
                }.font(.system(size: 25, weight: .medium, design: .serif))
                VoiceLeadingDiagram(from: [62, 65, 69, 72], to: [62, 65, 67, 71], onDark: true)
                Text("Two voices stay. Two voices move.").font(.caption).opacity(0.8)
                Button("Explore the pathway", systemImage: "arrow.up.right") {
                    state.musicalPathwaySelection = pathway.id
                    state.showPathways()
                }.buttonStyle(.plain).font(.caption).underline()
            }.frame(width: 230).padding(.leading, 22).overlay(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1)
            }
        }.padding(26).foregroundStyle(.white).background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
    }
    private var firstSession: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 13) {
                Eyebrow(text: "Start with your ears").foregroundStyle(Color.moss)
                Text("Hear it. Then make it yours.").font(.system(size: 30, weight: .medium, design: .serif))
                Text(
                    "Hear a phrase, imagine it in silence, sing it, then find it on your keyboard. A useful return and a new key follow."
                ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(
                    state.earPractice.active == nil ? "Begin ear-first session" : "Continue ear-first session",
                    systemImage: "ear"
                ) { state.openEarPathway() }.buttonStyle(.cadencePrimary).controlSize(.large)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "books.vertical").font(.system(size: 26)).foregroundStyle(Color.moss)
                Text("A pathway from your books").font(.system(size: 20, weight: .medium, design: .serif))
                Text("Connect reading, playing and a phrase of your own.").font(.caption).foregroundStyle(.secondary)
                Button("Explore courses", systemImage: "arrow.right") { state.showPathways() }
            }.frame(width: 220).padding(.leading, 24).overlay(alignment: .leading) {
                Rectangle().fill(Color.line).frame(width: 1)
            }
        }.padding(26).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
    private func reviewList(_ reviews: [PracticeReviewItem], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if reviews.isEmpty {
                Label("Room for something new", systemImage: "sun.max").font(
                    .system(size: 17, weight: .medium, design: .serif)
                ).foregroundStyle(Color.moss)
                Text("No passage reviews are waiting. As you practise music, useful returns will appear here.").font(
                    .callout
                ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                Button("Choose an exercise", systemImage: "arrow.right") { state.openPractice() }.padding(.top, 15)
            } else {
                ForEach(Array(reviews.prefix(3).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.vertical, 12) }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text(item.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.review.reason(now: now)).font(.caption).foregroundStyle(Color.moss).fixedSize(
                                horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            state.openPracticeReview(item)
                        } label: {
                            Image(systemName: "arrow.right").frame(width: 24, height: 26)
                        }.help("Practise \(item.title)").accessibilityLabel("Practise \(item.title)")
                    }
                }
                if reviews.count > 3 {
                    Button("More practice", systemImage: "arrow.right") { state.openPractice() }.padding(.top, 14)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading).background(
            Color.paper, in: RoundedRectangle(cornerRadius: 12)
        ).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
    }
    private var composition: some View {
        Card(title: "", spacing: 16, tint: Color.ochre.opacity(0.07)) {
            Eyebrow(text: "Your musical notebook").foregroundStyle(Color.ochre)
            Text(state.homeComposition?.title ?? "Leave a little idea here.").font(
                .system(size: 21, weight: .medium, design: .serif)
            ).lineLimit(2)
            Text("Give a chord change a rhythm. Listen back. Keep something you like.").font(.caption).foregroundStyle(
                .secondary)
            Button(
                state.homeComposition == nil ? "Start a piano phrase" : "Continue my phrase",
                systemImage: "pencil.and.outline"
            ) {
                if let piece = state.homeComposition {
                    state.openLibraryPiece(piece)
                } else {
                    state.newLibraryComposition(.piano)
                }
            }
        }
    }
    private func activity(_ title: String, subtitle: String, icon: String, number: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color.moss)
                    Spacer()
                    Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 21, weight: .medium, design: .serif))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(Color.moss)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }
}

@MainActor enum PracticeHomeDiagnostics { static var checks: [String: Bool] = [:] }

private struct PendingPlayAlongView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: PlayAlongSession
    var body: some View {
        if session.timing.hasUnsavedResult, let material = session.plan?.material {
            HStack {
                Label(
                    "A play-along pass is waiting to be saved · " + material.title, systemImage: "tray.and.arrow.down")
                Spacer()
                Button("Return to pass") {
                    state.playAlongMaterial = material
                    state.practicePage = .playAlong
                }
            }.font(.callout).padding(14).background(Color.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
