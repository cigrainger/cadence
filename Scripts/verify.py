#!/usr/bin/env python3
"""Local release checks. No API keys, paid model requests or microphone access."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from build_inputs import source_digest
from native_arguments import native_arguments
from native_coverage import NativeCoverage, check_source_inventory, reset_unit_coverage
from swift_build_config import SWIFT_TEST_FLAGS

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def require_flags(report, names, label):
    missing = [name for name in names if report.get(name) is not True]
    require(not missing, f"{label}: missing or failed checks: {', '.join(missing)}")


def check_group(report, key, names):
    group = report.get(key, {})
    require(isinstance(group, dict), f"Invalid {key}")
    require_flags(group, names, key)
    require(all(value is True for value in group.values()), f"{key} contains a failed check")


def check_native(report, skip_audio_output):
    require(not report.get("error"), "Native self-check failed: " + str(report.get("error")))
    output = ["audioOutput", "timedAudioScheduled", "metronomeOutput", "studyLoopOutput"]
    require(report.get("skippedChecks") == (output if skip_audio_output else []),
            "Native self-check skipped unexpected work")
    require(not skip_audio_output or all(name not in report for name in output),
            "Skipped audio checks cannot also claim device results")
    required = ["passed", "pdfBatchPassed", "libraryPassed", "piecePathwayPassed", "virtualMIDITimestamps", "midiClientRetained", "spaceTapPassed",
                "sampledBand", "bundledSoundBank", "earPathway", "expressionDynamics", "expressionStaccato"]
    require_flags(report, required + ([] if skip_audio_output else output), "native app")


def test_counts(log):
    require(not re.search(r"Test (?:Case|Suite).*failed", log), "A test failed")
    # SwiftPM 6.2 combines targets; 6.4 can launch separate XCTest bundles.
    # Both formats must finish after the final case, with evidence from each target.
    counts = {}
    for target in ("MusicCoreTests", "CadenceTests"):
        cases = list(re.finditer(r"Test Case '-\[" + target +
                                 r"\.([^]]+)\]' (started|passed|skipped)", log))
        terminal = {case.group(1): case.group(2) for case in cases}
        require(terminal and all(status != "started" for status in terminal.values()),
                f"Missing or unfinished XCTest cases for {target}")
        names = {name for name, status in terminal.items() if status == "passed"}
        require(names, f"No passing XCTest cases found for {target}")
        completions = list(re.finditer(r"Test Suite '(?:" + target +
                                      r"|CadencePackageTests)\.xctest' passed", log))
        require(any(completion.start() > cases[-1].end() for completion in completions),
                f"Missing completion for {target}")
        counts[target] = len(names)
    return counts


def require_clean_swift(log, root=ROOT):
    prefixes = tuple(str(root / folder) + "/" for folder in ("Sources", "Tests"))
    warnings = [line for line in log.splitlines() if line.startswith(prefixes) and ": warning:" in line]
    require(not warnings, "First-party Swift warnings remain:\n" + "\n".join(warnings))


def test_inputs_digest(root=ROOT):
    digest = hashlib.sha256()
    for path in sorted((root / "Tests").rglob("*.swift")):
        digest.update(str(path.relative_to(root)).encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def summarize_coverage(document):
    result = {}
    for module in ("MusicCore", "Cadence"):
        files = [file for data in document["data"] for file in data["files"]
                 if f"/Sources/{module}/" in file["filename"]]
        require(files, f"Missing {module} coverage")
        totals = {}
        for kind in ("lines", "regions", "functions"):
            count = sum(file["summary"][kind]["count"] for file in files)
            covered = sum(file["summary"][kind]["covered"] for file in files)
            totals[kind] = {"count": count, "covered": covered,
                            "percent": round(100 * covered / count, 2) if count else 0}
        result[module] = {"files": len(files), **totals}
    # The full Cadence denominator above is retained, including views and diagnostics.
    # These additional gates protect the owners and orchestration changed here.
    groups = {
        "WorkspaceOwners": ["Infrastructure/Storage/PracticeWorkspace.swift",
                            "Infrastructure/Storage/LibraryWorkspace.swift",
                            "Infrastructure/Storage/CourseWorkspace.swift"],
        "LearningWorkflows": ["Infrastructure/Import/PDFImportQueue.swift",
                              "Infrastructure/AI/SavedRequest.swift",
                              "Features/Journey/SongJourneyState.swift",
                              "Features/Journey/SongOpeningInput.swift"],
        "DeviceAndRequestOwners": ["Infrastructure/AI/AISettings.swift", "Infrastructure/AI/AIModelCatalog.swift",
                                   "Infrastructure/AI/ContextCoachSession.swift",
                                   "Infrastructure/AI/SavedRequest.swift", "Infrastructure/AI/PieceCoachSession.swift",
                                   "Infrastructure/Audio/Microphone.swift", "Infrastructure/Audio/MicrophoneInput.swift",
                                   "Infrastructure/MIDI/MIDIKeyboard.swift",
                                   "Features/Practice/CalibratedPracticeSession.swift"],
    }
    for label, paths in groups.items():
        files = [file for data in document["data"] for file in data["files"]
                 if any(file["filename"].endswith("/Sources/Cadence/" + path) for path in paths)]
        count = sum(file["summary"]["lines"]["count"] for file in files)
        covered = sum(file["summary"]["lines"]["covered"] for file in files)
        result[label] = {"files": len(files), "lines": {"count": count, "covered": covered,
                         "percent": round(100 * covered / count, 2) if count else 0}}
    return result


def record_combined_coverage(report, combined):
    require(report.get("coverage") == report.get("unitCoverage"), "The legacy coverage field must remain unit-only")
    for module in ("MusicCore", "Cadence"):
        unit = report["unitCoverage"][module]
        native = combined[module]
        require(unit["files"] == native["files"] and unit["lines"]["count"] == native["lines"]["count"],
                f"Combined {module} coverage changed the unit-test denominator")
        require(native["lines"]["covered"] >= unit["lines"]["covered"],
                f"Combined {module} coverage lost unit-covered lines")
    report["combinedCoverage"] = combined


def run(command, log, env, timeout):
    print(f"Running {log.stem}…", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen([str(arg) for arg in command], cwd=ROOT, env=env,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Sample only this isolated child before terminating it. A blocked
            # UI thread otherwise leaves neither a report nor an actionable log.
            if sys.platform == "darwin":
                diagnostic = log.with_name(log.stem + ".sample.log")
                try:
                    subprocess.run(["/usr/bin/sample", str(process.pid), "1", "-file", str(diagnostic)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            # Only terminate this check and its children, never a user's Cadence.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise RuntimeError(f"Stopped {log.stem}; see {log}")
    if code != 0:
        # CI must expose a useful failure even when artifact upload also fails.
        print("\n".join(log.read_text(errors="replace").splitlines()[-80:]), file=sys.stderr)
    require(code == 0, f"{log.stem} exited {code}; see {log}")


def native_scenarios():
    editor = ["offline", "allEventsMapped", "selectionIDsValid", "selectedFirst", "selectedLast", "playbackHighlight", "distinctVoices", "continuousPlayhead"]
    smooth = ["twoSources", "fiveSteps", "fourStudies", "epubReadable", "unreviewedBlocked", "midiEvidence", "spacedReview", "sessionBudget"]
    song = ["sourceLinked", "eightBarSource", "openMilestones", "noPaidRequests"]
    return [
        ('song-pathway', ['--song-preview', '--width', '1350', '--height', '1050'], [], 'songJourneyChecks', song),
        ('song-pathway-small', ['--song-preview', '--width', '1120', '--height', '800'], [], 'songJourneyChecks', song),
        ('song-pathway-guitar', ['--song-preview', '--song-guitar', '--width', '1350', '--height', '1050'], [], 'songJourneyChecks', song),
        ('song-opening', ['--song-preview', '--song-opening', '--width', '1350', '--height', '1050'], [], 'songJourneyChecks', song),
        ('song-arrangement', ['--song-preview', '--song-arrangement', '--width', '1350', '--height', '1050'], ['offline'], 'songJourneyChecks', song),
        ('workspace-editor-return', ['--screen', 'editor', '--song-preview', '--workspace-editor-roundtrip', '--width', '1350', '--height', '1050'], ['offline'], 'nativeEditing', ['navigationKeepsSelection', 'navigationKeepsUndo']),
        ('song-coach', ['--song-preview', '--coach-panel', '--width', '1500', '--height', '1050'], [], 'songJourneyChecks', song),
        ('song-coach-small', ['--song-preview', '--coach-panel', '--width', '1120', '--height', '800'], [], 'songJourneyChecks', song),
        ('piece-coach', ['--song-preview', '--coach-panel', '--coach-piece', '--width', '1500', '--height', '1050'], ['offline'], 'nativeEditing', ['coachBlocksMIDI', 'coachDisablesNoteShortcuts']),
        ('song-accessibility', ['--song-preview', '--song-ax', '--width', '1350', '--height', '1050'], [], 'songJourneyChecks', song + ['accessibleMilestones', 'accessibleFullScore', 'theoryMissOffersRetry', 'theoryRetryKeepsSupportVisible', 'opensEightBarArrangement', 'unfinishedArrangementCannotFinish', 'returnsToMap', 'opensFullPiece', 'coachAlongsideFullScore', 'coachDraftSurvivesClosure', 'sectionsKeepFullScore', 'coachDraftSurvivesNavigation', 'learnReturnsToPathway']),
        ('reharm', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones']),
        ('reharm-explain', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-explain'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones']),
        ('reharm-piano', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-play'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones']),
        ('reharm-guitar', ['--reharm-detail', '--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-play', '--reharm-guitar'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones']),
        ('reharm-small', ['--reharm-detail', '--screen', 'practice', '--reharm-preview', '--width', '1120', '--height', '800', '--reharm-play', '--reharm-guitar'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones']),
        ('reharm-create', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-create'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones']),
        ('reharm-pending', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-pending'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones', 'pendingTakeRetained']),
        ('reharm-takes', ['--reharm-detail', '--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-takes'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones', 'recordedAndListened', 'savedFullAlternative']),
        ('reharm-ending', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-ending'], [], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones', 'savedFullAlternative']),
        ('reharm-complete', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-complete'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones', 'fourReviews', 'recordedAndListened']),
        ('reharm-review', ['--screen', 'practice', '--reharm-preview', '--width', '1350', '--height', '1050', '--reharm-review'], ['offline', 'focusMapped'], 'reharmChecks', ['sourceLinked', 'validState', 'sourceUnchanged', 'sharedGuideTones', 'independentReturn']),
        ('tension-editor-guard', ['--screen', 'practice', '--tension-preview', '--tension-ending', '--tension-editor-guard', '--width', '1350', '--height', '1050'], [], 'tensionChecks', ['sourceLinked', 'validState', 'savedLinkedEnding', 'analysisBlocksMIDI', 'analysisBlocksNoteKeys']),
        ('tension', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050'], [], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-explain', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-explain'], ['offline', 'focusMapped'], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-analysis', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-analysis'], ['offline', 'focusMapped'], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-reading', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-analysis', '--tension-reading'], [], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-piano', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-play'], ['offline', 'focusMapped'], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-guitar', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-play', '--tension-guitar'], ['offline', 'focusMapped'], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-small', ['--screen', 'practice', '--tension-preview', '--width', '1120', '--height', '760', '--tension-play', '--tension-guitar'], ['offline', 'focusMapped'], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests']),
        ('tension-create', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-create'], ['offline', 'focusMapped'], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests', 'pianoPitchEvidence']),
        ('tension-ending', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-ending'], [], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests', 'pianoPitchEvidence', 'savedLinkedEnding']),
        ('tension-complete', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-complete'], [], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests', 'pianoPitchEvidence', 'savedLinkedEnding', 'fourSeparateReviews']),
        ('tension-review', ['--screen', 'practice', '--tension-preview', '--width', '1350', '--height', '1050', '--tension-review'], [], 'tensionChecks', ['sourceLinked', 'validState', 'editableAlternatives', 'musicalSourceUnchanged', 'noPaidRequests', 'pianoPitchEvidence', 'independentHintsHidden']),
        ('triads-setup', ['--screen', 'practice', '--triad-preview', '--triad-setup', '--width', '1120', '--height', '760'], [], 'triadChecks', ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded']),
        ('triads', ['--screen', 'practice', '--triad-preview', '--width', '1350', '--height', '1050'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded']),
        ('triads-connect', ['--screen', 'practice', '--triad-preview', '--width', '1350', '--height', '1050', '--triad-connect'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded']),
        ('triads-small', ['--screen', 'practice', '--triad-preview', '--width', '1120', '--height', '760', '--triad-connect'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded']),
        ('triads-ear', ['--screen', 'practice', '--triad-preview', '--width', '1350', '--height', '1050', '--triad-ear'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded']),
        ('triads-create', ['--screen', 'practice', '--triad-preview', '--width', '1350', '--height', '1050', '--triad-create'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded', 'microphonePitchMatch']),
        ('triads-complete', ['--screen', 'practice', '--triad-preview', '--width', '1350', '--height', '1050', '--triad-complete'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded', 'microphonePitchMatch', 'spacedSupportedReview']),
        ('triads-answer', ['--screen', 'practice', '--triad-preview', '--width', '1350', '--height', '1050', '--triad-answer'], [], "triadChecks", ['sourceLinked', 'validState', 'separateEvidence', 'noMicrophonePermissionNeeded', 'microphonePitchMatch', 'editableSourceLinkedAnswer']),
        ('flow', ['--screen', 'practice', '--flow-preview', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery']),
        ('flow-hand', ['--screen', 'practice', '--flow-preview', '--flow-hand', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery']),
        ('flow-gaps', ['--screen', 'practice', '--flow-preview', '--flow-gaps', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery']),
        ('flow-live', ['--screen', 'practice', '--flow-preview', '--flow-live', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery', 'liveUngraded']),
        ('flow-small', ['--screen', 'practice', '--flow-preview', '--flow-gaps', '--width', '1120', '--height', '760'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery']),
        ('flow-context', ['--screen', 'practice', '--flow-preview', '--flow-context', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery', 'wholeReturn']),
        ('flow-complete', ['--screen', 'practice', '--flow-preview', '--flow-complete', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'flowChecks', ['fullScore', 'observedJoin', 'twoPassesSaved', 'suggestionAvailable', 'supportSaved', 'validState', 'noPracticeMastery', 'wholeReturn', 'reflectionSaved', 'returnUnassistedAudio']),
        ('hands-setup', ['--screen', 'practice', '--hands-preview', '--hands-setup', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'setupReady']),
        ('hands-right', ['--screen', 'practice', '--hands-preview', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll', 'feedbackMapped', 'feedbackClearOfNextSystem'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'rightPartnerSaved']),
        ('hands-left', ['--screen', 'practice', '--hands-preview', '--hands-left', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll', 'feedbackMapped', 'feedbackClearOfNextSystem'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'leftSaved']),
        ('hands-solo', ['--screen', 'practice', '--hands-preview', '--hands-left', '--hands-solo', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll', 'feedbackMapped', 'feedbackClearOfNextSystem'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'leftSaved']),
        ('hands-together', ['--screen', 'practice', '--hands-preview', '--hands-together', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll', 'feedbackMapped', 'feedbackClearOfNextSystem'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'togetherSaved']),
        ('hands-live', ['--screen', 'practice', '--hands-preview', '--hands-live', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll', 'feedbackMapped', 'feedbackClearOfNextSystem'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'liveUngraded']),
        ('hands-small', ['--screen', 'practice', '--hands-preview', '--hands-left', '--width', '1120', '--height', '760'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll', 'feedbackMapped', 'feedbackClearOfNextSystem'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'leftSaved']),
        ('hands-takes', ['--screen', 'practice', '--hands-preview', '--hands-takes', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'togetherSaved']),
        ('hands-context', ['--screen', 'practice', '--hands-preview', '--hands-context', '--width', '1350', '--height', '1050'], ['offline', 'focusMapped', 'continuousCursor', 'cursorCheckPreservesScroll'], 'handsChecks', ['fullScore', 'twoStaffOpening', 'validState', 'bothReturn']),
        ('shape-listen', ['--screen','practice','--shape-preview','--width','1350','--height','1050'], ['offline','focusMapped','continuousCursor','cursorCheckPreservesScroll'], 'shapeChecks', ['fullScore','takesSaved','comparable','pedalDistinct','validState']),
        ('shape-observations', ['--screen','practice','--shape-preview','--shape-observations','--width','1350','--height','1050'], ['offline','focusMapped'], 'shapeChecks', ['fullScore','takesSaved','reflectionSaved','validState']),
        ('shape-playing', ['--screen','practice','--shape-preview','--shape-playing','--width','1350','--height','1050'], ['offline','focusMapped','continuousCursor','cursorCheckPreservesScroll'], 'shapeChecks', ['fullScore','takesSaved','performanceCursor','validState']),
        ('shape-small', ['--screen','practice','--shape-preview','--width','1120','--height','760'], ['offline','focusMapped'], 'shapeChecks', ['fullScore','takesSaved','comparable','validState']),
        ('shape-empty', ['--screen','practice','--shape-preview','--shape-empty','--width','1350','--height','1050'], ['offline','focusMapped'], 'shapeChecks', ['fullScore','emptyHonest','validState']),
        ('shape-stale', ['--screen','practice','--shape-preview','--shape-stale','--width','1350','--height','1050'], ['offline','focusMapped'], 'shapeChecks', ['fullScore','staleBlocked','validState']),
        ('rehearsal-chords', ['--screen','practice','--rehearsal-preview','--rehearsal-chords','--width','1350','--height','1050'], ['offline','focusMapped','feedbackMapped','feedbackClearOfNextSystem'], 'rehearsalChecks', ['fullScore','focusFromEvidence','openingSaved','validSavedState']),
        ('rehearsal-stale', ['--screen','practice','--rehearsal-preview','--rehearsal-stale','--width','1350','--height','1050'], ['offline','focusMapped','feedbackMapped'], 'rehearsalChecks', ['fullScore','staleSourceBlocked','pendingRetained','validSavedState']),
        ('rehearsal-opening', ['--screen','practice','--rehearsal-preview','--rehearsal-opening','--width','1350','--height','1050'], ['offline','focusMapped','continuousCursor'], 'rehearsalChecks', ['fullScore','sourceLinked','openingUngraded','validSavedState']),
        ('rehearsal-focus', ['--screen','practice','--rehearsal-preview','--width','1350','--height','1050'], ['offline','focusMapped','feedbackMapped','feedbackWithinScore','feedbackClearOfNextSystem'], 'rehearsalChecks', ['fullScore','focusFromEvidence','openingSaved','validSavedState']),
        ('rehearsal-live', ['--screen','practice','--rehearsal-preview','--rehearsal-live','--width','1350','--height','1050'], ['offline','focusMapped','feedbackMapped','continuousCursor'], 'rehearsalChecks', ['fullScore','liveUngraded','validSavedState']),
        ('rehearsal-small', ['--screen','practice','--rehearsal-preview','--width','1120','--height','760'], ['offline','focusMapped','feedbackMapped','feedbackClearOfNextSystem'], 'rehearsalChecks', ['fullScore','focusFromEvidence','openingSaved']),
        ('rehearsal-context', ['--screen','practice','--rehearsal-preview','--rehearsal-context','--width','1350','--height','1050'], ['offline','focusMapped'], 'rehearsalChecks', ['fullScore','contextRestored','validSavedState']),
        ('rehearsal-review', ['--screen','practice','--rehearsal-preview','--rehearsal-review','--width','1350','--height','1050'], ['offline','focusMapped'], 'rehearsalChecks', ['fullScore','dueReturn','independentReady','supportedNoMastery','validSavedState']),
        ('rehearsal-complete', ['--screen','practice','--rehearsal-preview','--rehearsal-complete','--width','1350','--height','1050'], ['offline','focusMapped'], 'rehearsalChecks', ['fullScore','dueReturn','supportedNoMastery','validSavedState']),
        ('playalong-result', ['--screen','practice','--playalong-preview','--width','1350','--height','1050'], ['offline','cursorForward','continuousCursor','feedbackMapped','feedbackSafeText','feedbackWithinScore'], 'playAlongChecks', ['calibrated','calibrationUngraded','separatePitchPulse','missDoesNotCascade','savedAndReviewable','canonicalResult']),
        ('playalong-live', ['--screen','practice','--playalong-preview','--playalong-live','--width','1350','--height','1000'], ['offline','continuousCursor','feedbackMapped'], 'playAlongChecks', ['calibrated','liveFeedback','unfinishedUngraded']),
        ('playalong-small', ['--screen','practice','--playalong-preview','--width','1120','--height','760'], ['offline','feedbackMapped'], 'playAlongChecks', ['calibrated','savedAndReviewable']),
        ('playalong-calibration', ['--screen','practice','--playalong-preview','--playalong-calibration','--width','1350','--height','1050'], ['offline'], 'playAlongChecks', ['calibrated','calibrationUngraded']),
        ('creative-answer', ['--screen','practice','--score-ear-preview','--creative-preview','--width','1350','--height','1000'], ['offline','allEventsMapped','continuousPlayhead'], 'scoreEarChecks', ['creativeLinked','creativeSaved','creativeIndependent']),
        ('creative-small', ['--screen','practice','--score-ear-preview','--creative-preview','--width','1120','--height','760'], ['offline','allEventsMapped'], 'scoreEarChecks', ['creativeLinked','creativeSaved']),
        ('creative-library', ['--screen','practice','--score-ear-preview','--creative-preview','--creative-library','--width','1350','--height','980'], ['offline'], 'scoreEarChecks', ['creativeLinked','creativeSaved']),
        ('full-piece', ['--screen','practice','--score-ear-preview','--full-piece-preview','--width','1350','--height','980'], ['offline','allEventsMapped','continuousPlayhead','scrollRetained'], 'scoreEarChecks', ['fullPieceOpened']),
        ('full-study', ['--screen','practice','--score-ear-preview','--full-piece-preview','--full-study','--width','1350','--height','980'], ['offline','cursorForward','cursorRewind','continuousCursor','cursorHidden'], 'scoreEarChecks', ['fullPieceOpened']),
        ('score-band', ['--screen','practice','--score-ear-preview','--band-preview','--width','1350','--height','1050'], ['offline','cursorForward','cursorRewind','continuousCursor'], 'scoreEarChecks', ['bandLanes']),
        ('score-ear-opening', ['--screen', 'practice', '--score-ear-preview', '--width', '1350', '--height', '980'], [], 'scoreEarChecks', ['capturedExactVoice', 'sourceLinked', 'learningSupported', 'bandUngraded', 'dueReturn', 'independentHidden', 'hintSaved', 'validSnapshot', 'bandLanes']),
        ('score-ear-solfege', ['--screen', 'practice', '--score-ear-preview', '--score-ear-solfege', '--width', '1350', '--height', '980'], [], 'scoreEarChecks', ['capturedExactVoice', 'sourceLinked', 'learningSupported', 'bandUngraded', 'dueReturn', 'independentHidden', 'hintSaved', 'validSnapshot', 'bandLanes']),
        ('score-ear-review', ['--screen', 'practice', '--score-ear-preview', '--score-ear-review', '--width', '1350', '--height', '1100'], [], 'scoreEarChecks', ['capturedExactVoice', 'sourceLinked', 'learningSupported', 'bandUngraded', 'dueReturn', 'independentHidden', 'hintSaved', 'validSnapshot', 'bandLanes']),
        ('score-ear-return', ['--screen', 'practice', '--score-ear-preview', '--score-ear-return', '--width', '1350', '--height', '980'], [], 'scoreEarChecks', ['capturedExactVoice', 'sourceLinked', 'learningSupported', 'bandUngraded', 'dueReturn', 'independentHidden', 'hintSaved', 'validSnapshot', 'bandLanes']),
        ('score-ear-setup', ['--screen', 'practice', '--score-ear-preview', '--score-ear-setup', '--width', '1350', '--height', '1100'], [], 'scoreEarChecks', ['capturedExactVoice', 'sourceLinked', 'learningSupported', 'bandUngraded', 'dueReturn', 'independentHidden', 'hintSaved', 'validSnapshot', 'bandLanes']),
        ('score-ear-small', ['--screen', 'practice', '--score-ear-preview', '--score-ear-solfege', '--width', '1120', '--height', '760'], [], 'scoreEarChecks', ['capturedExactVoice', 'sourceLinked', 'learningSupported', 'bandUngraded', 'dueReturn', 'independentHidden', 'hintSaved', 'validSnapshot', 'bandLanes']),
        ('ear-opening', ['--screen', 'practice', '--ear-preview', '--width', '1350', '--height', '980'], [], "earChecks", ["voiceCaptured", "midiCaptured", "focusedReturn", "separateReviews", "transferHidden", "sessionComplete", "validSnapshot"]),
        ('ear-solfege', ['--screen', 'practice', '--ear-preview', '--ear-solfege', '--width', '1350', '--height', '980'], [], "earChecks", ["voiceCaptured", "midiCaptured", "focusedReturn", "separateReviews", "transferHidden", "sessionComplete", "validSnapshot"]),
        ('ear-play', ['--screen', 'practice', '--ear-preview', '--ear-play', '--width', '1350', '--height', '980'], [], "earChecks", ["voiceCaptured", "midiCaptured", "focusedReturn", "separateReviews", "transferHidden", "sessionComplete", "validSnapshot"]),
        ('ear-review', ['--screen', 'practice', '--ear-preview', '--ear-review', '--width', '1350', '--height', '980'], [], "earChecks", ["voiceCaptured", "midiCaptured", "focusedReturn", "separateReviews", "transferHidden", "sessionComplete", "validSnapshot"]),
        ('ear-summary', ['--screen', 'practice', '--ear-preview', '--ear-summary', '--width', '1350', '--height', '980'], [], "earChecks", ["voiceCaptured", "midiCaptured", "focusedReturn", "separateReviews", "transferHidden", "sessionComplete", "validSnapshot"]),
        ('ear-small', ['--screen', 'practice', '--ear-preview', '--ear-solfege', '--width', '1120', '--height', '760'], [], "earChecks", ["voiceCaptured", "midiCaptured", "focusedReturn", "separateReviews", "transferHidden", "sessionComplete", "validSnapshot"]),
        ('groove', ['--screen', 'practice', '--groove-preview', '--width', '1350', '--height', '980'], [], "grooveChecks", ["fourBarChanges", "threeParts", "countIn", "soundBank", "validArrangement"]),
        ('groove-small', ['--screen', 'practice', '--groove-preview', '--width', '1120', '--height', '760'], [], "grooveChecks", ["fourBarChanges", "threeParts", "countIn", "soundBank", "validArrangement"]),
        ("practice-home-empty", ["--screen", "practice", "--practice-home", "--width", "1350", "--height", "980"], [], "homeChecks", ["homeVisible", "emptyStateHonest"]),
        ("practice-home-ready", ["--screen", "practice", "--smooth-preview", "--practice-home", "--width", "1350", "--height", "980"], [], "homeChecks", ["homeVisible", "pathwayAvailable", "reviewAvailable"]),
        ("practice-home-small", ["--screen", "practice", "--smooth-preview", "--practice-home", "--width", "1120", "--height", "760"], [], "homeChecks", ["homeVisible", "pathwayAvailable", "reviewAvailable"]),
        ("practice-home-resume", ["--screen", "practice", "--smooth-preview", "--adaptive-preview", "--practice-home"], [], "homeChecks", ["homeVisible", "sessionResumable"]),
        ("practice-session", ["--screen", "practice", "--smooth-preview", "--adaptive-preview", "--practice-adaptive", "--width", "1120", "--height", "760"], ["offline"], "adaptiveChecks", ["sessionValid"]),
        ("adaptive-opening", ["--screen", "library", "--smooth-preview", "--adaptive-preview"], ["offline"], "adaptiveChecks", ["multipleAnswers", "midiCaptured", "retrySupported", "missRetained", "focusedRepair", "transferUnhinted", "independentTransfer", "compositionLinked", "sessionValid"]),
        ("adaptive-small", ["--screen", "library", "--smooth-preview", "--adaptive-preview", "--width", "1120", "--height", "760"], ["offline"], "adaptiveChecks", ["sessionValid"]),
        ("adaptive-screen", ["--screen", "library", "--smooth-preview", "--adaptive-preview", "--adaptive-screen"], ["offline"], "adaptiveChecks", ["sessionValid"]),
        ("adaptive-feedback", ["--screen", "library", "--smooth-preview", "--adaptive-preview", "--adaptive-feedback"], ["offline"], "adaptiveChecks", ["multipleAnswers", "retrySupported", "missRetained"]),
        ("adaptive-transfer", ["--screen", "library", "--smooth-preview", "--adaptive-preview", "--adaptive-transfer"], ["offline"], "adaptiveChecks", ["transferUnhinted", "independentTransfer"]),
        ("adaptive-composition", ["--screen", "library", "--smooth-preview", "--adaptive-preview", "--adaptive-compose"], [], "adaptiveChecks", ["compositionLinked"]),
        ("adaptive-summary", ["--screen", "library", "--smooth-preview", "--adaptive-preview", "--adaptive-summary"], [], "adaptiveChecks", ["sessionValid", "compositionLinked"]),
        ("pathway-overview", ["--screen", "library", "--smooth-preview"], [], "smoothChecks", smooth),
        ("pathway-small", ["--screen", "library", "--smooth-preview", "--width", "1120", "--height", "760"], [], "smoothChecks", smooth),
        ("pathway-epub", ["--screen", "library", "--smooth-preview", "--smooth-lesson"], ["offline"], "smoothChecks", smooth),
        ("pathway-illustrations", ["--screen", "library", "--smooth-preview", "--smooth-lesson", "--smooth-illustrations"], ["offline"], "smoothChecks", smooth),
        ("pathway-pdf", ["--screen", "library", "--smooth-preview", "--smooth-lesson", "--smooth-pdf"], ["offline"], "smoothChecks", smooth),
        ("pathway-composition", ["--screen", "library", "--smooth-preview", "--smooth-compose"], [], "smoothChecks", smooth + ["compositionLinked"]),
        ("course-outline", ["--screen", "library", "--course-preview"], [],
         "courseChecks", ["sourceLinked", "outlineGate", "exerciseLinked", "unreviewedExerciseBlocked", "sourceLoaded"]),
        ("course-lesson", ["--screen", "library", "--course-preview", "--course-ready"], [],
         "courseChecks", ["sourceLinked", "outlineGate", "exerciseLinked", "reviewedExercisePlayable", "virtualMIDIRecorded", "spacedReviewSuggested", "sourceLoaded"]),
        ("course-session", ["--screen", "library", "--course-preview", "--course-ready", "--course-bottom"], [],
         "courseChecks", ["sourceLinked", "outlineGate", "exerciseLinked", "reviewedExercisePlayable", "virtualMIDIRecorded", "spacedReviewSuggested", "sourceLoaded"]),
        ("course-source", ["--screen", "editor", "--course-preview", "--course-score-review"], ["offline", "allEventsMapped"],
         "courseChecks", ["sourceLinked", "outlineGate", "exerciseLinked", "unreviewedExerciseBlocked", "sourceReviewOpened"]),
        ("timed-changes", ["--screen", "chords", "--timed-changes-check"], [],
         "timedChangesChecks", ["planBuilt", "harmonyMatched", "timingSeparated", "resultSaved", "reviewRecorded", "sourceLinked", "sourceValidated"]),
        ("timed-changes-piece", ["--screen", "chords", "--timed-changes-check", "--changes-piece"], [],
         "timedChangesChecks", ["planBuilt", "harmonyMatched", "timingSeparated", "resultSaved", "reviewRecorded", "sourceLinked", "sourceValidated"]),
        ("follow-changes", ["--screen", "chords", "--changes-check"], [],
         "changesChecks", ["wrongAnswerWaits", "progressionCompleted", "attemptsSaved", "hintsSeparated", "sourceLinked", "voicingsMatch"]),
        ("follow-piece", ["--screen", "chords", "--changes-check", "--changes-piece", "--changes-practice"], [],
         "changesChecks", ["wrongAnswerWaits", "progressionCompleted", "attemptsSaved", "hintsSeparated", "sourceLinked", "voicingsMatch"]),
        ("editor-guitar", ["--screen", "editor", "--editor-check", "--editor-live-edit"], editor,
         "nativeEditing", ["pitchEdit", "undo", "redo", "rhythmEdit", "rhythmUndo", "insertBars", "barUndo", "passagePaste", "pasteUndo", "writeAdvances", "writeRestAdvances", "writeAddsBar", "writeUndoRemovesAddedBar"]),
        ("editor-piano", ["--screen", "editor", "--poly-editor", "--piano-editor", "--poly-check"], editor,
         "nativeEditing", ["selectLowerVoice", "advanceWithinVoice", "expressionEdit", "expressionUndo", "expressionRedo"]),
        ("harmony-guitar", ["--screen", "editor", "--harmony-check"], editor + ["harmonyVisible", "harmonySeparated"],
         "nativeEditing", ["harmonyEdit", "harmonyUndo", "harmonyRedo", "harmonyTranspose", "harmonyCopy"]),
        ("harmony-piano", ["--screen", "editor", "--piano-editor", "--harmony-check"], editor + ["harmonyVisible", "harmonySeparated"],
         "nativeEditing", ["harmonyEdit", "harmonyUndo", "harmonyRedo", "harmonyTranspose", "harmonyCopy"]),
        ("harmony-controls", ["--screen", "editor", "--harmony-check", "--harmony-sheet"], ["offline", "harmonyVisible"], None, []),
        ("midi-entry", ["--screen", "editor", "--piano-editor", "--midi-entry-check"], ["offline"],
         "midiChecks", ["stepChordEntered", "stepAdvanced", "otherHandUnchanged", "midiUndo", "midiRedo"]),
        ("midi-practice", ["--screen", "practice", "--piece-pathway", "--piece-midi"], [],
         "piecePathwayChecks", ["piecePlanHasLocalExercises", "difficultTaskReturnsFirst", "pathwayMIDIMissRecorded", "pathwayMIDIAnswerMatched", "pathwayMIDIRetryNotPromoted"]),
        ("study-cursor", ["--screen", "studies"], ["offline", "cursorForward", "cursorRewind"], None, []),
        ("guided-midi", ["--screen", "studies", "--guided-practice-check"], ["offline", "cursorForward", "cursorRewind"],
         "guidedChecks", ["planBuilt", "wrongNoteWaits", "passageCompleted", "resultSaved", "guidedEvidenceDistinct", "reviewReturnsSooner"]),
        ("timed-midi", ["--screen", "studies", "--timed-practice-check"], ["offline", "cursorForward", "cursorRewind"],
         "timedChecks", ["planBuilt", "timingSeparated", "noCascade", "resultSaved", "reviewRecorded", "inputDistinct"]),
        ("rhythm-tapping", ["--screen", "practice", "--timed-practice-check"], [],
         "timedChecks", ["planBuilt", "timingSeparated", "noCascade", "resultSaved", "reviewRecorded", "inputDistinct"]),
    ]


def run_preview(executable, output, env, scenario):
    name, flags, required, group, group_flags = scenario
    png, sidecar = output / (name + ".png"), output / (name + ".json")
    png.unlink(missing_ok=True)
    sidecar.unlink(missing_ok=True)
    if name == "song-accessibility":
        run(["swift", "-swift-version", "6", ROOT / "Scripts/native_accessibility.swift", executable, png], output / (name + ".log"), env, 60)
    else:
        run([executable, *native_arguments(["--snapshot", png, *flags])], output / (name + ".log"), env, 60)
    require(png.is_file() and png.stat().st_size > 1000, f"Missing {name} image")
    checks = json.loads(sidecar.read_text())
    require_flags(checks, required, name)
    if required:
        require(checks.get("kind") == "ready" and checks.get("svgCount", 0) > 0, f"{name} did not render")
    if group:
        check_group(checks, group, group_flags)
    if name == "editor-guitar":
        require_flags(checks, ["linkedTab"], name)
        require(checks.get("tabTargets", 0) > 0, "Guitar tab has no edit targets")
    if name == "editor-piano":
        require(checks.get("staffCount") == 2, "Piano is missing a staff")
    return checks


def paired_native_checks(production, instrumented, jobs):
    """Overlap only two isolated captures; always join both owned processes.

    Each callback has its own app process, storage, logs and profile destination.
    Device self-checks and accessibility actions must not enter this helper with
    jobs=2: they deliberately own global input/focus resources.
    """
    require(jobs in (1, 2), "Native preview concurrency must be one or two")
    if jobs == 1:
        return production(), instrumented()
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(production)
        second = pool.submit(instrumented)
        # Exiting the executor joins the other bounded check even on failure.
        # A failed capture must never leave an app running in the background.
        return first.result(), second.result()


def preview_parallelism(scenario, requested):
    # Navigation round trips deliberately tear down and recreate WebKit views.
    # Keep their lifecycle check serial even when static captures overlap.
    return 1 if scenario[0] == 'song-accessibility' or '--workspace-editor-roundtrip' in scenario[1] else requested


def run_settings_preview(executable, output, env, name):
    png = output / ("settings-" + name + ".png")
    png.unlink(missing_ok=True)
    run([executable, *native_arguments(["--settings", "--" + name + "-settings", "--snapshot", png])],
        output / ("settings-" + name + ".log"), env, 30)
    require(png.is_file() and png.stat().st_size > 1000, "Missing settings preview: " + name)
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests-only", action="store_true", help="Skip desktop/audio/renderer checks; suitable for headless CI")
    parser.add_argument("--skip-accessibility", action="store_true", help="Explicitly leave native accessibility actions pending on CI without permission; never changes system permissions")
    parser.add_argument("--skip-audio-output", action="store_true", help="Record live output-device checks as skipped on CI; still render audio offline and test virtual MIDI")
    parser.add_argument("--output", type=Path, default=ROOT / ".verification", help="Logs, reports, previews and staged app")
    parser.add_argument("--scratch", type=Path, help="Reusable Swift build cache (defaults to OUTPUT/build)")
    parser.add_argument("--preview-jobs", type=int, choices=(1, 2), default=1,
                        help="Overlap isolated production/instrumented captures; device and accessibility checks stay serial")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scratch = args.scratch.resolve() if args.scratch else output / "build"
    env = dict(os.environ)
    env["CLANG_MODULE_CACHE_PATH"] = str(scratch / "module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(scratch / "module-cache")
    if "DEVELOPER_DIR" not in env and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    report = {"passed": False, "mode": "tests-only" if args.tests_only else "full",
              "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "paidRequests": 0, "physicalMIDI": False, "microphone": False}
    report["previewJobs"] = args.preview_jobs
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    started = time.time()
    inputs = source_digest()
    test_inputs = test_inputs_digest()
    try:
        run([sys.executable, "-m", "unittest", "discover", "-s", ROOT / "Scripts", "-p", "test_*.py"],
            output / "workflow-tests.log", env, 30)
        run(["node", "--test", "Scripts/test_site.cjs", "Scripts/test_score.cjs"], output / "site-tests.log", env, 30)
        run(["swift", "--version"], output / "toolchain.log", env, 30)
        report["toolchain"] = (output / "toolchain.log").read_text().strip()
        report["swiftLanguageMode"] = 6
        run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-module-cache-path", scratch / "module-cache",
             "-typecheck", ROOT / "Scripts/native_accessibility.swift"], output / "accessibility-typecheck.log", env, 60)
        reset_unit_coverage(scratch)
        run(["swift", "test", "--package-path", ROOT, "--scratch-path", scratch,
             "--disable-sandbox", *SWIFT_TEST_FLAGS], output / "tests.log", env, 900)
        report["tests"] = test_counts((output / "tests.log").read_text())
        require_clean_swift((output / "tests.log").read_text())
        exports = list(scratch.glob("**/codecov/Cadence.json"))
        require(exports, "Swift did not produce a coverage report")
        coverage_path = max(exports, key=lambda path: path.stat().st_mtime)
        require(coverage_path.stat().st_mtime >= started, "Coverage report is stale")
        coverage = json.loads(coverage_path.read_text())
        check_source_inventory(coverage, ROOT)
        report["coverage"] = summarize_coverage(coverage)
        report["unitCoverage"] = report["coverage"]
        (output / "unit-coverage-summary.json").write_text(json.dumps(report["unitCoverage"], indent=2) + "\n")
        (output / "coverage-summary.json").write_text(json.dumps(report["coverage"], indent=2) + "\n")
        # This is a regression floor for the core, not a claim about the whole UI.
        require(report["coverage"]["MusicCore"]["lines"]["percent"] >= 90, "MusicCore line coverage dropped below 90%")
        owners = report["coverage"].get("WorkspaceOwners", {})
        require(owners.get("files") == 3 and owners["lines"]["percent"] >= 85,
                "Library/practice/course workspace coverage is missing or below 85%")
        workflows = report["coverage"].get("LearningWorkflows", {})
        require(workflows.get("files") == 4 and workflows["lines"]["percent"] >= 80,
                "Learning/import workflow coverage is missing or below 80%")
        require(report["coverage"]["Cadence"]["lines"]["percent"] >= 12,
                "Whole-app unit-test line coverage dropped below 12%")
        if not args.tests_only:
            app = output / "Cadence.app"
            if app.exists():
                shutil.rmtree(app)
            env.update(CADENCE_BUILD_DIR=str(scratch), CADENCE_APP_PATH=str(app))
            run([ROOT / "build.sh"], output / "release-build.log", env, 900)
            require_clean_swift((output / "release-build.log").read_text())
            run(["codesign", "--verify", "--deep", "--strict", app], output / "signature.log", env, 30)
            executable = app / "Contents/MacOS/Cadence"
            # Exercise the real scene before accessory self-checks can save any
            # launch state. Keep the full post-selfcheck suite below as well.
            first_launch = output / "first-launch"
            first_launch.mkdir(exist_ok=True)
            report["firstLaunchPreview"] = run_preview(executable, first_launch, env, native_scenarios()[0])
            # Check score/cursor readiness before the long workflow suite.
            report["scoreRendererPreview"] = run_preview(
                executable, first_launch, env, next(case for case in native_scenarios() if case[0] == "flow"))
            collection = NativeCoverage.prepare(ROOT, output, coverage_path, app, env, run)
            instrumented_env = collection.environment(env)
            native_path = output / "native.json"
            native_path.unlink(missing_ok=True)
            audio_flags = ["--offline-audio"] if args.skip_audio_output else []
            run([executable, *native_arguments(["--selfcheck", native_path, *audio_flags])], output / "native.log", env, 180)
            native = json.loads(native_path.read_text())
            check_native(native, args.skip_audio_output)
            report["native"] = native
            instrumented_path = collection.folder / "native.json"
            run([collection.executable, *native_arguments(["--selfcheck", instrumented_path, *audio_flags])], collection.folder / "native.log", instrumented_env, 180)
            instrumented_native = json.loads(instrumented_path.read_text())
            check_native(instrumented_native, args.skip_audio_output)
            report["instrumentedNative"] = instrumented_native
            scenarios = native_scenarios()
            report["skippedNativeScenarios"] = []
            if args.skip_accessibility:
                report["skippedNativeScenarios"] = ["song-accessibility"]
                scenarios = [case for case in scenarios if case[0] != "song-accessibility"]
            report["previews"] = {}
            report["instrumentedPreviews"] = {}
            report["previewPairSeconds"] = {}
            for scenario in scenarios:
                name = scenario[0]
                pair_started = time.monotonic()
                production, instrumented = paired_native_checks(
                    lambda: run_preview(executable, output, env, scenario),
                    lambda: run_preview(collection.executable, collection.folder, instrumented_env, scenario),
                    preview_parallelism(scenario, args.preview_jobs))
                report["previews"][name] = production
                report["instrumentedPreviews"][name] = instrumented
                report["previewPairSeconds"][name] = round(time.monotonic() - pair_started, 3)
            report["settingsPreviews"] = []
            for name in ("general", "midi", "about"):
                paired_native_checks(
                    lambda: run_settings_preview(executable, output, env, name),
                    lambda: run_settings_preview(collection.executable, collection.folder, instrumented_env, name),
                    args.preview_jobs)
                report["settingsPreviews"].append(name)
            compared = 0
            for folder in ("ScoreViewer", "EditorViewer", "ImportExamples", "SoundBanks", "Brand"):
                origin = ROOT / "Resources" / folder
                for file in origin.rglob("*"):
                    if file.is_file():
                        bundled = app / "Contents/Resources" / folder / file.relative_to(origin)
                        require(file.read_bytes() == bundled.read_bytes(), f"Bundled resource differs: {file}")
                        compared += 1
            report["resourcesCompared"] = compared
            report["signatureVerified"] = True
            combined, evidence = collection.finish(ROOT, env, run, minimum=len(scenarios) + 4)
            report["nativeCoverage"] = evidence
            record_combined_coverage(report, summarize_coverage(combined))
            (output / "combined-coverage-summary.json").write_text(json.dumps(report["combinedCoverage"], indent=2) + "\n")
            require(report["combinedCoverage"]["Cadence"]["lines"]["percent"] >= 50,
                    "Combined whole-app coverage is below 50%; inspect the uncovered workflows")
            require(report["combinedCoverage"]["DeviceAndRequestOwners"]["lines"]["percent"] >= 80,
                    "Device/request boundary coverage is below 80%")
        require(source_digest() == inputs, "Build inputs changed during verification; rerun against a frozen source tree")
        require(test_inputs_digest() == test_inputs,
                "Test inputs changed during verification; rerun the full suite")
        report["sourceInputsSHA256"] = inputs
        report["testInputsSHA256"] = test_inputs
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        report["seconds"] = round(time.time() - started, 1)
        (output / "summary.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {output / 'summary.json'}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
