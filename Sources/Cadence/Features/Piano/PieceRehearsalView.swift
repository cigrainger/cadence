// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

private struct PracticeViewportHeight: EnvironmentKey { static let defaultValue: CGFloat = 800 }
extension EnvironmentValues {
    var practiceViewportHeight: CGFloat {
        get { self[PracticeViewportHeight.self] }
        set { self[PracticeViewportHeight.self] = newValue }
    }
}

struct PieceRehearsalView: View {
    @Environment(\.practiceViewportHeight) private var viewportHeight
    private var scoreViewport: CGFloat {
        session.shaping ? min(470, max(240, viewportHeight - 405)) : min(590, max(300, viewportHeight - 285))
    }
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: PieceRehearsalSession
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @State private var whole: MusicStudy?
    @State private var partID = ""
    @State private var staff = 1
    @State private var from = 1
    @State private var through = 4
    @State private var tempo = 80
    @State private var focusTempo = 65
    @State private var exercise = RehearsalExercise.notes
    @State private var input = TimedInput.space
    @State private var loopCount = 1
    @State private var scoreHeight: CGFloat = 400
    @State private var error: String?
    @State private var renderError: String?
    @State private var details = false
    @State private var discard = false
    @State private var showMap = false
    @State private var flowJoins: [FlowJoin] = []
    private var piece: LibraryPiece? { state.libraryPieces.first { $0.id == state.rehearsalPieceID } }
    private var isPiano: Bool {
        guard let piece, let whole else { return false }
        return PianoPhrase.isPiano(piece, part: whole.part)
    }
    private var record: PieceRehearsal? { state.currentRehearsal }
    private var timing: TimedPracticeSession { session.timing }
    private var locked: Bool {
        session.takePlayer.busy || timing.busy || timing.hasUnsavedResult || audio.isPlaying || audio.isPreparing
    }
    @State private var current = true
    private var visibleTake: PianoTake? {
        session.takePlayer.busy
            ? session.takePlayer.take : state.rehearsalTakes.first { $0.id == session.selectedTakeID }
    }
    private var selected: PassageScope? {
        (session.shaping ? visibleTake?.pass.plan.source?.scope : nil)
            ?? (timing.busy ? timing.plan?.source?.scope : nil) ?? record?.activePlan.source?.scope
            ?? whole.map {
                .init(partID: $0.partID, staff: staff == 0 ? nil : staff, from: from - 1, through: through - 1)
            }
    }
    private var head: StudyPlayhead? {
        if session.takePlayer.playing { return session.takePlayer.playhead }
        if audio.isPlaying { return audio.studyPlayhead }
        guard timing.active, !timing.calibration, let plan = timing.plan, let source = session.sourcePlan?.source else {
            return nil
        }
        return .init(
            sourceBeat: source.startBeat + max(0, min(plan.length - 0.00001, timing.elapsed / plan.secondsPerBeat)),
            isCountIn: timing.elapsed < 0, countInRemaining: Double(timing.countInRemaining), cycle: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            header
            journey
            if let whole {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Full score · \(whole.part.measures.count) bars", systemImage: "music.note.list")
                                .font(.callout.weight(.medium))
                            Spacer()
                            if let hands = record?.opening.handStaves {
                                Text("RH · staff \(hands[0])    LH · staff \(hands[1])").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Text(
                                selected.map {
                                    $0.from == $0.through
                                        ? "Focus · bar \($0.from+1)" : "Focus · bars \($0.from+1)–\($0.through+1)"
                                } ?? ""
                            ).font(.caption.monospacedDigit()).foregroundStyle(Color.moss)
                        }
                        ScoreRenderer(
                            study: whole, playhead: head,
                            feedback: !session.shaping && current && session.key == record?.key ? session.feedback : [],
                            feedbackStart: session.sourcePlan?.source?.startBeat, focus: selected, feedbackRoom: true,
                            height: $scoreHeight, error: $renderError
                        )
                        .frame(height: scoreViewport).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                        if session.shaping, let take = visibleTake {
                            PianoTakeTrace(
                                take: take, elapsed: session.takePlayer.playing ? session.takePlayer.elapsed : nil)
                        } else {
                            HStack(spacing: 12) {
                                Text("✓ On time").foregroundStyle(Color.moss)
                                Text("← Early   → Late   × Pitch   – Missed · chords: notes on time").foregroundStyle(
                                    .secondary)
                                Spacer()
                            }.font(.caption)
                        }
                        if let plan = timing.plan, session.key == record?.key, record?.opening.handStaves != nil,
                            timing.busy || timing.result != nil
                        {
                            Text(
                                (timing.busy ? "" : "Last pass · ") + handPassLabel(plan, conditions: timing.conditions)
                            ).font(.callout.weight(.medium)).foregroundStyle(Color.moss)
                        }
                        if timing.active {
                            ProgressView(value: max(0, min(1, timing.elapsed / (timing.plan?.duration ?? 1)))).tint(
                                Color.moss)
                            Text(
                                timing.elapsed < 0
                                    ? "Count in · \(timing.countInRemaining)"
                                    : timing.calibration
                                        ? "Tap one key on each click" : "Keep going. The next note is a fresh start."
                            ).font(.callout).foregroundStyle(Color.moss)
                        }
                        DisclosureGroup("Passage map · every bar stays in the score", isExpanded: $showMap) {
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34))], spacing: 6) {
                                    ForEach(whole.part.measures, id: \.index) { bar in
                                        let included =
                                            selected.map { ($0.from...$0.through).contains(bar.index) } ?? false
                                        Button("\(bar.index+1)") {
                                            from = bar.index + 1
                                            through = min(whole.part.measures.count, from + 3)
                                        }
                                        .buttonStyle(.plain).font(.caption.monospacedDigit()).frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(
                                            included ? Color.moss.opacity(0.16) : Color.canvas,
                                            in: RoundedRectangle(cornerRadius: 5)
                                        )
                                        .disabled(record != nil || locked).help(
                                            record == nil
                                                ? "Start the opening phrase at bar \(bar.index+1)"
                                                : "Choose another phrase to change the opening range")
                                    }
                                }
                            }.frame(maxHeight: 120)
                        }.font(.caption)
                    }.padding(16).frame(maxWidth: .infinity).background(
                        Color.white, in: RoundedRectangle(cornerRadius: 15)
                    ).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.line))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if record != nil && isPiano {
                                Picker(
                                    "Workspace",
                                    selection: Binding(
                                        get: { session.shaping },
                                        set: { value in perform { try state.showPhraseShaping(value) } })
                                ) {
                                    Text("Practice").tag(false)
                                    Text("Shape the phrase").tag(true)
                                }.pickerStyle(.segmented).labelsHidden().disabled(
                                    timing.busy || session.takePlayer.busy || audio.isPlaying || audio.isPreparing)
                                if record?.stage == .review && !session.shaping {
                                    Text("Opening Shape the phrase uses support for this return.").font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if session.shaping && isPiano {
                                ShapePhrasePanel(session: session, midi: midi)
                            } else {
                                if let record { sessionPanel(record) } else { setup }
                                if let result = timing.result, session.key == record?.key {
                                    feedback(result, stage: session.stage, saved: timing.saved)
                                } else if let record, record.stage != .review {
                                    if let latest = record.attempts.max(by: { $0.date < $1.date }) {
                                        feedback(latest, stage: nil, saved: true)
                                    }
                                }
                            }
                            if timing.hasUnsavedResult {
                                Text("This completed pass is still here. Save it before continuing.").font(.callout)
                                    .foregroundStyle(Color.clay)
                                Button("Try saving again") { save() }
                                Button("Discard unsaved pass…", role: .destructive) { discard = true }
                            }
                            if let error = error ?? timing.error ?? renderError {
                                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
                            }
                        }.padding(18)
                    }.frame(width: 280, height: scoreViewport + (session.shaping ? 230 : 110)).background(
                        Color.moss.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
                }
            } else {
                ContentUnavailableView(
                    "Choose a piece from your library", systemImage: "books.vertical",
                    description: Text("Your full score will stay here while you practise."))
            }
            DisclosureGroup("Keyboard & timing", isExpanded: $details) {
                VStack(alignment: .leading, spacing: 12) {
                    MIDIConnectionView(midi: midi).disabled(locked)
                    RehearsalCalibrationView(session: session, midi: midi).disabled(
                        audio.isPlaying || audio.isPreparing || session.takePlayer.busy)
                }.padding(.top, 8)
            }.font(.callout)
            Text(
                "Assesses sounding pitches and entrances in 2/4, 3/4 or 4/4. Hands follow the written staves; shared unisons count as one key, and MIDI cannot identify which hand played it. Piano takes preserve key lengths, touch and sustain for listen-back. Shape the phrase offers observations, not grades for expression or physical technique. Repeats follow written order. The full score remains available to read."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .background(
            SpaceTapCapture(enabled: timing.active && timing.conditions.input == .space) { timing.attack(at: $0) }
                .frame(width: 0, height: 0)
        )
        .onAppear {
            session.connect(midi)
            load()
            if !midi.connected { details = true }
        }
        .onChange(of: record?.id) { _, _ in checkSource() }
        .onChange(of: state.rehearsalPieceID) { _, _ in load() }
        .onChange(of: partID) { _, _ in if record == nil { loadPart() } }
        .onChange(of: from) { _, value in
            through = max(value, min(through, min(whole?.part.measures.count ?? value, value + 7)))
        }
        .onReceive(midi.updates) { if state.isPreview || NSApp.isActive { timing.receive($0) } }
        .onChange(of: timing.result?.id) { _, _ in save() }
        .onChange(of: session.exercise) { _, value in if session.stage == .focus { exercise = value } }
        .onChange(of: session.takePlayer.completedID) { _, id in
            if let id { perform { try state.finishPianoTakeListening(id) } }
        }
        .onChange(of: record?.stage) { _, stage in
            if stage == .review { session.shaping = false }
            if stage == .focus {
                focusTempo = max(40, (record?.opening.tempo ?? tempo) - 15)
                exercise = recommendedExercise
                loadJoins()
            }
        }
        .onChange(of: state.editor) { _, _ in checkSource() }
        .onChange(of: state.studies) { _, _ in checkSource() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.stop()
            audio.stop()
        }
        .onDisappear {
            session.stop()
            audio.stop()
        }
        .confirmationDialog("Discard this unsaved pass?", isPresented: $discard) {
            Button("Discard pass", role: .destructive) {
                session.stop()
                timing.discard()
            }
        }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Button("Practice home", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                    .font(.caption).foregroundStyle(Color.moss)
                Text(piece?.title ?? "Practise this piece").font(.system(size: 30, weight: .medium, design: .serif))
                Text("A phrase at a time. Always part of the music.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let piece {
                Button("Open piece", systemImage: "arrow.up.right") { state.openLibraryPiece(piece) }.disabled(locked)
            }
            if record != nil {
                Button("Choose another phrase") {
                    session.stop()
                    timing.discard()
                    session.shaping = false
                    state.rehearsalKey = nil
                    loadPart()
                }.disabled(locked)
            }
        }
    }
    private var journey: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Open", "Focus", "Connect", "Return later"].enumerated()), id: \.offset) { index, label in
                let active = stageIndex == index
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1)).font(.caption.monospaced()).opacity(0.65)
                    Text(label).font(.callout.weight(active ? .semibold : .regular))
                    if index < stageIndex { Image(systemName: "checkmark").font(.caption) }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.vertical, 11).foregroundStyle(active ? Color.moss : Color.secondary)
                    .background(active ? Color.moss.opacity(0.08) : Color.clear)
            }
        }.background(Color.paper, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var stageIndex: Int {
        switch record?.stage {
        case .focus: 1
        case .context: 2
        case .complete, .review: 3
        default: 0
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "Start with a phrase").foregroundStyle(Color.moss)
            Text("Where shall we begin?").font(.system(size: 25, weight: .medium, design: .serif))
            Text(
                "Choose 1–8 bars for an opening pass. Play once at a comfortable pace; we’ll use what happens to choose a smaller focus."
            ).font(.callout).foregroundStyle(.secondary)
            if let whole {
                Picker("Part", selection: $partID) {
                    ForEach(whole.document.parts, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Play", selection: $staff) {
                    if isPiano && whole.part.staves.filter({ !whole.part.tabStaves.contains($0) }).count == 2 {
                        Text("Hands together").tag(0)
                    }
                    ForEach(whole.part.staves.filter { !whole.part.tabStaves.contains($0) }, id: \.self) {
                        Text("Staff \($0)").tag($0)
                    }
                }
                Stepper("From bar \(from)", value: $from, in: 1...max(1, whole.part.measures.count))
                Stepper(
                    "Through bar \(through)", value: $through,
                    in: from...max(from, min(whole.part.measures.count, from + 7)))
            }
            if staff == 0 {
                Text(
                    "Start with a gentle opening pass. Then take either hand with Cadence playing the other, bring them together and return independently."
                ).font(.caption).foregroundStyle(Color.moss)
            }
            Stepper("\(tempo) bpm", value: $tempo, in: 40...160, step: 5).monospacedDigit()
            Button("Begin this phrase", systemImage: "arrow.right") {
                perform {
                    guard let piece, let selected else { return }
                    try state.beginRehearsal(piece, scope: selected, tempo: tempo)
                }
            }.buttonStyle(.cadencePrimary).controlSize(.large)
            Text("Your place is saved. Opening and focused attempts do not establish mastery.").font(.caption)
                .foregroundStyle(.secondary)
        }.disabled(locked)
    }
    @ViewBuilder private func sessionPanel(_ record: PieceRehearsal) -> some View {
        Eyebrow(text: record.stage == .review ? "Independent return" : "Practise this piece").foregroundStyle(
            Color.moss)
        Text(
            record.stage == .focus && record.flow != nil
                ? "Make it flow"
                : record.stage == .focus && record.opening.handStaves != nil
                    ? (exercise.isHand ? "One hand at a time" : "Bring them together") : record.stage.title
        ).font(.system(size: 26, weight: .medium, design: .serif))
        if let intention = record.phraseIntention {
            Label(intention.rawValue, systemImage: "waveform.path").font(.caption).foregroundStyle(Color.moss)
        }
        Text(
            scopeLabel(record.activePlan) + " · "
                + (record.stage == .focus ? "opening \(record.opening.tempo) bpm" : "\(record.activePlan.tempo) bpm")
        ).font(.caption.monospacedDigit()).foregroundStyle(Color.moss)
        if !current {
            Text(
                "This source has changed or needs review. Your old attempts are kept. Open the piece to review it, then choose a new phrase."
            ).font(.callout).foregroundStyle(Color.clay)
        }
        switch record.stage {
        case .opening:
            Text(
                "Play the highlighted phrase once. A count-in gets you started; then the click stops. Keep going through a missed note."
            ).font(.callout)
            Text("We’ll look at pitches and entrances separately, without guessing why something was difficult.").font(
                .caption
            ).foregroundStyle(.secondary)
            playButton("Count in & play", record: record)
            if isPiano {
                Text("This piano pass also saves a take. Open Shape the phrase afterwards to listen back.").font(
                    .caption
                ).foregroundStyle(Color.moss)
            }
        case .focus:
            Button(
                record.flow == nil ? "Make it flow" : "Back to focused exercises",
                systemImage: record.flow == nil ? "waveform.path" : "arrow.left"
            ) {
                perform {
                    if record.flow == nil {
                        try state.enableRehearsalFlow()
                    } else {
                        try state.configureRehearsalFlow(nil)
                    }
                }
            }.disabled(locked || !current)
            if record.flow != nil {
                FlowPassagePicker(record: record, joins: flowJoins, locked: locked || !current, error: $error)
            }
            if record.opening.handStaves == nil && record.flow == nil { Text(focusReason(record)).font(.callout) }
            Picker("Exercise", selection: $exercise) {
                ForEach(availableExercises(record).filter { $0 != .connected || isPiano }, id: \.self) {
                    Text($0 == .notes && record.opening.handStaves != nil ? "Both hands" : $0.rawValue).tag($0)
                }
            }.labelsHidden().disabled(locked)
            if exercise.isHand {
                Toggle(
                    "Cadence plays the other hand",
                    isOn: Binding(
                        get: { record.flow?.partner ?? session.partnerEnabled },
                        set: { enabled in
                            if var flow = record.flow {
                                flow.partner = enabled
                                perform { try state.configureRehearsalFlow(flow) }
                            } else {
                                session.partnerEnabled = enabled
                            }
                        })
                ).disabled(locked)
            }
            if exercise == .rhythm {
                Picker("Use", selection: $input) {
                    ForEach(TimedInput.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(locked)
            }
            Stepper(
                "\(record.flow?.tempo ?? focusTempo) bpm",
                value: Binding(
                    get: { record.flow?.tempo ?? focusTempo },
                    set: { value in
                        if var flow = record.flow {
                            flow.tempo = value
                            perform { try state.configureRehearsalFlow(flow) }
                        } else {
                            focusTempo = value
                        }
                    }), in: 40...max(40, record.opening.tempo), step: 5
            ).monospacedDigit().disabled(locked)
            Picker("Passes", selection: $loopCount) {
                Text("One pass").tag(1)
                Text("Three loops").tag(3)
            }.disabled(locked || exercise == .connected)
            playButton(exercise == .rhythm ? "Count in & tap" : "Count in & play", record: record)
            if exercise.isHand {
                Text(
                    exercise == .rightHand
                        ? "You play the upper staff. Hear the lower part underneath you."
                        : "You play the lower staff. Hear the upper part above you."
                ).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(
                    exercise == .connected
                        ? "Hear the next note inwardly. Aim for a connected line while keeping the written rests."
                        : exercise == .rhythm
                            ? "Tap once for each new entrance; a chord takes one tap. Count through the rests."
                            : (record.flow != nil
                                ? "Keep the music moving through the highlighted passage. A mistake does not stop the timeline."
                                : "Play the written pitches at a slower pace. The click stays with you.")
                ).font(.callout).foregroundStyle(.secondary)
            }
            if record.flow != nil {
                FlowAdviceView(
                    record: record, exercise: exercise, joins: flowJoins, locked: locked || !current, error: $error)
            }
            if record.opening.handStaves != nil {
                handProgress(record)
                if record.focusResults.last?.exercise == exercise && exercise.isHand {
                    Button(
                        exercise == .rightHand ? "Try the left hand" : "Bring both hands together",
                        systemImage: "arrow.right"
                    ) {
                        exercise = exercise == .rightHand ? .leftHand : .notes
                    }.disabled(locked)
                }
                DisclosureGroup("About this focus") {
                    Text(
                        focusReason(record)
                            + " The partner keeps moving through mistakes. Lower the tempo or restart whenever you need."
                    ).font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            }
            if audio.isPlaying || audio.isPreparing {
                Button("Stop listening", systemImage: "stop.fill") { audio.stop() }
            } else {
                HStack {
                    Button("Listen") { listen(loop: false) }
                    Button("Loop & listen") { listen(loop: true) }
                }.disabled(locked || !current)
            }
            if !record.focusResults.isEmpty
                && (record.opening.handStaves == nil || record.focusResults.contains(where: { $0.exercise == .notes }))
            {
                Text(
                    "\(record.focusResults.count) supported \(record.focusResults.count == 1 ? "pass" : "passes") saved"
                ).font(.caption).foregroundStyle(.secondary)
                Button("Back into the phrase", systemImage: "arrow.right") {
                    perform {
                        try state.updateRehearsal(record.key) { try $0.returnToPhrase() }
                        timing.discard()
                    }
                }.disabled(locked || !current)
            }
            Text("Every loop has a fresh count-in and saves separately. You decide when to move on.").font(.caption)
                .foregroundStyle(.secondary)
        case .context:
            Text(
                "Let the focused bars reconnect with the surrounding music. Return to your opening tempo, without the guiding click."
            ).font(.callout)
            playButton("Play the whole phrase", record: record)
            Text("This is still today’s supported session. The independent check comes later.").font(.caption)
                .foregroundStyle(.secondary)
        case .complete:
            Text("You’ve brought the phrase back into the music. Leave a little space before testing it again.").font(
                .callout)
            if record.flow != nil || record.focusResults.contains(where: { $0.flowSource != nil }) {
                Text(
                    isPiano
                        ? "Listen back in Shape the phrase. Did it feel easier and sound more intentional?"
                        : "Did the phrase feel easier and sound more intentional?"
                ).font(.callout)
                Picker(
                    "Your reflection",
                    selection: Binding(
                        get: { record.flowReflection },
                        set: { value in perform { try state.updateRehearsal(record.key) { $0.flowReflection = value } }
                        })
                ) {
                    Text("Choose when ready").tag(Optional<FlowReflection>.none)
                    ForEach(FlowReflection.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().disabled(locked || !current)
                Text("Your reflection is saved separately from timing and review results.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let due = record.nextReview {
                Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.callout)
                    .foregroundStyle(Color.moss)
                Text(
                    "Saved in Practice → Bring it back. Your next return starts without a demonstration or guiding click; the score stays visible."
                ).font(.caption).foregroundStyle(.secondary)
                if due <= Date() {
                    Button("Begin independent return", systemImage: "arrow.uturn.backward") {
                        perform {
                            try state.updateRehearsal(record.key) { try $0.beginReview() }
                            timing.discard()
                        }
                    }.buttonStyle(.cadencePrimary).disabled(locked || !current)
                }
            }
            if let review = record.reviews.last {
                Text(
                    review.independent
                        ? "Last return: independent first pass."
                        : "Last return used support or a restart. Its result is saved separately."
                ).font(.caption).foregroundStyle(Color.moss)
            }
            Button("More supported practice") {
                perform {
                    try state.updateRehearsal(record.key) { try $0.practiseAgain() }
                    timing.discard()
                }
            }.disabled(locked || !current)
        case .review:
            Text(
                "Before listening or warming up this phrase, play it once from the score. Keep going; the first complete attempt is the useful check."
            ).font(.callout)
            if record.reviewStarts > 0 {
                Text("You already started this return. Another start will be recorded as supported practice.").font(
                    .caption
                ).foregroundStyle(Color.clay)
            }
            playButton("Count in & return", record: record)
            Button("I’d like support first") {
                perform {
                    try state.updateRehearsal(record.key) { try $0.practiseAgain() }
                    timing.discard()
                }
            }.disabled(locked || !current)
        }
    }
    @ViewBuilder private func playButton(_ label: String, record: PieceRehearsal) -> some View {
        if timing.busy {
            Button("Stop", systemImage: "stop.fill") { session.stop() }.buttonStyle(.cadencePrimary)
            Text(
                session.loopsRemaining > 0
                    ? "\(session.loopsRemaining) more loops after this pass" : "An unfinished pass stays ungraded."
            ).font(.caption).foregroundStyle(.secondary)
        } else {
            Button(label, systemImage: "play.fill") {
                perform {
                    try state.startRehearsal(
                        exercise: exercise, tempo: focusTempo, input: input,
                        loops: exercise == .connected ? 1 : loopCount, playPartner: session.partnerEnabled)
                }
            }
            .buttonStyle(.cadencePrimary).controlSize(.large).disabled(
                locked || !current
                    || (!(record.stage == .focus && exercise == .rhythm && input == .space) && !midi.connected))
            if !midi.connected && !(record.stage == .focus && exercise == .rhythm && input == .space) {
                Text("Connect your MIDI keyboard to play this pass.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func feedback(_ result: TimedPracticeResult, stage: RehearsalStage?, saved: Bool) -> some View {
        let report = result.report
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Last pass · \(stage?.rawValue ?? "saved practice")").font(.caption).foregroundStyle(.secondary)
            if !result.plan.rhythmOnly {
                Text("\(report.matchedPitch) / \(report.notes.count) pitches").font(
                    .system(size: 22, weight: .medium, design: .serif))
            }
            Text("\(report.timedEntrances(tolerance:result.plan.tolerance)) / \(report.notes.count) entrances on time")
                .font(.callout)
            Text(
                "\(report.extras.count) extra presses · \(result.plan.tempo) bpm\n\(saved ? "Saved" : "Awaiting save") · ±\(Int((result.plan.tolerance*1000).rounded())) ms"
            ).font(.caption).foregroundStyle(.secondary)
            if let pulse = result.conditions.flowPulse {
                Text("Click · \(pulse.rawValue)").font(.caption).foregroundStyle(Color.moss)
            }
            DisclosureGroup("Every entrance") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                        Text(entranceLabel(note, result: result)).font(.caption).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    if !report.extras.isEmpty {
                        Text(
                            "Extra presses: "
                                + report.extras.map {
                                    Pitch.chromatic($0.pitch) + String($0.pitch / 12 - 1) + " at "
                                        + String(format: "%.2fs", $0.seconds)
                                }.joined(separator: ", ")
                        ).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 6)
            }.font(.caption)
            if result.attacks.contains(where: \.arrivalTimestamp) {
                Text("MIDI timestamps were unavailable; timing uses arrival time and counts as supported evidence.")
                    .font(.caption).foregroundStyle(Color.clay)
            }
        }
    }
    private func entranceLabel(_ note: TimedAssessment, result: TimedPracticeResult) -> String {
        let bar =
            note.target.bar
            + (result.plan.rhythmOnly
                ? session.sourcePlan?.source?.scope.from ?? record?.focus?.source?.scope.from ?? 0 : 0)
        let target =
            result.plan.rhythmOnly ? "tap" : Pitch.chromatic(note.target.pitch) + String(note.target.pitch / 12 - 1)
        let verdict: String
        switch note.verdict {
        case .onTime: verdict = "on time"
        case .early, .late: verdict = "\(Int(abs(note.delta ?? 0)*1000)) ms \(note.verdict.rawValue)"
        case .wrongPitch:
            verdict =
                "played "
                + (note.attack.map { Pitch.chromatic($0.pitch) + String($0.pitch / 12 - 1) } ?? "another pitch")
        case .missed: verdict = "missed"
        }
        let staff = note.target.staves.map { " · staff " + $0.map(String.init).joined(separator: " & ") } ?? ""
        return "Bar \(bar+1) · \(target)\(staff) · \(verdict)"
    }
    private var recommendedExercise: RehearsalExercise {
        if record?.opening.handStaves != nil { return .rightHand }
        guard let pass = record?.openingResult else { return .notes }
        return pass.report.matchedPitch == pass.report.notes.count && !pass.report.clean ? .rhythm : .notes
    }
    private func focusReason(_ record: PieceRehearsal) -> String {
        guard let pass = record.openingResult else { return "Explore the highlighted bars." }
        if pass.report.clean {
            return "The opening was steady. Explore these bars more closely, then bring the phrase back."
        }
        if pass.report.matchedPitch < pass.report.notes.count {
            return
                "Some written pitches were missed or different. Start with the highlighted bars, and give their rhythm its own turn too."
        }
        if !pass.report.extras.isEmpty {
            return
                "The written pitches were there, with some extra presses. Explore the highlighted bars and leave space for the rests."
        }
        return "The written pitches were there. Give the entrances and the spaces between them some attention."
    }
    private func scopeLabel(_ plan: TimedPracticePlan) -> String {
        plan.source.map {
            ($0.scope.from == $0.scope.through
                ? "Bar \($0.scope.from+1)" : "Bars \($0.scope.from+1)–\($0.scope.through+1)")
                + ($0.scope.staff.map { " · staff \($0)" } ?? " · both hands")
        } ?? "Phrase"
    }
    private func availableExercises(_ record: PieceRehearsal) -> [RehearsalExercise] {
        record.opening.handStaves == nil ? [.notes, .rhythm, .connected] : [.rightHand, .leftHand, .notes, .rhythm]
    }
    private func handPassLabel(_ plan: TimedPracticePlan, conditions: TimedConditions) -> String {
        let hands = record?.opening.handStaves ?? []
        let you =
            plan.rhythmOnly
            ? "Tap the rhythm"
            : plan.handStaves != nil
                ? "You · both hands" : plan.source?.scope.staff == hands.first ? "You · right hand" : "You · left hand"
        return you
            + (conditions.partnerStaff.map { "   Cadence · " + ($0 == hands.first ? "right hand" : "left hand") }
                ?? "   Partner off")
    }
    private func handProgress(_ record: PieceRehearsal) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach([RehearsalExercise.rightHand, .leftHand, .notes], id: \.self) { item in
                let done = record.focusResults.contains { $0.exercise == item }
                Label(
                    item == .notes ? "Bring both hands together" : item.rawValue,
                    systemImage: done ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption).foregroundStyle(done ? Color.moss : Color.secondary)
            }
            Text("Recent passes · take either hand as often as useful, then try both.").font(.caption).foregroundStyle(
                .secondary)
        }
    }
    private func perform(_ action: () throws -> Void) {
        do {
            error = nil
            try action()
        } catch { self.error = error.localizedDescription }
    }
    private func listen(loop: Bool) {
        perform { try state.listenToRehearsal(loop: loop, tempo: record?.flow?.tempo ?? focusTempo) }
    }
    private func save() {
        guard timing.result != nil, !timing.saved else { return }
        state.saveRehearsalPass()
        guard timing.saved, session.loopsRemaining > 0, session.stage == .focus, current else { return }
        let remaining = session.loopsRemaining
        perform {
            try state.startRehearsal(
                exercise: exercise, tempo: focusTempo, input: input, loops: remaining,
                playPartner: session.partnerEnabled)
        }
    }
    private func load() {
        guard let piece else {
            whole = nil
            return
        }
        perform {
            let saved = record?.opening.source
            whole = try RehearsalSource.whole(piece, partID: saved?.scope.partID)
            partID = whole?.partID ?? ""
            staff =
                saved.map { $0.scope.staff ?? 0 }
                ?? ((isPiano && whole?.part.staves.count == 2) ? 0 : whole?.part.staves.first ?? 1)
            from = saved.map { $0.scope.from + 1 } ?? 1
            through = saved.map { $0.scope.through + 1 } ?? min(4, whole?.part.measures.count ?? 1)
            checkSource()
            loadJoins()
            tempo = record?.opening.tempo ?? min(160, max(40, Int(whole?.document.tempo ?? 80)))
            focusTempo = max(40, tempo - 15)
            exercise = session.stage == .focus && session.key == record?.key ? session.exercise : recommendedExercise
        }
    }
    private func loadJoins() {
        if let piece, let record {
            flowJoins = (try? FlowPractice.joins(piece: piece, record: record)) ?? []
        } else {
            flowJoins = []
        }
    }
    private func loadPart() {
        guard let piece, !partID.isEmpty else { return }
        perform {
            whole = try RehearsalSource.whole(piece, partID: partID)
            staff =
                isPiano && whole?.part.staves.count == 2
                ? 0 : whole?.part.staves.first(where: { !(whole?.part.tabStaves.contains($0) ?? true) }) ?? 1
            from = 1
            through = min(4, whole?.part.measures.count ?? 1)
        }
    }
    private func checkSource() {
        current = record.map { state.rehearsalCurrent($0) } ?? true
        if !current {
            session.stop()
            audio.stop()
        }
    }
}

private struct RehearsalCalibrationView: View {
    @ObservedObject var session: CalibratedPracticeSession
    @ObservedObject var midi: MIDIKeyboard
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Optional timing check: follow four count-in clicks, then press and release one piano key on each of the next eight clicks."
            ).font(.callout)
            HStack {
                if session.timing.busy { Button("Stop check") { session.timing.cancel() } }
                Button("Check eight taps") { session.calibrate(held: midi.keyboard.downNotes) }.disabled(
                    session.timing.busy || session.timing.hasUnsavedResult || !midi.connected)
                Button("Reset") { session.invalidateTiming() }.disabled(
                    session.timing.busy || session.timing.hasUnsavedResult)
                Text(session.calibrated ? "Checked · \(session.offsetMS) ms" : "No timing offset applied").font(
                    .caption)
                if session.timing.calibrationReport != nil {
                    Button("Use this timing") { session.applyCalibration() }.disabled(
                        session.timing.calibrationReport?.calibrationOffsetMS == nil
                            || session.timing.attacks.contains(where: \.arrivalTimestamp))
                }
            }
            Text(
                "Includes your tapping tendency and device delay. This check lasts for this app session and resets after a keyboard or audio change. Spacebar tapping uses no MIDI offset."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RehearsalResumeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: PieceRehearsalSession
    var body: some View {
        let active = state.rehearsals.records.values.filter { $0.stage != .complete && state.rehearsalCurrent($0) }
            .sorted { $0.lastExposure > $1.lastExposure }
        if session.timing.hasUnsavedResult || !active.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LearningSectionHeading(title: "Your music, in progress", detail: "Practise this piece")
                if session.timing.hasUnsavedResult {
                    HStack {
                        Text("A completed pass is waiting to be saved.")
                        Spacer()
                        Button("Return to pass") {
                            state.rehearsalKey = session.key
                            state.rehearsalPieceID = session.sourcePlan?.source?.pieceID
                            state.practicePage = .rehearsal
                        }
                    }.font(.callout)
                }
                ForEach(Array(active.prefix(3))) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).fontWeight(.medium)
                            Text(record.stage.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Continue", systemImage: "arrow.right") {
                            if let piece = state.libraryPieces.first(where: { $0.id == record.pieceID }) {
                                state.openPieceRehearsal(piece, key: record.key)
                            }
                        }
                    }.font(.callout)
                }
            }.padding(20).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
