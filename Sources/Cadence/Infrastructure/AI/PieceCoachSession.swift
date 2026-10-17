// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

enum PieceCoachReply {
    case analysis(SavedPieceAnalysis)
    case exchange(PieceExchange)
}
typealias PieceCoachSession = SavedRequest<PieceCoachReply>

extension SavedRequest where Reply == PieceCoachReply {
    func run(state: AppState, pieceID: String, request: @escaping @MainActor () async throws -> PieceCoachReply) {
        guard state.libraryStorageError == nil else { return }
        run(request: request) { [state] reply in
            guard state.libraryPieces.contains(where: { $0.id == pieceID }) else {
                throw MusicError.invalid(
                    "This piece is no longer in the library. The reply has not been attached to another piece.")
            }
            try state.changePiece(pieceID) { record in
                switch reply {
                case .analysis(let value):
                    record.analyses.append(value)
                    record.analyses = Array(record.analyses.suffix(12))
                case .exchange(let value):
                    record.conversation.append(value)
                    record.conversation = Array(record.conversation.suffix(24))
                }
            }
        }
    }
    func save(state: AppState) { retrySave() }
}
