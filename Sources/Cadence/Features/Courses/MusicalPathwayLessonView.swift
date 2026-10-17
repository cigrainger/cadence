// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct MusicalPathwayLessonView: View {
    @EnvironmentObject private var state: AppState
    let pathway: MusicalPathway
    let step: MusicalPathway.Step
    @State private var asset: BookAsset?
    @State private var page = 1
    @State private var error: String?
    @State private var editing: CourseLesson?
    @State private var scoreHeight: CGFloat = 210
    @State private var scoreError: String?
    @State private var metrics = ""
    @State private var notes = ""
    @State private var listened = false
    @State private var saved = false
    @State private var reading = false
    private var context: (CourseDefinition, CourseLesson)? { try? state.pathwayLesson(step) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button {
                    state.musicalPathwayStep = nil
                } label: {
                    Label("Your pathway", systemImage: "arrow.left")
                }.buttonStyle(.plain).foregroundStyle(Color.moss)
                Spacer()
                Text(
                    "\((pathway.steps.firstIndex(where:{ $0.id == step.id }) ?? 0)+1) of \(pathway.steps.count) · "
                        + step.role.rawValue
                ).font(.caption).foregroundStyle(.secondary)
            }
            if let (course, lesson) = context {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.system(size: 30, weight: .medium, design: .serif))
                    Text(lesson.goal).font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 16) {
                        if step.role == .compose {
                            composition(lesson)
                        } else {
                            if let link = course.link(lesson),
                                let score = state.editor.documents.first(where: { $0.id == link.scoreID })
                            {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("A small study").font(.system(size: 21, weight: .medium, design: .serif))
                                        Spacer()
                                        Button("Hear it", systemImage: "play.fill") {
                                            state.audio.play(score.playback(from: 0, through: score.barCount - 1))
                                        }
                                    }
                                    EditorRenderer(
                                        document: score, engine: "OpenSheetMusicDisplay", from: 0,
                                        through: min(3, score.barCount - 1), selection: nil, playhead: nil,
                                        select: { _ in }, height: $scoreHeight, error: $scoreError, metrics: $metrics
                                    ).frame(height: min(350, max(170, scoreHeight)))
                                    Text("Cadence-written practice arrangement · compare the idea with the source")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let scoreError { Text(scoreError).font(.caption).foregroundStyle(Color.clay) }
                                }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                            }
                            if !course.chapter.reviewed {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("A moment to make this yours").fontWeight(.medium)
                                    Text(
                                        "Read the linked source and the guidance below. You can edit any lesson; approve the chapter when its goals and exercises make sense to you."
                                    ).font(.caption).foregroundStyle(.secondary)
                                    Button("I checked this chapter’s guidance", systemImage: "checkmark") {
                                        perform { try state.reviewChapter(course.id) }
                                    }.disabled(asset == nil)
                                }.padding(16).background(
                                    Color.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                            }
                            CourseLessonView(
                                course: course, lesson: lesson, asset: asset, model: .recommended,
                                edit: { editing = lesson }, showTitle: false
                            ).id(lesson.learningIdentity)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("FROM YOUR BOOK").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(
                            Color.moss)
                        if let book = try? state.courseBook(course) {
                            Text(book.title).font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(3)
                            Text(book.author + " · " + lesson.source.label).font(.caption).foregroundStyle(.secondary)
                        }
                        if let asset {
                            Button("Open reading view", systemImage: "arrow.up.left.and.arrow.down.right") {
                                reading = true
                            }.controlSize(.small)
                            BookSourcePane(asset: asset, page: $page).frame(height: 560)
                        } else {
                            ContentUnavailableView(
                                "Opening the original", systemImage: "book.pages",
                                description: Text(error ?? "Your source stays beside the lesson.")
                            ).frame(height: 400)
                        }
                        if let asset, !asset.images(in: lesson.source).isEmpty {
                            Text(
                                "Illustrations stay as printed. The playable study is a separately labelled arrangement."
                            ).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(18).frame(width: 330).background(
                        Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                }
                if let index = pathway.steps.firstIndex(where: { $0.id == step.id }), index + 1 < pathway.steps.count {
                    HStack {
                        Spacer()
                        Button("Explore next: " + pathway.steps[index + 1].title, systemImage: "arrow.right") {
                            state.openMusicalStep(pathway.steps[index + 1])
                        }
                    }.padding(.top, 8)
                }
            }
            if let error { Text(error).foregroundStyle(Color.clay).font(.caption) }
        }.sheet(item: $editing) { if let (course, _) = context { CourseLessonEditor(course: course, draft: $0) } }
            .sheet(isPresented: $reading) {
                if let asset {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(asset.title).font(.headline)
                            Spacer()
                            Button("Done") { reading = false }
                        }
                        BookSourcePane(asset: asset, page: $page)
                    }.padding(24).frame(width: 740, height: 740)
                }
            }
            .task(id: step.id) {
                notes = pathway.compositionReflection
                if let id = pathway.compositionID, let score = state.editor.documents.first(where: { $0.id == id }) {
                    listened = pathway.compositionReviewedFingerprint == LibraryPiece(source: .score(score)).fingerprint
                }
                do {
                    let (course, lesson) = try state.pathwayLesson(step)
                    let book = try state.courseBook(course)
                    let value = try await state.loadBook(book)
                    guard CourseBook.digest(value.data) == book.digest else {
                        throw MusicError.invalid(
                            "The original book has changed. Restore its saved edition to keep these links accurate.")
                    }
                    asset = value
                    page = lesson.source.fromPage
                } catch { self.error = error.localizedDescription }
            }
    }
    private func composition(_ lesson: CourseLesson) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Four bars. Your choices.").font(.system(size: 26, weight: .medium, design: .serif))
                Text(lesson.practice).font(.callout)
                Text(
                    "1  Choose a progression\n2  Find nearby shapes\n3  Give the phrase a rhythm\n4  Listen, change one thing, keep it"
                ).font(.callout).lineSpacing(9).foregroundStyle(Color.moss)
                Button(
                    pathway.compositionID == nil ? "Start my composition" : "Continue my composition",
                    systemImage: "pencil.and.outline"
                ) { perform { try state.openPathwayComposition(pathway.id) } }.buttonStyle(.cadencePrimary).controlSize(
                    .large)
                Text(
                    "Starts with four empty piano bars and editable C–F–G–C chord symbols. You can change everything; it is saved under My compositions."
                ).font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(
                .white, in: RoundedRectangle(cornerRadius: 17))
            if let id = pathway.compositionID, let score = state.editor.documents.first(where: { $0.id == id }) {
                Card(title: "Listen to your choices", padding: 18, spacing: 12) {
                    Text(score.title + " · \(score.barCount) bars").font(.callout)
                    Button("Play my phrase", systemImage: "play.fill") {
                        state.audio.play(score.playback(from: 0, through: score.barCount - 1))
                    }.disabled(!score.events.contains { !$0.pitches.isEmpty })
                    TextField("Which change feels connected? What did you revise?", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...6)
                    Toggle("I listened back and made a musical choice", isOn: $listened).toggleStyle(.checkbox).font(
                        .caption)
                    Button("Save my reflection") {
                        perform {
                            try state.saveCompositionReflection(pathway.id, text: notes, listened: listened)
                            saved = true
                        }
                    }
                    if saved { Text("Reflection saved.").font(.caption).foregroundStyle(Color.moss) }
                    if let fingerprint = pathway.compositionReviewedFingerprint,
                        fingerprint != LibraryPiece(source: .score(score)).fingerprint
                    {
                        Text("Your phrase has changed since this reflection. Listen again when you’re ready.").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }
                    Text(
                        "Your reflection records your intention. It does not award an automatic performance or creativity grade."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("The idea in the book · paraphrase").font(.caption).foregroundStyle(.secondary)
                Text(lesson.bookSummary).font(.callout)
            }
        }.onChange(of: notes) { _, _ in saved = false }.onChange(of: listened) { _, _ in saved = false }
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
