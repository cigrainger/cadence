// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct CreativeAnswerCard: View {
    @EnvironmentObject private var state: AppState
    let session: EarSession
    var body: some View {
        if let material = session.opening.material {
            let answer = state.creativeAnswer(material.id)
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Make it yours").foregroundStyle(Color.moss)
                Text("What would you say back?").font(.system(size: 25, weight: .medium, design: .serif))
                Text(
                    "Write a short answer. Borrow a rhythm, turn the melody another way, or lead it somewhere new. Start with space, in the same key and meter; written chord changes are there if you want them."
                ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(answer == nil ? "Write my answer" : "Open my answer", systemImage: "square.and.pencil") {
                        do { try state.openCreativeAnswer(session.id) } catch {
                            state.message = error.localizedDescription
                        }
                    }.buttonStyle(.cadencePrimary)
                    if let answer {
                        Text(
                            answer.responseSource?.isFinished(answer) == true
                                ? "Saved in My compositions" : "Draft saved · ready to continue"
                        ).font(.caption).foregroundStyle(Color.moss)
                    }
                }
                Text("Your composition stays linked to these bars. There is no right-answer score for this part.").font(
                    .caption
                ).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
                Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct CreativeAnswerBar: View {
    @EnvironmentObject private var state: AppState
    let document: EditorDocument
    @ObservedObject var audio: AudioPlayer
    @State private var playback: (id: UUID, fingerprint: String)?
    @State private var listened: String?
    @State private var error: String?
    private var isArrangement: Bool { state.songJourneys.contains { $0.compositionID == document.id } }
    private var fingerprint: String { LibraryPiece(source: .score(document)).fingerprint }
    var body: some View {
        if let link = document.responseSource {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(text: isArrangement ? "Your eight-bar arrangement" : "Your musical answer")
                            .foregroundStyle(Color.moss)
                        Text("In conversation with “\(link.material.title)”").font(
                            .system(size: 22, weight: .medium, design: .serif))
                        Text(link.material.label + " · " + link.material.sourceLabel).font(.caption).foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    if let returnSession = state.scoreEarPractice.latest(link.material.id) {
                        Button("Back to practice", systemImage: "arrow.uturn.backward") {
                            do { try state.resumeScoreEarSession(returnSession.id) } catch {
                                self.error = error.localizedDescription
                            }
                        }.controlSize(.small)
                    }
                }
                Text(
                    isArrangement
                        ? "Give the melody, bass and accompaniment clear roles. Make a contrast in the second phrase, then find a way home. Enter notes or use MIDI step entry; your draft saves as you work."
                        : "Keep something you heard; change something of your own. Enter notes below or turn on MIDI step entry. Drafts save as you work."
                ).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Hear original", systemImage: "ear") {
                        playback = nil
                        var notes = link.material.melody
                        notes.append(ScoreNote(midi: -1, start: 0, duration: link.material.beats))
                        audio.play(Score(tempo: link.material.tempo, notes: notes))
                    }
                    Button(
                        audio.isPlaying || audio.isPreparing
                            ? "Stop" : isArrangement ? "Hear my arrangement" : "Hear my answer",
                        systemImage: audio.isPlaying || audio.isPreparing ? "stop.fill" : "play.fill"
                    ) {
                        if audio.isPlaying || audio.isPreparing {
                            audio.stop()
                            playback = nil
                        } else {
                            hearAnswer()
                        }
                    }.disabled(!document.events.contains { !$0.pitches.isEmpty })
                    Button(
                        isArrangement ? "Save finished arrangement" : "Save finished answer",
                        systemImage: "checkmark.seal"
                    ) {
                        do {
                            try state.finishCreativeAnswer(
                                document.id, listenedFingerprint: listened ?? link.listenedFingerprint ?? "")
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.cadencePrimary).disabled(listened != fingerprint && !link.isFinished(document))
                    Spacer(minLength: 0)
                    if let source = state.libraryPieces.first(where: { $0.id == link.material.pieceID }) {
                        Button("Open original", systemImage: "arrow.up.right") { state.openLibraryPiece(source) }
                    }
                }.controlSize(.small)
                Text(
                    link.isFinished(document)
                        ? "Saved in My compositions · linked to the original passage"
                        : listened == fingerprint
                            ? "You’ve heard this version. Save it when it says what you want."
                            : "Listen to the whole answer once before marking it finished."
                ).font(.caption).foregroundStyle(Color.moss)
                if !state.scoreEarCurrent(link.material) {
                    Text(
                        "The original has changed or is unavailable. Your answer and its saved source reference are kept."
                    ).font(.caption).foregroundStyle(.secondary)
                }
                if let error = error ?? audio.error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            }.padding(18).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .onChange(of: audio.completedPlayback) { _, id in
                    guard let id, let playback, id == playback.id else { return }
                    if fingerprint == playback.fingerprint { listened = fingerprint }
                    self.playback = nil
                }
                .onChange(of: fingerprint) { _, _ in
                    if playback != nil { audio.stop() }
                    playback = nil
                    listened = nil
                }
                .onDisappear { audio.stop() }
        }
    }
    private func hearAnswer() {
        do {
            var study = MusicStudy(
                document: try StudyImport.read(Data(EditorXML.encode(document).utf8)), filename: "My answer")
            study.from = 0
            study.through = document.barCount - 1
            study.countIn = false
            audio.playStudy(try StudyPlaybackPlan(study: study, wholePiece: true), loop: false)
            playback = (audio.playbackID, fingerprint)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
