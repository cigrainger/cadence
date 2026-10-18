// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct MicrophonePhraseHomeCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: MicrophonePhraseSession
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "waveform").font(.system(size: 27)).foregroundStyle(Color.moss)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.hasUnsavedTake ? "Your guitar take is waiting" : "Let the phrase speak").font(
                    .system(size: 23, weight: .medium, design: .serif))
                Text(
                    session.hasUnsavedTake
                        ? "Review the matches, then keep or discard your take."
                        : "Play a single-note phrase. Choose one change. Try it again."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(session.hasUnsavedTake ? "Review take" : "Microphone coaching", systemImage: "arrow.right") {
                state.showMicrophonePhrases()
            }.buttonStyle(.cadencePrimary)
        }.padding(22).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MicrophonePhraseView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: MicrophonePhraseSession
    @ObservedObject var microphone: Microphone
    @State private var choosing = false
    @State private var focusOnMusic = CommandLine.arguments.contains("--microphone-score-focus")
    @State private var pitchOnly = false
    @State private var study: MusicStudy?
    @State private var scoreHeight: CGFloat = 260
    @State private var scoreError: String?
    @State private var error: String?
    @State private var current = false
    @State private var report: MicrophonePhraseReport?
    @State private var marks: [LiveTimedNote] = []
    @State private var discarding = false
    private var plan: MicrophonePhrasePlan? { session.plan }
    private var progress: MicrophonePhraseProgress? {
        state.microphonePhrases.sessions.first { $0.id == plan?.key }
    }
    private var locked: Bool { session.busy || session.hasUnsavedTake }
    private var playhead: StudyPlayhead? {
        guard let plan, session.phase == .playing || session.phase == .countIn else { return nil }
        return .init(
            sourceBeat: (plan.timed.source?.startBeat ?? plan.sourceStart)
                + max(0, min(plan.timed.length - 0.00001, session.elapsed / plan.timed.secondsPerBeat)),
            isCountIn: session.elapsed < 0,
            countInRemaining: max(0, ceil(-session.elapsed / plan.timed.secondsPerBeat)), cycle: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Back to Learn", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                Spacer()
                if plan != nil, !choosing {
                    Button(
                        focusOnMusic ? "Show setup" : "Focus on the score",
                        systemImage: focusOnMusic ? "slider.horizontal.3" : "viewfinder"
                    ) {
                        focusOnMusic.toggle()
                    }.disabled(session.busy).accessibilityIdentifier("microphone.score-focus")
                }
                Button(choosing ? "Back to phrase" : "Choose a phrase", systemImage: "music.note.list") {
                    state.stopAllPlayback()
                    choosing.toggle()
                }.disabled(plan == nil || locked)
            }
            if !focusOnMusic && !session.busy {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: "Guitar · listen, play, reshape").foregroundStyle(Color.clay)
                    Text("Let the phrase speak.").font(.system(size: 34, weight: .medium, design: .serif))
                    Text("A short phrase. One useful change. Another chance to hear it.").foregroundStyle(.secondary)
                }
            }
            if choosing || plan == nil {
                MicrophonePhraseChooser {
                    choosing = false
                    refresh()
                }
            } else if let plan {
                if !focusOnMusic && !session.busy {
                    phraseHeader(plan)
                } else {
                    HStack {
                        Text(plan.material.title).font(.title3.weight(.semibold))
                        Spacer()
                        Text("Bars \(plan.fromBar)–\(plan.throughBar) · \(plan.mode.rawValue)").font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !current {
                    ContentUnavailableView(
                        "Revisit the source", systemImage: "book.closed",
                        description: Text(
                            "Your takes are kept. This music changed or needs review; choose its current phrase before recording."
                        ))
                }
                if !focusOnMusic && !session.busy { timingSetup }
                score(plan)
                if let take = session.displayedTake, let report { feedback(take, report) }
                savedTakes
            }
            if let error = error ?? session.error ?? microphone.error ?? scoreError {
                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            Text(
                "Clean single-note phrases, 1–4 complete bars. Chords, distortion, note lengths, bends, dynamics and picking-hand mechanics are outside this check. Timing estimates include detector and calibration uncertainty."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if plan == nil, let active = state.microphonePhrases.active {
                tryAction { try session.select(active.sourcePlan) }
            }
            refresh()
            refreshFeedback()
        }
        .onChange(of: session.busy) { _, active in if active { focusOnMusic = true } }
        .onChange(of: session.plan) { _, _ in refresh() }
        .onChange(of: session.displayedTake) { _, _ in refreshFeedback() }
        .onChange(of: state.editor) { _, _ in checkSource() }
        .onChange(of: state.studies) { _, _ in checkSource() }
        .onChange(of: scenePhase) { _, value in if value != .active { session.cancel() } }
        .onDisappear { session.cancel() }
        .confirmationDialog("Discard this unsaved take?", isPresented: $discarding) {
            Button("Discard take", role: .destructive) { tryAction { try state.discardMicrophoneTake() } }
        }
    }

    private func phraseHeader(_ plan: MicrophonePhrasePlan) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.material.title).font(.title3.weight(.semibold))
                Text("\(plan.material.label) · \(plan.material.melody.count) written attacks").font(.caption)
                    .foregroundStyle(.secondary)
                Text(invitation(plan)).font(.callout).foregroundStyle(Color.moss)
            }
            Spacer()
            if let piece = state.libraryPieces.first(where: { $0.id == plan.material.pieceID }) {
                Button("Open full piece", systemImage: "arrow.up.right") { state.openLibraryPiece(piece) }
            }
        }
    }

    private var timingSetup: some View {
        Card(title: "Your input & timing", padding: 16, spacing: 10) {
            HStack(spacing: 16) {
                Stepper("Input channel \(session.inputChannel + 1)", value: $session.inputChannel, in: 0...63)
                    .frame(width: 165).disabled(locked)
                Button(session.phase == .calibrating ? "Measuring…" : "Measure delay", systemImage: "waveform.path") {
                    state.stopAllPlayback()
                    session.calibrate(microphone: microphone)
                }.disabled(locked)
                if let calibration = session.calibration {
                    Label(
                        "About \(Int((calibration.offsetMS / 10).rounded()) * 10) ms · \(calibration.matchedPulses) tones",
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption).foregroundStyle(Color.moss)
                } else {
                    Text("Timing uncalibrated").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Toggle("Pitch only · leave timing unassessed", isOn: $pitchOnly).toggleStyle(.checkbox).font(.callout)
                    .disabled(locked || plan?.mode == .independent)
                Spacer()
                DisclosureGroup("Setup help") {
                    Text(
                        "Choose your Mac microphone or USB interface in System Settings → Sound, then select the input channel carrying your guitar. For the Mac mic, let it hear eight quiet tones from the speakers while you stay silent. An interface needs an internal or physical loopback on this same channel for timing calibration; without it, choose pitch only. Keep input, output, channel and routing unchanged afterwards. Changing them requires a new check. This is separate from MIDI calibration."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: 430, alignment: .trailing)
            }
            if session.needsExposureSave {
                Button("Retry saving interrupted practice") { session.retryExposureSave() }
            }
        }
    }

    private func score(_ plan: MicrophonePhrasePlan) -> some View {
        Card(title: "Keep the music in view", padding: 18, spacing: 14) {
            HStack {
                Stepper(
                    "\(plan.tempo) bpm",
                    value: Binding(
                        get: { plan.tempo },
                        set: { tempo in
                            tryAction {
                                try session.select(
                                    plan.configured(tempo: tempo, mode: plan.mode == .independent ? .context : nil))
                            }
                        }), in: 50...140, step: 5
                ).frame(width: 150).disabled(locked || !current)
                Spacer()
                Text(status).font(.callout.monospacedDigit()).foregroundStyle(Color.moss)
            }
            if session.busy {
                HStack {
                    ProgressView(value: min(1, max(0, microphone.acousticLevel * 6))).frame(width: 120)
                    Text("Input level").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel pass", systemImage: "stop.fill") { session.cancel() }
                }
            } else {
                HStack(spacing: 12) {
                    Button("Count in & listen", systemImage: "mic.fill") {
                        tryAction { try state.startMicrophoneTake(plan, pitchOnly: pitchOnly) }
                    }.buttonStyle(.cadencePrimary)
                        .disabled(!current || session.hasUnsavedTake || (!pitchOnly && session.calibration == nil))
                    Button("Hear the phrase", systemImage: "play.fill") {
                        tryAction { try state.hearMicrophonePhrase(plan) }
                    }.disabled(!current || session.hasUnsavedTake)
                    if plan.mode == .focused || !plan.isFullPhrase {
                        Button("Reconnect the phrase", systemImage: "arrow.up.left.and.arrow.down.right") {
                            tryAction { try session.select(plan.surrounding()) }
                        }.disabled(session.hasUnsavedTake)
                    }
                    if !plan.isFullPhrase {
                        Button("Whole phrase") { tryAction { try session.select(plan.whole(mode: .context)) } }
                            .disabled(session.hasUnsavedTake)
                    }
                }
            }
            if let study, current {
                ScoreRenderer(
                    study: study, playhead: playhead, feedback: marks,
                    feedbackStart: session.displayedTake?.plan.timed.source?.startBeat,
                    focus: .init(
                        partID: plan.material.scope.partID, staff: plan.material.staff,
                        from: plan.fromBar - 1, through: plan.throughBar - 1),
                    feedbackRoom: true, height: $scoreHeight, error: $scoreError
                )
                .frame(height: min(420, max(220, scoreHeight)))
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(
                "The last count-in beat is silent so the microphone can settle. Then play through the phrase. Follow the moving score cursor; feedback appears after the complete pass."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func feedback(_ take: MicrophonePhraseTake, _ report: MicrophonePhraseReport) -> some View {
        Card(title: "What came through", padding: 18, spacing: 14) {
            feedbackSummary(take, report)
            Text(report.suggestion).font(.headline).foregroundStyle(Color.moss)
            ForEach(report.notes, id: \.index) { note in
                noteFeedback(take, note)
            }
            if take.calibration == nil {
                Text("Heard pitches: " + heardPitches(take))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !report.extras.isEmpty {
                Text(
                    "\(report.extras.count) additional attacks were heard. They are kept separately rather than moving the written notes."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = take.signalIssue { Text(issue).foregroundStyle(Color.clay).font(.callout) }
            feedbackActions(take, report)
            DisclosureGroup("Inspect the evidence and its limits") {
                Text(take.evidence).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            }
        }
    }

    private func heardPitches(_ take: MicrophonePhraseTake) -> String {
        let notes: [Int] = Array(take.attacks.compactMap(\.midi).prefix(24))
        return notes.map { Pitch.chromatic($0) + String($0 / 12 - 1) }.joined(separator: " · ")
    }

    private func feedbackSummary(_ take: MicrophonePhraseTake, _ report: MicrophonePhraseReport) -> some View {
        HStack(spacing: 22) {
            Label("\(report.matchedPitch)/\(report.notes.count) pitches matched", systemImage: "music.note")
            Text(
                take.calibration == nil
                    ? "Timing unassessed" : "\(report.onTime)/\(report.notes.count) entrances in the window")
            Spacer()
            Text(
                session.hasUnsavedTake
                    ? "Review before keeping" : (current ? "Saved on this Mac" : "Saved · earlier source version")
            ).foregroundStyle(.secondary)
        }.font(.callout)
    }

    private func noteFeedback(_ take: MicrophonePhraseTake, _ note: MicrophonePhraseNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(
                "Bar \(note.target.bar + 1) · \(Pitch.chromatic(note.target.pitch))\(note.target.pitch / 12 - 1)"
            )
            .font(.callout.weight(.medium)).frame(width: 135, alignment: .leading)
            Text(note.pitch.label).frame(width: 105, alignment: .leading)
            Text(timingText(note)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Toggle(
                "Uncertain match",
                isOn: Binding(
                    get: { take.disputedTargets.contains(note.index) },
                    set: {
                        session.dispute(note.index, uncertain: $0)
                    })
            ).toggleStyle(.checkbox).disabled(!session.hasUnsavedTake).font(.caption)
        }.font(.callout)
    }

    @ViewBuilder private func feedbackActions(_ take: MicrophonePhraseTake, _ report: MicrophonePhraseReport)
        -> some View
    {
        if session.hasUnsavedTake {
            HStack {
                Button(current ? "Keep take" : "Keep earlier-version evidence", systemImage: "checkmark") {
                    session.save(using: state.saveMicrophoneTake)
                }
                .buttonStyle(.cadencePrimary)
                Button("Retry without keeping") {
                    let retry = try? take.plan.focused(around: report.focusBar ?? take.plan.fromBar)
                    tryAction {
                        try state.discardMicrophoneTake()
                        if let retry { try session.select(retry) }
                    }
                }
                Button("Discard take…", role: .destructive) { discarding = true }
            }
        } else {
            HStack {
                if let bar = report.focusBar {
                    Button("Slow retry · bar \(bar)", systemImage: "scope") {
                        tryAction {
                            try session.select(
                                take.plan.focused(around: bar).configured(
                                    tempo: max(50, Int(Double(take.plan.tempo) * 0.8))))
                        }
                    }.buttonStyle(.cadencePrimary).disabled(!current)
                }
                Button("Return to the whole phrase") {
                    tryAction { try session.select(take.plan.whole(mode: .context)) }
                }.disabled(!current)
                Button("Discuss this take with coach", systemImage: "sparkles") { state.openContextCoach() }
            }
        }
    }

    @ViewBuilder private var savedTakes: some View {
        if let progress {
            Card(title: "Your takes & the next return", padding: 18, spacing: 12) {
                ForEach(progress.takes.reversed()) { take in
                    Button {
                        session.inspect(take)
                    } label: {
                        HStack {
                            Text(
                                "\(take.plan.mode.rawValue.capitalized) · \(take.plan.tempo) bpm · bars \(take.plan.fromBar)–\(take.plan.throughBar)"
                            )
                            Spacer()
                            Text(take.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).font(.callout).disabled(locked)
                }
                Text(
                    "\(progress.takes.count)/16 takes kept for this phrase. Compare a saved take above, or retry without keeping every pass."
                )
                .font(.caption).foregroundStyle(.secondary)
                if progress.baseline != nil, let available = state.microphonePhrases.returnDate(progress.id) {
                    HStack {
                        Text(
                            Date() >= available
                                ? "Ready for an independent return."
                                : "Independent return after \(available.formatted(date: .abbreviated, time: .shortened))."
                        )
                        .font(.callout).foregroundStyle(Color.moss)
                        Spacer()
                        Button("Independent return", systemImage: "arrow.uturn.backward") {
                            pitchOnly = false
                            tryAction { try state.resumeMicrophonePhrase(progress.id, independent: true) }
                        }.disabled(locked || !current || Date() < available)
                    }
                    Text(
                        "First try the whole phrase without hearing the guide or using the coach. Guided retries stay separate from independent recall."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var status: String {
        switch session.phase {
        case .idle: return session.hasUnsavedTake ? "Take ready to review" : "Ready when you are"
        case .preparing: return "Preparing the microphone…"
        case .calibrating: return "Listen for the eight tones"
        case .countIn: return "Count in · \(Int(ceil(-session.elapsed / (plan?.timed.secondsPerBeat ?? 1))))"
        case .playing: return "Play · \(max(0, session.elapsed).formatted(.number.precision(.fractionLength(1)))) s"
        case .finishing: return "Checking the phrase…"
        }
    }
    private func invitation(_ plan: MicrophonePhrasePlan) -> String {
        switch plan.mode {
        case .opening: "Opening pass · keep going through the whole phrase."
        case .focused: "Focused retry · bars \(plan.fromBar)–\(plan.throughBar). Then reconnect it to the phrase."
        case .context: "Surrounding phrase · let the small change carry into the music."
        case .independent: "Independent return · play before revealing the guide."
        }
    }
    private func timingText(_ note: MicrophonePhraseNote) -> String {
        guard let delta = note.deltaMS, let uncertainty = note.uncertaintyMS else { return note.timing.label }
        return
            "\(note.timing.label) · about \(Int((delta / 10).rounded()) * 10) ms (±\(Int(ceil(uncertainty / 10)) * 10) ms)"
    }
    private func refreshFeedback() {
        report = session.displayedTake?.report
        marks = current ? session.displayedTake?.scoreFeedback ?? [] : []
    }
    private func refresh() {
        checkSource()
        guard current, let plan, let piece = state.libraryPieces.first(where: { $0.id == plan.material.pieceID }) else {
            study = nil
            return
        }
        do {
            study = try ScoreEarMaterial.study(piece: piece, scope: plan.material.scope)
            study?.staff = plan.material.staff
            scoreError = nil
        } catch { scoreError = error.localizedDescription }
        if plan.mode == .independent { pitchOnly = false }
    }
    private func checkSource() {
        current = plan.map { (try? state.validateMicrophonePhrase($0)) != nil } ?? false
        if !current {
            study = nil
            marks = []
        }
        if !current && session.busy { session.cancel("The score changed. Choose its reviewed current phrase.") }
    }
    private func tryAction(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct MicrophonePhraseChooser: View {
    @EnvironmentObject private var state: AppState
    var opened: () -> Void
    @State private var pieceID = ""
    @State private var partID = "P1"
    @State private var from = 1
    @State private var through = 4
    @State private var voiceID = ""
    @State private var reviewed = false
    @State private var error: String?
    private var piece: LibraryPiece? { state.libraryPieces.first { $0.id == pieceID } }
    private var parts: [(String, String)] {
        if case .study(let study) = piece?.source { return study.document.parts.map { ($0.id, $0.name) } }
        return [("P1", "Score")]
    }
    private var bars: Int {
        if case .study(let study) = piece?.source {
            return study.document.parts.first { $0.id == partID }?.measures.count ?? 1
        }
        return piece?.bars ?? 1
    }
    private var scope: PieceScope {
        .init(
            fromBar: from, throughBar: through, partID: partID, partName: parts.first { $0.0 == partID }?.1 ?? "Score")
    }
    private var study: MusicStudy? { piece.flatMap { try? ScoreEarMaterial.study(piece: $0, scope: scope) } }
    private var voices: [SingingVoice] {
        guard let study else { return [] }
        return SingingVoice.choices(study).filter { !study.part.tabStaves.contains($0.staff) }
    }
    private var voice: SingingVoice? { voices.first { $0.id == voiceID } ?? voices.first }
    var body: some View {
        Card(title: "Choose a little music to work with", padding: 20, spacing: 15) {
            Text(
                "Pick a reviewed, single-note voice from your library: 1–4 complete bars and up to 12 attacks, including rests and complete ties. Piano melodies can be practised on guitar too."
            )
            .font(.callout).foregroundStyle(.secondary)
            if !state.libraryPieces.isEmpty {
                Picker("Piece", selection: $pieceID) {
                    ForEach(state.libraryPieces) { Text($0.title).tag($0.id) }
                }
                HStack {
                    Picker("Part", selection: $partID) { ForEach(parts, id: \.0) { Text($0.1).tag($0.0) } }
                    Stepper("From \(from)", value: $from, in: 1...max(1, bars))
                    Stepper("Through \(through)", value: $through, in: from...max(from, min(bars, from + 3)))
                    Picker("Voice", selection: Binding(get: { voice?.id ?? "" }, set: { voiceID = $0 })) {
                        ForEach(voices) { Text($0.label).tag($0.id) }
                    }
                }
                Toggle("I’ve checked the notes, rhythm and sounding register against the source", isOn: $reviewed)
                    .toggleStyle(.checkbox).font(.callout)
                Button("Work with this phrase", systemImage: "mic") {
                    do {
                        guard let piece, let voice else {
                            throw MusicError.invalid("Choose a single melodic voice first.")
                        }
                        let material = try ScoreEarMaterial(
                            piece: piece, scope: scope, staff: voice.staff, voice: voice.voice)
                        try state.openMicrophonePhrase(material)
                        opened()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.cadencePrimary).disabled(!reviewed || voice == nil)
            }
            Button("Try an original guitar phrase", systemImage: "guitars") {
                do {
                    try state.addMicrophoneExample()
                    opened()
                } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).font(.callout).foregroundStyle(Color.clay) }
        }
        .onAppear { pieceID = state.librarySelection ?? state.libraryPieces.first?.id ?? "" }
        .onChange(of: pieceID) { _, _ in
            partID = parts.first?.0 ?? "P1"
            from = 1
            through = min(4, bars)
            reviewed = false
        }
        .onChange(of: partID) { _, _ in
            from = 1
            through = min(4, bars)
            voiceID = ""
            reviewed = false
        }
        .onChange(of: from) { _, _ in
            through = min(bars, max(from, min(through, from + 3)))
            reviewed = false
        }
        .onChange(of: through) { _, _ in reviewed = false }
        .onChange(of: voiceID) { _, _ in reviewed = false }
    }
}
