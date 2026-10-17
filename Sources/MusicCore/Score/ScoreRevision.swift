// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// Display metadata is not a musical edit. Version the hash so old saved links
/// can migrate only when their original fingerprint still matches the source.
public enum ScoreRevision {
    public static func valid(_ value: String) -> Bool {
        let digest = value.hasPrefix("v2:") ? String(value.dropFirst(3)) : value
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    public static func fingerprint(xml: String, sourceMap: String) -> String {
        let normalized: String
        if let document = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]) {
            for name in ["work", "movement-title", "movement-number", "identification", "credit"] {
                for node in (try? document.nodes(forXPath: "//*[local-name()='\(name)']")) ?? [] { node.detach() }
            }
            normalized = document.xmlString
        } else {
            // An invalid source is never treated as an empty, matching score.
            normalized = xml
        }
        return "v2:" + digest(normalized + sourceMap)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func migrate(learning: inout LearningLibrary, notebook: inout PieceNotebook, pieces: [LibraryPiece]) {
        for piece in pieces {
            let legacy = piece.legacyFingerprint
            let current = piece.fingerprint
            for index in learning.pathways.indices {
                if learning.pathways[index].piecePractice?.pieceID == piece.id,
                    learning.pathways[index].piecePractice?.fingerprint == legacy
                {
                    learning.pathways[index].piecePractice?.fingerprint = current
                }
            }
            guard var record = notebook.records[piece.id] else { continue }
            for index in record.analyses.indices where record.analyses[index].fingerprint == legacy {
                record.analyses[index].fingerprint = current
            }
            for index in record.conversation.indices where record.conversation[index].fingerprint == legacy {
                record.conversation[index].fingerprint = current
            }
            notebook.records[piece.id] = record
        }
    }
}
