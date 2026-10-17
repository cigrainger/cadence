// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import MusicCore
import XCTest

@testable import Cadence

final class CourseWorkspaceTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor func testCommitPublishesOnceAfterWriteAndCorruptionBlocksReplacement() throws {
        let dir = try folder()
        let storage = WorkspaceStorage(directory: dir)
        let owner = CourseWorkspace(storage: storage)
        owner.load()
        var events = 0
        let observation = owner.objectWillChange.sink {
            events += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.courses.url.path))
        }
        try owner.commit(CourseLibrary())
        XCTAssertEqual(events, 1)
        XCTAssertThrowsError(try owner.course(UUID()))
        XCTAssertThrowsError(try owner.change(UUID()) { $0.chapter.title = "Missing" })
        let original = Data("broken".utf8)
        try original.write(to: storage.courses.url)
        let reopened = CourseWorkspace(storage: WorkspaceStorage(directory: dir))
        reopened.load()
        XCTAssertNotNil(reopened.loadError)
        XCTAssertThrowsError(try reopened.commit(CourseLibrary()))
        XCTAssertThrowsError(try reopened.save())
        XCTAssertEqual(try Data(contentsOf: storage.courses.url), original)
        withExtendedLifetime(observation) {}
    }
    @MainActor func testEphemeralWorkspaceDoesNotWriteAndRejectsInvalidContent() throws {
        let dir = try folder()
        let owner = CourseWorkspace(storage: WorkspaceStorage(directory: dir), ephemeral: true)
        try owner.commit(CourseLibrary())
        try owner.save()
        var invalid = CourseLibrary()
        invalid.schemaVersion = Int.max
        XCTAssertThrowsError(try owner.commit(invalid))
        XCTAssertEqual(owner.library, CourseLibrary())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}

extension CourseWorkspaceTests {
    @MainActor func testNavigatingToAnotherChapterCannotCancelTheActiveOutline() async throws {
        let state = AppState(storageOverride: try folder())
        defer { state.midi.shutdown() }
        let id = try CourseExamples.install(state: state)
        var gate: CheckedContinuation<Void, Never>?
        try state.startCourseRequest(id, model: .sol, instrument: .piano) {
            await withCheckedContinuation { gate = $0 }
            throw MusicError.invalid("Stopped fixture request")
        }
        for _ in 0..<1000 {
            if gate != nil { break }
            await Task.yield()
        }
        let continuation = try XCTUnwrap(gate)
        state.stopCourseOutline(UUID())
        XCTAssertTrue(state.courseOutline.busy)
        XCTAssertEqual(try state.course(id).outlineJob?.status, .reading)
        state.stopCourseOutline(id)
        XCTAssertFalse(state.courseOutline.busy)
        XCTAssertEqual(try state.course(id).outlineJob?.status, .stopped)
        continuation.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(try state.course(id).outlineJob?.status, .stopped)
    }
}
