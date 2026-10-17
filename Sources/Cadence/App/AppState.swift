// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import MusicCore
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case explore = "Explore"
    case chords = "Chord lab"
    case practice = "Practice"
    case coach = "AI coach"
    case studies = "Studies"
    case
        tools = "Practice tools"
    case editor = "Compose"
    case library = "Library"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .explore: "circle.hexagongrid"
        case .chords: "guitars"
        case .practice: "ear"
        case .coach: "sparkles"
        case .studies: "music.note.list"
        case .tools: "metronome"
        case .editor: "pencil.and.outline"
        case .library: "books.vertical"
        }
    }
    var subtitle: String {
        switch self {
        case .explore: "Find the connections. Then hear them."
        case .chords: "Find the notes. Hear the connections."
        case .practice: "A little practice. A deeper musical instinct."
        case .coach: "Ask about the music in front of you."
        case .studies: "Make a little music your own."
        case .tools: "Find your pitch. Set your pulse."
        case .editor: "Write a phrase. Make it your own."
        case .library: "Your music, and the things it can teach you."
        }
    }
}
struct EditorPassageFocus: Equatable {
    var documentID: UUID
    var from: Int
    var through: Int
    var wholePiece = false
}

struct Preferences: Codable, Equatable {
    var root: Pitch
    var scale: Scale
    var quality: ChordQuality
    var tuning: Tuning
    var capo: Int
    var leftHanded: Bool
    var showDegrees: Bool
    var showRewards: Bool
    var comparison: Scale?
    var chordRoot: Pitch?
    var showSolfege: Bool?
    var metronome: MetronomeSettings?
    var tuner: TunerSettings?
}

@MainActor final class AppState: ObservableObject {
    @Published var destination: Destination = .practice
    @Published var practicePage = PracticePage.home
    @Published var practiceMIDIExercise = false
    @Published var adaptiveFromPractice = false
    @Published var root = Pitch(0)
    @Published var scale = Scale.major
    @Published var quality = ChordQuality.major
    @Published var chordRoot: Pitch?
    @Published var showChanges = false
    @Published var changesPlan = ChangesPlan.example
    let changesSession = ChangesSession()
    let timedChangesSession = TimedChangesSession()
    @Published var showTimedChanges = false
    @Published var changesReview: TimedChangesResult?
    @Published var tuning = Tuning.presets[0]
    @Published var capo = 0
    @Published var leftHanded = false
    @Published var showDegrees = false
    @Published var showRewards = true
    @Published var showSolfege = true
    @Published var comparison: Scale?
    @Published var instrumentFocus = 0
    @Published var message: String?
    @Published var coachPrompt = ""
    @Published var coachFocus = 0
    @Published var coachLines: [ChatLine] = []
    var learningStorageError: String? { stores.practiceError }
    @Published var libraryLearning = false
    @Published var pathwaySession: PathwayPracticeSession?
    @Published var importingStudy = false
    @Published var coachStudy: StudyReference?
    @Published var pendingStudyPathway: StudyReference?
    @Published var practiceExercise: Exercise?
    @Published var guidedStudyID: UUID?
    @Published var timedStudyID: UUID?
    @Published var rhythmReview: TimedPracticeResult?
    let timedSession = TimedPracticeSession()
    let playAlongSession = PlayAlongSession()
    let rehearsalSession = PieceRehearsalSession()
    let triadInput = TriadInput()
    let tensionInput = TensionInput()
    let reharmInput = ReharmInput()
    let reharmTransport = ReharmTransport()
    @Published var rehearsalPieceID: String?
    @Published var rehearsalKey: String?
    @Published var playAlongMaterial: ScoreEarMaterial?
    @Published var metronome = MetronomeSettings()
    @Published var tuner = TunerSettings()
    @Published var librarySelection: String?
    @Published var libraryCourses = false
    @Published var courses = CourseLibrary()
    @Published var learningShelf = "Pathways"
    @Published var musicalPathwaySelection: UUID?
    @Published var musicalPathwayStep: UUID?
    let earInput = EarSessionInput()
    let scoreEarInput = EarSessionInput(library: true)
    @Published var showAdaptiveSession = false
    let adaptiveInput = AdaptiveSessionInput()
    var previewBooks: [UUID: BookAsset] = [:]
    @Published var courseSelection: UUID?
    @Published var courseLessonSelection: UUID?
    @Published var courseReturn: CourseLocation?
    let courseOutline = SavedRequest<CourseOutlineReply>()
    var libraryStorageError: String? { stores.notebook.loadError }
    @Published var editorPassageFocus: EditorPassageFocus?
    @Published var studyWholePiece = false
    @Published var showPDFImport = false
    @Published var pdfImportScoreID: UUID?
    @Published var pdfReviewPage: Int?
    @Published var pdfImportRevision = 0
    var journalStorageError: String? { stores.practiceError }
    private(set) var practiceSessionID = UUID()
    let midi: MIDIKeyboard
    let aiSettings: AISettings
    let audio = AudioPlayer()
    let microphone = Microphone()
    let practiceWorkspace: PracticeWorkspace
    let libraryWorkspace: LibraryWorkspace
    private var workspaceObservations = Set<AnyCancellable>()
    let stores: WorkspaceStorage
    var storage: URL { stores.directory }
    @Published var saveErrors: [String: String] = [:]
    var editorStorageError: String? { stores.editor.loadError }
    var studyStorageError: String? { stores.studies.loadError }
    let isPreview: Bool
    private var pendingSave: Task<Void, Never>?

    init(preview: Bool = false, storageOverride: URL? = nil) {
        self.isPreview = preview
        midi = MIDIKeyboard(preview: preview || storageOverride != nil)
        aiSettings = AISettings(preview: preview || storageOverride != nil)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        stores = WorkspaceStorage(
            directory: storageOverride ?? support.appendingPathComponent("Cadence", isDirectory: true))
        practiceWorkspace = PracticeWorkspace(storage: stores, ephemeral: preview)
        libraryWorkspace = LibraryWorkspace(storage: stores, ephemeral: preview)
        if !preview { loadWorkspace() }
        configurePreview()
        // Forward only persisted draft changes; transport ticks keep their own observers.
        practiceWorkspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &workspaceObservations)
        libraryWorkspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &workspaceObservations)
    }
    var libraryPieces: [LibraryPiece] { libraryWorkspace.pieces }
    func pieceRecord(_ piece: LibraryPiece) -> PieceRecord { libraryWorkspace.record(for: piece) }
    func reconcileLibrary() { libraryWorkspace.reconcile() }
    func changePiece(_ id: String, _ change: (inout PieceRecord) -> Void) throws {
        try libraryWorkspace.changePiece(id, change)
    }
    func showLibraryPiece(_ id: String) {
        libraryCourses = false
        audio.stop()
        librarySelection = id
        reconcileLibrary()
        destination = .library
    }
    func openLibraryPiece(
        _ piece: LibraryPiece, from: Int = 0, through: Int? = nil, partID: String? = nil, practise: Bool = false
    ) {
        do { try changePiece(piece.id) { $0.lastOpened = Date() } } catch { message = error.localizedDescription }
        audio.stop()
        microphone.stop()
        switch piece.source {
        case .score(let score):
            if practise {
                practiseEditor(score, from: from, through: min(score.barCount - 1, through ?? 3))
                studyWholePiece = through == nil
            } else {
                returnToCompose(score.id, from: from, through: through)
            }
        case .study(let source):
            studies.activeID = source.id
            editStudy(source.id) { study in
                if let partID { study.selectPart(partID) }
                study.staff = nil
                study.select(from: from, through: through ?? 3)
            }
            studyWholePiece = through == nil
            destination = .studies
        }
    }
    func newLibraryComposition(_ instrument: EditorInstrument) {
        do {
            if let editorStorageError { throw MusicError.invalid(editorStorageError) }
            guard editor.documents.count < 100 else {
                throw MusicError.invalid("Cadence keeps up to 100 editable scores.")
            }
            var doc = try EditorDocument.blank(instrument: instrument)
            doc.title = "Untitled \(instrument.rawValue.lowercased())"
            try libraryWorkspace.addComposition(doc)
            librarySelection = "score:" + doc.id.uuidString
            destination = .editor
            save()
        } catch { message = error.localizedDescription }
    }
    func copyLibraryComposition(_ piece: LibraryPiece) {
        guard editorStorageError == nil else {
            message = editorStorageError
            return
        }
        guard case .score(var doc) = piece.source, editor.documents.count < 100 else {
            message = "Only editable scores can be copied into Compose (up to 100 scores)."
            return
        }
        doc.id = UUID()
        doc.title = String((doc.title + " · my version").prefix(120))
        doc.pdfSource = nil
        do { try libraryWorkspace.addComposition(doc) } catch {
            message = error.localizedDescription
            return
        }
        destination = .editor
        save()
    }
    var preferences: Preferences {
        Preferences(
            root: root, scale: scale, quality: quality, tuning: tuning, capo: capo, leftHanded: leftHanded,
            showDegrees: showDegrees, showRewards: showRewards, comparison: comparison, chordRoot: chordRoot,
            showSolfege: showSolfege, metronome: metronome, tuner: tuner)
    }
    var scaleNotes: [Pitch] { scale.notes(root) }
    var scalePCs: Set<Int> { Set(scaleNotes.map(\.pc)) }
    var activeChordRoot: Pitch { chordRoot ?? root }
    var chordNotes: [Pitch] { quality.notes(activeChordRoot) }
    var chordPCs: Set<Int> { Set(chordNotes.map(\.pc)) }
    var context: String {
        "Tonal context: \(root.name) \(scale.rawValue); notes: \(scaleNotes.map(\.name).joined(separator:", ")); degrees: \(scale.formula.joined(separator:", ")). Selected chord: \(activeChordRoot.name)\(quality.symbol); tones: \(chordNotes.map(\.name).joined(separator:", ")). Guitar: \(tuning.name), capo \(capo)."
    }
    func beginPracticeSession() { practiceSessionID = UUID() }
    func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }
    func editStudy(_ id: UUID, _ change: (inout MusicStudy) -> Void) {
        guard studyStorageError == nil else {
            message = studyStorageError
            return
        }
        guard let index = studies.studies.firstIndex(where: { $0.id == id }) else { return }
        change(&studies.studies[index])
        saveSoon()
    }
    func addExampleStudy() {
        guard studyStorageError == nil else {
            message = studyStorageError
            return
        }
        do {
            studies.add(
                MusicStudy(
                    document: try StudyImport.read(Data(StudyExamples.smallSteps.utf8)),
                    filename: "Small steps.musicxml"))
            save()
        } catch { message = error.localizedDescription }
    }
    func practiseEditor(
        _ score: EditorDocument, from: Int, through: Int, speed: Double = 1, loop: Bool = true, countIn: Bool = true,
        metronome: Bool = false
    ) {
        guard studyStorageError == nil else {
            message = studyStorageError
            return
        }
        do {
            var snapshot = try ComposePractice.make(score, from: from, through: through)
            if let old = studies.studies.first(where: {
                $0.sourceEditor?.scoreID == score.id && $0.document.originalXML == snapshot.document.originalXML
            }) {
                snapshot = old
                snapshot.select(from: from, through: through)
                studies.activeID = old.id
            } else {
                guard studies.studies.count < 100 else {
                    throw MusicError.invalid(
                        "Cadence keeps up to 100 studies. Remove an unused study before creating another practice copy."
                    )
                }
                snapshot.speed = speed.isFinite ? min(1.5, max(0.25, speed)) : 1
                snapshot.loop = loop
                snapshot.countIn = countIn
                snapshot.metronome = metronome
                studies.add(snapshot)
            }
            audio.stop()
            microphone.stop()
            editStudy(snapshot.id) { $0 = snapshot }
            root = ScoreKey.tonic(fifths: score.fifths, minor: score.minor)
            scale = score.minor ? .minor : .major
            if score.instrument == .guitar {
                tuning = score.tuning
                capo = score.capo
            }
            studyWholePiece = false
            destination = .studies
            save()
        } catch { message = error.localizedDescription }
    }
    func returnToCompose(_ id: UUID, from: Int = 0, through: Int? = nil) {
        guard editor.documents.contains(where: { $0.id == id }) else {
            message = "The original score is no longer in Compose. This saved practice copy is still available."
            return
        }
        audio.stop()
        microphone.stop()
        editor.activeID = id
        editorPassageFocus = EditorPassageFocus(
            documentID: id, from: from, through: through ?? 3, wholePiece: through == nil)
        destination = .editor
    }
    func importStudy(_ url: URL) {
        guard studyStorageError == nil else {
            message = studyStorageError
            return
        }
        guard !importingStudy else { return }
        importingStudy = true
        Task {
            defer { importingStudy = false }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= StudyImport.maximumBytes else {
                        throw MusicError.invalid("Choose a MusicXML file smaller than 20 MB.")
                    }
                    return try StudyImport.read(Data(contentsOf: url))
                }.value
                audio.stop()
                studies.add(MusicStudy(document: document, filename: url.lastPathComponent))
                save()
            } catch { message = "Could not import this score: " + error.localizedDescription }
        }
    }
    func attachStudy(_ studyID: UUID, to pathwayID: UUID) {
        guard let study = studies.studies.first(where: { $0.id == studyID }),
            let index = learning.pathways.firstIndex(where: { $0.id == pathwayID })
        else { return }
        learning.pathways[index].study = study.reference
        editStudy(studyID) { $0.pathwayID = pathwayID }
        save()
    }
    func openStudy(_ reference: StudyReference) {
        guard studies.studies.contains(where: { $0.id == reference.studyID }) else {
            message = "This study has been removed. The pathway still keeps its passage reference."
            return
        }
        studies.activeID = reference.studyID
        editStudy(reference.studyID) {
            $0.selectPart(reference.partID)
            $0.staff = reference.staff
            $0.select(from: reference.from, through: reference.through)
        }
        studyWholePiece = false
        destination = .studies
    }
    func playScale(_ comparison: Scale? = nil) {
        let first = 60 + root.pc
        let notes = ((comparison ?? scale).intervals + [12]).enumerated().map {
            ScoreNote(midi: first + $0.element, start: Double($0.offset), duration: 0.85)
        }
        audio.play(Score(tempo: 110, notes: notes))
    }
    func useChord(_ chord: ScaleChord) {
        chordRoot = chord.root
        quality = chord.quality
        showChanges = false
        destination = .chords
    }
    func ask(_ prompt: String, study: StudyReference? = nil) {
        coachStudy = study
        coachPrompt = prompt
        destination = .coach
        coachFocus += 1
    }
    func useLearningTool(_ tool: PathwayTool) {
        if let exercise = tool.exercise {
            openPractice(exercise)
        } else if tool == .explore {
            destination = .explore
        } else if tool == .chords {
            destination = .chords
        }
    }
}
