// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

/// Public metadata only: this client never receives a credential or sends a paid request.
struct AIModelCatalog: Sendable {
    private let send: OpenRouterTransport.Send
    init(send: @escaping OpenRouterTransport.Send = Self.send) { self.send = send }

    func load() async throws -> [RouterModel] {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.timeoutInterval = 30
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            throw MusicError.invalid("Model list could not be loaded. You can still enter a model ID.")
        }
        guard data.count <= 16_000_000 else { throw MusicError.invalid("The model list is too large.") }
        let values = try JSONDecoder().decode(Response.self, from: data).data
        guard values.count <= 5000, Set(values.map(\.id)).count == values.count,
            values.allSatisfy({
                !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.id.count <= 256
                    && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 256
            })
        else { throw MusicError.invalid("The model list contains invalid or duplicate entries.") }
        return values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct Response: Decodable { var data: [RouterModel] }
    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MusicError.invalid("The model list did not return an HTTP response.")
        }
        return (data, response)
    }
}
