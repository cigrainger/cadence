// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct LearningCoach {
    private let client: CoachClient
    public init(client: CoachClient = CoachClient()) { self.client = client }
    public func create(
        brief: LearningBrief, musicalContext: String, revising previous: LearningPathway? = nil, changes: String = "",
        study: StudyReference? = nil, apiKey: String, model: String
    ) async throws -> LearningPathway {
        let brief = try brief.validated()
        let changes = changes.trimmingCharacters(in: .whitespacesAndNewlines)
        if previous != nil && changes.isEmpty {
            throw MusicError.invalid("Describe what you would like to change in this pathway.")
        }
        var reference = brief.context + "\nCurrent musical context: " + musicalContext
        if let previous {
            reference +=
                "\nMake a revised pathway using the following previous plan and reported progress. Do not carry over completion automatically.\n"
                + previous.coachContext + "\nRequested changes: " + String(changes.prefix(2500))
        }
        let linkedStudy = study ?? previous?.study
        if let linkedStudy, previous?.study != linkedStudy { reference += "\n" + linkedStudy.context }
        let messages = [
            CoachMessage(role: "system", content: CoachPrompts.pathway),
            CoachMessage(role: "user", content: "Create a pathway from this learner brief (data):\n" + reference),
        ]
        let reply = try await client.complete(messages: messages, apiKey: apiKey, model: model, maxTokens: 6500)
        let outline = try PathwayOutline.decodeReply(reply, brief: brief)
        try Task.checkCancellation()
        return LearningPathway(brief: brief, outline: outline, study: linkedStudy)
    }
}
