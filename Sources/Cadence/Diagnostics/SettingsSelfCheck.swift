// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum SettingsSelfCheck {
    static func run() throws -> [String: Bool] {
        var savedKey = "fixture-key"
        var savedModel = "fixture/previous-model"
        var rejectWrites = false
        var keyReads = 0
        var keyWrites = 0
        let store = AISettingsStore(
            readKey: {
                keyReads += 1
                return savedKey
            },
            writeKey: { value in
                if rejectWrites { throw MusicError.invalid("Fixture storage unavailable") }
                keyWrites += 1
                savedKey = value
            }, readModel: { savedModel }, writeModel: { savedModel = $0 })

        let settings = AISettings(store: store)
        settings.checkKeyIfNeeded()
        var checks = ["existingConfiguration": settings.isReady && settings.model == savedModel]
        let initialReads = keyReads
        settings.checkKeyIfNeeded()
        checks["credentialsLoadedOnce"] = keyReads == initialReads
        settings.model = "fixture/new-model"
        try settings.saveKey("  replacement-key\n")
        let restored = AISettings(store: store)
        restored.checkKeyIfNeeded()
        let restoredKey = try restored.requestKey()
        checks["savedConfigurationRestored"] =
            restored.isReady && restored.model == "fixture/new-model" && restoredKey == "replacement-key"

        rejectWrites = true
        do {
            try settings.saveKey("")
            checks["failedRemovalPreservesKey"] = false
        } catch {
            checks["failedRemovalPreservesKey"] = settings.hasSavedKey && savedKey == "replacement-key"
        }
        rejectWrites = false
        try settings.saveKey("")
        checks["removalDisablesCoach"] = !settings.isReady && savedKey.isEmpty
        do {
            _ = try settings.requestKey()
            checks["missingKeyStopsRequest"] = false
        } catch {
            checks["missingKeyStopsRequest"] = true
        }
        try settings.saveKey("fixture-key")
        settings.model = " \n "
        checks["blankModelDisablesCoach"] = !settings.isReady

        let readsBeforePreview = keyReads
        let writesBeforePreview = keyWrites
        let modelBeforePreview = savedModel
        let preview = AISettings(preview: true, store: store)
        preview.refreshKeyStatus()
        try preview.saveKey("preview-key")
        preview.model = "preview/model"
        do {
            _ = try preview.requestKey()
            checks["previewBlocksRequests"] = false
        } catch {
            checks["previewBlocksRequests"] = true
        }
        checks["previewLeavesStorageUntouched"] =
            keyReads == readsBeforePreview && keyWrites == writesBeforePreview && savedModel == modelBeforePreview
        return checks
    }
}
