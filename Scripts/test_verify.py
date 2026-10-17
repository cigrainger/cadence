import unittest
from verify import check_group, require_flags, summarize_coverage, test_counts


class VerificationTests(unittest.TestCase):
    def test_missing_or_false_native_results_cannot_pass(self):
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

    def test_coverage_excludes_dependencies_and_test_code(self):
        summary = {kind: {"count": 10, "covered": 7} for kind in ("lines", "regions", "functions")}
        paths = ["/Sources/MusicCore/A.swift", "/Sources/Cadence/A.swift", "/Tests/MusicCoreTests/A.swift", "/Sources/ZIPFoundation/A.swift"]
        report = summarize_coverage({"data": [{"files": [{"filename": path, "summary": summary} for path in paths]}]})
        self.assertEqual(report["MusicCore"]["lines"], {"count": 10, "covered": 7, "percent": 70.0})
        self.assertEqual(report["Cadence"]["files"], 1)
