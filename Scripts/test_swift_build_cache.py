# SPDX-License-Identifier: AGPL-3.0-or-later
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from swift_build_cache import fingerprint, record, restore


class SwiftBuildCacheTests(unittest.TestCase):
    def fixture(self, folder):
        root = Path(folder)
        for name in ('Package.swift', 'Package.resolved', 'build.sh', 'Scripts/verify.py',
                     'Scripts/native_coverage.py', 'Scripts/swift_build_cache.py',
                     'Scripts/swift_build_config.py',
                     'Sources/Cadence/A.swift', 'Tests/CadenceTests/A.swift'):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('original')
        return root, root / 'build'

    def test_only_byte_identical_inputs_reuse_timestamps(self):
        with tempfile.TemporaryDirectory() as folder:
            root, scratch = self.fixture(folder)
            unchanged = root / 'Sources/Cadence/A.swift'
            changed = root / 'Tests/CadenceTests/A.swift'
            original = unchanged.stat().st_mtime_ns
            record(root, scratch)
            for path in (unchanged, changed):
                os.utime(path, ns=(original + 1_000_000_000, original + 1_000_000_000))
            changed.write_text('modified')
            new_time = changed.stat().st_mtime_ns
            restore(root, scratch)
            self.assertEqual(unchanged.stat().st_mtime_ns, original)
            self.assertEqual(changed.stat().st_mtime_ns, new_time)
            self.assertEqual(changed.read_text(), 'modified')

    def test_cache_save_removes_coverage_but_preserves_compiler_work(self):
        with tempfile.TemporaryDirectory() as folder:
            root, scratch = self.fixture(folder)
            coverage = scratch / 'arm64/debug/codecov'
            coverage.mkdir(parents=True)
            for name in ('old.profraw', 'default.profdata', 'Cadence.json', 'object.o'):
                (coverage / name).write_bytes(b'fixture')
            record(root, scratch)
            self.assertEqual([p.name for p in coverage.iterdir()], ['object.o'])

    def test_cache_manifest_cannot_choose_writable_paths_or_follow_input_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root, scratch = self.fixture(folder)
            record(root, scratch)
            manifest = scratch / 'source-times.json'
            state = json.loads(manifest.read_text())
            protected = root / 'private.txt'
            protected.write_text('keep')
            before = protected.stat().st_mtime_ns
            state['files']['../private.txt'] = {'mtimeNS': 1, 'sha256': 'ignored'}
            state['files'][str(protected)] = {'mtimeNS': 1, 'sha256': 'ignored'}
            manifest.write_text(json.dumps(state))
            restore(root, scratch)
            self.assertEqual(protected.stat().st_mtime_ns, before)
            link = root / 'Sources/Cadence/link.swift'
            link.symlink_to(protected)
            with self.assertRaises(ValueError):
                restore(root, scratch)

    def test_cache_identity_changes_with_toolchain_build_flags_and_checkout_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root, _ = self.fixture(folder)
            with patch('swift_build_cache.subprocess.check_output', return_value='SDK A'):
                first = fingerprint(root)
                (root / 'build.sh').write_text('new compiler flags')
                self.assertNotEqual(fingerprint(root), first)
                (root / 'build.sh').write_text('original')
                self.assertEqual(fingerprint(root), first)
                (root / 'Scripts/verify.py').write_text('new screenshot scheduling')
                self.assertEqual(fingerprint(root), first)
                (root / 'Scripts/swift_build_config.py').write_text('new unit compiler flags')
                self.assertNotEqual(fingerprint(root), first)
                (root / 'Scripts/swift_build_config.py').write_text('original')
                other, _ = self.fixture(root / 'other-checkout')
                self.assertNotEqual(fingerprint(other), first)
            with patch('swift_build_cache.subprocess.check_output', return_value='SDK B'):
                self.assertNotEqual(fingerprint(root), first)

    def test_absent_cache_is_cold_and_malformed_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root, scratch = self.fixture(folder)
            self.assertEqual(restore(root, scratch), 0)
            record(root, scratch)
            (scratch / 'source-times.json').write_text('{"version": 2, "files": {}}')
            with self.assertRaises(ValueError):
                restore(root, scratch)
