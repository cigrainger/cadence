// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

public enum PieceKind: String, Codable, CaseIterable, Sendable {
    case sheetMusic = "Sheet music"
    case composition = "My compositions"
    case example = "Examples"
}
public enum PieceStage: String, Codable, CaseIterable, Sendable {
    case exploring = "To explore"
    case learning = "Learning"
    case comfortable = "Comfortable"
}
public enum PieceSource: Sendable {
    case score(EditorDocument)
    case study(MusicStudy)
}
public struct LibraryPiece: Identifiable, Sendable {
    public var source: PieceSource
    public var id: String {
        switch source {
        case .score(let s): "score:" + s.id.uuidString
        case .study(let s): "study:" + s.id.uuidString
        }
    }
    public var title: String {
        switch source {
        case .score(let s): s.title
        case .study(let s): s.document.title
        }
    }
    public var instrument: String {
        switch source {
        case .score(let s): s.instrument.rawValue
        case .study(let s): s.part.name
        }
    }
    public var bars: Int {
        switch source {
        case .score(let s): s.barCount
        case .study(let s): s.part.measures.count
        }
    }
    public var sourceLabel: String {
        switch source {
        case .score(let s):
            s.pdfSource.map {
                "PDF · \($0.importedPageCount)" + ($0.pages.map { "/\($0.count)" } ?? "")
                    + (($0.pages?.count ?? 1) == 1 ? " page ready" : " pages ready")
            } ?? "Editable score"
        case .study(let s): s.sourceEditor == nil ? "MusicXML" : "Saved practice copy"
        }
    }
    public var defaultKind: PieceKind {
        switch source {
        case .score(let score):
            if score.reharmSource != nil { return .composition }
            if score.pdfSource != nil { return .sheetMusic }
            let examples: [EditorDocument] = [.guitarExample, .pianoExample, .fingerstyleExample, .innerVoiceExample]
            if let example = examples.first(where: { $0.title == score.title && $0.instrument == score.instrument }),
                Self.musicXML(example) == Self.musicXML(score)
            {
                return .example
            }
            return .composition
        case .study(let study):
            return study.filename == "Small steps.musicxml" && study.document.originalXML == StudyExamples.smallSteps
                ? .example : .sheetMusic
        }
    }
    public var composer: String {
        if case .study(let study) = source { return study.document.composer }
        return ""
    }
    public var createdAt: Date? {
        switch source {
        case .score(let score): score.pdfSource?.importedAt
        case .study(let study): study.importedAt
        }
    }
    private static func musicXML(_ score: EditorDocument) -> String {
        ((try? EditorXML.encode(score)) ?? "").replacingOccurrences(
            of: " id=\"n[A-Fa-f0-9]{32}s[0-9]+p[0-9]+\"", with: "", options: .regularExpression)
    }
    private var revisionInput: (xml: String, sourceMap: String) {
        switch source {
        case .score(let score):
            let links = score.pdfSource?.pages?.map { "\($0.page):\($0.barCount)" }.joined(separator: ",") ?? ""
            return (Self.musicXML(score), "\nPDF:" + (score.pdfSource?.fileID.uuidString ?? "") + links)
        case .study(let study): return (study.document.originalXML, "")
        }
    }
    public var fingerprint: String {
        let input = revisionInput
        var sourceMap = input.sourceMap
        // Earlier single-page imports have no pages array. Include their page
        // without changing the legacy hash used to migrate existing links.
        if case .score(let score) = source, let pdf = score.pdfSource, pdf.pages == nil {
            sourceMap += ":page:\(pdf.page)"
        }
        return ScoreRevision.fingerprint(xml: input.xml, sourceMap: sourceMap)
    }
    public var legacyFingerprint: String {
        let input = revisionInput
        return ScoreRevision.digest(input.xml + input.sourceMap)
    }
    public static func catalog(scores: [EditorDocument], studies: [MusicStudy]) -> [Self] {
        let ids = Set(scores.map(\.id))
        return scores.map { Self(source: .score($0)) }
            + studies.filter { $0.sourceEditor.map { !ids.contains($0.scoreID) } ?? true }.map {
                Self(source: .study($0))
            }
    }
    public init(source: PieceSource) { self.source = source }
}
public struct PieceScope: Codable, Equatable, Sendable {
    public var fromBar: Int
    public var throughBar: Int
    public var partID: String
    public var partName: String
    public var label: String { "\(partName) · bars \(fromBar)–\(throughBar)" }
    public var valid: Bool {
        fromBar >= 1 && throughBar >= fromBar && throughBar - fromBar < 16 && throughBar <= 1000 && partID.count <= 200
            && partName.count <= 300
    }
    public init(fromBar: Int, throughBar: Int, partID: String, partName: String) {
        self.fromBar = fromBar
        self.throughBar = throughBar
        self.partID = partID
        self.partName = partName
    }
}
public struct PieceSnapshot: Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var scope: PieceScope
    public var context: String
    public var truncated: Bool
    public var reference: StudyReference
    public init(piece: LibraryPiece, from: Int, through: Int, partID: String? = nil) throws {
        var study: MusicStudy
        switch piece.source {
        case .score(let score):
            guard score.pdfSource?.pages == nil || (score.pdfSource?.importedPageCount ?? 0) > 0 else {
                throw MusicError.invalid("Import at least one page before analysing this piece.")
            }
            study = try ComposePractice.make(score, from: from, through: through)
        case .study(let source):
            study = source
            if let partID { study.selectPart(partID) }
            study.staff = nil
        }
        guard from >= 0, through >= from, through < study.part.measures.count, through - from < 16 else {
            throw MusicError.invalid("Choose up to 16 bars inside this piece.")
        }
        study.select(from: from, through: through)
        study.notes = ""
        study.practiceBook = nil
        study.speed = 1
        reference = study.reference
        pieceID = piece.id
        fingerprint = piece.fingerprint
        scope = PieceScope(fromBar: from + 1, throughBar: through + 1, partID: study.partID, partName: study.part.name)
        truncated = study.part.sourceNotes().filter { $0.measure >= from && $0.measure <= through }.count > 160
        context =
            reference.context
            + "\nBar links use 1-based positions in the score, even when the printed measure labels differ. Requested scope: \(scope.fromBar)–\(scope.throughBar)."
        if case .score(let score) = piece.source {
            context += "\nInstrument: \(score.instrument.rawValue)."
            if score.instrument == .guitar {
                context +=
                    " Tuning (low to high sounding MIDI): \(score.tuning.pitches). Capo: \(score.capo). Tab positions are proposals, not verified physical technique."
            }
            if let source = score.pdfSource {
                context +=
                    "\nThis is an AI-transcribed PDF draft. The original PDF is NOT included in this request. Do not claim to verify it."
                if let pages = source.pages {
                    context +=
                        "\nSource page map: "
                        + pages.map { item in
                            source.range(for: item.page).map {
                                "PDF page \(item.page): score bars \($0.lowerBound+1)–\($0.upperBound), learner reviewed: \(item.reviewed)."
                            } ?? "PDF page \(item.page): MISSING; no bars in this score."
                        }.joined(separator: " ")
                } else {
                    context += " Source page \(source.page); learner reviewed: \(source.reviewed)."
                }
            }
        }
        guard context.count <= 60000 else { throw MusicError.invalid("Choose a shorter passage for analysis.") }
    }
}
public struct PieceObservation: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var fromBar: Int
    public var throughBar: Int
    public init(title: String, detail: String, fromBar: Int, throughBar: Int) {
        self.title = title
        self.detail = detail
        self.fromBar = fromBar
        self.throughBar = throughBar
    }
}
public struct PiecePracticeStep: Codable, Equatable, Sendable {
    public var title: String
    public var instructions: String
    public var readyWhen: String
    public var fromBar: Int
    public var throughBar: Int
    public init(title: String, instructions: String, readyWhen: String, fromBar: Int, throughBar: Int) {
        self.title = title
        self.instructions = instructions
        self.readyWhen = readyWhen
        self.fromBar = fromBar
        self.throughBar = throughBar
    }
}
public struct PieceAnalysisOutline: Codable, Equatable, Sendable {
    public var summary: String
    public var observations: [PieceObservation]
    public var practice: [PiecePracticeStep]
    public var caveats: [String]
    public init(summary: String, observations: [PieceObservation], practice: [PiecePracticeStep], caveats: [String]) {
        self.summary = summary
        self.observations = observations
        self.practice = practice
        self.caveats = caveats
    }
    public func validated(scope: PieceScope) throws -> Self {
        func text(_ s: String, _ max: Int) -> Bool {
            !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.count <= max
        }
        func bars(_ a: Int, _ b: Int) -> Bool { a >= scope.fromBar && b <= scope.throughBar && a <= b }
        guard scope.valid, text(summary, 2000), (1...6).contains(observations.count), (1...6).contains(practice.count),
            caveats.count <= 6, caveats.allSatisfy({ text($0, 1000) }),
            observations.allSatisfy({ text($0.title, 120) && text($0.detail, 2000) && bars($0.fromBar, $0.throughBar) }
            ),
            practice.allSatisfy({
                text($0.title, 120) && text($0.instructions, 2000) && text($0.readyWhen, 800)
                    && bars($0.fromBar, $0.throughBar)
            })
        else {
            throw MusicError.invalid(
                "The analysis was incomplete or referred to bars outside the selected passage. Your saved analysis is unchanged."
            )
        }
        return self
    }
    public static func decode(_ reply: String, scope: PieceScope) throws -> Self {
        guard reply.utf8.count <= 100000, let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b
        else { throw MusicError.invalid("The model did not return a complete piece analysis.") }
        return try JSONDecoder().decode(Self.self, from: Data(reply[a...b].utf8)).validated(scope: scope)
    }
}
public struct SavedPieceAnalysis: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var fingerprint: String
    public var scope: PieceScope
    public var model: String
    public var goal: String
    public var outline: PieceAnalysisOutline
    public init(snapshot: PieceSnapshot, model: String, goal: String, outline: PieceAnalysisOutline) {
        fingerprint = snapshot.fingerprint
        scope = snapshot.scope
        self.model = model
        self.goal = goal
        self.outline = outline
    }
}
public struct PieceExchange: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var fingerprint: String
    public var scope: PieceScope
    public var model: String
    public var question: String
    public var answer: String
    public init(snapshot: PieceSnapshot, model: String, question: String, answer: String) {
        fingerprint = snapshot.fingerprint
        scope = snapshot.scope
        self.model = model
        self.question = question
        self.answer = answer
    }
}
public struct PieceRecord: Codable, Equatable, Sendable {
    public var kind: PieceKind
    public var addedAt = Date()
    public var lastOpened: Date?
    public var favorite = false
    public var stage = PieceStage.exploring
    public var composer = ""
    public var tags = ""
    public var goal = ""
    public var notes = ""
    public var analyses: [SavedPieceAnalysis] = []
    public var conversation: [PieceExchange] = []
    public init(kind: PieceKind) { self.kind = kind }
    public var valid: Bool {
        addedAt.timeIntervalSince1970.isFinite && (lastOpened?.timeIntervalSince1970.isFinite ?? true)
            && composer.count <= 160 && tags.count <= 250 && goal.count <= 1500 && notes.count <= 5000
            && analyses.count <= 12 && conversation.count <= 24 && Set(analyses.map(\.id)).count == analyses.count
            && Set(conversation.map(\.id)).count == conversation.count
            && analyses.allSatisfy {
                $0.date.timeIntervalSince1970.isFinite && ScoreRevision.valid($0.fingerprint) && !$0.model.isEmpty
                    && $0.model.count <= 200 && $0.goal.count <= 1500
                    && (try? $0.outline.validated(scope: $0.scope)) != nil
            }
            && conversation.allSatisfy {
                $0.date.timeIntervalSince1970.isFinite && ScoreRevision.valid($0.fingerprint) && $0.scope.valid
                    && !$0.question.isEmpty && $0.question.count <= 2500 && !$0.answer.isEmpty
                    && $0.answer.count <= 20000 && !$0.model.isEmpty && $0.model.count <= 200
            }
    }
}
public struct PieceNotebook: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var records: [String: PieceRecord] = [:]
    public init() {}
    public func validated() throws -> Self {
        guard schemaVersion == 1, records.count <= 500,
            records.allSatisfy({ key, value in
                let parts = key.split(separator: ":", omittingEmptySubsequences: false)
                return parts.count == 2 && ["score", "study"].contains(String(parts[0]))
                    && UUID(uuidString: String(parts[1])) != nil && value.valid
            })
        else {
            throw MusicError.invalid(
                "This library notebook is damaged or needs a newer Cadence. The existing file has been preserved.")
        }
        return self
    }
    public mutating func reconcile(_ pieces: [LibraryPiece]) {
        for piece in pieces where records[piece.id] == nil && records.count < 500 {
            var record = PieceRecord(kind: piece.defaultKind)
            record.addedAt = piece.createdAt ?? Date()
            record.composer = String(piece.composer.prefix(160))
            records[piece.id] = record
        }
    }
}
