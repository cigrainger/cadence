# Verification

Run from the repository root on macOS with Xcode/Swift 6 and Python 3.11+ and Node.js 24+. CI selects Xcode 26.3 explicitly; local builds honour DEVELOPER_DIR. The formatter omits the multiline-string reflow option because older and newer Swift toolchains encode its default differently.

```sh
python3 Scripts/check_repository.py
python3 -m unittest discover -s Scripts -p 'test_*.py'
node --test Scripts/test_site.cjs
./verify.sh --tests-only
./verify.sh
```

The first command checks public-repository hygiene, vendor hashes, license policy, dependency pins and website links, and generates `.verification/cadence.cdx.json`. Gitleaks is a separate gate (`Scripts/scan_secrets.sh`). The full native workflow builds a fresh release app, verifies its ad hoc signature/resources, renders audio silently and runs deterministic desktop scenarios. It produces logs, JSON assertions and screenshots in `.verification`, not Git. It fails on a missing or stale report.

## What tests establish

Core tests cover musical happy paths and meaningful failure/adversarial cases: invalid pitches/notation, archive traversal and oversized entries, unsupported transcription, injected provider errors, persistence conflict/corruption, stale reviews, assisted versus independent evidence, MIDI timing and cancellation. Native state tests check save/retry and feature integration. Owner tests cover disk conflicts, corruption, failed commits without publication, missing pieces with retained notes, size/identity limits, legacy snapshots and observation forwarding. Signing tests reject development certificates, missing timestamps/runtime, debugger entitlements, failed notarisation and missing tickets. Website controller tests run real code with silent fake audio and cover visible/sounding pitch agreement, cancellation while audio resumes, stop, completion and unavailable sound. Original fixtures keep the workflow independent of paid models or private books.

Coverage is measured separately for **MusicCore** and the **Cadence app**. The core has a 90% line-coverage regression floor. The two workspace owners have a separate 85% line-coverage regression floor. The whole-app figure retains every application source file, including views and diagnostics: a high owner/core figure is not whole-app UI coverage. Native screenshot checks complement state tests; they do not replace VoiceOver, physical-instrument or human musical review.

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
