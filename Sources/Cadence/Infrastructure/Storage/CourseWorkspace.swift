// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

/// Course content and source links have one owner. Practice evidence remains in
/// PracticeWorkspace; a failed course write cannot publish an approval or a route.
@MainActor final class CourseWorkspace: ObservableObject {
    @Published var library = CourseLibrary()
    let outline = SavedRequest<CourseOutlineReply>()
    private let storage: WorkspaceStorage
    private let ephemeral: Bool
    private var outlineCourseID: UUID?

    init(storage: WorkspaceStorage, ephemeral: Bool = false) {
        self.storage = storage
        self.ephemeral = ephemeral
    }

    var loadError: String? { storage.courses.loadError }

    func load() { library = storage.courses.load(default: CourseLibrary()) }

    func course(_ id: UUID) throws -> CourseDefinition {
        guard let course = library.courses.first(where: { $0.id == id }) else {
            throw MusicError.invalid("This chapter is no longer available.")
        }
        return course
    }

    func commit(_ candidate: CourseLibrary) throws {
        if let loadError { throw MusicError.invalid(loadError) }
        _ = try candidate.validated()
        if !ephemeral { try storage.courses.save(candidate) }
        library = candidate
    }

    func change(_ id: UUID, _ change: (inout CourseDefinition) throws -> Void) throws {
        var candidate = library
        guard let index = candidate.courses.firstIndex(where: { $0.id == id }) else {
            throw MusicError.invalid("This chapter is no longer available.")
        }
        try change(&candidate.courses[index])
        try commit(candidate)
    }

    func save() throws {
        if let loadError { throw MusicError.invalid(loadError) }
        if !ephemeral { try storage.courses.save(library) }
    }

    func startOutline(
        _ id: UUID, model: PDFImportModel, instrument: EditorInstrument,
        operation: @escaping () async throws -> CourseOutlineReply
    ) throws {
        guard !outline.busy, outline.pending == nil else {
            throw MusicError.invalid("Finish or save the current chapter reply first.")
        }
        let original = try course(id)
        guard let book = library.books.first(where: { $0.id == original.chapter.source.bookID }) else {
            throw MusicError.invalid("The chapter's original book is unavailable.")
        }
        let job = CourseOutlineJob(model: model.rawValue, previous: original.outlineJob)
        try change(id) { $0.outlineJob = job }
        outlineCourseID = id
        outline.run { [weak self] in
            do { return try await operation() } catch {
                try? self?.change(id) { current in
                    guard current.outlineJob?.id == job.id, current.outlineJob?.status == .reading else { return }
                    current.outlineJob?.status = Task.isCancelled ? .stopped : .failed
                    current.outlineJob?.error = String(error.localizedDescription.prefix(4000))
                }
                throw error
            }
        } commit: { [weak self] reply in
            guard let self else { throw MusicError.invalid("The course workspace is no longer available.") }
            try self.change(id) { current in
                guard current.outlineJob?.id == job.id, current.outlineJob?.status == .reading,
                    current.chapter.identity == original.chapter.identity
                else {
                    throw MusicError.invalid("This outline belongs to an earlier chapter. Your current work is kept.")
                }
                let proposal = try reply.outline.chapter(
                    source: original.chapter.source, book: book, instrument: instrument,
                    origin: "AI proposal · " + reply.model)
                current.revise(proposal)
                current.outlineJob?.status = .ready
                current.outlineJob?.error = nil
                if let cost = reply.costUSD {
                    guard cost.isFinite, (0...10000).contains(cost) else {
                        throw MusicError.invalid("Invalid reported request cost.")
                    }
                    current.outlineJob?.costUSD += cost
                    current.outlineJob?.unpricedAttempts -= 1
                }
            }
        }
    }

    func stopOutline(_ id: UUID) throws {
        // A different chapter's navigation cannot cancel this chapter's work.
        guard outlineCourseID == id, outline.pending == nil else { return }
        outline.cancel()
        try change(id) {
            if $0.outlineJob?.status == .reading {
                $0.outlineJob?.status = .stopped
                $0.outlineJob?.error = "Stopped. Work already sent may still be charged. No retry was made."
            }
        }
    }
}
