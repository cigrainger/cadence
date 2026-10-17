// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import Security
import SwiftUI

// Keep these identifiers stable so updates can use an already saved key.
private enum Secrets {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cadence.OpenRouter",
            kSecAttrAccount as String: "api-key",
        ]
    }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw MusicError.invalid("Could not read the saved key from Keychain (\(status)).")
        }
        return key
    }
    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw MusicError.invalid("Could not remove the key from Keychain (\(status)).")
            }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(values) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw MusicError.invalid("Could not store the API key in Keychain (\(added)).")
            }
        } else if status != errSecSuccess {
            throw MusicError.invalid("Could not update Keychain (\(status)).")
        }
    }
}

// Injectable storage lets the native self-check verify migration and failure paths
// without reading or changing the user's credentials or preferences.
struct AISettingsStore {
    var readKey: () throws -> String
    var writeKey: (String) throws -> Void
    var readModel: () -> String
    var writeModel: (String) -> Void
    static let system = AISettingsStore(
        readKey: Secrets.read, writeKey: Secrets.save,
        readModel: { UserDefaults.standard.string(forKey: "openrouter-model") ?? "" },
        writeModel: { UserDefaults.standard.set($0, forKey: "openrouter-model") })
}

struct RouterModel: Decodable, Identifiable {
    var id: String
    var name: String
}
private struct RouterModels: Decodable { var data: [RouterModel] }

@MainActor final class AISettings: ObservableObject {
    @Published var model: String { didSet { if !isPreview { store.writeModel(model) } } }
    @Published private(set) var hasSavedKey = false
    @Published private(set) var credentialError: String?
    @Published private(set) var models: [RouterModel] = []
    @Published private(set) var loadingModels = false
    @Published private(set) var modelStatus = ""
    private var checkedKey = false
    private let isPreview: Bool
    private let store: AISettingsStore

    init(preview: Bool = false, store: AISettingsStore = .system) {
        isPreview = preview
        self.store = store
        model = preview ? "" : store.readModel()
    }
    var isReady: Bool { hasSavedKey && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var modelName: String { models.first { $0.id == model }?.name ?? model }
    func refreshKeyStatus() {
        guard !isPreview else { return }
        do {
            hasSavedKey = !(try store.readKey()).isEmpty
            credentialError = nil
            checkedKey = true
        } catch {
            credentialError = error.localizedDescription
        }
    }
    func checkKeyIfNeeded() { if !checkedKey { refreshKeyStatus() } }
    func saveKey(_ value: String) throws {
        guard !isPreview else { return }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.writeKey(key)
        hasSavedKey = !key.isEmpty
        credentialError = nil
        checkedKey = true
    }
    func requestKey() throws -> String {
        guard !isPreview else { throw MusicError.invalid("AI requests are disabled in previews.") }
        let key = try store.readKey().trimmingCharacters(in: .whitespacesAndNewlines)
        hasSavedKey = !key.isEmpty
        guard !key.isEmpty else { throw MusicError.invalid("Add your OpenRouter key in Settings to use the coach.") }
        return key
    }
    func loadModels() async {
        guard !loadingModels else { return }
        loadingModels = true
        modelStatus = ""
        defer { loadingModels = false }
        do {
            let (data, response) = try await URLSession.shared.data(
                from: URL(string: "https://openrouter.ai/api/v1/models")!)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw MusicError.invalid("Model list could not be loaded. You can still enter a model ID.")
            }
            models = try JSONDecoder().decode(RouterModels.self, from: data).data.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            modelStatus = "\(models.count) models available. Choose one to suit your budget."
        } catch is CancellationError { modelStatus = "Model loading cancelled." } catch {
            modelStatus = error.localizedDescription
        }
    }
}
