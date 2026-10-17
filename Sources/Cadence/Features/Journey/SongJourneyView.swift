// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct SongJourneyWelcomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var instrument = EditorInstrument.piano
    @State private var pieceID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "A musical pathway").foregroundStyle(Color.moss)
            Text("Make a song your own.").font(.system(size: 36, weight: .medium, design: .serif))
            Text(
                "Hear it, understand it, find it under your fingers. Finish with an eight-bar arrangement that belongs to you."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Picker("Instrument", selection: $instrument) {
                    Text("Piano").tag(EditorInstrument.piano)
                    Text("Guitar").tag(EditorInstrument.guitar)
                }.pickerStyle(.segmented).frame(width: 200)
                ChoiceMenu(title: "Starting music", selection: $pieceID, options: [""] + state.libraryPieces.map(\.id))
                { id in
                    id.isEmpty
                        ? "Original Cadence example"
                        : state.libraryPieces.first(where: { $0.id == id })?.title ?? "Unavailable piece"
                }.frame(maxWidth: 300)
                Spacer(minLength: 0)
            }
            HStack {
                Button("Begin my pathway", systemImage: "arrow.right") {
                    do {
                        try state.startSongJourney(instrument: instrument, pieceID: pieceID.isEmpty ? nil : pieceID)
                    } catch { state.message = error.localizedDescription }
                }.buttonStyle(.cadencePrimary).accessibilityIdentifier("journey.begin")
                Text("15-minute sessions · every chapter stays open").font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "Original music works offline. For your own piece, begin with four reviewed 4/4 bars, a single melodic voice and written chord symbols."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.paper, in: RoundedRectangle(cornerRadius: 16)).overlay(
                RoundedRectangle(cornerRadius: 16).stroke(Color.line))
    }
}

struct SongJourneyView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.workspaceWidth) private var width
    @State private var selected = SongLesson.changes
    @State private var error: String?
    let input: SongOpeningInput
    let midi: MIDIKeyboard
    var body: some View {
        if let journey = state.selectedSongJourney {
            TimelineView(.periodic(from: .now, by: 60)) { time in
                VStack(alignment: .leading, spacing: 22) {
                    header(journey)
                    if (try? state.validateSongJourney(journey)) == nil {
                        ContentUnavailableView(
                            "Your source needs another look", systemImage: "doc.badge.ellipsis",
                            description: Text(
                                "A piece changed or needs review. Your earlier work is kept. Open the full score to review it, then begin a fresh pathway."
                            ))
                        Button("Start a fresh pathway") {
                            state.practicePage = .home
                            state.songJourneyID = nil
                        }
                    } else {
                        SongOpeningCheckView(journey: journey, input: input, midi: midi)
                        if width >= 780 {
                            HStack(alignment: .top, spacing: 26) {
                                map(journey, now: time.date).frame(width: 270)
                                detail(journey, now: time.date).frame(minWidth: 380, maxWidth: .infinity)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 22) {
                                ChoiceMenu(
                                    title: "Chapter",
                                    selection: Binding(
                                        get: { selected },
                                        set: {
                                            selected = $0
                                            state.songLesson = $0
                                        }), options: SongLesson.allCases, label: { $0.title })
                                detail(journey, now: time.date)
                                map(journey, now: time.date)
                            }
                        }
                    }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(Color.clay).accessibilityIdentifier("journey.error")
                    }
                    DisclosureGroup("Explore other activities") { PracticeHomeView(input: state.adaptiveInput) }
                }
            }
            .onAppear {
                selected = state.songLesson ?? state.songSession(journey).first?.lesson ?? .hear
                state.songLesson = selected
            }
            .onDisappear { input.pause() }
        } else {
            SongJourneyWelcomeView()
        }
    }
    private func header(_ journey: SongJourney) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Your musical pathway").foregroundStyle(Color.moss)
                Spacer()
                if state.songJourneys.count > 1 {
                    ChoiceMenu(
                        title: "Pathway", selection: Binding(get: { journey.id }, set: { state.openSongJourney($0) }),
                        options: state.songJourneys.map(\.id)
                    ) { id in
                        state.songJourneys.first(where: { $0.id == id }).map {
                            $0.material.title + " · " + $0.instrument.rawValue
                        } ?? "Pathway"
                    }.frame(width: 250)
                }
            }
            Text("Make a song your own.").font(.system(size: 36, weight: .medium, design: .serif))
            HStack(alignment: .firstTextBaseline) {
                Text(
                    journey.material.title + " · " + journey.instrument.rawValue + " · an eight-bar arrangement to keep"
                )
                .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open full score", systemImage: "music.note.list") {
                    if let piece = state.libraryPieces.first(where: { $0.id == journey.material.pieceID }) {
                        state.openLibraryPiece(piece)
                    }
                }.accessibilityIdentifier("journey.full-score")
            }
        }
    }
    private func map(_ journey: SongJourney, now: Date) -> some View {
        let evidence = state.songEvidence(journey, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "The whole journey")
                Spacer()
                Text("Every step is open").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 18)
            ForEach(Array(SongLesson.allCases.enumerated()), id: \.element) { index, lesson in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selected = lesson
                        state.songLesson = lesson
                    } label: {
                        HStack(spacing: 15) {
                            ZStack {
                                Circle().fill(selected == lesson ? Color.moss : Color.moss.opacity(0.07)).frame(
                                    width: 38, height: 38)
                                Image(systemName: lesson.icon).foregroundStyle(
                                    selected == lesson ? Color.white : Color.moss)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(lesson.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
                                Text(evidence[lesson]?.label ?? "Ready to explore").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("journey.lesson." + lesson.rawValue)
                        .accessibilityAddTraits(selected == lesson ? [.isSelected] : [])
                        .accessibilityHint("Show the lesson, its evidence and a suggested next activity")
                    if index < SongLesson.allCases.count - 1 {
                        Rectangle().fill(Color.line).frame(width: 1, height: 22).padding(.leading, 18)
                            .accessibilityHidden(true)
                    }
                }
            }
            Divider().padding(.vertical, 18)
            Text("Independent return: " + state.songReturnDate(journey).formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            Text("Early practice stays open. Time away and a different piece provide separate evidence.").font(.caption)
                .foregroundStyle(.secondary).padding(.top, 7)
        }.accessibilityElement(children: .contain).accessibilityLabel("Learning pathway")
    }
    private func detail(_ journey: SongJourney, now: Date) -> some View {
        let session = state.songSession(journey, now: now)
        let evidence = state.songEvidence(journey, now: now)
        return VStack(alignment: .leading, spacing: 17) {
            HStack {
                Eyebrow(text: selected == session.first?.lesson ? "Suggested for today" : "Explore this chapter")
                    .foregroundStyle(Color.moss)
                Spacer()
                ChoiceMenu(
                    title: "Session length",
                    selection: Binding(
                        get: { journey.minutes },
                        set: { value in
                            perform { try state.setSongMinutes(value, journey: journey) }
                        }), options: [10, 15, 25]
                ) { "\($0) min" }.frame(width: 105)
            }
            Text(selected.title).font(.system(size: 28, weight: .medium, design: .serif))
            Text(selected.goal).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(
                (selected == .independent ? journey.transfer : journey.material).chords.map { $0.symbol.label }.joined(
                    separator: "  →  ")
            )
            .font(.system(size: 24, design: .serif)).foregroundStyle(Color.moss).padding(.vertical, 7)
            HStack(alignment: .top, spacing: 16) {
                capability("Hear", evidence[.hear]?.label ?? "Ready to explore")
                capability("Explain", state.songExplanation(journey).label)
                capability(
                    "Play",
                    evidence[.groove]?.latest == nil
                        ? evidence[.changes]?.label ?? "Ready to explore" : evidence[.groove]!.label)
                capability("Create", evidence[.arrange]?.label ?? "Ready to explore")
            }
            if selected == .changes {
                VStack(alignment: .leading, spacing: 9) {
                    Text("A small theory check").font(.headline)
                    Text("Which note can stay in the same octave when C–E–G becomes F–A–C?").font(.callout)
                    HStack {
                        ForEach([0, 4, 7], id: \.self) { answer in
                            Button(Pitch.spelled(answer).name) {
                                perform { try state.saveSongExplanation(journey, answer: answer) }
                            }
                            .accessibilityLabel("Common tone: " + Pitch.spelled(answer).name)
                            .accessibilityIdentifier("journey.theory." + String(answer))
                        }
                    }
                    if let answer = state.songExplanation(journey).latest {
                        Text(
                            answer.outcome == .correct
                                ? "C can stay. The other two voices can move to F and A."
                                : "Compare the two sets of chord tones, then try again."
                        )
                        .font(.caption).foregroundStyle(Color.moss)
                    }
                    Text("Naming a relationship is recorded separately from hearing or playing it.").font(.caption)
                        .foregroundStyle(.secondary)
                }.padding(14).background(Color.moss.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            if selected == .arrange {
                Text(
                    "Keep the original beside you. Write a melody or borrow its contour, add an accompaniment, then give the second phrase a contrast. Listen to the complete version before saving it as finished."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Button(
                selected == .arrange
                    ? "Open my eight bars" : selected == .independent ? "Try another piece" : "Open activity",
                systemImage: selected.icon
            ) {
                perform { try state.openSongActivity(selected, journey: journey) }
            }.buttonStyle(.cadencePrimary).accessibilityIdentifier("journey.open-activity")
            Button("Ask my coach about this chapter", systemImage: "sparkles") {
                state.coachForSong(journey, lesson: selected)
            }
            .font(.caption)
            Divider()
            HStack {
                Text("Today’s session").font(.headline)
                Spacer()
                Text("Suggested time · no countdown").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(session) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button(item.lesson.title) {
                            selected = item.lesson
                            state.songLesson = item.lesson
                        }.buttonStyle(.plain).foregroundStyle(
                            Color.moss)
                        Spacer()
                        Text("\(item.minutes) min").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(item.reason).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            }
            Text(
                "Your listening, explanations, playing and creative work stay separate. These suggestions are based on recorded attempts, not a general mastery score."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.paper, in: RoundedRectangle(cornerRadius: 15)
        )
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.line))
    }
    private func capability(_ title: String, _ status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(status).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct SongJourneyReturnBar: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        if let journey = state.selectedSongJourney, state.songJourneyID != nil,
            !(state.destination == .practice && state.practicePage == .songJourney)
        {
            HStack(spacing: 12) {
                Button("Your pathway", systemImage: "arrow.uturn.backward") { state.openSongJourney(journey.id) }
                    .accessibilityIdentifier("journey.return")
                Text("Make a song your own · " + (state.songLesson?.title ?? journey.material.title)).font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let piece = state.libraryPieces.first(where: { $0.id == journey.material.pieceID }) {
                    Button("Full score") { state.openLibraryPiece(piece) }
                }
            }.font(.caption).padding(.horizontal, 22).padding(.vertical, 9).background(Color.moss.opacity(0.06))
        }
    }
}
