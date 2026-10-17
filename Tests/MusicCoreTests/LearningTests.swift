// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class LearningTests: XCTestCase {
    private var brief: LearningBrief { LearningBrief(target: "Play a relaxed accompaniment") }
    private func outline() -> PathwayOutline {
        let activity = PathwayActivity(
            title: "Keep a pulse", instructions: "Tap four even beats, then play one chord slowly.", minutes: 10)
        let step = PathwayStep(
            title: "Steady pulse", focus: "Keep time while preparing a change.", activities: [activity],
            application: "Use it in a simple accompaniment.", readyWhen: "Eight bars at a comfortable, even tempo.",
            tool: .rhythm)
        return PathwayOutline(
            title: "A steady accompaniment", summary: "Repeat short sessions until comfortable.",
            sourceNotes: "A provisional plan based on the learner’s description.", questions: [],
            steps: [step, step, step])
    }
    func testPathwayParsesJSONAndMarkdownFences() throws {
        let plan = outline()
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertEqual(try PathwayOutline.decodeReply(json, brief: brief), plan)
        XCTAssertEqual(try PathwayOutline.decodeReply("```json\n" + json + "\n```", brief: brief), plan)
        XCTAssertThrowsError(try PathwayOutline.decodeReply("Here are some ideas without a plan", brief: brief))
        XCTAssertThrowsError(try PathwayOutline.decodeReply("{\"title\":\"Incomplete\"}", brief: brief))
    }
    func testRejectsIncompleteAndUnrealisticSessions() throws {
        var plan = outline()
        plan.steps[0].activities[0].minutes = 21
        XCTAssertThrowsError(try plan.validated(minutesPerSession: 20))
        plan.steps[0].activities[0].minutes = 0
        XCTAssertThrowsError(try plan.validated(minutesPerSession: 20))
        plan = outline()
        plan.steps[0].activities = []
        XCTAssertThrowsError(try plan.validated(minutesPerSession: 20))
        plan = outline()
        plan.steps[0].readyWhen = "   "
        XCTAssertThrowsError(try plan.validated(minutesPerSession: 20))
        plan = outline()
        plan.steps.removeLast()
        XCTAssertThrowsError(try plan.validated(minutesPerSession: 20))
    }
    func testBriefValidationAndContext() throws {
        var input = LearningBrief(target: "  Fingerstyle folk\n", detail: "Clear alternating bass")
        input.focus = .style
        input.profile.instrument = .piano
        XCTAssertEqual(try input.validated().target, "Fingerstyle folk")
        XCTAssertTrue(input.context.contains("Piano"))
        input.profile.minutesPerSession = 0
        XCTAssertThrowsError(try input.validated())
        input.profile.minutesPerSession = 20
        input.profile.sessionsPerWeek = 8
        XCTAssertThrowsError(try input.validated())
        input.profile.sessionsPerWeek = 4
        input.target = "  "
        XCTAssertThrowsError(try input.validated())
    }
    func testLibraryRestoresProfileNotesAndReadiness() throws {
        var library = LearningLibrary()
        library.profile.instrument = .both
        let path = LearningPathway(brief: brief, outline: outline())
        library.add(path)
        library.toggleStep(0, in: path.id)
        library.toggleStep(2, in: path.id)
        library.pathways[0].notes = "The second chord change is still difficult."
        let restored = try JSONDecoder().decode(LearningLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored, library)
        XCTAssertEqual(restored.activePathway?.completedCount, 2)
        XCTAssertEqual(restored.activePathway?.nextStep, 1)
        XCTAssertTrue(restored.activePathway!.coachContext.contains("second chord change"))
        let before = library
        library.toggleStep(-1, in: path.id)
        library.toggleStep(99, in: path.id)
        XCTAssertEqual(library, before)
        library.toggleStep(0, in: path.id)
        XCTAssertEqual(library.activePathway?.completedCount, 1)
    }
    func testRevisionKeepsOriginalProgressAndProfileSnapshot() {
        var library = LearningLibrary()
        let original = LearningPathway(brief: brief, outline: outline())
        library.add(original)
        library.toggleStep(0, in: original.id)
        var revisedBrief = brief
        revisedBrief.profile.minutesPerSession = 10
        let revised = LearningPathway(brief: revisedBrief, outline: outline())
        library.add(revised)
        XCTAssertEqual(library.pathways.count, 2)
        XCTAssertEqual(library.activePathway?.id, revised.id)
        XCTAssertEqual(library.pathways[1].completedSteps, [0])
        XCTAssertTrue(library.pathways[0].completedSteps.isEmpty)
        XCTAssertEqual(library.pathways[1].brief.profile.minutesPerSession, 20)
    }
    func testPracticeToolsAndUnknownModelTool() throws {
        XCTAssertEqual(PathwayTool.rhythm.exercise, .rhythm)
        XCTAssertEqual(PathwayTool.scaleDegrees.exercise, .functional)
        XCTAssertEqual(PathwayTool.triadSpelling.exercise, .triads)
        XCTAssertEqual(PathwayTool.keySignatures.exercise, .signatures)
        XCTAssertEqual(PathwayTool.chordQuality.exercise, .chords)
        XCTAssertNil(PathwayTool.chords.exercise)
        XCTAssertEqual(try JSONDecoder().decode(PathwayTool.self, from: Data("\"invented-tool\"".utf8)), .none)
    }
    func testCoachRequestUsesSelectedModelAndKeepsKeyOutOfBody() async throws {
        let client = CoachClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "fixture/model")
            XCTAssertEqual(json["max_tokens"] as? Int, 6500)
            XCTAssertEqual((json["provider"] as? [String: Any])?["zdr"] as? Bool, true)
            XCTAssertNil(json["response_format"])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-key"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"A useful reply"}}]}"#.utf8), response
            )
        }
        let reply = try await client.complete(
            messages: [CoachMessage(role: "user", content: "Help with my goal")], apiKey: " fixture-key\n",
            model: " fixture/model ", maxTokens: 6500)
        XCTAssertEqual(reply, "A useful reply")
    }
    func testCoachDoesNotRetryFailedPaidRequests() async {
        for (status, body) in [
            (429, #"{"error":{"message":"Rate limited"}}"#),
            (200, #"{"choices":[{"finish_reason":"length","message":{"content":"Partial plan"}}]}"#),
            (200, #"{"choices":[{"message":{"content":null}}]}"#),
        ] {
            var count = 0
            let client = CoachClient { request in
                count += 1
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
            do {
                _ = try await client.complete(messages: [], apiKey: "fixture", model: "fixture")
                XCTFail("Invalid response must fail")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            XCTAssertEqual(count, 1)
        }
    }
    func testCancelledReplyIsNotReturned() async {
        let client = CoachClient { request in
            withUnsafeCurrentTask { $0?.cancel() }
            let data = Data(#"{"choices":[{"message":{"content":"Late reply"}}]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let task = Task { try await client.complete(messages: [], apiKey: "fixture", model: "fixture") }
        do {
            _ = try await task.value
            XCTFail("A cancelled reply must not be returned or saved")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testCreatesTailoredRevisionThroughMockProvider() async throws {
        var brief = self.brief
        brief.profile.instrument = .piano
        brief.profile.minutesPerSession = 15
        brief.profile.background = "Comfortable with triads, learning left-hand independence."
        brief.focus = .style
        brief.target = "Soul accompaniment"
        var original = LearningPathway(brief: self.brief, outline: outline())
        original.completedSteps = [0]
        original.notes = "The hand coordination is difficult."
        let planData = try JSONEncoder().encode(outline())
        let responseData = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": String(decoding: planData, as: UTF8.self)]]]
        ])
        let client = CoachClient { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let context = try XCTUnwrap(messages.last?["content"])
            XCTAssertTrue(context.contains("Soul accompaniment"))
            XCTAssertTrue(context.contains("Piano"))
            XCTAssertTrue(context.contains("15 minutes"))
            XCTAssertTrue(context.contains("left-hand independence"))
            XCTAssertTrue(context.contains("hand coordination is difficult"))
            XCTAssertTrue(context.contains("Simpler left-hand patterns"))
            XCTAssertTrue(context.contains("C major"))
            return (
                responseData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let revised = try await LearningCoach(client: client).create(
            brief: brief, musicalContext: "C major", revising: original, changes: "Simpler left-hand patterns",
            apiKey: "fixture", model: "fixture")
        XCTAssertEqual(revised.brief, brief)
        XCTAssertEqual(revised.outline, outline())
        XCTAssertTrue(revised.completedSteps.isEmpty)
        XCTAssertNotEqual(revised.id, original.id)
        XCTAssertEqual(original.completedSteps, [0])
    }
    func testPathwayRequestUsesActualSelectedPassageAndRetainsItsReference() async throws {
        var study = MusicStudy(
            document: try StudyImport.read(Data(StudyExamples.smallSteps.utf8)), filename: "fixture.musicxml")
        study.select(from: 1, through: 1)
        let reference = study.reference
        let encoded = try JSONEncoder().encode(outline())
        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": String(decoding: encoded, as: UTF8.self)]]]
        ])
        let client = CoachClient { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let context = try XCTUnwrap(messages.last?["content"])
            XCTAssertTrue(context.contains(reference.context))
            XCTAssertTrue(context.contains("F4"))
            XCTAssertFalse(context.contains("bar 1, quarter-beat"))
            XCTAssertFalse(context.contains("<score-partwise"))
            return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let path = try await LearningCoach(client: client).create(
            brief: brief, musicalContext: "C major", study: reference, apiKey: "fixture", model: "fixture")
        XCTAssertEqual(path.study, reference)
        let revision = try await LearningCoach(client: client).create(
            brief: brief, musicalContext: "C major", revising: path, changes: "Make the bass easier", apiKey: "fixture",
            model: "fixture")
        XCTAssertEqual(revision.study, reference)
        XCTAssertNotEqual(revision.id, path.id)
    }

}
