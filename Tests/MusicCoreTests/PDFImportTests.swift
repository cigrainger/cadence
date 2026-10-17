// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PDFImportTests: XCTestCase {
    func testOriginalFixturesBecomeEditableWithWrittenGuitarOctaveAndVoices() throws {
        for source in [
            EditorDocument.guitarExample, .pianoExample, .innerVoiceExample, .fingerstyleExample,
            VisionExamples.compound,
        ] {
            let converted = try PDFTranscription(source).makeDocument(instrument: source.instrument)
            let actual = VisionTranscription(converted.document)
            let expected = VisionTranscription(source)
            XCTAssertEqual(actual.compare(to: expected).exactF1, 1)
            XCTAssertEqual(converted.document.minor, source.minor)
            XCTAssertEqual(converted.document.events.filter(\.tieNext).count, source.events.filter(\.tieNext).count)
            let reopened = try EditorXML.decode(Data(EditorXML.encode(converted.document).utf8))
            XCTAssertEqual(VisionTranscription(reopened).compare(to: expected).exactF1, 1)
        }
    }
    func testChordTonesAreGroupedWithoutChangingIndependentVoices() throws {
        var source = EditorDocument.innerVoiceExample
        let first = source.ordered(staff: 1)[0]
        try source.setPitch(first.id, midi: 72)
        try source.addChordTone(first.id)
        let converted = try PDFTranscription(source).makeDocument(instrument: .piano).document
        XCTAssertEqual(converted.inBar(0, staff: 1)[0].pitches.count, 2)
        XCTAssertEqual(converted.voices(staff: 1), [1, 2])
        XCTAssertEqual(
            converted.ordered(staff: 1, voice: 2).map { $0.pitches.map(\.midi) },
            source.ordered(staff: 1, voice: 2).map { $0.pitches.map(\.midi) })
    }
    func testMissingDurationsBecomeExplicitFlaggedRestsAndEmptyHandsAreComplete() throws {
        var data = PDFTranscription(.pianoExample)
        data.notes = [PDFWrittenNote(bar: 1, midi: 60, start: 1, duration: 1, step: "C", alter: 0)]
        let draft = try data.makeDocument(instrument: .piano)
        XCTAssertEqual(draft.document.inBar(0, staff: 1).map(\.isRest), [true, false, true])
        XCTAssertTrue(draft.document.ordered(staff: 2).allSatisfy(\.isRest))
        XCTAssertTrue(draft.warnings.contains { $0.contains("gaps") })
        _ = try draft.document.validated()
    }
    func testOverlapsDuplicatePitchesAndMixedRestsCannotSilentlyEraseMusic() throws {
        for issue in 0..<4 {
            var data = PDFTranscription(.pianoExample)
            var duplicate = data.notes[0]
            if issue == 1 { duplicate.midi = -1 }
            if issue == 2 { duplicate.duration = 2 }
            if issue == 3 {
                duplicate.start = 0.5
                duplicate.midi += 1
            }
            data.notes.append(duplicate)
            XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        }
    }
    func testUnsupportedStructureInvalidStaffAndOutOfBarRhythmsAreRejected() throws {
        var data = PDFTranscription(.pianoExample)
        data.unsupported = ["Changing meter"]
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        data = PDFTranscription(.pianoExample)
        data.notes[0].staff = 3
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        data = PDFTranscription(.pianoExample)
        data.notes[0].duration = 5
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        data = PDFTranscription(.pianoExample)
        data.notes[0].start = .infinity
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        data = PDFTranscription(.pianoExample)
        data.notes[0].duration = 0.12345
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
    }
    func testAccidentalsExpressionAndTiesSurviveButInconsistentSpellingsAreFlagged() throws {
        let source = VisionExamples.compound
        var data = PDFTranscription(source)
        let accidental = try XCTUnwrap(data.notes.firstIndex { $0.midi == 78 })
        data.notes[accidental].staccato = true
        data.notes[accidental].accent = true
        data.notes[accidental].dynamic = "mf"
        let draft = try data.makeDocument(instrument: .piano)
        let sharp = try XCTUnwrap(draft.document.events.first { $0.pitches.first?.midi == 78 })
        XCTAssertEqual(sharp.pitches[0].spelling, Pitch(3, 1))
        XCTAssertTrue(sharp.accent)
        XCTAssertTrue(sharp.staccato)
        XCTAssertEqual(sharp.dynamic, .mf)
        data.notes[accidental].step = "C"
        let repaired = try data.makeDocument(instrument: .piano)
        XCTAssertTrue(repaired.warnings.contains { $0.contains("spellings") })
        XCTAssertEqual(repaired.document.events.flatMap(\.pitches).first { $0.midi == 78 }?.midi, 78)
    }
    func testInvalidAndPartialTiesAreFlaggedRatherThanInventingConnections() throws {
        var data = PDFTranscription(.pianoExample)
        data.notes[0].tieNext = true
        let draft = try data.makeDocument(instrument: .piano)
        XCTAssertFalse(draft.document.events[0].tieNext)
        XCTAssertTrue(draft.warnings.contains { $0.contains("ties") })
        var chord = data.notes[0]
        chord.midi = 72
        chord.tieNext = false
        data.notes.append(chord)
        let partial = try data.makeDocument(instrument: .piano)
        XCTAssertFalse(partial.document.events[0].tieNext)
        XCTAssertTrue(partial.warnings.contains { $0.contains("ties") })
    }
    func testBoundsMalformedOutputAndUnplayableGuitarAreRejected() throws {
        XCTAssertThrowsError(try PDFTranscription.decode("not notation"))
        var data = PDFTranscription(.guitarExample)
        data.notes[0].midi = 30
        XCTAssertThrowsError(try data.makeDocument(instrument: .guitar))
        data = PDFTranscription(.pianoExample)
        data.barCount = 33
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        data = PDFTranscription(.pianoExample)
        data.tempo = 0
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
        data = PDFTranscription(.pianoExample)
        data.notes = []
        XCTAssertThrowsError(try data.makeDocument(instrument: .piano))
    }
    func testSourceProvenanceIsOptionalForOldScoresAndRetainedInExactCopies() throws {
        var document = EditorDocument.guitarExample
        let old = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document))
        XCTAssertNil(old.pdfSource)
        document.pdfSource = PDFScoreSource(
            filename: "Guitar method.pdf", page: 21, model: PDFImportModel.astra.rawValue, costUSD: 0.12,
            warnings: ["Check ties"], reviewed: true)
        let copy = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document)).validated()
        XCTAssertEqual(copy, document)
        XCTAssertTrue(copy.pdfSource?.reviewed == true)
        document.pdfSource?.page = 0
        XCTAssertThrowsError(try document.validated())
    }
    func testRequestUsesSelectedPageNativeParserSchemaAndZDRWithoutCredentialInBody() async throws {
        let transcription = PDFTranscription(.pianoExample)
        let text = String(decoding: try JSONEncoder().encode(transcription), as: UTF8.self)
        let client = PDFTranscriptionClient { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-key"))
            XCTAssertEqual(json["model"] as? String, PDFImportModel.astra.rawValue)
            let provider = try XCTUnwrap(json["provider"] as? [String: Any])
            XCTAssertEqual(provider["zdr"] as? Bool, true)
            XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
            XCTAssertEqual(provider["require_parameters"] as? Bool, true)
            XCTAssertEqual(provider["data_collection"] as? String, "deny")
            XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
            let format = try XCTUnwrap(json["response_format"] as? [String: Any])
            let definition = try XCTUnwrap(format["json_schema"] as? [String: Any])
            let schema = try XCTUnwrap(definition["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let structural = try XCTUnwrap(properties["unsupported"] as? [String: Any])
            let items = try XCTUnwrap(structural["items"] as? [String: Any])
            XCTAssertEqual(
                Set(items["enum"] as? [String] ?? []),
                Set([
                    "pickup_or_incomplete_bar", "changing_key", "changing_meter", "more_than_two_voices",
                    "cross_staff_voice", "unsupported_tuplet",
                ]))
            let harmonies = try XCTUnwrap(properties["harmonies"] as? [String: Any])
            let harmonyItem = try XCTUnwrap(harmonies["items"] as? [String: Any])
            XCTAssertEqual(Set(harmonyItem["required"] as? [String] ?? []), Set(["bar", "start", "staff", "symbol"]))
            XCTAssertTrue((schema["required"] as? [String] ?? []).contains("harmonies"))
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
            let file = try XCTUnwrap(content.last?["file"] as? [String: Any])
            XCTAssertEqual(
                file["file_data"] as? String,
                "data:application/pdf;base64," + Data("%PDF-selected-page".utf8).base64EncodedString())
            let plugins = try XCTUnwrap(json["plugins"] as? [[String: Any]])
            XCTAssertEqual((plugins[0]["pdf"] as? [String: Any])?["engine"] as? String, "native")
            let reply: [String: Any] = [
                "model": "resolved/model", "usage": ["cost": 0.03],
                "choices": [["finish_reason": "stop", "message": ["content": text]]],
            ]
            return (
                try JSONSerialization.data(withJSONObject: reply),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let reply = try await client.transcribe(
            pagePDF: Data("%PDF-selected-page".utf8), instrument: .piano, model: .astra, apiKey: "fixture-key")
        XCTAssertEqual(reply.transcription, transcription)
        XCTAssertEqual(reply.model, "resolved/model")
        XCTAssertEqual(reply.costUSD, 0.03)
    }
    func testGeminiImportExplicitlyRequestsHighReasoningWithRoomForOutput() async throws {
        for model in [PDFImportModel.argon, .flash] {
            let client = PDFTranscriptionClient { request in
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
                XCTAssertEqual(json["max_tokens"] as? Int, 32768)
                XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_object")
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                XCTAssertTrue((content[0]["text"] as? String)?.contains("pickup_or_incomplete_bar") == true)
                return (
                    Data(
                        #"{"choices":[{"finish_reason":"length","message":{"content":""}}],"usage":{"cost":0.04}}"#.utf8
                    ), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            do {
                _ = try await client.transcribe(
                    pagePDF: Data("%PDF-fixture".utf8), instrument: .guitar, model: model, apiKey: "fixture")
                XCTFail("Truncated score must fail")
            } catch { XCTAssertTrue(error.localizedDescription.contains("US$0.0400")) }
        }
    }
    func testPaidFailuresDoNotRetryAndMissingKeyDoesNotCallTransport() async {
        var calls = 0
        let client = PDFTranscriptionClient { request in
            calls += 1
            return (
                Data(#"{"error":{"message":"No ZDR endpoint"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await client.transcribe(pagePDF: Data("%PDF-fixture".utf8), instrument: .guitar, apiKey: "")
            XCTFail()
        } catch {}
        XCTAssertEqual(calls, 0)
        do {
            _ = try await client.transcribe(pagePDF: Data("%PDF-fixture".utf8), instrument: .guitar, apiKey: "fixture")
            XCTFail()
        } catch {}
        XCTAssertEqual(calls, 1)
    }
    func testCancellationDiscardsACompletedResponse() async throws {
        let text = String(decoding: try JSONEncoder().encode(PDFTranscription(.pianoExample)), as: UTF8.self)
        let client = PDFTranscriptionClient { request in
            withUnsafeCurrentTask { $0?.cancel() }
            let reply: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
            return (
                try JSONSerialization.data(withJSONObject: reply),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let task = Task {
            try await client.transcribe(pagePDF: Data("%PDF-fixture".utf8), instrument: .piano, apiKey: "fixture")
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled request must not create a draft")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation result: \(error)") }
    }
    func testSolUsesHighReasoningStrictSchemaAndTheSamePrivacyControls() async throws {
        let text = String(decoding: try JSONEncoder().encode(PDFTranscription(.pianoExample)), as: UTF8.self)
        let client = PDFTranscriptionClient { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "openai/gpt-6.1-sol")
            XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
            XCTAssertEqual(json["max_tokens"] as? Int, 32768)
            XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
            let provider = try XCTUnwrap(json["provider"] as? [String: Any])
            XCTAssertEqual(provider["zdr"] as? Bool, true)
            XCTAssertEqual(provider["require_parameters"] as? Bool, true)
            XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
            XCTAssertEqual(provider["data_collection"] as? String, "deny")
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-secret"))
            let reply: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
            return (
                try JSONSerialization.data(withJSONObject: reply),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        _ = try await client.transcribe(
            pagePDF: Data("%PDF-fixture".utf8), instrument: .piano, model: .sol, apiKey: "test-secret")
    }
    func testDefaultImportUsesSolHighWithoutChangingExplicitChoices() async throws {
        let client = PDFTranscriptionClient { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "openai/gpt-6.1-sol")
            XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
            XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
            throw URLError(.badServerResponse)
        }
        do {
            _ = try await client.transcribe(pagePDF: Data("%PDF-fixture".utf8), instrument: .guitar, apiKey: "test")
            XCTFail()
        } catch {}
    }
    func testTotalDeadlineCancelsBusyTransportWithoutRetry() async throws {
        let started = expectation(description: "request started")
        let cancelled = expectation(description: "request cancelled")
        var calls = 0
        let client = PDFTranscriptionClient(deadline: 0.08) { _ in
            calls += 1
            started.fulfill()
            do {
                // Activity must not reset the total deadline.
                while true { try await Task.sleep(nanoseconds: 5_000_000) }
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        let before = Date()
        do {
            _ = try await client.transcribe(pagePDF: Data("%PDF-fixture".utf8), instrument: .guitar, apiKey: "test")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("four minutes"))
            XCTAssertTrue(error.localizedDescription.contains("has not retried"))
        }
        await fulfillment(of: [started, cancelled], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(before), 2)
        XCTAssertEqual(calls, 1)
    }
    func testStoppingAnInFlightRequestCancelsTransportPromptly() async throws {
        let started = expectation(description: "request started")
        let cancelled = expectation(description: "request cancelled")
        let client = PDFTranscriptionClient { _ in
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw URLError(.badServerResponse)
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        let task = Task {
            try await client.transcribe(pagePDF: Data("%PDF-fixture".utf8), instrument: .piano, apiKey: "test")
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled import returned a draft")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [cancelled], timeout: 1)
    }
}
