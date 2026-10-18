// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

extension AppState {
    /// Shared stop boundary for playback, recording and owned input sessions. Completed
    /// pending results stay with their sessions so stopping cannot discard work.
    func stopAllPlayback(keepingMetronome: Bool = false) {
        rehearsalSession.stop()
        playAlongSession.timing.cancel()
        timedSession.cancel()
        timedChangesSession.cancel()
        reharmTransport.stop()
        reharmInput.pause()
        tensionInput.pause()
        triadInput.pause()
        pickingInput.pause()
        microphonePhraseSession.cancel()
        earInput.pause()
        scoreEarInput.pause()
        adaptiveInput.pause(held: midi.keyboard.downNotes)
        songInput.pause()
        earDailyInput.pause()
        changesSession.pause(held: midi.keyboard.downNotes)
        if !keepingMetronome || !audio.isMetronome { audio.stop() }
        microphone.stop()
    }
}

/// Observe transports here, not through AppState: a moving playback clock must
/// not invalidate the entire window's theory and notation views on every tick.
struct PlaybackBar: View {
    let stop: () -> Void
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var microphone: Microphone
    @ObservedObject var timed: TimedPracticeSession
    @ObservedObject var changes: TimedChangesSession
    @ObservedObject var playAlong: TimedPracticeSession
    @ObservedObject var rehearsal: TimedPracticeSession
    @ObservedObject var take: PianoTakePlayer
    @ObservedObject var reharm: ReharmTransport
    @ObservedObject var acoustic: MicrophonePhraseSession

    init(state: AppState) {
        stop = { state.stopAllPlayback() }
        audio = state.audio
        microphone = state.microphone
        timed = state.timedSession
        changes = state.timedChangesSession
        playAlong = state.playAlongSession.timing
        rehearsal = state.rehearsalSession.timing
        take = state.rehearsalSession.takePlayer
        reharm = state.reharmTransport
        acoustic = state.microphonePhraseSession
    }

    private var active: Bool {
        microphone.listening || audio.isPlaying || timed.busy || changes.busy || playAlong.busy || rehearsal.busy
            || take.busy || reharm.busy || acoustic.busy
    }
    private var status: String {
        if let error = audio.error { return error }
        if reharm.recording { return "Recording your improvisation" }
        if audio.isMetronome { return "Metronome · \(audio.metronomeSettings?.bpm ?? 84) bpm" }
        if microphone.listening { return "Listening on this Mac" }
        if active { return "Playback active" }
        return "Ready when you are"
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "waveform" : "headphones").foregroundStyle(Color.moss).accessibilityHidden(true)
            Text(status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Stop all", systemImage: "stop.fill", action: stop)
                .controlSize(.small).disabled(!active)
                .help("Stop playback, count-ins, microphone and recording (⌘.)")
            Text("⌘1–4 to navigate").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.vertical, 7).background(Color.paper)
    }
}
