// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum StudyExamples {
    /// An original four-bar two-voice exercise. Guitar notation is written an
    /// octave above sounding pitch, explicitly encoded with MusicXML transpose.
    public static var smallSteps: String {
        let melodies = [
            [("E", 5, 4), ("G", 5, 4), ("A", 5, 4), ("G", 5, 4)],
            [("F", 5, 4), ("E", 5, 2), ("D", 5, 2), ("C", 5, 4), ("D", 5, 4)],
            [("D", 5, 4), ("F", 5, 4), ("G", 5, 4), ("B", 4, 4)],
            [("C", 5, 8), ("E", 5, 4), ("C", 5, 4)],
        ]
        let bass = [("C", 4), ("F", 4), ("G", 4), ("C", 4)]
        let frets: [String: (Int, Int)] = [
            "E5": (1, 0), "G5": (1, 3), "A5": (1, 5), "F5": (1, 1), "D5": (2, 3), "C5": (2, 1), "B4": (2, 0),
        ]
        let bassFrets = [(5, 3), (4, 3), (3, 0), (5, 3)]
        func technical(_ position: (Int, Int)) -> String {
            "<notations><technical><string>\(position.0)</string><fret>\(position.1)</fret></technical></notations>"
        }
        let bars = melodies.enumerated().map { index, melody in
            let attributes =
                index == 0
                ? "<attributes><divisions>4</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef><transpose><diatonic>0</diatonic><chromatic>0</chromatic><octave-change>-1</octave-change></transpose></attributes><direction><direction-type><words>Evenly, let the bass ring</words></direction-type><sound tempo=\"84\"/></direction>"
                : ""
            let notes = melody.map { step, octave, duration in
                let position = frets[step + String(octave)]!
                return
                    "<note><pitch><step>\(step)</step><octave>\(octave)</octave></pitch><duration>\(duration)</duration><voice>1</voice><type>\(duration == 8 ? "half" : duration == 2 ? "eighth" : "quarter")</type><stem>up</stem>\(technical(position))</note>"
            }.joined()
            return
                "<measure number=\"\(index+1)\">\(attributes)\(notes)<backup><duration>16</duration></backup><note><pitch><step>\(bass[index].0)</step><octave>\(bass[index].1)</octave></pitch><duration>16</duration><voice>2</voice><type>whole</type>\(technical(bassFrets[index]))</note>\(index == 3 ? "<barline location=\"right\"><bar-style>light-heavy</bar-style></barline>" : "")</measure>"
        }.joined()
        return
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><score-partwise version=\"4.0\"><work><work-title>Small steps in C</work-title></work><identification><creator type=\"composer\">Cadence practice study</creator></identification><part-list><score-part id=\"P1\"><part-name>Guitar</part-name></score-part></part-list><part id=\"P1\">\(bars)</part></score-partwise>"
    }
}
