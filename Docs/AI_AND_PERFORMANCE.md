# AI connections and performance coaching

Design proposal, October 2026. These are next steps, not supported features. Current AI requests use OpenRouter; current microphone input provides a clean single-note YIN pitch estimate, held-note checks and a basic quantised transcription. It does not yet provide calibrated acoustic onset timing, polyphonic grading or technique diagnosis.

## Bring your own key, bring your own model

Settings should manage named connections, then assign a connection and model to **Coaching**, **Score import** and later **Performance feedback**. The composer and practice engines remain usable without AI. A request shows its destination and included information before sending. Switching settings must not change an in-flight request's destination, credential, model or saved provenance.

| Connection | First supported use | Integration boundary |
| --- | --- | --- |
| OpenRouter | Keep existing coaching and reviewed transcription | Preserve current Keychain identity, model setting and enforced request privacy fields |
| OpenAI API | Direct text coaching, followed by tested image import | Bearer API credential; Responses adapter rather than treating every provider as OpenRouter |
| Anthropic API | Direct text coaching, followed by tested image import | Messages adapter, including its distinct authentication, system-message and response formats |
| Ollama / LM Studio | User-selected models through a local server | OpenAI-compatible adapter, explicit server URL and model ID; no invented API credential requirement |
| Other compatible servers | A deliberately configured endpoint | HTTPS for remote servers; plain HTTP limited to literal loopback addresses; redirects rejected |
| GitHub Copilot | A separately evaluated authenticated connection | Official SDK/sign-in flow, subscription/policy checks and runtime packaging; never scrape an editor's stored tokens |

A provider-independent request should carry bounded text/image content, the intended task, token limit and explicit optional reasoning settings. Each adapter translates supported capabilities and rejects unsupported ones before sending. A local text model must not appear to support PDF transcription merely because its server implements chat. Validated task-specific reply schemas remain in MusicCore. Avoid a universal agent runtime or tools with shell/filesystem access for a coaching conversation.

Store credentials per connection in Keychain. Ordinary settings contain only identifiers, endpoint, model and capability choices. Keep the existing OpenRouter migration intact. Resolve a credential only when explicitly sending; freeze the connection snapshot then. Preserve deadlines, cancellation, save-only recovery, redacted errors and no automatic paid retries. No provider fallback may send a score to another destination without the learner choosing it. OpenRouter's ZDR request fields must not become a claim that another provider offers the same retention policy.

“Local server” is a connection description, not proof of offline execution: a server can proxy to a cloud model. Show that distinction, and test genuine on-device use with networking unavailable. Cadence need not download or run models itself in the first version.

First acceptance: the same contextual question works through each of OpenRouter, direct OpenAI, direct Anthropic and a local compatible server. An existing installation retains its key and model. Cancellation and local save failure retain existing semantics; keys never cross connections or appear in saved conversations. Injected senders cover provider wire formats, errors, truncation, missing capabilities, redirects and destination validation. Live smoke tests are explicit opt-in and use an original bounded example. Copilot remains a separate acceptance item until its official authentication and redistributable runtime have been exercised.

Official references: [OpenAI API authentication](https://developers.openai.com/api/reference/overview), [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create), [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility), [LM Studio server](https://lmstudio.ai/docs/developer/core/server), [Copilot SDK authentication](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate).

## Measure locally; coach from evidence

The musical goal is a short feedback loop: **record → inspect → choose one change → retry → return independently**. Show the source score, the take and the evidence together. One useful suggestion beats a wall of scores. A learner can hear the passage, inspect a highlighted note, challenge a match and keep a take without requesting AI feedback.

The measurement layer captures unquantised observations. A score matcher aligns them to expected sounding pitches, timing and expressive instructions, with explicit unmatched/ambiguous notes. The practice policy decides which comparisons are suitable for the activity and records assisted versus independent evidence. The optional coach explains that evidence and proposes a reviewed next step. AI text cannot assign practice credit, alter a take or infer measurements that the detector did not provide.

Keep separate:

- **Observation:** measured pitch contour, onset candidate, amplitude envelope, capture timestamp, detector version and quality indicators.
- **Comparison:** score event/voice, match confidence, expected versus observed timing/pitch, and missing/extra/ambiguous events.
- **Interpretation:** possible musical intent, a cautious hypothesis and an actionable experiment. Physical technique is not observable from these signals alone.

Retain sample positions and the audio device's host-clock timestamp, not just the time the analysis queue finishes. The current microphone callback discards its supplied audio time and publishes after analysis; those timestamps cannot establish millisecond attack accuracy. Microphone latency needs its own calibration, separate from MIDI. Keep raw observations separate from notation quantisation. Unknown latency, noise, clipping, insufficient sustained pitch and uncertain matching should produce an inconclusive comparison rather than a confident mark against the learner.

For microphone input, amplitude is an envelope/RMS measurement, not MIDI velocity. Room acoustics, microphone distance, gain and automatic processing complicate loudness comparisons. Pitch-detector confidence is not automatically a calibrated probability. A bend needs a trajectory relative to a known starting/target pitch, not only its highest detected frequency. Retain enough information to revisit an interpretation.

Suggested first exercise: play or sing a short, clean monophonic phrase at a comfortable tempo. Show the measured pitch against its intended note, then one timing or intonation target when the signal supports it. Save a baseline, focused retry and later independent return. Add controlled bend/vibrato exercises only after sustained-note contours and capture timing are validated. Polyphonic acoustic assessment follows a benchmark rather than a promise of perfect chord recognition.

Spotify's [Basic Pitch](https://github.com/spotify/basic-pitch) is a candidate for an offline transcription experiment: it supports polyphony and pitch bends, works best on one instrument at a time, and includes a Core ML conversion. That is not evidence of teacher-level grading accuracy or a turnkey Swift live-analysis integration. Benchmark its model/runtime and postprocessing, latency, memory and licensing before adding it to the bundle. Compare against the existing lightweight detector for monophonic tasks; do not add a large runtime solely because a model is available.

## More instruments through capabilities

Separate the instrument someone practises from the score editor's current piano/guitar layout. A practice profile can describe sounding range, written-to-sounding transposition, tuning/reference pitch and supported inputs. Activities request capabilities: single-note pitch, rhythmic attack, MIDI polyphony, guitar string/fret positions or piano hand roles. Unsupported activities explain what input they need.

Flute, violin, bass and voice could share appropriate listening, theory, rhythm and single-note exercises. A drum needs onset/rhythm assessment rather than pitched-note grading. Guitar fingering, piano hands, bowing and embouchure remain distinct. Start with one additional instrument and a real musician before claiming general instrument support; changing the instrument label is not a validated teaching method.

## Validation before grading claims

Use original synthetic fixtures with known frequencies, onset positions and pitch trajectories, plus consented recordings on real devices. Cover silence, noise, room reverberation, accompaniment leakage, octaves, low/high registers, clipping, distortion and interrupted capture. Measure errors by instrument and input method, including uncertainty and abstention. Keep a small held-out set rather than tuning every threshold on the acceptance examples.

MIDI can provide a comparison reference for piano attacks, but it is not ground truth for every acoustic onset or expressive intention. Test delayed and freely expressive performances as well as mistakes. Separate rubric choices (straight time, swing, rubato, intentional laid-back playing) from physical measurements. A consistently late onset does not establish a string-changing or posture problem. The coach can propose an experiment to investigate it, with uncertainty visible.

Raw recordings stay on the Mac unless the learner explicitly chooses to send them to a named provider. A first performance-coaching request needs only the selected score passage, task/rubric and compact evidence summary. Exact takes, derived measurements and source links remain reviewable locally. Do not describe interpretive text as measured fact or present adaptation as educationally validated before teacher and learner testing.
