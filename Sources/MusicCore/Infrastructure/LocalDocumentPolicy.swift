// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Engraving views may load their own entry document, never another local file
/// or a remote page. Resource loads remain governed by WebKit and the page CSP.
public enum LocalDocumentPolicy {
    public static func allows(_ candidate: URL?, entry: URL?) -> Bool {
        guard let candidate, let entry, candidate.isFileURL, entry.isFileURL,
            candidate.host == nil || candidate.host == "" || candidate.host == "localhost",
            candidate.query == nil
        else { return false }
        return candidate.standardizedFileURL.resolvingSymlinksInPath().path
            == entry.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
