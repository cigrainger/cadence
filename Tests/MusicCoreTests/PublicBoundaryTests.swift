// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest

@testable import MusicCore

final class PublicBoundaryTests: XCTestCase {
    func testAIEndpointAcceptsOnlyTheExpectedHTTPSPost() throws {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        XCTAssertNoThrow(try OpenRouterTransport.validate(request))
        for address in [
            "http://openrouter.ai/api/v1/chat/completions",
            "https://openrouter.ai.evil.test/api/v1/chat/completions",
            "https://openrouter.ai@evil.test/api/v1/chat/completions",
            "https://person:secret@openrouter.ai/api/v1/chat/completions",
            "https://openrouter.ai:444/api/v1/chat/completions",
            "https://openrouter.ai/api/v1/chat/completions?key=example",
            "https://openrouter.ai/api/v1/chat/completions#fragment",
            "https://openrouter.ai/api/v1/models",
        ] {
            request.url = URL(string: address)
            XCTAssertThrowsError(try OpenRouterTransport.validate(request), address)
        }
        request.url = URL(string: "https://openrouter.ai/api/v1/chat/completions")
        request.httpMethod = "GET"
        XCTAssertThrowsError(try OpenRouterTransport.validate(request))
    }

    func testInvalidAIRequestNeverReachesTheInjectedNetworkSender() async {
        let transport = OpenRouterTransport { _ in
            XCTFail("An invalid destination reached the network boundary")
            throw URLError(.badURL)
        }
        do {
            _ = try await transport.perform(URLRequest(url: URL(string: "https://example.invalid")!))
            XCTFail("Expected destination rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No request was sent")) }
    }

    func testProviderErrorsAreRedactedBeforeTheyAreTruncated() {
        let detail = String(repeating: "credential-placeholder ", count: 200)
        let message = OpenRouterTransport.failure(status: 400, detail: detail, key: "credential-placeholder")
            .localizedDescription
        XCTAssertFalse(message.contains("credential-placeholder"))
        XCTAssertTrue(message.contains("[redacted]"))
        XCTAssertLessThan(message.count, 2100)
    }

    func testRendererCannotNavigateToOtherFilesOrWebsites() {
        let entry = URL(fileURLWithPath: "/tmp/cadence/ScoreViewer/index.html")
        XCTAssertTrue(LocalDocumentPolicy.allows(entry, entry: entry))
        XCTAssertTrue(LocalDocumentPolicy.allows(URL(string: entry.absoluteString + "#bar-2"), entry: entry))
        for candidate in [
            URL(string: "https://example.invalid"), URL(string: "javascript:alert(1)"),
            URL(string: "file://remote.example/tmp/cadence/ScoreViewer/index.html"),
            URL(string: entry.absoluteString + "?document=private.json"),
            URL(fileURLWithPath: "/tmp/cadence/ScoreViewer/../private.json"),
            URL(fileURLWithPath: "/tmp/cadence/ScoreViewer/index.html.bak"), nil,
        ] {
            XCTAssertFalse(LocalDocumentPolicy.allows(candidate, entry: entry))
        }
        XCTAssertFalse(LocalDocumentPolicy.allows(entry, entry: nil))
    }

    func testOversizedSnapshotIsPreservedAndCannotBeReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let bytes = Data(repeating: 32, count: 1025)
        try bytes.write(to: file)
        let store = JSONFileStore<String>(url: file, validate: { $0 }, maximumBytes: 1024)
        XCTAssertEqual(store.load(default: "fallback"), "fallback")
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.save("replacement"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testOversizedSaveDoesNotReplaceAValidSnapshot() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("previous"))
        }
        let store = JSONFileStore<String>(url: file, validate: { $0 }, maximumBytes: 64)
        _ = store.load(default: "original")
        try store.save("original")
        let previous = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.save(String(repeating: "x", count: 65)))
        XCTAssertEqual(try Data(contentsOf: file), previous)
        try store.save("recovered")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file)), "recovered")
    }

    func testRetiredRendererPreferenceMigratesWithoutLosingMusic() throws {
        var library = EditorLibrary()
        library.engine = "Smoosic"
        let restored = try library.restored()
        XCTAssertEqual(restored.engine, "OpenSheetMusicDisplay")
        XCTAssertEqual(restored.documents, library.documents)
    }
}
