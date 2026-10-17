// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The document stays owned by the library; this value owns its edit history.
public struct EditorSession {
    private var past: [EditorDocument] = []
    private var future: [EditorDocument] = []
    private var expected: EditorDocument?
    public init() {}
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func reset() {
        past = []
        future = []
        expected = nil
    }

    public mutating func edit(_ document: EditorDocument, change: (inout EditorDocument) throws -> Void) throws
        -> EditorDocument
    {
        var copy = document
        try change(&copy)
        copy.invalidatePDFReviews(comparedTo: document)
        _ = try copy.validated()
        guard copy.id == document.id else {
            throw MusicError.invalid("An edit cannot replace the identity of this score.")
        }
        if let expected, expected != document { reset() }
        guard copy != document else { return document }
        past.append(document)
        if past.count > 100 { past.removeFirst() }
        future = []
        expected = copy
        return copy
    }
    public mutating func undo(_ document: EditorDocument) -> EditorDocument? {
        guard expected == document else {
            reset()
            return nil
        }
        guard let old = past.popLast() else { return nil }
        future.append(document)
        expected = old
        return old
    }
    public mutating func redo(_ document: EditorDocument) -> EditorDocument? {
        guard expected == document else {
            reset()
            return nil
        }
        guard let next = future.popLast() else { return nil }
        past.append(document)
        expected = next
        return next
    }
}
