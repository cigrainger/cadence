// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct OpenRouterPrivacy: Encodable {
    public var zdr = true
    public var data_collection = "deny"
    public var allow_fallbacks = false
    public var require_parameters = true
    public var dictionary: [String: Any] {
        [
            "zdr": zdr, "data_collection": data_collection, "allow_fallbacks": allow_fallbacks,
            "require_parameters": require_parameters,
        ]
    }
}

/// Shared paid-request boundary. Prompts and response schemas remain task-specific.
public struct OpenRouterTransport {
    public typealias Send = (URLRequest) async throws -> (Data, HTTPURLResponse)
    public static let timeoutSeconds: TimeInterval = 240
    public static var privacy: [String: Any] { OpenRouterPrivacy().dictionary }
    private let deadline: TimeInterval
    private let send: Send
    public init(deadline: TimeInterval = timeoutSeconds, send: @escaping Send = Self.send) {
        self.deadline = deadline.isFinite ? min(Self.timeoutSeconds, max(0.01, deadline)) : Self.timeoutSeconds
        self.send = send
    }
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try validate(request)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MusicError.invalid("No response from OpenRouter.")
        }
        return (data, response)
    }
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            try Self.validate(request)
            return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
                group.addTask {
                    let result = try await send(request)
                    try Task.checkCancellation()
                    return result
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                let result = try await group.next()!
                try Task.checkCancellation()
                return result
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                throw MusicError.invalid(
                    "The model did not finish within four minutes. Cadence has not retried; work already sent may still be charged. Try a smaller passage or another model."
                )
            }
            throw error
        }
    }
    /// A caller cannot accidentally send the user's bearer key to another host.
    static func validate(_ request: URLRequest) throws {
        guard let url = request.url, url.scheme == "https", url.host == "openrouter.ai",
            url.port == nil || url.port == 443, url.user == nil, url.password == nil,
            url.path == "/api/v1/chat/completions", url.query == nil, url.fragment == nil,
            request.httpMethod == "POST"
        else {
            throw MusicError.invalid("The AI request has an unexpected destination. No request was sent.")
        }
    }

    public static func failure(status: Int, detail: String, key: String) -> MusicError {
        let redacted = key.isEmpty ? detail : detail.replacingOccurrences(of: key, with: "[redacted]")
        return .invalid("OpenRouter \(status): " + String(redacted.prefix(2000)))
    }
}

/// Redirects are not part of the API contract. Return the 3xx response to the
/// caller instead of forwarding its credentials or its score to another URL.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
