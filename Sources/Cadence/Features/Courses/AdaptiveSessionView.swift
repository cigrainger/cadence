// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct AdaptiveSessionView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var input: AdaptiveSessionInput
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @State private var selected = Set<Int>()
    @State private var useScreen = false
    @State private var upperKeys = false
    @State private var error: String?
    @State private var reading = false
    @State private var reflection = ""
    @State private var listened = false
    @State private var notation: EditorDocument?
    @State private var scoreHeight: CGFloat = 180
    @State private var scoreError: String?
    @State private var metrics = ""
    private var session: SmoothSession? { state.smoothPractice.active }
    private var pathway: MusicalPathway? { state.courses.musicalPathways?.first { $0.id == session?.pathwayID } }
    private var renderKey: String {
        guard let s = session else { return "" }
        return "\(s.id):\(s.phase):\(s.cursor):\(s.hinted):\(s.awaitingAdvance)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let session {
                HStack {
                    Button(state.adaptiveFromPractice ? "Practice home" : "Your pathway", systemImage: "arrow.left") {
                        input.pause(held: midi.keyboard.downNotes)
                        if state.adaptiveFromPractice {
                            state.showPracticeHome()
                        } else {
                            state.showAdaptiveSession = false
                        }
                    }.buttonStyle(.plain).foregroundStyle(Color.moss)
                    Spacer()
                    Label(
                        input.pending == nil ? "Your place is saved" : "Answer waiting to save",
                        systemImage: input.pending == nil ? "checkmark.circle" : "exclamationmark.circle"
                    ).font(.caption).foregroundStyle(input.pending == nil ? Color.secondary : Color.clay)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 7) {
                        Eyebrow(text: "Smooth changes · about \(session.minutes) minutes").foregroundStyle(Color.moss)
                        Text(session.phase.title).font(.system(size: 29, weight: .medium, design: .serif))
                    }
                    Spacer()
                }
                SessionJourney(phase: session.phase)
                if session.phase == .summary {
                    summary(session)
                } else if session.phase == .composition {
                    composition(session)
                } else if session.blockComplete {
                    blockFinish(session)
                } else if let prompt = session.current {
                    HStack(alignment: .top, spacing: 18) {
                        exercise(session, prompt).frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 14) {
                            if session.awaitingAdvance, let response = session.lastResponse {
                                feedback(response)
                            } else {
                                keyboardInput(session, prompt)
                            }
                            DisclosureGroup("About this exercise") { guidance(session, prompt) }.font(.caption).padding(
                                14
                            ).background(Color.moss.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        }.frame(width: 300)
                    }
                }
                if let error = input.error ?? error {
                    Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
                }
                if input.pending != nil {
                    HStack {
                        Text("Your answer is still here.").font(.caption)
                        Button("Save answer again") { input.save(state: state) }
                        Button("Discard unsaved answer") { input.discard() }
                    }
                }
            }
        }
        .task(id: renderKey) {
            selected = []
            makeNotation()
            if let session, session.phase == .opening, session.cursor == 0, session.lastResponse == nil,
                let mode = session.openingReviewInput
            {
                useScreen = mode == .choice
            }
            if state.isPreview && CommandLine.arguments.contains("--adaptive-screen") {
                useScreen = true
                selected = [60, 65, 69]
            }
        }
        .onReceive(midi.updates) { update in
            input.receive(update, state: state, active: state.isPreview || NSApp.isActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            input.pause(held: midi.keyboard.downNotes)
        }
        .onChange(of: midi.connectionRevision) { _, _ in input.pause(held: midi.keyboard.downNotes) }
        .onChange(of: midi.connected) { _, _ in input.pause(held: midi.keyboard.downNotes) }
        .onChange(of: audio.isPlaying) { _, value in if value { input.pause(held: midi.keyboard.downNotes) } }
        .onDisappear {
            input.pause(held: midi.keyboard.downNotes)
            audio.stop()
        }
        .sheet(isPresented: $reading) {
            if let pathway, let step = pathway.steps.dropFirst().first {
                AdaptiveSourceReader(step: step)
            }
        }
    }
    private func exercise(_ session: SmoothSession, _ prompt: VoicingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(prompt.title).font(.system(size: 32, weight: .medium, design: .serif))
                Spacer()
                Text(
                    session.phase == .opening && session.cursor == 0 && session.openingReview != nil
                        ? "Spaced review" : "Change \(session.cursor+1) of \(session.phase.count)"
                ).font(.caption).foregroundStyle(.secondary)
            }
            if !session.awaitingAdvance {
                Label("Before you play, imagine how the next chord could sound.", systemImage: "ear").font(.caption)
                    .foregroundStyle(Color.moss)
                Text("Find a nearby \(Pitch.spelled(prompt.toRoot).name) major voicing.").font(
                    .system(size: 17, weight: .medium))
                Text(
                    "Start with \(names(prompt.from)). Keep any shared note in the same octave; move each voice no more than five semitones."
                ).font(.callout).foregroundStyle(.secondary)
            }
            if let notation {
                EditorRenderer(
                    document: notation, engine: "OpenSheetMusicDisplay", from: 0, through: 1, selection: nil,
                    playhead: nil, select: { _ in }, height: $scoreHeight, error: $scoreError, metrics: $metrics
                ).frame(height: min(205, max(150, scoreHeight)))
            }
            Text(
                session.awaitingAdvance
                    ? "Your answer is shown in the second bar."
                    : session.hinted
                        ? "One possible answer is shown. Other voicings can fit too."
                        : "The second bar is yours to fill. Several answers can work."
            ).font(.caption).foregroundStyle(Color.moss)
            if let scoreError { Text(scoreError).font(.caption).foregroundStyle(Color.clay) }
            if let answer = visibleVoiceAnswer(session, prompt), answer.count == prompt.from.count {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: session.awaitingAdvance ? "Your voices in motion" : "One possible connection")
                        .foregroundStyle(Color.moss)
                    VoiceLeadingDiagram(from: prompt.from, to: answer)
                    Text("Low, middle and high voices · a dashed line stays on the same note").font(.caption2)
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            HStack {
                Button("Hear starting chord", systemImage: "speaker.wave.2") {
                    input.pause()
                    audio.chord(prompt.from)
                }
                if !session.awaitingAdvance {
                    Button(session.hinted ? "Hear one solution" : "Show & hear a solution", systemImage: "lightbulb") {
                        perform {
                            try state.changeAdaptiveSession { try $0.reveal() }
                            hear(prompt.from, prompt.solutions.first ?? [])
                        }
                    }.disabled(input.pending != nil)
                }
            }.controlSize(.small)
            if pathway != nil {
                Button("Read the linked lesson", systemImage: "book.pages") {
                    perform {
                        if !session.awaitingAdvance { try state.changeAdaptiveSession { try $0.reveal() } }
                        input.pause()
                        reading = true
                    }
                }.controlSize(.small).disabled(input.pending != nil)
            }
        }.padding(22).background(Color.paper, in: RoundedRectangle(cornerRadius: 12)).overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.line))
    }
    private func keyboardInput(_ session: SmoothSession, _ prompt: VoicingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try your choice").font(.system(size: 23, weight: .medium, design: .serif))
            Toggle("Use on-screen keys", isOn: $useScreen).toggleStyle(.checkbox).font(.caption).onChange(of: useScreen)
            { _, _ in
                input.pause(held: midi.keyboard.downNotes)
                selected = []
            }
            if useScreen {
                Picker("Register", selection: $upperKeys) {
                    Text("C3–C5").tag(false)
                    Text("C4–C6").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                Piano(
                    root: Pitch.spelled(prompt.toRoot), notes: [], degrees: [], showDegrees: false,
                    exactNotes: selected,
                    play: { note in
                        if selected.contains(note) { selected.remove(note) } else { selected.insert(note) }
                        audio.note(note)
                    }, midiRange: upperKeys ? 60...84 : 48...72, keyHeight: 100)
                Text(selected.isEmpty ? "Choose three notes." : names(selected.sorted())).font(.caption)
                HStack {
                    Button("Clear") { selected = [] }
                    Spacer()
                    Button("Check my choice") { input.submit(selected.sorted(), state: state, input: .choice) }
                        .buttonStyle(.cadencePrimary).disabled(selected.isEmpty || input.pending != nil)
                }
                Text("Recorded as an on-screen choice. MIDI playing has its own review history.").font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                MIDIConnectionView(midi: midi, compact: true)
                Piano(
                    root: Pitch.spelled(prompt.toRoot), notes: [], degrees: [], showDegrees: false,
                    exactNotes: midi.keyboard.downNotes, play: { _ in }, midiRange: 48...84, keyHeight: 90
                ).allowsHitTesting(false)
                Text(
                    input.waitingForRelease
                        ? "Release the held keys before beginning."
                        : input.preparationMessage
                            ?? (input.listening
                                ? "Play the starting shape shown above, then release it."
                                : "Turn on input, then play the starting shape and your next chord.")
                ).font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Button(
                        input.listening ? "Pause input" : "Listen to keyboard",
                        systemImage: input.listening ? "pause.circle" : "pianokeys"
                    ) {
                        input.listening
                            ? input.pause(held: midi.keyboard.downNotes) : input.listen(held: midi.keyboard.downNotes)
                    }.buttonStyle(.cadencePrimary).disabled(
                        !midi.connected || input.pending != nil || audio.isPlaying || audio.isPreparing)
                    Button(input.verifiedFrom == nil ? "Check starting shape" : "Check held chord") {
                        input.checkHeld(midi.keyboard.downNotes.sorted(), state: state)
                    }.disabled(
                        !midi.connected || midi.keyboard.downNotes.isEmpty || input.pending != nil || audio.isPlaying
                            || audio.isPreparing)
                }
            }
            Text("Three notes, within one octave · C3–C6").font(.caption).foregroundStyle(.secondary)
            Text(
                session.hinted
                    ? "This attempt uses support."
                    : session.phase == .transfer
                        ? "Try before opening a hint. Help stays available."
                        : "Try first, or open a hint whenever you need one."
            ).font(.caption).foregroundStyle(.secondary)
            Button("Skip this change") {
                input.submit([], state: state, input: useScreen ? .choice : .midi, skipped: true)
            }.controlSize(.small).disabled(input.pending != nil)
        }.padding(20).background(Color.paper, in: RoundedRectangle(cornerRadius: 12)).overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.line))
    }
    private func feedback(_ response: SmoothResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                response.skipped
                    ? "Left open for another time"
                    : response.feedback.correct ? "A connected change" : "A useful place to explore",
                systemImage: response.feedback.correct ? "checkmark.circle" : "arrow.triangle.branch"
            ).font(.system(size: 22, weight: .medium, design: .serif)).foregroundStyle(Color.moss).fixedSize(
                horizontal: false, vertical: true)
            if !response.skipped {
                Text(response.feedback.message).font(.callout)
                Text("You chose " + names(response.played)).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    fact("Chord tones", response.feedback.harmony)
                    fact("Shared notes", response.feedback.common)
                    fact("Small movement", response.feedback.movement)
                }
                if response.feedback.shape {
                    Text(
                        "Low · middle · high voice: "
                            + response.feedback.movements.map { "\($0) semitones" }.joined(separator: " · ")
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Button("Listen to my change", systemImage: "play.fill") { hear(response.prompt.from, response.played) }
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 10) {
                Button(response.feedback.correct ? "Try another voicing" : "Try this change again") {
                    perform { try state.changeAdaptiveSession { try $0.retry() } }
                }
                Button("Continue", systemImage: "arrow.right") {
                    perform {
                        try state.changeAdaptiveSession {
                            try $0.advance()
                            $0.suggestFocus()
                        }
                    }
                }.buttonStyle(.cadencePrimary)
            }
            Text("Retries stay marked as practice with support. You can continue even when a change needs more time.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(22).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    private func fact(_ title: String, _ matches: Bool) -> some View {
        Label(title, systemImage: matches ? "checkmark" : "circle").font(.caption).foregroundStyle(
            matches ? Color.moss : Color.clay)
    }
    private func guidance(_ session: SmoothSession, _ prompt: VoicingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Image(systemName: session.phase == .transfer ? "sparkle" : "ear").font(.title2).foregroundStyle(Color.moss)
            Text(session.phase == .transfer ? "Same idea. New setting." : "Listen for connection").font(
                .system(size: 21, weight: .medium, design: .serif))
            Text(
                session.phase == .transfer
                    ? "D–A–G–D changes both the key and the order. Work out your own shapes before seeing an example."
                    : session.phase == .workshop
                        ? session.focusReason
                        : "This short check helps choose a useful focus. You can change that choice after the three transitions."
            ).font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("For this exercise").fontWeight(.medium)
            Text(
                "Three different notes, within one octave. Stay between C3 and C6. Any inversion that fits is welcome."
            ).font(.caption).foregroundStyle(.secondary)
            Text("Voices are compared from low to high. Replaying a shared note in the same octave is fine.").font(
                .caption
            ).foregroundStyle(.secondary)
            Text("Take your time. This session checks notes and movement; it has no timing grade.").font(.caption)
                .foregroundStyle(.secondary)
            if pathway != nil {
                Button("Read the linked lesson", systemImage: "book.pages") {
                    perform {
                        if !session.awaitingAdvance { try state.changeAdaptiveSession { try $0.reveal() } }
                        input.pause()
                        reading = true
                    }
                }.controlSize(.small).disabled(input.pending != nil)
            }
        }.padding(20).background(Color.moss.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
    private func blockFinish(_ session: SmoothSession) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                session.phase == .opening
                    ? "Choose one change to explore"
                    : session.phase == .workshop ? "Try the idea without the example" : "Now give it your own rhythm"
            ).font(.system(size: 28, weight: .medium, design: .serif))
            if session.phase == .opening {
                Text(session.focusReason).font(.callout).foregroundStyle(.secondary)
                HStack {
                    ForEach(0..<3, id: \.self) { index in
                        Button {
                            perform { try state.changeAdaptiveSession { try $0.chooseFocus(index) } }
                        } label: {
                            Text(SmoothSession.focusPrompt(index).title).font(.title2).padding(20).frame(
                                maxWidth: .infinity
                            ).background(
                                index == session.focusIndex ? Color.moss.opacity(0.15) : Color.canvas,
                                in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                Text(
                    "The next two attempts start in different inversions. You choose which change gets that attention."
                ).font(.callout)
            } else if session.phase == .workshop {
                Text(
                    "Next: D–A–G–D. Start from a D-major shape, then find nearby voicings. Hints stay closed until you ask; those attempts are recorded separately."
                ).font(.callout)
            } else {
                Text(
                    "You tried \(session.responses.filter { $0.phase == .transfer && !$0.skipped }.count) answers in a new setting. Bring one of those choices into a short phrase."
                ).font(.callout)
            }
            Button(
                session.phase == .transfer
                    ? "Make my phrase"
                    : session.phase == .opening ? "Practise this change" : "Begin the independent attempt",
                systemImage: "arrow.right"
            ) { perform { try state.changeAdaptiveSession { try $0.nextPhase() } } }.buttonStyle(.cadencePrimary)
                .controlSize(.large)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.paper, in: RoundedRectangle(cornerRadius: 12))
    }
    private func composition(_ session: SmoothSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Four bars. Something you want to hear.").font(.system(size: 28, weight: .medium, design: .serif))
            Text(
                "Choose C–F–G–C, D–A–G–D, or your own progression. Use a nearby inversion you discovered, give it a rhythm, then listen and revise one change."
            ).font(.callout)
            Button(
                state.adaptiveComposition() == nil ? "Open my blank page" : "Continue my composition",
                systemImage: "pencil.and.outline"
            ) { perform { try state.openPathwayComposition(session.pathwayID) } }.buttonStyle(.cadencePrimary)
                .controlSize(.large)
            if let score = state.adaptiveComposition() {
                Text(score.title).font(.headline)
                Button("Listen to my phrase", systemImage: "play.fill") {
                    audio.play(score.playback(from: 0, through: score.barCount - 1))
                    listened = true
                }.disabled(!score.events.contains { !$0.pitches.isEmpty })
                TextField(
                    "Which voicing did you choose, and what do you like about it?", text: $reflection, axis: .vertical
                ).textFieldStyle(.roundedBorder).lineLimit(3...6)
                Button("Keep this phrase & finish", systemImage: "checkmark") {
                    perform { try state.finishAdaptiveSession(reflection: reflection, includeComposition: true) }
                }.disabled(!listened || reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Finish today; write another time") {
                perform { try state.finishAdaptiveSession(reflection: reflection, includeComposition: false) }
            }.buttonStyle(.plain).foregroundStyle(Color.moss)
            Text(
                "Your musical choices are yours. Finishing records a reflection, without assigning a creativity score."
            ).font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.paper, in: RoundedRectangle(cornerRadius: 12))
    }
    private func summary(_ session: SmoothSession) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("You made time for your music.").font(.system(size: 29, weight: .medium, design: .serif))
            Text(
                session.responses.contains { !$0.skipped }
                    ? "You explored " + SmoothSession.focusPrompt(session.focusIndex).title
                        + " and reached the D-major activity."
                    : "You explored the session. The playing checks remain open for another time."
            ).font(.callout)
            ForEach([PracticeInput.midi, .choice], id: \.self) { mode in
                let answers = session.responses.filter { $0.phase == .transfer && $0.input == mode && !$0.skipped }
                if !answers.isEmpty {
                    Text(
                        "\(mode == .midi ? "Keyboard" : "On-screen") transfer: \(answers.filter { $0.outcome == .correct && !$0.assisted && $0.ordinal == 1 }.count) of 3 changes matched on the first attempt without hints."
                    ).font(.callout)
                }
            }
            Text(
                !session.responses.contains { !$0.skipped }
                    ? "No performance was graded in this session."
                    : session.responses.contains { $0.outcome == .incorrect }
                        ? "The changes that needed another try are scheduled for review. A successful retry keeps that earlier difficulty visible."
                        : "Your checked changes are saved for spaced review. A later session will show what has stayed with you."
            ).font(.callout).foregroundStyle(.secondary)
            if let review = session.responses.compactMap({
                state.history.cards[$0.attempt(sessionID: session.id, pathwayID: session.pathwayID).activityID]?.review
            }).filter({ $0.due != nil }).min(by: { $0.due! < $1.due! }) {
                Text(review.reason()).font(.caption).foregroundStyle(Color.moss)
            }
            if session.compositionID != nil {
                Label("Your composition and reflection are saved", systemImage: "music.note").foregroundStyle(
                    Color.moss)
                Text(session.reflection).font(.callout)
            } else {
                Text("Your composition invitation stays open in the pathway.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Button(
                state.adaptiveFromPractice ? "Back to practice home" : "Back to my pathway", systemImage: "arrow.right"
            ) {
                if state.adaptiveFromPractice {
                    state.showPracticeHome()
                } else {
                    state.showAdaptiveSession = false
                    state.musicalPathwayStep = nil
                }
            }.buttonStyle(.cadencePrimary)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.paper, in: RoundedRectangle(cornerRadius: 12))
    }
    private func visibleVoiceAnswer(_ session: SmoothSession, _ prompt: VoicingPrompt) -> [Int]? {
        AdaptivePresentation.answer(session)
    }
    private func makeNotation() {
        guard let session, let prompt = session.current else {
            notation = nil
            return
        }
        let shown = AdaptivePresentation.answer(session) ?? []
        var score = EditorDocument(
            title: prompt.title, instrument: .piano,
            events: [
                .init(bar: 0, rhythm: .init(1920), pitches: prompt.from.map { EditorPitch($0) }),
                .init(bar: 0, staff: 2, rhythm: .init(1920)),
                .init(
                    bar: 1, rhythm: .init(1920),
                    pitches: shown.filter { (21...108).contains($0) }.prefix(8).map { EditorPitch($0) }),
                .init(bar: 1, staff: 2, rhythm: .init(1920)),
            ])
        score.barCount = 2
        score.fifths = prompt.isTransferKey ? 2 : 0
        do {
            score.harmonies = [
                EditorHarmony(bar: 0, symbol: try ChordSymbol.parse(Pitch.spelled(prompt.fromRoot).name)),
                EditorHarmony(bar: 1, symbol: try ChordSymbol.parse(Pitch.spelled(prompt.toRoot).name)),
            ]
        } catch {
            scoreError = error.localizedDescription
            notation = nil
            return
        }
        notation = try? score.validated()
    }
    private func names(_ notes: [Int]) -> String {
        notes.map { Solfege.noteName(midi: $0, pitch: Pitch.spelled($0)) }.joined(separator: " · ")
    }
    private func hear(_ from: [Int], _ to: [Int]) {
        input.pause()
        audio.play(
            Score(
                tempo: 75,
                notes: from.map { ScoreNote(midi: $0, start: 0, duration: 2) }
                    + to.map { ScoreNote(midi: $0, start: 2, duration: 2) }))
    }
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct AdaptiveSourceReader: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let step: MusicalPathway.Step
    @State private var asset: BookAsset?
    @State private var page = 1
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("The idea in your book").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            if let (_, lesson) = try? state.pathwayLesson(step) {
                Text(lesson.bookSummary).font(.callout)
                Text("Source-linked summary · " + lesson.source.label).font(.caption).foregroundStyle(.secondary)
            }
            if let asset {
                BookSourcePane(asset: asset, page: $page)
            } else {
                ContentUnavailableView(
                    "Opening your book", systemImage: "book.pages",
                    description: Text(error ?? "The original stays in your local library."))
            }
        }.padding(24).frame(width: 740, height: 740).task {
            do {
                let (course, lesson) = try state.pathwayLesson(step)
                let book = try state.courseBook(course)
                let loaded = try await state.loadBook(book)
                guard CourseBook.digest(loaded.data) == book.digest else {
                    throw MusicError.invalid(
                        "The source book has changed. Restore its saved edition to keep this link accurate.")
                }
                asset = loaded
                page = lesson.source.fromPage
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// One visibility rule for both notation and the movement diagram: an
/// independent attempt must not reveal the target through a secondary visual.
enum AdaptivePresentation {
    static func answer(_ session: SmoothSession) -> [Int]? {
        if session.awaitingAdvance { return session.lastResponse?.played }
        return session.hinted ? session.current?.solutions.first : nil
    }
}

private struct SessionJourney: View {
    var phase: SmoothPhase
    private var current: Int { SmoothPhase.allCases.firstIndex(of: phase) ?? 0 }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(SmoothPhase.allCases.enumerated()), id: \.element) { index, step in
                VStack(alignment: .leading, spacing: 9) {
                    Rectangle().fill(index <= current ? Color.moss : Color.line).frame(height: 3)
                    HStack(spacing: 6) {
                        Text(index < current ? "✓" : String(format: "%02d", index + 1)).font(
                            .system(size: 10, weight: .semibold, design: .monospaced))
                        Text(step.label).font(.system(size: 11, weight: index == current ? .semibold : .regular))
                            .lineLimit(1)
                    }.foregroundStyle(index == current ? Color.moss : Color.secondary)
                }.padding(.trailing, index == 4 ? 0 : 12)
                    .accessibilityElement(children: .ignore).accessibilityLabel(
                        "Step \(index+1), \(step.label)\(index == current ? ", current" : index < current ? ", visited" : "")"
                    )
            }
        }.padding(.bottom, 2)
    }
}
