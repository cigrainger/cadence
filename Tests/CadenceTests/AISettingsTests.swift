// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore
import XCTest

@testable import Cadence

@MainActor private final class SettingsFixture {
    var key = ""
    var model = "example/model"
    var reads = 0
    var writes = 0
    var failRead = false
    var failWrite = false
    var store: AISettingsStore {
        AISettingsStore(
            readKey: {
                self.reads += 1
                if self.failRead { throw MusicError.invalid("Keychain unavailable") }
                return self.key
            },
            writeKey: {
                self.writes += 1
                if self.failWrite { throw MusicError.invalid("Keychain write refused") }
                self.key = $0
            }, readModel: { self.model }, writeModel: { self.model = $0 })
    }
}

private actor CatalogGate {
    private(set) var calls = 0
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    func send() async -> (Data, HTTPURLResponse) {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func finish(_ data: Data) {
        pending?.resume(returning: AISettingsTests.reply(data))
        pending = nil
    }
}

private actor CatalogSequence {
    private var first = true
    func send(_ data: Data) throws -> (Data, HTTPURLResponse) {
        if first {
            first = false
            return AISettingsTests.reply(data)
        }
        throw URLError(.notConnectedToInternet)
    }
}

final class AISettingsTests: XCTestCase {
    fileprivate static func reply(_ data: Data, status: Int = 200) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: URL(string: "https://openrouter.ai/api/v1/models")!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: [:])!
        )
    }
    private static let catalog = Data(
        "{\"data\":[{\"id\":\"z\",\"name\":\"Zulu\"},{\"id\":\"a\",\"name\":\"Alpha\"}]}".utf8)

    @MainActor func testKeyReadIsLazyCachedAndFailureCanBeRetried() throws {
        let fixture = SettingsFixture()
        fixture.failRead = true
        let settings = AISettings(store: fixture.store)
        XCTAssertEqual(fixture.reads, 0)
        settings.checkKeyIfNeeded()
        XCTAssertEqual(fixture.reads, 1)
        XCTAssertNotNil(settings.credentialError)
        XCTAssertFalse(settings.isReady)
        fixture.failRead = false
        fixture.key = "test-key"
        settings.checkKeyIfNeeded()
        settings.checkKeyIfNeeded()
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertNil(settings.credentialError)
        XCTAssertTrue(settings.isReady)
        fixture.key = ""
        XCTAssertThrowsError(try settings.requestKey())
        XCTAssertFalse(settings.hasSavedKey)
    }

    @MainActor func testFailedKeyWritesPreserveSavedStateAndSuccessfulRemovalDisablesCoach() throws {
        let fixture = SettingsFixture()
        let settings = AISettings(store: fixture.store)
        try settings.saveKey("  test-key\n")
        XCTAssertEqual(fixture.key, "test-key")
        XCTAssertTrue(settings.isReady)
        fixture.failWrite = true
        XCTAssertThrowsError(try settings.saveKey(""))
        XCTAssertTrue(settings.hasSavedKey)
        XCTAssertEqual(fixture.key, "test-key")
        fixture.failWrite = false
        try settings.saveKey(" \n")
        XCTAssertFalse(settings.isReady)
        XCTAssertEqual(fixture.key, "")
    }

    @MainActor func testModelChoicePersistsWithoutRewritingCredentials() throws {
        let fixture = SettingsFixture()
        let settings = AISettings(store: fixture.store)
        try settings.saveKey("test-key")
        settings.model = " \n"
        XCTAssertEqual(fixture.model, " \n")
        XCTAssertFalse(settings.isReady)
        settings.model = "other/model"
        XCTAssertTrue(settings.isReady)
        XCTAssertEqual(settings.modelName, "other/model")
        XCTAssertEqual(fixture.writes, 1)
        let reopened = AISettings(store: fixture.store)
        XCTAssertEqual(reopened.model, "other/model")
    }

    @MainActor func testPreviewNeverTouchesStorageOrDownloadsModels() async throws {
        let fixture = SettingsFixture()
        let settings = AISettings(
            preview: true, store: fixture.store,
            catalog: .init { _ in
                XCTFail("Preview must not send a model-list request")
                return Self.reply(Self.catalog)
            })
        settings.checkKeyIfNeeded()
        settings.refreshKeyStatus()
        try settings.saveKey("test-key")
        settings.model = "changed"
        await settings.loadModels()
        XCTAssertThrowsError(try settings.requestKey())
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.model, "example/model")
        XCTAssertTrue(settings.models.isEmpty)
    }

    @MainActor func testPublicCatalogUsesNoCredentialAndSortsNames() async {
        let settings = AISettings(
            store: SettingsFixture().store,
            catalog: .init { request in
                XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.timeoutInterval, 30)
                return Self.reply(Self.catalog)
            })
        await settings.loadModels()
        XCTAssertFalse(settings.loadingModels)
        XCTAssertEqual(settings.models.map(\.id), ["a", "z"])
        settings.model = "a"
        XCTAssertEqual(settings.modelName, "Alpha")
        XCTAssertTrue(settings.modelStatus.contains("2 models"))
    }

    @MainActor func testConcurrentModelLoadsDoNotSendTwiceAndCancelledReplyCannotPublish() async throws {
        let gate = CatalogGate()
        let settings = AISettings(store: SettingsFixture().store, catalog: .init { _ in await gate.send() })
        let first = Task { await settings.loadModels() }
        for _ in 0..<100 {
            if await gate.calls == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(settings.loadingModels)
        await settings.loadModels()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        first.cancel()
        await gate.finish(Self.catalog)
        await first.value
        XCTAssertTrue(settings.models.isEmpty)
        XCTAssertFalse(settings.loadingModels)
        XCTAssertEqual(settings.modelStatus, "Model loading cancelled.")
    }

    @MainActor func testCatalogFailureKeepsManualChoice() async {
        let fixture = SettingsFixture()
        let settings = AISettings(
            store: fixture.store,
            catalog: .init { _ in
                throw URLError(.notConnectedToInternet)
            })
        await settings.loadModels()
        XCTAssertFalse(settings.loadingModels)
        XCTAssertFalse(settings.modelStatus.isEmpty)
        XCTAssertEqual(settings.model, "example/model")
        XCTAssertTrue(settings.models.isEmpty)
    }

    @MainActor func testFailedCatalogRefreshKeepsPreviouslyLoadedModelsAndSelection() async {
        let sequence = CatalogSequence()
        let settings = AISettings(
            store: SettingsFixture().store,
            catalog: .init { _ in
                try await sequence.send(Self.catalog)
            })
        await settings.loadModels()
        settings.model = "a"
        await settings.loadModels()
        XCTAssertEqual(settings.models.map(\.id), ["a", "z"])
        XCTAssertEqual(settings.modelName, "Alpha")
        XCTAssertFalse(settings.loadingModels)
        XCTAssertFalse(settings.modelStatus.isEmpty)
    }

    func testCatalogRejectsProviderErrorsMalformedOversizedAndDuplicateData() async {
        var invalid = [
            Data("not JSON".utf8), Data("{}".utf8),
            Data("{\"data\":[{\"id\":\"same\",\"name\":\"A\"},{\"id\":\"same\",\"name\":\"B\"}]}".utf8),
            Data("{\"data\":[{\"id\":\" \",\"name\":\"A\"}]}".utf8),
            Data("{\"data\":[{\"id\":\"a\",\"name\":\"\"}]}".utf8),
            Data(repeating: 32, count: 16_000_001),
        ]
        for entries in [
            [["id": String(repeating: "i", count: 257), "name": "A"]],
            [["id": "a", "name": String(repeating: "n", count: 257)]],
            (0...5000).map { ["id": "id-\($0)", "name": "Name"] },
        ] {
            if let data = try? JSONSerialization.data(withJSONObject: ["data": entries]) {
                invalid.append(data)
            } else {
                XCTFail("Invalid test fixture")
            }
        }
        for data in invalid {
            do {
                _ = try await AIModelCatalog { _ in Self.reply(data) }.load()
                XCTFail("Invalid catalog accepted")
            } catch {}
        }
        do {
            _ = try await AIModelCatalog { _ in Self.reply(Self.catalog, status: 429) }.load()
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("enter a model ID")) }
    }
}
