// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct CoachMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct CoachClient {
    private let client: OpenRouterTransport
    public init(deadline: TimeInterval = 240, transport: @escaping OpenRouterTransport.Send = Self.send) {
        client = OpenRouterTransport(deadline: deadline, send: transport)
    }
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OpenRouterTransport.send(request)
    }

    public func complete(messages: [CoachMessage], apiKey: String, model: String, maxTokens: Int = 2500) async throws
        -> String
    {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !modelID.isEmpty else {
            throw MusicError.invalid("Add your OpenRouter key and choose a model in Settings.")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Cadence", forHTTPHeaderField: "X-Title")
        struct Payload: Encodable {
            var model: String
            var messages: [CoachMessage]
            var max_tokens: Int
            var provider = OpenRouterPrivacy()
        }
        // Do not require response_format: the user's chosen model may not support it.
        // Pathway JSON is requested in the prompt, then validated before saving.
        request.httpBody = try JSONEncoder().encode(Payload(model: modelID, messages: messages, max_tokens: maxTokens))
        let (data, response) = try await client.perform(request)
        try Task.checkCancellation()
        struct Reply: Decodable {
            struct Failure: Decodable { var message: String? }
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message?
                var finish_reason: String?
            }
            var choices: [Choice]?
            var error: Failure?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (200..<300).contains(response.statusCode), reply?.error == nil else {
            let message = reply?.error?.message ?? "The request could not be completed."
            throw OpenRouterTransport.failure(status: response.statusCode, detail: message, key: key)
        }
        guard let choice = reply?.choices?.first else {
            throw MusicError.invalid("The model returned an unreadable response. Try another model.")
        }
        guard choice.finish_reason != "length" else {
            throw MusicError.invalid("The response was cut short. Try a more focused request or another model.")
        }
        guard let content = choice.message?.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MusicError.invalid("The model returned no text. Try another model.")
        }
        return content
    }
}
