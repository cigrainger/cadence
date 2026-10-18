// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct EarDailySessionCard: View {
    @EnvironmentObject private var state: AppState
    let journey: SongJourney
    @State private var error: String?
    @State private var archiving = false
    private var active: EarDailySession? {
        state.earDailySession.flatMap { $0.journeyID == journey.id && $0.stage != .complete ? $0 : nil }
    }
    var body: some View {
        let recommendation = state.earDailyRecommendation(journey)
        HStack(alignment: .center, spacing: 22) {
            Image(systemName: "ear.badge.waveform").font(.system(size: 30)).foregroundStyle(Color.moss)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow(text: "Today’s connected session").foregroundStyle(Color.moss)
                Text("Play it by ear.").font(.system(size: 26, weight: .medium, design: .serif))
                Text(
                    active == nil
                        ? recommendation.reason
                        : "Your place is saved · " + active!.stage.rawValue.capitalized
                )
                .font(.callout).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
                if state.earDailyPractice.sessions.contains(where: {
                    $0.stage == .complete && $0.id != state.earDailyPractice.selectedID
                }) {
                    Button("Archive completed sessions") { archiving = true }.font(.caption).buttonStyle(.plain)
                        .foregroundStyle(Color.moss)
                }
            }
            Spacer(minLength: 0)
            Button(
                active == nil
                    ? (recommendation.mode == .recall
                        ? "Bring the phrase back"
                        : recommendation.mode == .transfer ? "Try another piece" : "Begin today’s session")
                    : "Continue my session", systemImage: "arrow.right"
            ) {
                do {
                    if let active {
                        try state.resumeEarDaily(active.id)
                    } else {
                        try state.openEarDaily(journey, mode: recommendation.mode)
                    }
                    error = nil
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.cadencePrimary).accessibilityIdentifier("daily-ear.begin")
        }.padding(22).background(Color.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            .confirmationDialog("Archive completed daily sessions?", isPresented: $archiving) {
                Button("Archive completed sessions") {
                    do {
                        try state.archiveEarDailyCompleted()
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text(
                    "Your selected session, unfinished work, journal results, compositions and review dates stay. Older completed session coordinators leave the active list."
                )
            }
    }
}

struct EarDailyView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var input: EarDailyInput
    @ObservedObject var acoustic: MicrophonePhraseSession
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @State private var study: MusicStudy?
    @State private var height: CGFloat = 260
    @State private var scoreError: String?
    @State private var error: String?
    @State private var clearingDetails = false
    private var locked: Bool { input.pending != nil || acoustic.hasUnsavedTake || input.listening || acoustic.busy }
    var body: some View {
        if let session = state.earDailySession {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(
                            text: session.mode == .transfer
                                ? "Another piece · independent transfer"
                                : session.mode == .recall
                                    ? "After time away · independent recall" : "Make a song your own · today’s session"
                        )
                        .foregroundStyle(Color.moss)
                        Text("Play it by ear.").font(.system(size: 36, weight: .medium, design: .serif))
                        Text(
                            session.material.title + " · " + session.material.label + " · "
                                + session.instrument.rawValue
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        session.assisted ? "With support" : "Before hints",
                        systemImage: session.assisted ? "leaf" : "ear"
                    )
                    .font(.callout).foregroundStyle(Color.moss)
                }
                trail(session)
                if (try? state.validateEarDaily(session)) == nil {
                    ContentUnavailableView(
                        "Review the source again", systemImage: "doc.badge.ellipsis",
                        description: Text(
                            "The piece changed or is no longer reviewed. Your saved takes and answer are kept; begin a fresh pathway from the reviewed music."
                        ))
                } else {
                    Card(title: invitation(session), padding: 24, spacing: 18) {
                        if session.revealed, let study {
                            Text(
                                "Movable Do · " + EarPhrase(material: session.material).solfege.joined(separator: "  ")
                            )
                            .font(.callout).foregroundStyle(Color.moss)
                            ScoreRenderer(
                                study: study,
                                focus: .init(
                                    partID: session.material.scope.partID, staff: session.material.staff,
                                    from: (session.focusBar ?? session.material.scope.fromBar) - 1,
                                    through: (session.focusBar ?? session.material.scope.throughBar) - 1),
                                height: $height, error: $scoreError
                            )
                            .frame(height: min(360, max(220, height)))
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        }
                        activity(session)
                        if [.imagine, .play, .review].contains(session.stage) {
                            HStack(spacing: 14) {
                                Button("Hear it again", systemImage: "speaker.wave.2") {
                                    perform { try state.hearEarDaily(session.id) }
                                }
                                if !session.revealed {
                                    Button("Reveal notation & solfège", systemImage: "music.note") {
                                        perform { try state.updateEarDaily(session.id) { try $0.reveal(now: Date()) } }
                                    }.accessibilityIdentifier("daily-ear.reveal")
                                }
                                Button("Ask my coach", systemImage: "sparkles") { state.openContextCoach() }
                            }.font(.callout).disabled(locked || audio.isPlaying || audio.isPreparing)
                            Text("Replays, notation, solfège and coaching count as support. They are always available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = error ?? input.error ?? acoustic.error ?? scoreError ?? audio.error {
                    Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
                }
                if input.pending != nil {
                    HStack {
                        Button("Retry saving answer") { input.save(state: state) }.buttonStyle(.cadencePrimary)
                        Button("Discard unsaved answer", role: .destructive) { input.discard() }
                    }
                }
                if acoustic.hasUnsavedTake, (try? state.validateEarDaily(session)) == nil {
                    HStack {
                        Button("Keep earlier-version evidence") { acoustic.save(using: state.saveMicrophoneTake) }
                        Button("Discard unsaved take", role: .destructive) {
                            perform { try state.discardEarDailyMicrophone() }
                        }
                    }
                    Text("This take cannot receive current-source practice credit.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if session.instrument == .guitar, !locked, state.earDailyDetailCleanupCount(session) > 0 {
                    Button("Clear older detector details…") { clearingDetails = true }.font(.caption)
                }
                Text(
                    "This session checks pitch and note order. It does not assess rhythm, imagination, expression, fingering or artistic quality. Guitar observations remain provisional until tested on real inputs; uncertain or disputed captures receive no grade."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { refresh(session) }
            .onChange(of: state.earDailySession) { _, value in if let value { refresh(value) } }
            .onChange(of: state.editor) { _, _ in refresh(session) }
            .onChange(of: state.studies) { _, _ in refresh(session) }
            .onChange(of: midi.connectionRevision) { _, _ in input.pause() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { state.stopAllPlayback() } }
            .onDisappear {
                input.pause()
                acoustic.cancel()
            }
            .onReceive(midi.updates) { input.receive($0, state: state, active: state.isPreview || NSApp.isActive) }
            .confirmationDialog("Keep the two newest pitch-only takes?", isPresented: $clearingDetails) {
                Button("Clear older detector details", role: .destructive) {
                    perform { try state.retireEarDailyDetails(session.id) }
                }
            } message: {
                Text(
                    "Older detector details are removed. Pitch/order journal results, inconclusive summaries, compositions and review cutoffs stay. Calibrated timing takes are kept."
                )
            }
        }
    }

    private func trail(_ session: EarDailySession) -> some View {
        let steps: [(String, EarDailyStage)] = [
            ("Hear", .hear), ("Imagine", .imagine), ("Find & refine", .play), ("Make an answer", .create),
            ("Return later", .complete),
        ]
        let selected = session.stage == .review ? EarDailyStage.play : session.stage
        return HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    Text(String(index + 1)).font(.caption.monospacedDigit()).frame(width: 25, height: 25)
                        .background(selected == step.1 ? Color.moss : Color.moss.opacity(0.08), in: Circle())
                        .foregroundStyle(selected == step.1 ? Color.white : Color.moss)
                    Text(step.0).font(.callout).foregroundStyle(selected == step.1 ? Color.ink : Color.secondary)
                    if index < steps.count - 1 {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.line).frame(maxWidth: 38).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                }.accessibilityElement(children: .combine).accessibilityAddTraits(
                    selected == step.1 ? [.isSelected] : [])
            }
        }.padding(16).background(Color.moss.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func activity(_ session: EarDailySession) -> some View {
        switch session.stage {
        case .hear:
            Text("Listen for the shape and its landing note. Let the sound come before the written notes.")
                .foregroundStyle(.secondary)
            Button("Hear the phrase", systemImage: "play.fill") { perform { try state.hearEarDaily(session.id) } }
                .buttonStyle(.cadencePrimary).disabled(audio.isPlaying || audio.isPreparing).accessibilityIdentifier(
                    "daily-ear.hear")
        case .imagine:
            Text(
                session.mode == .learning
                    ? "Let the phrase play silently in your mind. Sing or hum it if you like; imagine where it comes home."
                    : "Bring the phrase back before using a replay or hint. A new piece tests transfer, separately from remembering the familiar one."
            )
            .foregroundStyle(.secondary)
            Button("I’m ready to find it", systemImage: "arrow.right") {
                perform {
                    state.stopAllPlayback()
                    try state.updateEarDaily(session.id) { try $0.imagined(now: Date()) }
                }
            }.buttonStyle(.cadencePrimary).disabled(audio.isPlaying || audio.isPreparing)
                .accessibilityIdentifier("daily-ear.imagine")
            Button("Skip the playing check") {
                perform { try state.updateEarDaily(session.id) { try $0.skip(now: Date()) } }
            }
            .font(.caption)
        case .play:
            Text(
                session.focusBar.map {
                    "Source bar \($0), a little more slowly. Then reconnect it to the complete phrase."
                }
                    ?? "Find the whole phrase from memory, one note at a time. Take a comfortable pace; timing is unassessed."
            )
            .foregroundStyle(.secondary)
            if session.instrument == .piano { piano(session) } else { guitar(session) }
            if session.focusBar != nil {
                Button("Return to the whole phrase", systemImage: "arrow.uturn.backward") {
                    perform { try state.updateEarDaily(session.id) { try $0.retry(now: Date()) } }
                }.disabled(locked).accessibilityIdentifier("daily-ear.leave-focus")
            }
            if !locked {
                Button("Skip the playing check") {
                    perform { try state.updateEarDaily(session.id) { try $0.skip(now: Date()) } }
                }.font(.caption)
            }
        case .review:
            if let attempt = state.earDailyLatestAttempt {
                Text(
                    attempt.outcome == .correct
                        ? "The pitches came back in order." : "There’s a useful place to listen again."
                )
                .font(.title3).foregroundStyle(Color.moss)
                Text(
                    attempt.assisted
                        ? "Supported pitch recall · timing unassessed" : "Independent pitch recall · timing unassessed"
                ).font(.caption).foregroundStyle(.secondary)
                Text(
                    "Heard: "
                        + attempt.played.map { Pitch.chromatic($0) + String($0 / 12 - 1) }.joined(separator: " · ")
                ).font(.callout)
            } else {
                Text("This capture was inconclusive. No correctness grade or weakness was recorded.").foregroundStyle(
                    .secondary)
            }
            HStack(spacing: 12) {
                if let bar = state.earDailyFocusBar(session), session.focusBar == nil {
                    Button("Focus on bar \(bar)", systemImage: "scope") {
                        perform { try state.updateEarDaily(session.id) { try $0.retry(bar: bar, now: Date()) } }
                    }.accessibilityIdentifier("daily-ear.focus")
                }
                Button(
                    session.focusBar == nil ? "Try the whole phrase again" : "Reconnect the whole phrase",
                    systemImage: "arrow.uturn.backward"
                ) {
                    perform { try state.updateEarDaily(session.id) { try $0.retry(now: Date()) } }
                }.accessibilityIdentifier("daily-ear.reconnect")
                Button("Write my answer", systemImage: "square.and.pencil") {
                    perform { try state.openEarDailyAnswer(session.id) }
                }.buttonStyle(.cadencePrimary).accessibilityIdentifier("daily-ear.answer")
                if session.mode != .learning {
                    Button("Finish this review", systemImage: "checkmark") {
                        perform { try state.finishEarDailyReview(session.id) }
                    }
                }
            }
            Text(
                "A focused retry is a branch of this session. Return to the whole phrase before calling it independent."
            )
            .font(.caption).foregroundStyle(.secondary)
        case .create:
            Text(
                "Borrow a rhythm, turn the ending another way, or answer the phrase with one of your own. Your composition keeps its source link; there is no right-answer grade."
            )
            .foregroundStyle(.secondary)
            HStack {
                Button("Open my musical answer", systemImage: "pencil.and.outline") {
                    perform { try state.openEarDailyAnswer(session.id) }
                }
                .buttonStyle(.cadencePrimary)
                Button("Finish today’s session", systemImage: "checkmark") {
                    perform { try state.finishEarDaily(session.id) }
                }
                .disabled(!answerFinished(session)).accessibilityIdentifier("daily-ear.finish")
            }
            Text(
                answerFinished(session)
                    ? "Your musical answer is saved in My compositions."
                    : "Add notes, hear the complete answer and save it as finished in Studio. Then come back here."
            )
            .font(.caption).foregroundStyle(.secondary)
        case .complete:
            Text("Your session is kept.").font(.title3).foregroundStyle(Color.moss)
            Text(
                answerFinished(session)
                    ? "Your answer is in My compositions, linked to the original. Supported practice and independent recall remain separate."
                    : "Your review is recorded separately from creative work. Writing another answer is optional."
            ).foregroundStyle(.secondary)
            Button(
                answerFinished(session) ? "Open my musical answer" : "Write a musical answer", systemImage: "music.note"
            ) { perform { try state.openEarDailyAnswer(session.id) } }
            if let journey = state.songJourneys.first(where: { $0.id == session.journeyID }) {
                let due = state.earDailyReturnDate(journey.material, instrument: session.instrument) ?? .distantFuture
                Text("Independent return after " + due.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                    .foregroundStyle(Color.moss)
                HStack {
                    Button("Bring this phrase back") { perform { try state.openEarDaily(journey, mode: .recall) } }
                        .disabled(Date() < due)
                    Button("Try another piece") { perform { try state.openEarDaily(journey, mode: .transfer) } }
                        .disabled(Date() < (state.earDailyTransferDate(journey) ?? due))
                    Button("Guided practice today") { perform { try state.openEarDaily(journey) } }
                }
                Text(
                    "Returns appear in Practice & review. A replay or fresh practice moves the next independent return; the activities stay open."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func piano(_ session: EarDailySession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MIDIConnectionView(midi: midi)
            HStack {
                Button(
                    input.listening ? "Start a fresh MIDI take" : "Listen to my MIDI keyboard", systemImage: "pianokeys"
                ) {
                    perform { try input.arm(state: state) }
                }.disabled(input.pending != nil).accessibilityIdentifier("daily-ear.midi")
                Button("Check my take", systemImage: "checkmark") { input.submit(state: state) }
                    .buttonStyle(.cadencePrimary).disabled(!input.listening || input.notes.isEmpty)
                    .accessibilityIdentifier("daily-ear.check")
                Text("\(input.notes.count) notes captured").font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "Release each note before the next. Notes held before capture must be released first. Use Check my take when finished; pauses and tempo are not graded."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func guitar(_ session: EarDailySession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            guitarSetup(session)
            if acoustic.busy {
                guitarListening
            } else if let take = acoustic.pending {
                pendingGuitarTake(take)
            } else {
                Button("Count in & listen", systemImage: "mic.fill") {
                    perform { try state.startEarDailyMicrophone(session.id) }
                }.buttonStyle(.cadencePrimary).accessibilityIdentifier("daily-ear.microphone")
            }
        }
    }

    private func guitarSetup(_ session: EarDailySession) -> some View {
        let bars: Int =
            session.focusBar == nil ? session.material.scope.throughBar - session.material.scope.fromBar + 1 : 1
        let description: String =
            "\(bars) \(bars == 1 ? "bar" : "bars") · \(session.invitationTempo) bpm · capture stops at the end of the phrase."
        return VStack(alignment: .leading, spacing: 12) {
            Stepper("Input channel \(acoustic.inputChannel + 1)", value: $acoustic.inputChannel, in: 0...63)
                .frame(width: 195).disabled(locked)
            DisclosureGroup("Mac microphone or USB interface setup") {
                Text(
                    "Choose the input in System Settings → Sound, then the channel carrying your guitar. Play clean single notes. Pitch-only recall needs no loopback calibration; timing stays unassessed."
                )
                .font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var guitarListening: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(acoustic.phase == .countIn ? "Count in · the final beat is silent" : "Listening through the phrase…")
            Button("Cancel take") { acoustic.cancel() }
        }.font(.callout)
    }

    private func pendingGuitarTake(_ take: MicrophonePhraseTake) -> some View {
        let pitches: String = take.attacks.compactMap(\.midi).map { Pitch.chromatic($0) + String($0 / 12 - 1) }.joined(
            separator: " · ")
        return VStack(alignment: .leading, spacing: 12) {
            Text("Take captured · inspect it before keeping").font(.headline)
            Text("Heard: " + pitches).font(.callout)
            ForEach(take.report.notes, id: \.index) { note in
                uncertainPitchToggle(take, index: note.index)
            }
            HStack {
                Button("Keep take", systemImage: "checkmark") { acoustic.save(using: state.saveEarDailyMicrophone) }
                    .buttonStyle(.cadencePrimary).accessibilityIdentifier("daily-ear.keep")
                Button("Discard take", role: .destructive) { perform { try state.discardEarDailyMicrophone() } }
            }
            if let issue = take.signalIssue { Text(issue).font(.caption).foregroundStyle(Color.clay) }
        }
    }

    private func uncertainPitchToggle(_ take: MicrophonePhraseTake, index: Int) -> some View {
        let disputed = Binding<Bool>(
            get: { take.disputedTargets.contains(index) }, set: { acoustic.dispute(index, uncertain: $0) })
        return Toggle("Uncertain match · note \(index + 1)", isOn: disputed).toggleStyle(.checkbox).font(.caption)
    }

    private func answerFinished(_ session: EarDailySession) -> Bool {
        state.editor.documents.first(where: { $0.id == session.answerID }).map {
            $0.responseSource?.isFinished($0) == true
        } ?? false
    }
    private func invitation(_ session: EarDailySession) -> String {
        switch session.stage {
        case .hear: "First, just listen."
        case .imagine: "Carry the sound before you play."
        case .play: session.focusBar == nil ? "Find the phrase." : "One small branch. Then back to the phrase."
        case .review: "Notice what connected."
        case .create: "What would you say back?"
        case .complete: "Something to keep. Something to return to."
        }
    }
    private func refresh(_ session: EarDailySession) {
        guard (try? state.validateEarDaily(session)) != nil else {
            study = nil
            input.pause()
            acoustic.cancel()
            return
        }
        guard session.revealed, let piece = state.libraryPieces.first(where: { $0.id == session.material.pieceID })
        else {
            study = nil
            return
        }
        do {
            study = try ScoreEarMaterial.study(piece: piece, scope: session.material.scope)
            study?.staff = session.material.staff
        } catch { self.scoreError = error.localizedDescription }
    }
    private func perform<T>(_ action: () throws -> T) {
        do {
            _ = try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
