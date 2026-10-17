# SPDX-FileCopyrightText: 2026 Cadence contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from native_coverage import NativeCoverage, check_diagnostics, check_source_inventory, file_hash, reset_unit_coverage
from verify import native_scenarios, run_preview


class NativeCoverageTests(unittest.TestCase):
    def test_filtered_run_profiles_cannot_leak_into_full_unit_coverage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            coverage = root / "out/Products/Debug/codecov"
            coverage.mkdir(parents=True)
            for name in ("old.profraw", "default.profdata", "Cadence.json", "build-product"):
                (coverage / name).write_text("original")
            reset_unit_coverage(root)
            self.assertEqual([p.name for p in coverage.iterdir()], ["build-product"])

    def test_coverage_cleanup_cannot_follow_a_symlink_outside_the_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cache, external = root / "cache", root / "external"
            cache.mkdir(); external.mkdir()
            protected = external / "original.profdata"
            protected.write_text("keep")
            (cache / "codecov").symlink_to(external, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                reset_unit_coverage(cache)
            self.assertEqual(protected.read_text(), "keep")

    def fixture(self, folder):
        root = Path(folder)
        (root / "raw").mkdir()
        binary, unit = root / "Cadence", root / "unit.profdata"
        binary.write_bytes(b"instrumented")
        unit.write_bytes(b"unit")
        return NativeCoverage(root, binary, (binary,), {str(p): file_hash(p) for p in (binary, unit)}, time.time() - 1)

    def test_missing_empty_stale_and_changed_profiles_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            collection = self.fixture(folder)
            with self.assertRaises(RuntimeError): collection.profiles(1)
            raw = Path(folder) / "raw/one.profraw"
            raw.touch()
            with self.assertRaises(RuntimeError): collection.profiles(1)
            raw.write_bytes(b"profile")
            os.utime(raw, (0, 0))
            with self.assertRaises(RuntimeError): collection.profiles(1)
            os.utime(raw, None)
            self.assertEqual(collection.profiles(1), [raw])
            with self.assertRaises(RuntimeError): collection.profiles(2)
            (Path(folder) / "unit.profdata").write_bytes(b"a different run")
            with self.assertRaises(RuntimeError): collection.profiles(1)

    def test_changed_binary_cannot_be_combined_with_old_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            collection = self.fixture(folder)
            (Path(folder) / "raw/one.profraw").write_bytes(b"profile")
            collection.executable.write_bytes(b"changed binary")
            with self.assertRaises(RuntimeError): collection.profiles(1)
            with self.assertRaises(RuntimeError): collection.profiles(0)

    def test_every_first_party_view_and_diagnostic_remains_in_inventory(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            sources = [root / "Sources/Cadence/View.swift", root / "Sources/Cadence/Diagnostics/Check.swift",
                       root / "Sources/MusicCore/Rules.swift"]
            for path in sources:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// fixture")
            document = {"data": [{"files": [{"filename": str(path)} for path in sources]}]}
            check_source_inventory(document, root)
            document["data"][0]["files"].pop(0)
            with self.assertRaisesRegex(RuntimeError, "View.swift"):
                check_source_inventory(document, root)
            document["data"][0]["files"].append({"filename": str(sources[1])})
            with self.assertRaisesRegex(RuntimeError, "duplicate"):
                check_source_inventory(document, root)

    def test_llvm_warnings_are_not_silently_treated_as_valid_coverage(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "llvm.log"
            for text in ("warning: 7 functions have mismatched data", "error: malformed profile"):
                log.write_text(text)
                with self.assertRaises(RuntimeError): check_diagnostics(log)
            log.write_text("")
            check_diagnostics(log)

    def test_release_and_instrumented_app_use_one_complete_scenario_inventory(self):
        scenarios = native_scenarios()
        names = [scenario[0] for scenario in scenarios]
        self.assertGreaterEqual(len(names), 129)
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("song-accessibility", names)
        self.assertIn("editor-guitar", names)
        self.assertTrue(all(len(scenario) == 5 for scenario in scenarios))

    def test_failed_native_run_cannot_reuse_old_images_and_assertions(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "fixture.png").write_bytes(b"old" * 1000)
            (root / "fixture.json").write_text(json.dumps({"passed": True}))
            with patch("verify.run"):
                with self.assertRaisesRegex(RuntimeError, "Missing fixture image"):
                    run_preview(Path("Cadence"), root, {"CADENCE_PREVIEW_RUNNER": "native-preview"}, ("fixture", [], [], None, []))

    def test_renderer_flags_cannot_substitute_for_a_ready_score(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def fake_run(*_):
                (root / "fixture.png").write_bytes(b"image" * 1000)
                (root / "fixture.json").write_text(json.dumps({"offline": True, "kind": "error", "svgCount": 0}))
            with patch("verify.run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "did not render"):
                    run_preview(Path("Cadence"), root, {"CADENCE_PREVIEW_RUNNER": "native-preview"}, ("fixture", [], ["offline"], None, []))


if __name__ == "__main__":
    unittest.main()
