// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore

// Used only by isolated UI previews and the local persistence check.
enum LearningPreview {
    static var library: LearningLibrary {
        var profile = LearnerProfile()
        profile.background = "I know open chords but lose the pulse while changing shapes."
        let brief = LearningBrief(
            profile: profile, focus: .style, target: "Blues rhythm guitar",
            detail: "Keep a steady groove and begin adding short melodic responses.")
        let json = #"""
            {"title":"A steadier blues rhythm","summary":"Build a relaxed pulse, keep it through chord changes, then leave room for a short melodic response. Use four short sessions a week and repeat each stage until it feels comfortable.","sourceNotes":"Built-in preview data: general blues exercises, not an analysis of a specific recording. This plan assumes you can play A, D, and E open chords.","questions":["Would you prefer a straight or a swung feel?"],"steps":[
            {"title":"Keep the pulse through one chord","focus":"Separate the timing of your strumming hand from the work of changing shapes. Keep the movement small and relaxed.","activities":[{"title":"Find a comfortable pulse","instructions":"Tap four even beats while counting aloud. Start slowly enough that you can stay relaxed. Keep the pulse going while you say a short sentence.","minutes":4},{"title":"Add one chord","instructions":"Hold A and strum once on each beat. Try four bars, rest, then repeat. If it feels tense, use muted strings and return to the chord later.","minutes":6},{"title":"Leave space, keep time","instructions":"Play A for three beats and leave beat four silent. Keep your hand moving through the silence. Repeat, listening for an even return to beat one.","minutes":10}],"application":"Use this pulse underneath a simple blues accompaniment before adding a swung feel or chord changes.","readyWhen":"You can play eight relaxed bars and keep the pulse during the silent beats.","tool":"rhythm"},
            {"title":"Make room for the chord change","focus":"Move the fretting hand without asking the strumming hand to stop keeping time.","activities":[{"title":"Prepare the next shape","instructions":"Alternate A and D slowly, allowing a full bar for each. Watch for fingers that can move together. Stop and reset if your hand tightens.","minutes":8},{"title":"Keep the last beat light","instructions":"Play three beats, use the fourth to prepare the next chord, and arrive on the next downbeat. Repeat with A to E. Add the fourth strum only when comfortable.","minutes":12}],"application":"Try these changes in a simple blues progression you already know, keeping the same easy pulse.","readyWhen":"You can change between A, D, and E on the downbeat for two rounds without rushing.","tool":"chords"},
            {"title":"Answer the groove with a short phrase","focus":"Hear a melodic idea before reaching for more notes. Silence is part of the response.","activities":[{"title":"Sing a small response","instructions":"Play two bars of A, pause, and sing a short two- or three-note idea. Repeat it until you can remember it.","minutes":8},{"title":"Find and answer","instructions":"Find the sung notes slowly on one string. Play the accompaniment again, then your response. Keep it short enough to return to the pulse without rushing.","minutes":12}],"application":"Use your phrase as a call and response after a short stretch of accompaniment. Change one note or its rhythm at a time.","readyWhen":"You can repeat your response on purpose and return to the groove while keeping time.","tool":"scaleDegrees"}
            ]}
            """#
        var library = LearningLibrary()
        library.profile = profile
        if let outline = try? PathwayOutline.decodeReply(json, brief: brief) {
            library.add(LearningPathway(brief: brief, outline: outline))
        }
        return library
    }
}
