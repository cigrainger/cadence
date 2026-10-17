import unittest
from unittest.mock import Mock, patch
import signal
import subprocess
from verify import run, check_group, check_native, record_combined_coverage, require_clean_swift, require_flags, summarize_coverage, test_counts, test_inputs_digest
import copy
from pathlib import Path
import tempfile


class VerificationTests(unittest.TestCase):
    def test_timeout_samples_only_the_check_child_and_still_terminates_if_sampling_fails(self):
        for sample_error in (None, OSError("sample unavailable"), subprocess.TimeoutExpired("sample", 10)):
            with self.subTest(sample_error=sample_error), tempfile.TemporaryDirectory() as folder:
                child = Mock(pid=1234)
                child.wait.side_effect = [subprocess.TimeoutExpired("fixture", 1), 0]
                events = []
                def sample(command, **kwargs):
                    events.append(("sample", command))
                    if sample_error:
                        raise sample_error
                with patch('verify.subprocess.Popen', return_value=child), \
                     patch('verify.subprocess.run', side_effect=sample), \
                     patch('verify.os.killpg', side_effect=lambda *args: events.append(("terminate", args))), \
                     patch('verify.sys.platform', 'darwin'):
                    with self.assertRaisesRegex(RuntimeError, 'Stopped fixture'):
                        run(["fixture"], Path(folder) / 'fixture.log', {}, 1)
                self.assertEqual(events[0][1][:3], ['/usr/bin/sample', '1234', '1'])
                self.assertEqual(events[1], ("terminate", (1234, signal.SIGTERM)))
                self.assertTrue(events[0][1][-1].endswith('/fixture.sample.log'))

    def test_combined_execution_cannot_rename_unit_coverage_or_shrink_its_denominator(self):
        unit = {name: {'files': 2, 'lines': {'count': 100, 'covered': 12}} for name in ('MusicCore', 'Cadence')}
        report = {'coverage': copy.deepcopy(unit), 'unitCoverage': copy.deepcopy(unit)}
        combined = copy.deepcopy(unit)
        for module in combined.values(): module['lines']['covered'] = 70
        record_combined_coverage(report, combined)
        self.assertEqual(report['coverage'], unit)
        self.assertEqual(report['unitCoverage'], unit)
        self.assertEqual(report['combinedCoverage'], combined)
        for change in ('files', 'count', 'covered'):
            invalid = copy.deepcopy(combined)
            if change == 'files': invalid['Cadence']['files'] = 1
            else: invalid['Cadence']['lines'][change] = 1
            with self.assertRaises(RuntimeError): record_combined_coverage(report, invalid)
    def test_sdk_boundary_warnings_are_gated_even_when_the_compiler_leaves_them_as_warnings(self):
        root = Path('/fixture')
        for folder in ('Sources/Cadence', 'Sources/MusicCore', 'Tests/CadenceTests'):
            with self.assertRaises(RuntimeError):
                require_clean_swift(f'/fixture/{folder}/A.swift:1:2: warning: actor access', root)
        require_clean_swift('/fixture/.verification/checkouts/ZIPFoundation/Package.swift:2: warning: deployment', root)

    def test_verification_binds_test_paths_as_well_as_contents(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            tests = root / 'Tests'
            tests.mkdir()
            path = tests / 'A.swift'
            path.write_text('// original')
            original = test_inputs_digest(root)
            path.rename(tests / 'B.swift')
            self.assertNotEqual(test_inputs_digest(root), original)
    def test_ci_skips_are_explicit_and_cannot_hide_other_failures(self):
        output = ["audioOutput", "timedAudioScheduled", "metronomeOutput", "studyLoopOutput"]
        required = ["passed", "pdfBatchPassed", "libraryPassed", "piecePathwayPassed", "virtualMIDITimestamps", "midiClientRetained", "spaceTapPassed",
                    "sampledBand", "bundledSoundBank", "earPathway", "expressionDynamics", "expressionStaccato"]
        complete = {name: True for name in required + output}
        complete["skippedChecks"] = []
        check_native(complete, False)
        with self.assertRaises(RuntimeError): check_native(complete, True)
        offline = {name: True for name in required}
        offline["skippedChecks"] = output
        check_native(offline, True)
        with self.assertRaises(RuntimeError): check_native(offline, False)
        offline["audioOutput"] = True
        with self.assertRaises(RuntimeError): check_native(offline, True)
        offline.pop("audioOutput")
        offline["virtualMIDITimestamps"] = False
        with self.assertRaises(RuntimeError): check_native(offline, True)

    def test_window_keyboard_checks_remain_required_when_device_output_is_skipped(self):
        required = ["passed", "pdfBatchPassed", "libraryPassed", "piecePathwayPassed", "virtualMIDITimestamps",
                    "midiClientRetained", "sampledBand", "bundledSoundBank", "earPathway",
                    "expressionDynamics", "expressionStaccato"]
        report = {name: True for name in required}
        report["skippedChecks"] = ["audioOutput", "timedAudioScheduled", "metronomeOutput", "studyLoopOutput"]
        with self.assertRaisesRegex(RuntimeError, 'spaceTapPassed'):
            check_native(report, True)
        report["spaceTapPassed"] = False
        with self.assertRaisesRegex(RuntimeError, 'spaceTapPassed'):
            check_native(report, True)
        report["spaceTapPassed"] = True
        check_native(report, True)

    def test_missing_or_false_native_results_cannot_pass(self):
        with self.assertRaisesRegex(RuntimeError, 'MIDI source.*-10830'):
            check_native({"error": "MIDI source (-10830)", "passed": False}, False)
        for report in ({}, {"passed": False}, {"passed": 1}):
            with self.assertRaises(RuntimeError):
                require_flags(report, ["passed"], "fixture")
        with self.assertRaises(RuntimeError):
            check_group({"checks": {"required": True, "newRegression": False}}, "checks", ["required"])

    def test_failed_first_target_cannot_hide_behind_successful_last_target(self):
        log = "Test Suite 'MusicCoreTests.xctest' failed\nTest Suite 'CadenceTests.xctest' passed"
        with self.assertRaises(RuntimeError):
            test_counts(log)
        with self.assertRaises(RuntimeError):
            test_counts("Test Suite 'All tests' passed")

    def test_counts_both_targets_without_counting_duplicate_summaries(self):
        log = "\n".join(f"Test Case '-[{target}.Fixture testOne]' passed\nTest Suite '{target}.xctest' passed"
                        for target in ("MusicCoreTests", "CadenceTests"))
        self.assertEqual(test_counts(log + log), {"MusicCoreTests": 1, "CadenceTests": 1})

    def test_combined_swiftpm_bundle_counts_each_target(self):
        log = "\n".join(f"Test Case '-[{target}.Fixture testOne]' passed"
                        for target in ("MusicCoreTests", "CadenceTests"))
        with self.assertRaises(RuntimeError):
            test_counts(log)
        log += "\nTest Suite 'CadencePackageTests.xctest' passed"
        self.assertEqual(test_counts(log), {"MusicCoreTests": 1, "CadenceTests": 1})
        with self.assertRaises(RuntimeError):
            test_counts(log + "\nTest Case '-[MusicCoreTests.Fixture testInterrupted]' started")

    def test_incomplete_case_or_failed_combined_bundle_cannot_pass(self):
        cases = "\n".join(f"Test Case '-[{target}.Fixture testOne]' passed"
                          for target in ("MusicCoreTests", "CadenceTests"))
        for ending in ("Test Suite 'CadencePackageTests.xctest' failed",
                       "Test Case '-[CadenceTests.Fixture testInterrupted]' started\n"
                       "Test Suite 'CadencePackageTests.xctest' passed"):
            with self.assertRaises(RuntimeError):
                test_counts(cases + "\n" + ending)

    def test_coverage_excludes_dependencies_and_test_code(self):
        summary = {kind: {"count": 10, "covered": 7} for kind in ("lines", "regions", "functions")}
        paths = ["/Sources/MusicCore/A.swift", "/Sources/Cadence/A.swift", "/Tests/MusicCoreTests/A.swift", "/Sources/ZIPFoundation/A.swift"]
        report = summarize_coverage({"data": [{"files": [{"filename": path, "summary": summary} for path in paths]}]})
        self.assertEqual(report["MusicCore"]["lines"], {"count": 10, "covered": 7, "percent": 70.0})
        self.assertEqual(report["Cadence"]["files"], 1)

    def test_owner_and_workflow_gates_keep_views_in_whole_app_denominator(self):
        summary = {kind: {"count": 10, "covered": 7} for kind in ("lines", "regions", "functions")}
        app_paths = ["Infrastructure/Storage/PracticeWorkspace.swift", "Infrastructure/Storage/LibraryWorkspace.swift",
                     "Infrastructure/Storage/CourseWorkspace.swift", "Infrastructure/Import/PDFImportQueue.swift",
                     "Infrastructure/AI/SavedRequest.swift", "Features/Journey/SongJourneyState.swift",
                     "Features/Journey/SongOpeningInput.swift", "Features/Journey/SongJourneyView.swift",
                     "Diagnostics/SongJourneyChecks.swift"]
        paths = ["/Sources/MusicCore/Fixture.swift"] + ["/Sources/Cadence/" + path for path in app_paths]
        report = summarize_coverage({"data": [{"files": [{"filename": path, "summary": summary} for path in paths]}]})
        self.assertEqual(report["Cadence"]["files"], 9)
        self.assertEqual(report["Cadence"]["lines"]["count"], 90)
        self.assertEqual(report["WorkspaceOwners"]["files"], 3)
        self.assertEqual(report["LearningWorkflows"]["files"], 4)
        self.assertEqual(report["LearningWorkflows"]["lines"]["percent"], 70.0)
