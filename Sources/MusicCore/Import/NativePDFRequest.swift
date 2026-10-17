// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Shared native-PDF envelope for notation and chapter outlines. The caller owns
/// the selected-page extraction, task prompt, schema and local validation.
enum NativePDFRequest {
    static func make(
        pdf: Data, filename: String, prompt: String, schema: [String: Any], schemaName: String, model: PDFImportModel,
        key: String, maxTokens: Int, title: String, maximumBytes: Int
    ) throws -> URLRequest {
        guard !key.isEmpty, key.count <= 500, !key.contains("\n"), !key.contains("\r") else {
            throw MusicError.invalid("Add your OpenRouter key in Settings first.")
        }
        guard pdf.starts(with: Data("%PDF-".utf8)), pdf.count <= maximumBytes else {
            throw MusicError.invalid("Choose a smaller PDF excerpt.")
        }
        return try makeContent(
            content: [
                [
                    "type": "file",
                    "file": [
                        "filename": filename, "file_data": "data:application/pdf;base64," + pdf.base64EncodedString(),
                    ],
                ]
            ], prompt: prompt, schema: schema, schemaName: schemaName, model: model, key: key, maxTokens: maxTokens,
            title: title, nativePDF: true)
    }
    static func makeContent(
        content: [[String: Any]], prompt: String, schema: [String: Any], schemaName: String, model: PDFImportModel,
        key: String, maxTokens: Int, title: String, nativePDF: Bool = false
    ) throws -> URLRequest {
        guard !key.isEmpty, key.count <= 500, !key.contains("\n"), !key.contains("\r") else {
            throw MusicError.invalid("Add your OpenRouter key in Settings first.")
        }
        var instruction = prompt
        let format: [String: Any]
        if model.usesStrictSchema {
            format = ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schema]]
        } else {
            let schemaText = String(
                decoding: try JSONSerialization.data(withJSONObject: schema, options: .sortedKeys), as: UTF8.self)
            instruction +=
                "\nReturn one complete JSON object conforming to this schema. Include every required property. Schema: "
                + schemaText
            format = ["type": "json_object"]
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "messages": [["role": "user", "content": [["type": "text", "text": instruction]] + content]],
            "max_tokens": maxTokens, "provider": OpenRouterTransport.privacy, "response_format": format,
        ]
        if nativePDF { body["plugins"] = [["id": "file-parser", "pdf": ["engine": "native"]]] }
        if model != .astra { body["reasoning"] = ["effort": "high"] }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = OpenRouterTransport.timeoutSeconds
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
