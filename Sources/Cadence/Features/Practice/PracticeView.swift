// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct PracticeView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var microphone: Microphone
    @ObservedObject var audio: AudioPlayer
    @State private var midiExercise = false
    @State private var tapRhythm = true
    @State private var exercise = Exercise.intervals
    @State private var question: PracticeQuestion?
    @State private var feedback = ""
    @State private var solved = false
    @State private var attempts = 0
    @State private var played = false
    @State private var reveal = false
    @State private var awaitingMicrophone = false
    @State private var octaveStrict = false
    @State private var showLearningNotes = false
    @State private var lastJudgedPitch: Int?
    private var deck: [PracticeQuestion] { QuestionFactory.deck(exercise, root: state.root, scale: state.scale) }
    private var answerColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: exercise == .functional ? 7 : exercise == .rhythm ? 2 : 4)
    }

    var body: some View {
        if let session = state.pathwaySession {
            PathwayExerciseView(midi: state.midi, audio: audio).id(session.episode)
        } else {
            regularPractice
        }
    }
    private var regularPractice: some View {
        VStack(spacing: 16) {
            PieceReviewQueueView()
            GuidedReviewQueueView()
            TimedReviewQueueView()
            TimedChangesReviewQueue()
            HStack {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.moss)
                Text("Follow the changes").fontWeight(.medium)
                Text("Dm7 → G7 → Cmaj7 · roots, guide tones and chords").foregroundStyle(.secondary)
                Spacer()
                Button("Open", systemImage: "arrow.right") { state.openChanges() }
            }.font(.callout).padding(14).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            HStack(spacing: 22) {
                stat(
                    state.practicedConceptCount == 1 ? "concept practised" : "concepts practised",
                    value: "\(state.practicedConceptCount)", icon: "music.note")
                stat(
                    state.practicedDayCount == 1 ? "day with music" : "days with music",
                    value: "\(state.practicedDayCount)", icon: "sun.max")
                if state.showRewards { stat("practice points", value: "\(state.history.xp)", icon: "sparkle") }
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.line.opacity(0.7), lineWidth: 1))
            Card(title: "", padding: 20, spacing: 14) {
                Picker(
                    "Exercise",
                    selection: Binding(
                        get: { midiExercise ? "Play chords" : exercise.rawValue },
                        set: { value in
                            midiExercise = value == "Play chords"
                            if let item = Exercise(rawValue: value) { exercise = item }
                        })
                ) {
                    ForEach(Exercise.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    Text("Play chords").tag("Play chords")
                }.pickerStyle(.segmented).labelsHidden()
                if !midiExercise && exercise == .rhythm {
                    Picker("Rhythm practice", selection: $tapRhythm) {
                        Text("Tap it out").tag(true)
                        Text("Recognise a rhythm").tag(false)
                    }.pickerStyle(.segmented).frame(width: 320)
                }
                if !midiExercise && exercise != .intervals && !(exercise == .rhythm && tapRhythm) {
                    HStack {
                        Text(
                            state.history.dueCount(in: deck) > 0
                                ? "\(state.history.dueCount(in:deck)) concepts ready to revisit"
                                : "Explore a new question or practise a familiar one"
                        ).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Show points", isOn: $state.showRewards).toggleStyle(.checkbox).font(.caption)
                    }
                }
                if midiExercise {
                    PlayChordView(midi: state.midi, audio: audio)
                } else if exercise == .intervals {
                    IntervalSingingView(microphone: microphone, audio: audio)
                } else if exercise == .rhythm && tapRhythm {
                    TimedPracticeView(midi: state.midi, session: state.timedSession)
                } else if let question {
                    VStack(spacing: 14) {
                        Text(question.title).font(.system(size: 25, weight: .medium, design: .serif))
                            .multilineTextAlignment(.center)
                        Text(question.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if let score = question.audio {
                            Button(played ? "Hear it again" : "Play the question", systemImage: "play.fill") {
                                microphone.stop()
                                audio.play(score)
                                played = true
                            }.buttonStyle(.cadencePrimary).controlSize(.regular).keyboardShortcut(.space, modifiers: [])
                        }
                        LazyVGrid(columns: answerColumns, spacing: 8) {
                            ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                                Button {
                                    answer(index)
                                } label: {
                                    VStack(spacing: 8) {
                                        if exercise == .rhythm {
                                            RhythmPattern(values: QuestionFactory.rhythmValues[index]).frame(height: 44)
                                        }
                                        Text(choice).font(.system(size: exercise == .rhythm ? 12 : 15, weight: .medium))
                                            .multilineTextAlignment(.center)
                                        if state.showSolfege, let notes = question.singingNotes,
                                            notes.indices.contains(index)
                                        {
                                            Text(notes[index].solfege).font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(Color.moss)
                                            Text(notes[index].pitch.name).font(.system(size: 10)).foregroundStyle(
                                                .secondary)
                                        }
                                    }.frame(maxWidth: .infinity, minHeight: 42).padding(8)
                                        .background(
                                            (solved || reveal) && index == question.answer
                                                ? Color.moss.opacity(0.17) : Color.canvas,
                                            in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).keyboardShortcut(
                                    KeyEquivalent(Character(String(index + 1))), modifiers: []
                                ).help("Answer \(index+1): \(choice)").disabled(
                                    solved || (question.audio != nil && !played) || audio.isPlaying)
                            }
                        }
                        if !feedback.isEmpty {
                            Text(feedback).foregroundStyle(solved ? Color.moss : Color.clay).fontWeight(.medium)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                        if solved || reveal {
                            Text(question.explanation).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).textSelection(.enabled)
                        }
                        HStack {
                            if !solved && !reveal {
                                Button("Show answer") {
                                    guard state.recordEvidence(question, outcome: .revealed, assisted: true) else {
                                        return
                                    }
                                    reveal = true
                                    attempts += 1
                                    microphone.stop()
                                }
                            }
                            if solved {
                                Button("Next question", systemImage: "arrow.right") { newQuestion() }.buttonStyle(
                                    .cadencePrimary
                                ).keyboardShortcut(.return, modifiers: [])
                            } else {
                                Button("Skip for now", systemImage: "arrow.right") {
                                    if state.recordEvidence(question, outcome: .skipped, assisted: reveal) {
                                        newQuestion()
                                    }
                                }.buttonStyle(.cadence)
                            }
                        }
                        Text(
                            solved
                                ? "Return for next question"
                                : exercise == .functional
                                    ? "1–7 to answer · Space to listen"
                                    : question.audio != nil ? "1–4 to answer · Space to listen" : "1–4 to answer"
                        ).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 10).frame(maxWidth: .infinity)
                }
            }
            if !midiExercise && exercise == .functional {
                Card(title: "Sing it back", subtitle: "Hold a note for about a second", padding: 16, spacing: 10) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(Color.moss).frame(
                            width: 36)
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Listen first, then sing the final note. Your voice is analysed on this Mac.").font(
                                .caption
                            ).foregroundStyle(.secondary)
                            if state.showSolfege, solved || reveal, let question, let notes = question.singingNotes,
                                notes.indices.contains(question.answer)
                            {
                                Text(
                                    "\(notes[question.answer].solfege) · \(notes[question.answer].pitch.name) · degree \(notes[question.answer].degreeLabel)"
                                ).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.moss)
                            }
                            HStack(spacing: 14) {
                                Button(
                                    microphone.listening ? "Stop listening" : "Listen to my voice",
                                    systemImage: microphone.listening ? "stop.circle" : "mic"
                                ) {
                                    if microphone.listening {
                                        microphone.stop()
                                    } else {
                                        lastJudgedPitch = nil
                                        awaitingMicrophone = true
                                        Task {
                                            await microphone.start()
                                            awaitingMicrophone = false
                                        }
                                    }
                                }.disabled(!played || audio.isPlaying || solved || reveal || awaitingMicrophone)
                                Toggle("Match the octave", isOn: $octaveStrict).toggleStyle(.checkbox).font(.caption)
                                Toggle("Solfège labels", isOn: $state.showSolfege).toggleStyle(.checkbox).font(.caption)
                            }
                            if let pitch = microphone.pitch {
                                HStack {
                                    Text("\(Pitch.chromatic(pitch.midi))\(pitch.midi/12-1)").font(
                                        .system(size: 24, weight: .medium, design: .serif))
                                    Text("\(Int(pitch.cents)) cents").font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(abs(pitch.cents) < 35 ? "Hold steady…" : "Ease towards the centre").font(
                                        .caption
                                    ).foregroundStyle(.secondary)
                                }
                                PitchMeter(cents: pitch.cents).frame(height: 22)
                            } else if microphone.listening {
                                Text("Listening for a clear note…").font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = microphone.error { Text(error).foregroundStyle(Color.clay).font(.caption) }
                        }
                    }
                }
            }
            PracticeHistoryView()
            DisclosureGroup("About these exercises", isExpanded: $showLearningNotes) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 24) {
                        skill(
                            "Hear relationships",
                            body:
                                "Echo intervals to practise distance and direction. Scale degree questions use a cadence to practise a note’s role in the key. Movable Do names that role; Do-based minor uses Me, Le, and Te."
                        )
                        skill(
                            "Make room for mistakes",
                            body:
                                "Missed concepts return sooner. Confident answers gradually spread reviews further apart."
                        )
                        skill(
                            "Keep what you learn",
                            body: "Your practice history stays on this Mac. Every exercise is always available.")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 8) {
                        ForEach(Exercise.allCases, id: \.self) { item in
                            Pill(
                                text: "\(item.rawValue): \(state.history.skills[item.rawValue,default:0])",
                                active: false)
                        }
                    }.accessibilityLabel("Correct unassisted answers by skill")
                }.padding(.top, 10)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 5)
        }
        .onAppear {
            state.beginPracticeSession()
            midiExercise = state.practiceMIDIExercise
            if state.isPreview && CommandLine.arguments.contains("--midi-chord-check") { midiExercise = true }
            if state.rhythmReview != nil
                || (state.isPreview && CommandLine.arguments.contains("--timed-practice-check"))
            {
                exercise = .rhythm
                tapRhythm = true
            }
            if let requested = state.practiceExercise {
                exercise = requested
                state.practiceExercise = nil
            }
            if let argument = CommandLine.arguments.firstIndex(of: "--exercise"),
                argument + 1 < CommandLine.arguments.count,
                let requested = Exercise.allCases.first(where: { $0.rawValue == CommandLine.arguments[argument + 1] })
            {
                exercise = requested
            }
            if question == nil { newQuestion() }
        }
        .onChange(of: state.practiceExercise) { _, requested in
            if let requested {
                midiExercise = state.practiceMIDIExercise
                exercise = requested
                state.practiceExercise = nil
            }
        }
        .onChange(of: midiExercise) { _, _ in
            microphone.stop()
            audio.stop()
            state.midi.panic()
        }
        .onChange(of: exercise) { _, _ in newQuestion() }
        .onChange(of: state.rhythmReview?.id) { _, id in
            if id != nil {
                exercise = .rhythm
                tapRhythm = true
                midiExercise = false
            }
        }
        .onChange(of: state.root) { _, _ in newQuestion() }
        .onChange(of: state.scale) { _, _ in newQuestion() }
        .onChange(of: microphone.heldPitch) { _, value in
            guard exercise == .functional, let value, let question, let target = question.target, microphone.listening,
                played, !solved, !reveal, !audio.isPlaying, value != lastJudgedPitch
            else { return }
            lastJudgedPitch = value
            let correct = octaveStrict ? value == target : mod(value) == mod(target)
            if correct {
                answer(question.answer, input: .singing)
            } else {
                guard
                    state.record(
                        question, correct: false, firstTry: attempts == 0, revealed: reveal, input: .singing,
                        played: [value], ordinal: attempts + 1) != nil
                else {
                    feedback = state.message ?? "The answer could not be saved."
                    return
                }
                attempts += 1
                feedback = "I heard \(Pitch.chromatic(value)). Try the target again, or replay the question."
            }
        }
        .onDisappear {
            microphone.stop()
            audio.stop()
        }
    }
    private func stat(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.moss)
            Text(value).font(.system(size: 17, weight: .medium, design: .serif))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func skill(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fontWeight(.medium)
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func answer(_ index: Int, input: PracticeInput = .choice) {
        guard let question, !solved else { return }
        let correct = index == question.answer
        guard
            let reward = state.record(
                question, correct: correct, firstTry: attempts == 0, revealed: reveal, input: input,
                played: input == .singing ? microphone.heldPitch.map { [$0] } ?? [] : [], ordinal: attempts + 1,
                selectedChoice: input == .choice ? question.choices[index] : nil)
        else {
            feedback = state.message ?? "The answer could not be saved."
            return
        }
        attempts += 1
        if correct {
            solved = true
            feedback = "You’ve got it." + (state.showRewards && reward > 0 ? " +\(reward) points" : "")
            microphone.stop()
        } else {
            feedback = "Take another listen. You can try again whenever you’re ready."
        }
    }
    private func newQuestion() {
        state.beginPracticeSession()
        microphone.stop()
        audio.stop()
        feedback = ""
        solved = false
        attempts = 0
        played = false
        reveal = false
        lastJudgedPitch = nil
        if exercise == .intervals {
            question = nil
            return
        }
        question = state.history.next(in: deck, avoiding: question?.id)
    }
}

struct PitchMeter: View {
    var cents: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule().fill(Color.line.opacity(0.4)).frame(height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color.moss.opacity(0.2)).frame(
                    width: geometry.size.width * 0.35, height: 15)
                Rectangle().fill(Color.moss).frame(width: 2, height: 20)
                Circle().fill(abs(cents) < 35 ? Color.moss : Color.clay).frame(width: 12, height: 12).position(
                    x: geometry.size.width * (0.5 + min(50, max(-50, cents)) / 100), y: geometry.size.height / 2)
            }.frame(height: geometry.size.height)
        }.accessibilityLabel("Pitch offset \(Int(cents)) cents from the nearest note")
    }
}

struct RhythmPattern: View {
    var values: [Double]
    var body: some View {
        Canvas { context, size in
            let gap = size.width / Double(values.count + 1)
            for (index, value) in values.enumerated() {
                let x = gap * Double(index + 1)
                let y = 32.0
                let head = Path(ellipseIn: CGRect(x: x - 5, y: y - 3, width: 10, height: 6))
                if value >= 2 {
                    context.stroke(head, with: .color(.ink), lineWidth: 1.4)
                } else {
                    context.fill(head, with: .color(.ink))
                }
                var stem = Path()
                stem.move(to: CGPoint(x: x + 4, y: y))
                stem.addLine(to: CGPoint(x: x + 4, y: y - 24))
                context.stroke(stem, with: .color(.ink), lineWidth: 1.2)
                if value < 1 {
                    var flag = Path()
                    flag.move(to: CGPoint(x: x + 4, y: y - 24))
                    flag.addQuadCurve(to: CGPoint(x: x + 11, y: y - 10), control: CGPoint(x: x + 20, y: y - 19))
                    context.stroke(flag, with: .color(.ink), lineWidth: 1.5)
                }
            }
        }.accessibilityHidden(true)
    }
}
