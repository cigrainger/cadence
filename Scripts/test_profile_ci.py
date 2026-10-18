# SPDX-FileCopyrightText: 2026 Cadence contributors
import json
from pathlib import Path
import tempfile
import unittest
from profile_ci import execution_seconds, evidence_profile, seconds


class CIProfileTests(unittest.TestCase):
    def test_skipped_job_timestamps_and_missing_native_evidence_remain_unavailable(self):
        self.assertIsNone(seconds(None, None))
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(evidence_profile(Path(directory))['available'])

    def test_test_execution_does_not_double_count_nested_suites_or_separate_bundles(self):
        log = """Test Suite 'A.xctest' passed
Executed 2 tests in 10.0 (10.0) seconds
Test Suite 'All tests' passed at today
  Executed 2 tests, with 0 failures in 10.0 (10.0) seconds
Test Suite 'All tests' passed at today
  Executed 3 tests, with 0 failures in 20.0 (20.0) seconds
"""
        self.assertEqual(execution_seconds(log), 30)

    def test_matrix_wall_time_is_not_the_sum_of_overlapping_pair_times_and_sources_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = {'passed': True, 'mode': 'full', 'sourceInputsSHA256': 'same',
                      'previewMatrixSeconds': 10, 'previewPairSeconds': {'a': 9, 'b': 9},
                      'previews': {'a': {}, 'b': {}}}
            (root / 'summary.json').write_text(json.dumps(report))
            result = evidence_profile(root)
            self.assertEqual(result['nativeMatrixSeconds'], 10)
            self.assertEqual(result['scenariosPerBuild'], 2)
            extra = root / 'unit'
            extra.mkdir()
            (extra / 'summary.json').write_text(json.dumps(dict(report, mode='tests-only', sourceInputsSHA256='other')))
            with self.assertRaisesRegex(ValueError, 'different source'): evidence_profile(root)
