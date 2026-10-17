// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class FollowChangesTests: XCTestCase {
    private func chord(_ text: String) throws -> ChordRealization { try ChordRealization(ChordSymbol.parse(text)) }
    private func source(_ symbols: [(Int, Int, String)], from: Int = 0, through: Int = 3) throws -> ChangesSource {
        var doc = try EditorDocument.blank(instrument: .piano)
        doc.harmonies = try symbols.map { EditorHarmony(bar: $0.0, tick: $0.1, symbol: try ChordSymbol.parse($0.2)) }
        return try ChangesSource(piece: LibraryPiece(source: .score(doc)), from: from, through: through)
    }
    func testIIVIHasCorrectSpellingAndGuideToneMotion() throws {
        let plan = ChangesPlan.example
        XCTAssertEqual(plan.steps.map { $0.chord.symbol.label }, ["Dm7", "G7", "Cmaj7"])
        XCTAssertEqual(
            plan.steps.map { $0.chord.tones.map(\.pitch.name) },
            [["D", "F", "A", "C"], ["G", "B", "D", "F"], ["C", "E", "G", "B"]])
        let targets = try plan.targets(.guides)
        XCTAssertEqual(targets.map(\.pitchClasses), [[5, 0], [11, 5], [4, 11]])
        XCTAssertEqual(VoiceLeading.commonTones(targets[0], targets[1]).map(\.name), ["F"])
        XCTAssertEqual(VoiceLeading.commonTones(targets[1], targets[2]).map(\.name), ["B"])
        XCTAssertEqual(targets[1].pianoVoicings(previous: [53, 60]).first, [53, 59])
        XCTAssertEqual(targets[2].pianoVoicings(previous: [53, 59]).first, [52, 59])
    }
    func testEveryHarmonyKindHasExpectedIntervals() throws {
        let expected: [HarmonyKind: [Int]] = [
            .major: [0, 4, 7], .minor: [0, 3, 7], .augmented: [0, 4, 8], .diminished: [0, 3, 6],
            .dominant: [0, 4, 7, 10], .majorSeventh: [0, 4, 7, 11], .minorSeventh: [0, 3, 7, 10],
            .diminishedSeventh: [0, 3, 6, 9], .augmentedSeventh: [0, 4, 8, 10], .halfDiminished: [0, 3, 6, 10],
            .majorMinor: [0, 3, 7, 11], .majorSixth: [0, 4, 7, 9], .minorSixth: [0, 3, 7, 9],
            .dominantNinth: [0, 4, 7, 10, 14], .majorNinth: [0, 4, 7, 11, 14], .minorNinth: [0, 3, 7, 10, 14],
            .dominant11th: [0, 4, 7, 10, 14, 17], .major11th: [0, 4, 7, 11, 14, 17], .minor11th: [0, 3, 7, 10, 14, 17],
            .dominant13th: [0, 4, 7, 10, 14, 17, 21], .major13th: [0, 4, 7, 11, 14, 17, 21],
            .minor13th: [0, 3, 7, 10, 14, 17, 21], .suspendedSecond: [0, 2, 7], .suspendedFourth: [0, 5, 7],
            .power: [0, 7], .none: [],
        ]
        for kind in HarmonyKind.allCases {
            XCTAssertEqual(
                try ChordRealization(.init(root: kind == .none ? nil : Pitch(0), kind: kind)).tones.map(\.semitones),
                expected[kind], kind.rawValue)
        }
    }
    func testEnharmonicSpellingAndCompoundDegrees() throws {
        XCTAssertEqual(try chord("F#dim7").tones.map(\.pitch.name), ["F♯", "A", "C", "E♭"])
        XCTAssertEqual(try chord("Cdim7").tones.map(\.pitch.name), ["C", "E♭", "G♭", "B♭♭"])
        XCTAssertEqual(try chord("Dbmaj9").tones.map(\.pitch.name), ["D♭", "F", "A♭", "C", "E♭"])
        XCTAssertEqual(try chord("Bb13").tones.map(\.label), ["1", "3", "5", "♭7", "9", "11", "13"])
    }
    func testHiddenAlterationsSoundAndKindTextIsNotParsed() throws {
        let altered = try chord("G7(b9,#11,no5)")
        XCTAssertEqual(altered.tones.map(\.pitch.name), ["G", "B", "F", "A♭", "C♯"])
        var symbol = try ChordSymbol.parse("C")
        symbol.kindText = "mystery display text"
        XCTAssertEqual(try ChordRealization(symbol).tones.map(\.pitch.pc), [0, 4, 7])
    }
    func testDegreeChangesFollowMusicXMLAndTypedSusSeventhIsMinor() throws {
        XCTAssertEqual(try chord("G7sus4").tones.map(\.pitch.name), ["G", "C", "D", "F"])
        XCTAssertEqual(try chord("G9sus4").tones.map(\.pitch.name), ["G", "C", "D", "F", "A"])
        XCTAssertEqual(try chord("G13sus2").tones.map(\.pitch.name), ["G", "A", "D", "F", "A", "E"])
        var symbol = ChordSymbol(root: Pitch(0), kind: .minorSeventh, degrees: [.init(3, alter: 1, type: .alter)])
        XCTAssertEqual(try ChordRealization(symbol).tones.map(\.pitch.pc), [0, 4, 7, 10])
        symbol = .init(root: Pitch(0), kind: .major, degrees: [.init(7)])
        XCTAssertEqual(try ChordRealization(symbol).tones.last?.pitch.name, "B♭")
        XCTAssertEqual(try chord("C7b7").tones.last?.semitones, 10)
        XCTAssertEqual(try chord("Cm7b3").tones[1].semitones, 3)
    }
    func testConflictingAndInvalidDegreesFailExplicitly() throws {
        for degrees: [HarmonyDegree] in [
            [.init(5, type: .subtract), .init(5, alter: 1, type: .alter)], [.init(9, type: .alter)],
            [.init(9, type: .subtract)], [.init(5, alter: 1, type: .subtract)], [.init(99)],
            [.init(1, type: .subtract), .init(3, type: .subtract), .init(5, type: .subtract)],
        ] {
            XCTAssertThrowsError(try ChordRealization(.init(root: Pitch(0), kind: .major, degrees: degrees)))
        }
        var symbol = ChordSymbol(root: Pitch(0), kind: .major)
        symbol.root?.letter = 999
        XCTAssertThrowsError(try ChordRealization(symbol))
    }
    func testTwoAlteredNinthsRemainDistinct() throws {
        XCTAssertEqual(try chord("C7(b9,#9)").tones.map(\.semitones), [0, 4, 7, 10, 13, 15])
        XCTAssertEqual(try chord("C9(b9,#9)").tones.map(\.semitones), [0, 4, 7, 10, 13, 15])
    }
    func testModesDoNotSilentlyReplaceUnsupportedGuideTones() throws {
        XCTAssertThrowsError(try chord("Csus4").target(.guides))
        XCTAssertThrowsError(try chord("C6").target(.shells))
        XCTAssertNoThrow(try chord("C6").target(.complete))
        XCTAssertEqual(try chord("Dm7").target(.shells).pitchClasses, [2, 5, 0])
        XCTAssertEqual(try chord("C/E").target(.roots).pitchClasses, [0])
        XCTAssertNil(try chord("C7/E").target(.guides).bass)
    }
    func testSlashBassMayBeOutsideChordAndIsRequiredOnlyForVoicings() throws {
        let target = try chord("Cmaj7/D").target(.complete)
        XCTAssertEqual(target.pitchClasses, [0, 2, 4, 7, 11])
        XCTAssertTrue(target.judge([50, 60, 64, 67, 71]).correct)
        XCTAssertFalse(target.judge([48, 50, 64, 67, 71]).bassCorrect)
        XCTAssertEqual(try chord("Cmaj7/D").target(.shells).pitchClasses, [0, 2, 4, 11])
    }
    func testMatchingAllowsInversionsAndDoublingsButRejectsMissingExtraAndInvalidNotes() throws {
        let target = try chord("Dm7").target(.complete)
        XCTAssertTrue(target.judge([53, 57, 60, 62, 74]).correct)
        XCTAssertEqual(target.judge([50, 53, 57]).missing, [0])
        XCTAssertEqual(target.judge([50, 53, 57, 60, 61]).extra, [1])
        XCTAssertFalse(target.judge([]).correct)
        XCTAssertFalse(target.judge([50, 53, 57, 60, 128]).correct)
    }
    func testPianoSuggestionsMatchAllTargetsAndRespectBass() throws {
        for symbol in ["Dm7", "G7", "Cmaj7", "Dbmaj9/Ab", "F#dim7", "G7(b9,#11)", "Bb13", "Cmaj7/D"] {
            for mode in ChangesMode.allCases {
                let target = try chord(symbol).target(mode)
                let choices = target.pianoVoicings(previous: [53, 60])
                XCTAssertFalse(choices.isEmpty)
                for notes in choices {
                    XCTAssertTrue(target.judge(notes).correct, symbol)
                    XCTAssertTrue(notes.allSatisfy { (48...84).contains($0) })
                }
            }
        }
        XCTAssertGreaterThan(VoiceLeading.distance([48], [60, 64]), 0)
    }
    func testGuitarSolverReusesCommonShapesAndNeverDropsAlterations() throws {
        let tuning = Tuning.presets[0]
        for text in ["Dm7", "G7", "Cmaj7", "Cmaj7/E", "G7(b9,no5)"] {
            let target = try chord(text).target(.complete)
            let shapes = target.guitarVoicings(tuning: tuning, capo: 0)
            XCTAssertFalse(shapes.isEmpty, text)
            for shape in shapes {
                XCTAssertTrue(target.judge(shape.pitches).correct, text)
                XCTAssertEqual(
                    shape.pitches,
                    shape.frets.enumerated().filter { $0.element >= 0 }.map { tuning.pitches[$0.offset] + $0.element })
            }
        }
        XCTAssertEqual(
            try chord("Dm7").target(.complete).guitarVoicings(tuning: tuning, capo: 0).first?.frets,
            [-1, -1, 0, 2, 1, 1])
        XCTAssertTrue(try chord("Bb13").target(.complete).guitarVoicings(tuning: tuning, capo: 0).isEmpty)
        let target = try chord("Dm7").target(.shells)
        for tuning in Tuning.presets {
            for capo in [0, 2, 5] {
                for shape in target.guitarVoicings(tuning: tuning, capo: capo) {
                    XCTAssertTrue(target.judge(shape.pitches).correct)
                }
            }
        }
        XCTAssertTrue(Guitar.voicings(root: Pitch(0), tones: [], tuning: tuning).isEmpty)
        XCTAssertTrue(Guitar.voicings(root: Pitch(0), tones: [0], tuning: tuning, capo: 100).isEmpty)
        XCTAssertTrue(Guitar.voicings(root: Pitch(0), tones: [0], tuning: tuning, bass: 2).isEmpty)
    }
    func testSelectionIncludesCarryAndPreservesRepeatedChangesAndNC() throws {
        let source = try source([(0, 0, "Dm7"), (2, 480, "G7"), (2, 960, "G7"), (3, 0, "N.C.")], from: 1)
        let plan = try source.plan(staff: 1)
        XCTAssertEqual(plan.steps.map { $0.chord.symbol.label }, ["Dm7", "G7", "G7", "N.C."])
        XCTAssertTrue(plan.steps[0].carried)
        XCTAssertTrue(plan.steps[0].position.contains("carried in"))
        XCTAssertEqual(plan.playableIndices, [0, 1, 2])
        XCTAssertEqual(try plan.targets(.roots).count, 3)
        XCTAssertThrowsError(try plan.steps.last!.chord.target(.complete))
    }
    func testSelectionStartingWithNewSymbolReplacesCarry() throws {
        let plan = try source([(0, 0, "Dm7"), (1, 0, "G7"), (3, 0, "Cmaj7")], from: 1, through: 2).plan(staff: 1)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertFalse(plan.steps[0].carried)
    }
    func testChordOnlyScoreAndImportedXMLHaveSameChanges() throws {
        let original = try source([(0, 0, "Dm7"), (0, 960, "G7"), (1, 0, "Cmaj7/E")])
        guard case .score(var doc) = original.piece.source else { return XCTFail() }
        try doc.setPitch(doc.events[0].id, midi: 60)
        let study = MusicStudy(
            document: try StudyImport.read(Data(EditorXML.encode(doc).utf8)), filename: "changes.musicxml")
        let imported = try ChangesSource(piece: LibraryPiece(source: .study(study)), from: 0, through: 3)
        XCTAssertEqual(try imported.plan(staff: 1).steps, try original.plan(staff: 1).steps)
        XCTAssertThrowsError(
            try ChangesSource(piece: LibraryPiece(source: .study(study)), from: 0, through: 3, partID: "missing"))
    }
    func testSourceBoundsEmptyNCAndMultipleStaffs() throws {
        XCTAssertThrowsError(try source([]))
        XCTAssertThrowsError(try source([(0, 0, "C")], from: -1))
        XCTAssertThrowsError(try source([(0, 0, "C")], through: 99))
        XCTAssertThrowsError(try source([(0, 0, "N.C.")]).plan(staff: 1))
        let original = try source([(0, 0, "C")])
        XCTAssertThrowsError(try original.plan(staff: 2))
        guard case .score(var doc) = original.piece.source else { return XCTFail() }
        doc.harmonies.append(EditorHarmony(bar: 0, staff: 2, symbol: try ChordSymbol.parse("Dm7")))
        let both = try ChangesSource(piece: LibraryPiece(source: .score(doc)), from: 0, through: 3)
        XCTAssertEqual(both.staffs, [1, 2])
        XCTAssertEqual(try both.plan(staff: 2).steps[0].chord.symbol.label, "Dm7")
    }
    func testPlansIgnoreRenamesButInvalidateMusicalChanges() throws {
        let original = try source([(0, 0, "Dm7")])
        let first = try original.plan(staff: 1)
        guard case .score(var doc) = original.piece.source else { return XCTFail() }
        doc.title = "Renamed"
        XCTAssertEqual(
            try ChangesSource(piece: LibraryPiece(source: .score(doc)), from: 0, through: 3).plan(staff: 1).id, first.id
        )
        doc.harmonies[0].symbol = try ChordSymbol.parse("G7")
        XCTAssertNotEqual(
            try ChangesSource(piece: LibraryPiece(source: .score(doc)), from: 0, through: 3).plan(staff: 1).id, first.id
        )
    }
    func testPracticeRequiresAcceptedAnswerAndKeepsHintAndRetryEvidence() throws {
        var practice = try ChangesPractice(plan: .example, mode: .guides)
        let wrong = try practice.answer([60])
        XCTAssertEqual(practice.cursor, 0)
        try practice.accept(wrong)
        XCTAssertEqual(practice.misses, 1)
        practice.reveal()
        let right = try practice.answer([53, 60])
        XCTAssertTrue(right.assisted)
        XCTAssertEqual(right.ordinal, 2)
        try practice.accept(right)
        XCTAssertEqual(practice.cursor, 1)
        XCTAssertEqual(practice.hinted, 1)
        XCTAssertFalse(practice.assisted)
        XCTAssertThrowsError(try practice.accept(right))
        for notes in [[53, 59], [52, 59]] { try practice.accept(practice.answer(notes)) }
        XCTAssertTrue(practice.finished)
        XCTAssertEqual(practice.completed, 3)
        XCTAssertThrowsError(try practice.answer([52, 59]))
    }
    func testForgedAndInvalidAttemptsCannotAdvance() throws {
        var practice = try ChangesPractice(plan: .example, mode: .roots)
        var attempt = try practice.answer([60])
        attempt.outcome = .correct
        XCTAssertThrowsError(try practice.accept(attempt))
        XCTAssertEqual(practice.cursor, 0)
        for notes in [[], [-1], [128], Array(repeating: 62, count: 129)] {
            XCTAssertThrowsError(try practice.answer(notes))
        }
        attempt = try practice.answer([62])
        attempt.assisted = true
        XCTAssertThrowsError(try practice.accept(attempt))
    }
}
