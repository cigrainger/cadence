# Verification

Run from the repository root on macOS with Xcode/Swift 6.2 or later, Python 3.11+ and Node.js 24+. CI selects Xcode 26.3, Python 3.13 and Node.js 24 explicitly; setup actions are pinned to immutable revisions and dependency caching is disabled. Local builds honour DEVELOPER_DIR. All first-party targets use Swift 6 language mode. Test and release builds treat warnings as errors; the verifier also rejects first-party SDK-boundary warnings that the compiler leaves as warnings. The formatter omits the multiline-string reflow option because older and newer Swift toolchains encode its default differently.

```sh
python3 Scripts/check_repository.py
python3 -m unittest discover -s Scripts -p 'test_*.py'
node --test Scripts/test_site.cjs
./verify.sh --tests-only
./verify.sh --skip-accessibility --skip-audio-output  # macOS CI with WindowServer
./verify.sh
```

The first command checks public-repository hygiene (including new nonignored files), vendor hashes, license policy, dependency pins, package-wide Swift 6 mode and website links, and generates `.verification/cadence.cdx.json`. Gitleaks is a separate gate (`Scripts/scan_secrets.sh`). The full native workflow builds a fresh release app and stages a separate instrumented debug app from the matching unit-test build. It verifies both with the same deterministic scenarios, ad hoc signatures, renderer assertions and original fixtures. It produces logs, JSON assertions and screenshots in `.verification`, not Git. It fails on a missing or stale report.

## What tests establish

Core tests cover musical happy paths and meaningful failure/adversarial cases: invalid pitches/notation, archive traversal and oversized entries, unsupported transcription, injected provider errors, persistence conflict/corruption, stale reviews, assisted versus independent evidence, MIDI timing and cancellation. Native state tests check save/retry and feature integration. Owner tests cover disk conflicts, corruption, failed commits without publication, missing pieces with retained notes, size/identity limits, legacy snapshots and observation forwarding. Signing tests reject development certificates, missing timestamps/runtime, debugger entitlements, failed notarisation and missing tickets. Website controller tests run real code with silent fake audio and cover visible/sounding pitch agreement, bass harmonics and isolated-bass comparison, cancellation while audio resumes or listening mode changes, stop, completion and unavailable sound. Original fixtures keep the workflow independent of paid models or private books.

Coverage is measured separately for **MusicCore** and the **Cadence app**, with distinct unit-only and combined native-workflow results. The core has a 90% line-coverage floor; the three workspace owners retain 85% and the changed learning/import orchestration retains 80%. The complete app has a 12% unit-only floor and a 50% combined floor. Combined device/request owner coverage must reach 80%. These are regression gates, not claims that every important behaviour is covered. Every first-party source file, including views and diagnostics, must appear in the inventory. Native execution coverage does not establish assertion quality, accessibility or musical accuracy by itself.

Before unit tests, remove old raw profiles as well as old exports so filtered runs cannot inflate a later full run. Full verification captures a unique profile for every instrumented app process, merges it with a copied unit profile and exports against copied matching binaries. Release binaries are tested separately and are never mixed into debug profile mappings. Hashes bind the objects, unit export and unit profile; fresh timestamps and expected process counts guard collection. LLVM warnings, missing sources and source/test changes during verification fail the run. `summary.json` keeps the existing `coverage` field as unit-only coverage (also labelled `unitCoverage`) and adds a separately named `combinedCoverage`. It also records native scenario results, skipped checks, toolchain and input digests. The per-file HTML report lives under `.verification/native-coverage/<run-id>/html/index.html`.

## Before release

Inspect representative screenshots at compact and large sizes: practice home, full score/editor, library, import/review, piano/guitar activities, general/AI/about settings and storage failure. Confirm focus/labels, selection semantics, discoverable exits, readable disabled reasons, score context and stop behaviour. Update the guide whenever actual controls differ from its instructions.

Manually test a connected MIDI keyboard, microphone permission denied/granted, audio-device changes, different display scaling and VoiceOver. These are explicit manual gaps if no hardware or accessibility session was used; do not label virtual MIDI as physical testing.

## Performance observations

```sh
CADENCE_BENCHMARK=1 swift test --filter PerformanceSmokeTests
```

These opt-in XCTest measurements cover guitar voicings across roots and a 128-bar score round trip. Compare on the same machine and toolchain. They deliberately impose no universal millisecond threshold; use a profiler and real long scores before making latency guarantees. Normal CI skips these timing observations.

## Website

`python3 Scripts/build_site.py` builds `site/dist` and checks internal links/anchors. Serve it at a `/cadence/` project path when reviewing GitHub Pages behaviour. Check desktop and phone widths, keyboard focus, the audible A/B example, stopped/finished states, guide search and browser console. No external scripts/fonts/analytics are required.

## Learning journeys and accessibility actions

The first complete journey has core and native tests for original piano/guitar scores, scoped evidence, common-tone recognition, a multi-answer opening, starting-shape verification, interrupted MIDI, whole-progression completion, failed saves and idempotent retry, current-source guards, an eight-bar creative artifact and delayed transfer to the other piece. Received PDF replies have explicit save-only retry tests, including disk conflicts and stale/cancelled results. No paid model requests are required.

Full verification requires an unlocked macOS session and Accessibility access for the invoking developer terminal; the external runner fails clearly if a connection is unavailable and never changes system permissions. A locked session can still render screenshots while refusing accessibility requests. A quick `--tests-only` run needs neither desktop controls nor output playback. macOS CI runs the native previews and combined coverage with `--skip-accessibility --skip-audio-output`: the report explicitly lists the unexecuted accessibility scenario and four live output checks. Offline synthesis, sampler rendering, virtual MIDI, storage and renderer checks still run. Neither skip option can hide another failure or claim a device result.

Full verification includes native course-map previews at compact/large sizes and for both instruments. The isolated `--song-preview --song-ax` scenario uses actual accessibility controls to answer incorrectly, retry with support visible, select the arrangement chapter, verify an unfinished arrangement cannot be finished, open its eight bars, return to the map and open the full source piece. The runner also opens the contextual coach beside the full score, enters a question through the accessibility text control, closes/reopens it, visits Library/Explore/Studio and returns to Learn. It requires the draft and source selection to survive. A separate native editor round trip checks that selected-event and undo history survive view teardown. Coach typing has MIDI and shortcut guards. The Swift 6 runner activates only the child it launched so an accessory preview exposes its accessibility tree reliably. It never targets a user's existing app. Reports must contain the required action results; screenshots alone cannot satisfy the gate. These actions do not test VoiceOver speech, a complete keyboard route, or physical devices. Complete the hands-on matrix in [Device testing](DEVICE_TESTING.md) before claiming those outcomes.

Device boundary tests use injected input, permission responses and a clock. They cover refusal, cancelled starts, grant-after-stop, an old refusal after a new start, background buffer delivery, stale callbacks, held pitch, silence and transcription finalisation. They do not grant/deny real macOS permissions. Settings/catalogue tests use memory storage and a fake sender; paid-reply tests retain a received result across disk failure and reject cancelled/stale completions. Renderer tests check the actual Objective-C delegate selector, main-frame ownership and malformed/nonfinite layouts. Request probes and mutable fault controls have explicit actor ownership; do not add unchecked Sendable or actor assumptions to make migration green.

Window-level Space-key routing runs inside the launched native app host, in both production and instrumented self-checks. It creates two private fixture windows and checks timestamp forwarding, repeats, modifiers, text focus, inactive/detached views, other keys/windows and monitor cleanup. It is required even with audio-output/accessibility skips. Command-line unit tests retain timing and rhythm policy; they do not initialise NSApplication to create windows.

The native self-check opens a MIDI client before audio setup and retains it through the complete run. It requires `midiClientRetained` as well as actual virtual notes, releases and timestamps. A framework/client error is reported directly rather than hidden behind missing downstream checks. A MIDI startup failure is never converted to a skip or an automatic retry. Keep the client alive while doing other work; disposing the last one can let MIDIServer idle out and invalidate the process's CoreMIDI connection.
