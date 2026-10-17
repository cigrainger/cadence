// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct ScoreEarSetupView: View {
    @EnvironmentObject private var state: AppState
    let piece: LibraryPiece
    let snapshot: PieceSnapshot?
    @State private var voiceID = ""
    @State private var harmonyStaff = 1
    @State private var reviewed = false
    @State private var error: String?
    private var study: MusicStudy? { snapshot.flatMap { try? ScoreEarMaterial.study(piece: piece, scope: $0.scope) } }
    private var choices: [SingingVoice] { study.map(SingingVoice.choices) ?? [] }
    private var voice: SingingVoice? { choices.first { $0.id == voiceID } ?? choices.first }
    private var harmonyStaffs: [Int] {
        guard let snapshot else { return [1] }
        return
            (try? ChangesSource(
                piece: piece, from: snapshot.scope.fromBar - 1, through: snapshot.scope.throughBar - 1,
                partID: snapshot.scope.partID
            ).staffs) ?? [1]
    }
    private var material: Result<ScoreEarMaterial, Error> {
        Result {
            guard let snapshot, let voice else {
                throw MusicError.invalid("Choose 1–4 bars above, then a single melodic voice with up to 12 notes.")
            }
            return try ScoreEarMaterial(
                piece: piece, scope: snapshot.scope, staff: voice.staff, voice: voice.voice,
                harmonyStaff: harmonyStaffs.contains(harmonyStaff) ? harmonyStaff : harmonyStaffs.first ?? 1)
        }
    }
    private var selectionKey: String {
        [piece.fingerprint, snapshot?.scope.label ?? "", snapshot?.scope.partID ?? "", voiceID, String(harmonyStaff)]
            .joined(separator: "|")
    }
    var body: some View {
        Card(title: "Carry this music with you", padding: 20, spacing: 14) {
            Text(
                "Hear → imagine → sing → play. Learn a short melody from this piece, then join the band and return to it another day."
            ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !choices.isEmpty {
                HStack {
                    Picker("Melody", selection: Binding(get: { voice?.id ?? "" }, set: { voiceID = $0 })) {
                        ForEach(choices) { Text($0.label).tag($0.id) }
                    }
                    Picker("Chord symbols", selection: $harmonyStaff) {
                        ForEach(harmonyStaffs, id: \.self) { Text("Staff \($0)").tag($0) }
                    }
                }.controlSize(.small)
            }
            switch material {
            case .success(let source):
                Text(source.label + " · \(source.melody.count) attacks · " + source.sourceLabel).font(.caption)
                    .foregroundStyle(Color.moss)
                if let issue = source.accompanimentIssue {
                    Text("Ear training is ready. Accompaniment: " + issue).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("I’ve checked this melody, key and any chord symbols against the source", isOn: $reviewed)
                    .toggleStyle(.checkbox).font(.callout)
                HStack {
                    Button("Begin with this passage", systemImage: "ear") {
                        do { try state.openScoreEar(source) } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.cadencePrimary).disabled(!reviewed)
                    if source.accompanimentIssue == nil {
                        Button("Play along", systemImage: "pianokeys") { state.openPlayAlong(source) }.disabled(
                            !reviewed)
                    }
                    Button("Review score & original", systemImage: "doc.text.magnifyingglass") {
                        state.openLibraryPiece(
                            piece, from: source.scope.fromBar - 1, through: source.scope.throughBar - 1,
                            partID: source.scope.partID)
                    }
                }
            case .failure(let issue):
                Text(issue.localizedDescription).font(.callout).foregroundStyle(Color.clay).fixedSize(
                    horizontal: false, vertical: true)
                Button("Open score to review") {
                    state.openLibraryPiece(
                        piece, from: (snapshot?.scope.fromBar ?? 1) - 1, through: (snapshot?.scope.throughBar ?? 4) - 1,
                        partID: snapshot?.scope.partID)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            ScoreEarSavedView(pieceID: piece.id)
        }.onChange(of: selectionKey) { _, _ in
            reviewed = false
            error = nil
        }
    }
}

struct ScoreEarSavedView: View {
    @EnvironmentObject private var state: AppState
    var pieceID: String?
    private var sessions: [EarSession] {
        state.scoreEarLatest.filter {
            pieceID == nil ? (try? $0.projection().stage) != .complete : $0.opening.material?.pieceID == pieceID
        }
    }
    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: pieceID == nil ? "Pick up your passage" : "Your saved passages").foregroundStyle(
                    Color.moss)
                ForEach(sessions) { session in
                    if let material = session.opening.material, let p = try? session.projection() {
                        let current = state.scoreEarCurrent(material)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(material.title + " · " + material.label).font(.callout.weight(.medium))
                                Text(
                                    current
                                        ? (p.stage == .complete
                                            ? state.scoreEarReview(material).reason()
                                            : "Saved at \(p.stage.rawValue) · \(p.results.count) checked or skipped attempts")
                                        : "Score changed or no longer reviewed · history preserved"
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(
                                !current ? "View saved session" : p.stage == .complete ? "Return to passage" : "Resume"
                            ) {
                                do {
                                    if current && p.stage == .complete {
                                        try state.openScoreEar(material)
                                    } else {
                                        try state.resumeScoreEarSession(session.id)
                                    }
                                } catch { state.message = error.localizedDescription }
                            }
                        }
                    }
                }
            }
        }
    }
}
