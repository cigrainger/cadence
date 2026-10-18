import unittest
from unittest.mock import Mock, patch
import signal
import subprocess
from verify import run, check_group, check_native, record_combined_coverage, require_clean_swift, require_flags, summarize_coverage, test_counts, test_inputs_digest
import copy
from pathlib import Path
import tempfile
import threading
import json
from verify import paired_native_checks, preview_parallelism, native_scenarios, run_preview


class VerificationTests(unittest.TestCase):
    def test_driver_passes_the_same_readiness_checks_it_validates_after_capture(self):
        scenario = next(case for case in native_scenarios() if case[0] == 'full-study')
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            def capture(command, *args):
                arguments = dict(zip(command[1::2], command[2::2]))
                requirements = json.loads(Path(arguments['--snapshot-requirements']).read_text())
                self.assertEqual(requirements, {'scenario': scenario[0], 'rendererFlags': scenario[2],
                                                'group': scenario[3], 'groupFlags': scenario[4]})
                Path(arguments['--snapshot']).write_bytes(b'fixture' * 200)
                report = {key: True for key in scenario[2]}
                report.update(kind='ready', svgCount=1)
                report[scenario[3]] = {key: True for key in scenario[4]}
                (output / 'full-study.json').write_text(json.dumps(report))
            with patch('verify.run', side_effect=capture):
                run_preview('/fixture/Cadence', output, {}, scenario)

    def test_accessibility_and_editor_navigation_stay_serial(self):
        scenarios = {case[0]: case for case in native_scenarios()}
        for name in ('song-accessibility', 'daily-ear-accessibility', 'workspace-editor-return'):
            self.assertEqual(preview_parallelism(scenarios[name], 2), 1)
        for name in ('song-pathway', 'flow', 'editor-piano'):
            self.assertEqual(preview_parallelism(scenarios[name], 2), 2)
            self.assertEqual(preview_parallelism(scenarios[name], 1), 1)

    def test_parallel_captures_overlap_and_keep_each_result(self):
        barrier = threading.Barrier(2, timeout=2)
        def capture(value):
            barrier.wait()
            return value
        self.assertEqual(paired_native_checks(lambda: capture('production'), lambda: capture('instrumented'), 2),
                         ('production', 'instrumented'))

    def test_serial_captures_do_not_overlap_and_failure_stops_the_next_launch(self):
        calls = []
        def first():
            calls.append('production')
            raise RuntimeError('capture failed')
        with self.assertRaisesRegex(RuntimeError, 'capture failed'):
            paired_native_checks(first, lambda: calls.append('instrumented'), 1)
        self.assertEqual(calls, ['production'])
        with self.assertRaises(RuntimeError):
            paired_native_checks(lambda: None, lambda: None, 3)

    def test_parallel_failure_joins_the_other_capture_before_returning(self):
        barrier = threading.Barrier(2, timeout=2)
        joined = threading.Event()
        def first():
            barrier.wait()
            raise RuntimeError('capture failed')
        def second():
            barrier.wait()
            joined.set()
        with self.assertRaisesRegex(RuntimeError, 'capture failed'):
            paired_native_checks(first, second, 2)
        self.assertTrue(joined.is_set())

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

class NativeMatrixSchedulingTests(unittest.TestCase):
    @staticmethod
    def case(name, flags=()):
        return (name, list(flags), [], None, [])

    def test_static_batches_drain_around_focus_sensitive_scenarios(self):
        from verify import native_scenario_batches
        cases = [self.case('a'), self.case('b'), self.case('navigation', ['--workspace-editor-roundtrip']),
                 self.case('c'), self.case('d'), self.case('song-accessibility'), self.case('daily-ear-accessibility'), self.case('e')]
        self.assertEqual([[case[0] for case in batch] for batch in native_scenario_batches(cases, 4)],
                         [['a', 'b'], ['navigation'], ['c', 'd'], ['song-accessibility'], ['daily-ear-accessibility'], ['e']])
        for jobs in (1, 2):
            self.assertTrue(all(len(batch) == 1 for batch in native_scenario_batches(cases, jobs)))
        self.assertEqual(preview_parallelism(cases[0], 4), 2)
        self.assertEqual(preview_parallelism(cases[2], 4), 1)

    def test_four_captures_overlap_and_keep_their_results_in_scenario_order(self):
        from verify import checked_native_scenarios
        barrier = threading.Barrier(4, timeout=3)
        second_case_done = threading.Event()
        completed = []
        lock = threading.Lock()
        def capture(case, build):
            barrier.wait()
            if case[0] == 'b':
                with lock:
                    completed.append(build)
                    if len(completed) == 2: second_case_done.set()
            else:
                self.assertTrue(second_case_done.wait(3))
            return (case[0], build)
        results = list(checked_native_scenarios([self.case('a'), self.case('b')],
                       lambda case: capture(case, 'production'), lambda case: capture(case, 'instrumented'), 4))
        self.assertEqual([(name, first, second) for name, first, second, _ in results],
                         [('a', ('a', 'production'), ('a', 'instrumented')),
                          ('b', ('b', 'production'), ('b', 'instrumented'))])

    def test_serial_scene_has_no_other_capture_alive(self):
        from verify import checked_native_scenarios
        lock = threading.Lock()
        active = {}
        finished = []
        barrier = threading.Barrier(4, timeout=3)
        def capture(case):
            with lock:
                if case[0] == 'navigation':
                    self.assertFalse(active)
                    self.assertEqual(sum(name in ('a', 'b') for name in finished), 4)
                elif case[0] == 'c':
                    self.assertEqual(finished.count('navigation'), 2)
                self.assertNotIn('navigation', active.values())
                active[threading.get_ident()] = case[0]
            if case[0] in ('a', 'b'): barrier.wait()
            with lock:
                del active[threading.get_ident()]
                finished.append(case[0])
            return case[0]
        cases = [self.case('a'), self.case('b'), self.case('navigation', ['--workspace-editor-roundtrip']), self.case('c')]
        self.assertEqual(len(list(checked_native_scenarios(cases, capture, capture, 4))), 4)
        self.assertFalse(active)

    def test_failed_pair_joins_all_four_captures_and_does_not_launch_the_next_batch(self):
        from verify import checked_native_scenarios
        barrier = threading.Barrier(4, timeout=3)
        finished = set()
        lock = threading.Lock()
        def capture(case, build):
            barrier.wait()
            with lock: finished.add((case[0], build))
            if case[0] == 'a' and build == 'production': raise RuntimeError('fixture failed')
            return case[0]
        with self.assertRaisesRegex(RuntimeError, 'fixture failed'):
            list(checked_native_scenarios([self.case('a'), self.case('b'), self.case('must-not-launch')],
                 lambda case: capture(case, 'production'), lambda case: capture(case, 'instrumented'), 4))
        self.assertEqual(finished, {('a', 'production'), ('a', 'instrumented'), ('b', 'production'), ('b', 'instrumented')})

    def test_duplicate_names_and_invalid_limits_fail_before_launch(self):
        from verify import checked_native_scenarios
        for cases, jobs in [([self.case('a'), self.case('a')], 4), ([self.case('a')], 3)]:
            with self.assertRaises(RuntimeError):
                list(checked_native_scenarios(cases, lambda _: self.fail('unexpected launch'),
                                            lambda _: self.fail('unexpected launch'), jobs))

    def test_failed_later_batch_retains_completed_results_and_matrix_wall_time(self):
        from verify import record_native_matrix
        report = {'existing': 'kept'}
        def capture(case):
            if case[0] == 'b': raise RuntimeError('later failure')
            return case[0]
        with self.assertRaisesRegex(RuntimeError, 'later failure'):
            record_native_matrix(report, [self.case('a'), self.case('b')], capture, capture, 1)
        self.assertEqual(report['previews'], {'a': 'a'})
        self.assertEqual(report['instrumentedPreviews'], {'a': 'a'})
        self.assertEqual(set(report['previewPairSeconds']), {'a'})
        self.assertGreaterEqual(report['previewMatrixSeconds'], 0)
        self.assertEqual(report['existing'], 'kept')

    def test_four_process_failure_retains_the_other_successful_pair_after_draining(self):
        from verify import record_native_matrix
        for broken in ('a', 'b'):
            with self.subTest(broken=broken):
                barrier = threading.Barrier(4, timeout=3)
                finished = set()
                lock = threading.Lock()
                def capture(case, build):
                    barrier.wait()
                    with lock: finished.add((case[0], build))
                    if case[0] == broken and build == 'production': raise RuntimeError('pair failed')
                    return (case[0], build)
                report = {}
                with self.assertRaisesRegex(RuntimeError, 'pair failed'):
                    record_native_matrix(report, [self.case('a'), self.case('b'), self.case('not-launched')],
                        lambda case: capture(case, 'production'), lambda case: capture(case, 'instrumented'), 4)
                kept = 'b' if broken == 'a' else 'a'
                self.assertEqual(report['previews'], {kept: (kept, 'production')})
                self.assertEqual(report['instrumentedPreviews'], {kept: (kept, 'instrumented')})
                self.assertEqual(set(report['previewPairSeconds']), {kept})
                self.assertEqual(len(finished), 4)
                self.assertGreaterEqual(report['previewMatrixSeconds'], 0)
