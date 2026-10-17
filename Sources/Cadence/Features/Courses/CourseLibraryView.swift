// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct BookChaptersView: View {
    @EnvironmentObject private var state: AppState
    @State private var newChapter = false
    @State private var error: String?
    private var selection: CourseDefinition? {
        state.courses.courses.first { $0.id == state.courseSelection } ?? state.courses.courses.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your books, brought to life").font(.system(size: 26, weight: .medium, design: .serif))
                    Text("Read a section, explore its music, and shape your own lessons.").foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                Button("Try original chapter") { perform { try CourseExamples.install(state: state) } }
                Button("Add a chapter", systemImage: "plus") { newChapter = true }.buttonStyle(.cadencePrimary)
            }
            if let error { Text(error).foregroundStyle(Color.clay).font(.caption).textSelection(.enabled) }
            if let course = selection {
                if state.courses.courses.count > 1 {
                    Picker("Chapter", selection: Binding(get: { course.id }, set: { state.showCourse($0) })) {
                        ForEach(state.courses.courses) { Text($0.chapter.title).tag($0.id) }
                    }.frame(maxWidth: 500)
                }
                CourseChapterView(course: course, request: state.courseOutline).id(course.id)
            } else {
                ContentUnavailableView(
                    "Begin with a chapter", systemImage: "book.pages",
                    description: Text(
                        "Choose an EPUB section or up to eight PDF pages. Build your own outline or ask your model to propose one, then check it against the book. The original example works offline."
                    )
                ).frame(minHeight: 350)
            }
        }.sheet(isPresented: $newChapter) { NewCourseChapterView() }
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct NewCourseChapterView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var asset: BookAsset?
    @State private var title = ""
    @State private var author = ""
    @State private var edition = ""
    @State private var chapter = "My first chapter"
    @State private var from = 1
    @State private var through = 1
    @State private var page = 1
    @State private var instrument = EditorInstrument.piano
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Bring a chapter to life").font(.system(size: 28, weight: .medium, design: .serif))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Button(asset?.filename ?? "Choose EPUB or PDF…", systemImage: "folder") { choose() }.disabled(busy)
                    if let asset {
                        BookSourcePane(asset: asset, page: $page)
                    } else {
                        ContentUnavailableView(
                            "Your original stays with the course", systemImage: "book.closed",
                            description: Text(
                                "EPUB brings searchable text and illustrations. PDF keeps the printed page. Choose a short section to begin."
                            ))
                    }
                }.frame(width: 390, height: 540)
                VStack(alignment: .leading, spacing: 15) {
                    TextField("Book title", text: $title).textFieldStyle(.roundedBorder)
                    TextField("Author (optional)", text: $author).textFieldStyle(.roundedBorder)
                    TextField("Edition (optional)", text: $edition).textFieldStyle(.roundedBorder)
                    TextField("Chapter title", text: $chapter).textFieldStyle(.roundedBorder)
                    Picker("Instrument", selection: $instrument) {
                        ForEach(EditorInstrument.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if let asset {
                        Stepper("First \(asset.unit.lowercased()): \(from)", value: $from, in: 1...asset.pageCount)
                        Stepper(
                            "Last \(asset.unit.lowercased()): \(through)", value: $through,
                            in: from...min(asset.pageCount, from + 7))
                        Text(
                            asset.epub == nil
                                ? "\(through-from+1) pages · use PDF positions, not printed page numbers."
                                : "\(through-from+1) reading sections · use Contents to find your starting point.")
                        Button("Start at the section I’m reading") {
                            from = page
                            through = page
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text(
                        "Create the local chapter first. You can edit every lesson yourself, or explicitly request an AI outline afterward."
                    ).font(.callout).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
                    Spacer()
                    Button("Create chapter") { create() }.buttonStyle(.cadencePrimary).disabled(
                        asset == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }.frame(width: 350, height: 540)
            }
        }.padding(24).onChange(of: from) { _, value in
            through = min(asset?.pageCount ?? 1, max(value, min(through, value + 7)))
            page = value
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub"), .pdf].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    asset = try await BookAsset.read(url)
                    title = asset!.title
                    author = asset?.epub?.author ?? ""
                    from = 1
                    through = min(8, asset!.pageCount)
                    page = 1
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func create() {
        guard let asset else { return }
        do {
            try state.createBookCourse(
                asset: asset, title: title, author: author, edition: edition, chapterTitle: chapter, from: from,
                through: through, instrument: instrument)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CourseChapterView: View {
    @EnvironmentObject private var state: AppState
    let course: CourseDefinition
    @ObservedObject var request: SavedRequest<CourseOutlineReply>
    @State private var asset: BookAsset?
    @State private var sourceError: String?
    @State private var error: String?
    @State private var page = 1
    @State private var model = PDFImportModel.recommended
    @State private var editing: CourseLesson?
    @State private var showHistory = false
    @State private var showOutlineTools = false
    private var selected: CourseLesson {
        course.chapter.lessons.first { $0.id == state.courseLessonSelection } ?? course.chapter.lessons[0]
    }
    private var locked: Bool { course.outlineJob?.status == .reading || request.pending != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            chapterHeader
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The original").font(.system(size: 19, weight: .medium, design: .serif))
                    Text(course.chapter.source.label).font(.caption).foregroundStyle(.secondary)
                    if let asset {
                        BookSourcePane(asset: asset, page: $page).frame(height: 470)
                    } else {
                        ContentUnavailableView(
                            "Original unavailable", systemImage: "doc",
                            description: Text(sourceError ?? "Opening the saved book…")
                        ).frame(height: 400)
                    }
                    Text(
                        "Book content and your learning guidance stay separately labelled. Check each lesson's page and exercise boundaries."
                    ).font(.caption).foregroundStyle(.secondary)
                    if let book = try? state.courseBook(course), asset != nil {
                        Button("Open original book", systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.open(state.courseBookURL(book))
                        }.controlSize(.small)
                    }
                }.frame(width: 300)
                VStack(alignment: .leading, spacing: 14) {
                    if !course.chapter.reviewed {
                        DisclosureGroup("Build your outline · optional AI proposal", isExpanded: $showOutlineTools) {
                            outlineControls.padding(.top, 8)
                        }
                        Text(
                            "Check the lessons against the original. Edit any lesson or add your own, then approve the outline below."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(course.chapter.reviewed ? "Your lessons" : "Review the lessons").font(
                            .system(size: 21, weight: .medium, design: .serif))
                        Spacer()
                        Button("Add lesson", systemImage: "plus") { addLesson() }.disabled(
                            locked || course.chapter.lessons.count >= 12)
                    }
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach(Array(course.chapter.lessons.enumerated()), id: \.element.id) { index, lesson in
                                Button {
                                    state.courseLessonSelection = lesson.id
                                    page = lesson.source.fromPage
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit())
                                            .foregroundStyle(Color.moss)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(lesson.title).fontWeight(.medium)
                                            Text(lesson.source.label + " · " + lesson.kind.rawValue).font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(
                                            systemName: lesson.kind == .music
                                                ? ((try? state.readyCourseScore(course, lesson)) != nil
                                                    ? "checkmark.circle" : "music.note") : "text.book.closed"
                                        ).foregroundStyle(Color.moss)
                                    }.padding(10).background(
                                        selected.id == lesson.id ? Color.moss.opacity(0.10) : Color.white.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: CGFloat(min(4, course.chapter.lessons.count)) * 56)
                    CourseLessonView(
                        course: course, lesson: selected, asset: asset, model: model, edit: { editing = selected }
                    ).id(selected.learningIdentity).disabled(locked)
                    if !course.chapter.reviewed {
                        Button("I checked this outline against the chapter", systemImage: "checkmark.seal") {
                            perform { try state.reviewChapter(course.id) }
                        }.buttonStyle(.cadencePrimary).disabled(locked || asset == nil)
                        Text(
                            "This approves the lesson outline. Each musical exercise still needs a notation review before assessed practice."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if course.chapter.reviewed { suggestions.id("course-session") }
        }
        .sheet(item: $editing) { CourseLessonEditor(course: course, draft: $0) }
        .sheet(isPresented: $showHistory) { CourseHistoryView(course: course) }
        .task(id: course.chapter.source.bookID) {
            page = selected.source.fromPage
            do {
                let book = try state.courseBook(course)
                let value = try await state.loadBook(book)
                guard CourseBook.digest(value.data) == book.digest else {
                    throw MusicError.invalid("The saved book changed. Restore its original bytes from your backup.")
                }
                asset = value
                if state.isPreview { CourseDiagnostics.checks["sourceLoaded"] = value.pageCount == 3 }
            } catch { sourceError = error.localizedDescription }
        }
        .onChange(of: state.courseLessonSelection) { _, _ in page = selected.source.fromPage }
    }
    private var chapterHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(course.chapter.title).font(.system(size: 23, weight: .medium, design: .serif))
                Spacer()
                Text(course.chapter.reviewed ? "Outline reviewed" : "Outline needs review").font(.caption)
                    .foregroundStyle(Color.moss)
                if !course.history.isEmpty {
                    Button("Revisions (\(course.history.count))") { showHistory = true }.controlSize(.small)
                }
            }
            if let book = try? state.courseBook(course) {
                Text([book.title, book.author, book.edition].filter { !$0.isEmpty }.joined(separator: " · ")).font(
                    .caption
                ).foregroundStyle(.secondary)
            }
            Text(course.chapter.summary).font(.callout)
            Text("Started from: " + course.chapter.origin + " · revision \(course.chapter.revision)").font(.caption)
                .foregroundStyle(.secondary)
            ForEach(course.chapter.caveats, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.clay) }
        }
    }
    private var outlineControls: some View {
        Card(title: "Your outline, with optional help", padding: 14, spacing: 10) {
            Text(
                "Edit or add lessons below. An AI proposal replaces this outline; its previous version stays in Revisions. Only \(course.chapter.source.label.lowercased()) will be sent."
            ).font(.caption).foregroundStyle(.secondary)
            Picker("Model", selection: $model) {
                ForEach(PDFImportModel.allCases, id: \.self) { Text($0.name).tag($0) }
            }.disabled(locked)
            HStack {
                Button("Propose outline", systemImage: "sparkles") {
                    perform {
                        if let asset {
                            try state.startBookOutline(
                                course.id, asset: asset, instrument: selected.instrument, model: model)
                        }
                    }
                }.disabled(locked || asset == nil || state.isPreview)
                if request.busy {
                    ProgressView().controlSize(.small)
                    Button("Stop") { state.stopCourseOutline(course.id) }
                }
                if request.pending != nil { Button("Save received reply again") { request.retrySave() } }
            }
            if let start = request.started {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("\(max(0,Int(context.date.timeIntervalSince(start)))) seconds · four-minute limit").font(
                        .caption.monospacedDigit())
                }
            }
            if let problem = request.error ?? course.outlineJob?.error {
                Text(problem).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            if let job = course.outlineJob {
                Text(
                    String(format: "Reported total: US$%.4f", job.costUSD)
                        + (job.unpricedAttempts > 0
                            ? " · \(job.unpricedAttempts) request(s) without a reported cost" : "")
                ).font(.caption)
            }
            Text(
                "Uses your OpenRouter key from Settings, with ZDR required. No automatic retries. Saving a received reply does not send another request."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var suggestions: some View {
        Card(title: "A small next session", padding: 16, spacing: 12) {
            let suggestions = state.courseSuggestions(course)
            if suggestions.isEmpty {
                Text("Explore any lesson, or add a reflection about what to try next.").font(.callout)
            }
            ForEach(suggestions) { item in
                if let lesson = course.chapter.lessons.first(where: { $0.id == item.lessonID }) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(lesson.title).fontWeight(.medium)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open lesson") {
                            state.courseLessonSelection = lesson.id
                            page = lesson.source.fromPage
                        }
                    }
                }
            }
            Text(
                "Suggestions use this reviewed music, your reflections and recorded practice. Reviews keep their existing spacing; all lessons remain open."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func addLesson() {
        guard let book = try? state.courseBook(course) else { return }
        editing = CourseLesson(
            title: "New lesson",
            source: CourseSourceAnchor(
                book: book, from: course.chapter.source.fromPage, through: course.chapter.source.fromPage),
            kind: .explanation, instrument: selected.instrument, goal: "Describe the musical goal.",
            practice: "Describe one small thing to try.", readyWhen: "Describe what to listen or look for.")
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
