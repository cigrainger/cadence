// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Rectangle().fill(Color.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.line)
                if state.destination != .library, !(state.destination == .practice && state.practicePage != .exercises),
                    let location = state.courseReturn
                {
                    CourseReturnBar(location: location)
                }
                GeometryReader { workspace in
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                switch state.destination {
                                case .explore: ExploreView()
                                case .chords: ChordsView()
                                case .practice:
                                    PracticeWorkspaceView().environment(\.practiceViewportHeight, workspace.size.height)
                                case .coach: CoachView()
                                case .studies: StudiesView(audio: state.audio)
                                case .tools: PracticeToolsView(audio: state.audio, microphone: state.microphone)
                                case .editor:
                                    if let error = state.editorStorageError {
                                        ContentUnavailableView(
                                            "Your saved scores need attention",
                                            systemImage: "externaldrive.badge.exclamationmark", description: Text(error)
                                        )
                                    } else {
                                        EditorView(audio: state.audio, midi: state.midi)
                                    }
                                case .library: LibraryView()
                                }
                            }.padding(22).frame(maxWidth: 1250).frame(maxWidth: .infinity).id("top")
                        }
                        .onChange(of: state.practicePage) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: state.destination) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: state.musicalPathwayStep) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: state.learningShelf) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: state.showAdaptiveSession) { _, _ in proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: state.smoothPractice.active?.phase) { _, _ in
                            if state.showAdaptiveSession { proxy.scrollTo("top", anchor: .top) }
                        }
                        .onChange(of: state.smoothPractice.active?.cursor) { _, _ in
                            if state.showAdaptiveSession { proxy.scrollTo("top", anchor: .top) }
                        }
                        .onChange(of: state.instrumentFocus) { _, _ in
                            withAnimation { proxy.scrollTo("instruments", anchor: .top) }
                        }
                        .onChange(of: state.coachFocus) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) }
                        }
                        .onAppear {
                            if CommandLine.arguments.contains("--instruments") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    proxy.scrollTo("instruments", anchor: .top)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--reharm-detail") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    proxy.scrollTo(
                                        CommandLine.arguments.contains("--reharm-takes")
                                            || CommandLine.arguments.contains("--reharm-create")
                                            ? "reharm-recording" : "reharm-activity", anchor: .top)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--band-preview") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    proxy.scrollTo("score-band", anchor: .top)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--study-bottom") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    proxy.scrollTo("study-learning", anchor: .bottom)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--practice-bottom") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    proxy.scrollTo("passage-singing", anchor: .center)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--study-instrument") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    proxy.scrollTo("study-instrument", anchor: .top)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--course-bottom") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    proxy.scrollTo("course-session", anchor: .bottom)
                                }
                            }
                        }
                        .onAppear {
                            if state.isPreview && CommandLine.arguments.contains("--pathway-bottom") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    proxy.scrollTo("pathway-notes", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                if !state.storageWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Some work needs attention before it can be saved").fontWeight(.semibold)
                        ForEach(Array(state.storageWarnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).textSelection(.enabled)
                        }
                        HStack {
                            Button("Open data folder") { NSWorkspace.shared.open(state.storage) }
                            Button("Try saving again") { state.save() }
                            Text("Unreadable originals are kept. Restore a backup, then reopen Cadence.")
                        }
                    }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                        Color.clay.opacity(0.09))
                }
                PlaybackBar(state: state)
            }
        }
        .background(Color.canvas).foregroundStyle(Color.ink).tint(.moss).buttonStyle(.cadence).preferredColorScheme(
            .light
        )
        .sheet(isPresented: $state.showPDFImport) {
            PDFImportView().environmentObject(state).environmentObject(state.aiSettings)
        }
        .onChange(of: state.preferences) { _, _ in state.saveSoon() }
        .onChange(of: state.showPDFImport) { _, shown in
            if shown {
                state.audio.stop()
                state.microphone.stop()
            }
        }
        .onChange(of: state.learning) { _, _ in state.saveSoon() }
        .onChange(of: state.studies) { _, _ in state.saveSoon() }
        .onChange(of: state.destination) { _, _ in
            state.stopAllPlayback(keepingMetronome: true)
        }
        .task {
            if state.isPreview && CommandLine.arguments.contains("--settings") { openSettings() }
            if state.isPreview && CommandLine.arguments.contains("--pdf-import-wizard") { state.showPDFImport = true }
            await state.runDiagnosticCommands()
        }
        .alert("Cadence", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } }))
        {
            Button("OK") { state.message = nil }
        } message: {
            Text(state.message ?? "")
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                CadenceMark().foregroundStyle(Color.moss)
                Text("cadence").font(.system(size: 26, weight: .medium, design: .serif))
            }.padding(.top, 19).padding(.bottom, 7)
            Text("A place to make music.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 27)
            navigationGroup("YOUR MUSIC", destinations: [.practice, .library, .editor, .studies])
            navigationGroup("EXPLORE & PLAY", destinations: [.explore, .chords, .tools, .coach]).padding(.top, 22)
            Spacer()
            SettingsLink {
                HStack(spacing: 11) {
                    Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 21)
                    Text("Settings").font(.system(size: 13))
                    Spacer()
                    Text("⌘,").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.bottom, 14)
            Button {
                NSWorkspace.shared.open(URL(string: "https://cigrainger.github.io/cadence/docs/")!)
            } label: {
                Label("Guide & keyboard shortcuts", systemImage: "questionmark.circle")
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 16)
                .help("Open the Cadence guide in your browser")
            HStack(spacing: 7) {
                Image(systemName: state.storageWarnings.isEmpty ? "internaldrive" : "exclamationmark.circle")
                    .foregroundStyle(state.storageWarnings.isEmpty ? Color.moss : Color.clay)
                Text(state.storageWarnings.isEmpty ? "Stored on this Mac" : "Some work is not saved")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 10)).padding(.horizontal, 12).padding(.bottom, 17)
        }.padding(.horizontal, 18).background(Color.sidebar)
    }
    private func navigationGroup(_ title: String, destinations: [Destination]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: title).foregroundStyle(.secondary).padding(.leading, 11).padding(.bottom, 8)
            ForEach(destinations) { destination in
                Button {
                    state.stopAllPlayback(keepingMetronome: true)
                    state.navigate(to: destination)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: destination.icon).font(.system(size: 15)).frame(width: 21)
                        Text(destination.rawValue).font(
                            .system(size: 13, weight: state.destination == destination ? .semibold : .regular))
                        Spacer()
                        if state.destination == destination { Circle().fill(Color.moss).frame(width: 4, height: 4) }
                    }.padding(.horizontal, 11).padding(.vertical, 10).background(
                        state.destination == destination ? Color.moss.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    ).contentShape(Rectangle())
                }.buttonStyle(.plain).help(destination.rawValue)
            }
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.destination.rawValue).font(.system(size: 18, weight: .medium, design: .serif))
                if state.destination != .practice {
                    Text(state.destination.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 20)
            if [.explore, .chords, .practice].contains(state.destination)
                && !(state.destination == .practice
                    && (state.pathwaySession != nil || state.practicePage != .exercises))
                && !(state.destination == .chords && state.showChanges)
            {
                let currentRoot = state.destination == .chords ? state.activeChordRoot : state.root
                ChoiceMenu(
                    title: "Root note",
                    selection: Binding(
                        get: { state.destination == .chords ? state.activeChordRoot : state.root },
                        set: { if state.destination == .chords { state.chordRoot = $0 } else { state.root = $0 } }),
                    options: Pitch.roots.contains(currentRoot) ? Pitch.roots : [currentRoot] + Pitch.roots,
                    label: { $0.name }
                ).frame(width: 85)
                if state.destination == .chords {
                    ChoiceMenu(
                        title: "Chord quality", selection: $state.quality, options: ChordQuality.allCases,
                        label: { $0.rawValue }
                    ).frame(width: 170)
                } else {
                    ChoiceMenu(
                        title: "Scale or mode", selection: $state.scale, options: Scale.allCases, label: { $0.rawValue }
                    ).frame(width: 190)
                }
            }
            if state.destination == .practice && state.practicePage == .home {
                Text("Listen · play · make it yours").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 9).frame(minHeight: 50)
    }
}
