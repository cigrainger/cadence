# SPDX-License-Identifier: AGPL-3.0-or-later
import datetime
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from ci_stages import archive, context, export_unit, inventory, seal, unpack, validate
from native_coverage import file_hash


class CIStageTests(unittest.TestCase):
    def identity(self):
        return {'context': {'local': 'one-run'}, 'sourceInputsSHA256': 'a' * 64,
                'testInputsSHA256': 'b' * 64, 'hostFingerprint': 'c' * 64}

    def fixture(self, folder):
        folder.mkdir(parents=True)
        expected = self.identity()
        report = {'passed': True, 'mode': 'tests-only', 'verificationContext': expected['context'],
                  'sourceInputsSHA256': expected['sourceInputsSHA256'],
                  'testInputsSHA256': expected['testInputsSHA256']}
        (folder / 'summary.json').write_text(json.dumps(report))
        (folder / 'tests.log').write_text('original evidence')
        binary = folder / 'products/Cadence'
        binary.parent.mkdir()
        binary.write_bytes(b'matching instrumented executable')
        binary.chmod(0o755)
        seal(folder, 'unit', expected, 1)
        return expected

    def test_round_trip_preserves_executable_bytes_permissions_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / 'stage'
            expected = self.fixture(stage)
            output = root / 'stage.tar.gz'
            archive(stage, output)
            unpack(output, root / 'received', file_hash(output))
            self.assertEqual(validate(root / 'received', 'unit', expected)['files'], inventory(stage))
            self.assertTrue(os.access(root / 'received/products/Cadence', os.X_OK))
            self.assertEqual((root / 'received/products/Cadence').read_bytes(),
                             (stage / 'products/Cadence').read_bytes())

    def test_other_run_attempt_commit_inputs_host_and_kind_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory) / 'stage'
            expected = self.fixture(stage)
            for key in expected:
                wrong = dict(expected, **{key: 'changed'})
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'another run'):
                    validate(stage, 'unit', wrong)
            with self.assertRaisesRegex(ValueError, 'kind/version'):
                validate(stage, 'release', expected)

    def test_changed_missing_extra_or_symlinked_files_cannot_pass(self):
        for mutation in ('changed', 'missing', 'extra', 'symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                stage = Path(directory) / 'stage'
                expected = self.fixture(stage)
                path = stage / 'tests.log'
                if mutation == 'changed': path.write_text('different result')
                if mutation == 'missing': path.unlink()
                if mutation == 'extra': (stage / 'unexpected').write_text('extra')
                if mutation == 'symlink':
                    path.unlink()
                    path.symlink_to(stage / 'summary.json')
                with self.assertRaises(ValueError): validate(stage, 'unit', expected)

    def test_a_matching_file_inventory_cannot_make_a_failed_or_old_result_pass(self):
        for field, value in [('passed', False), ('passed', 1), ('mode', 'full'),
                             ('verificationContext', {'local': 'previous-run'}),
                             ('sourceInputsSHA256', 'different'), ('testInputsSHA256', 'different')]:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as directory:
                stage = Path(directory) / 'stage'
                expected = self.fixture(stage)
                report = json.loads((stage / 'summary.json').read_text())
                report[field] = value
                (stage / 'summary.json').write_text(json.dumps(report))
                with self.assertRaises(ValueError): seal(stage, 'unit', expected, 1)

    def test_archive_hash_is_checked_before_extraction_and_destination_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root / 'stage')
            archive(root / 'stage', root / 'stage.tar.gz')
            with self.assertRaisesRegex(ValueError, 'digest'):
                unpack(root / 'stage.tar.gz', root / 'bad', '0' * 64)
            self.assertFalse((root / 'bad').exists())
            with self.assertRaisesRegex(ValueError, 'Missing archive digest'):
                unpack(root / 'stage.tar.gz', root / 'bad', '')
            with self.assertRaisesRegex(ValueError, 'fresh'):
                unpack(root / 'stage.tar.gz', root / 'stage', file_hash(root / 'stage.tar.gz'))

    def test_archive_traversal_links_duplicates_and_excessive_sizes_are_rejected(self):
        for name, kind in [('../escape', 'file'), ('/escape', 'file'), ('link', 'symlink'),
                           ('link', 'hardlink'), ('duplicate', 'duplicate'), ('large', 'large'),
                           ('negative', 'negative')]:
            with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                path = root / 'bad.tar.gz'
                with tarfile.open(path, 'w:gz') as output:
                    entry = tarfile.TarInfo(name)
                    if kind in ('symlink', 'hardlink'):
                        entry.type = tarfile.SYMTYPE if kind == 'symlink' else tarfile.LNKTYPE
                        entry.linkname = '../escape'
                    if kind in ('large', 'negative'):
                        # Declared size is sufficient; no huge fixture is allocated.
                        entry.size = 2_000_000_001 if kind == 'large' else -1
                        output.fileobj.write(entry.tobuf())
                    else:
                        output.addfile(entry, io.BytesIO(b''))
                        if kind == 'duplicate': output.addfile(entry, io.BytesIO(b''))
                with self.assertRaises((ValueError, tarfile.TarError)):
                    unpack(path, root / 'received', file_hash(path))
                self.assertFalse((root / 'escape').exists())

    def test_ci_context_never_silently_falls_back_to_a_local_or_incomplete_identity(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2', 'GITHUB_SHA': 'a' * 40}
        self.assertEqual(context(env), {k: env[k] for k in env if k != 'GITHUB_ACTIONS'})
        for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA'):
            with self.subTest(key=key), self.assertRaises(ValueError): context(dict(env, **{key: ''}))
        with self.assertRaises(ValueError): context({})

    def test_export_keeps_only_matching_objects_and_fresh_coverage_not_the_build_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / 'build/arm64/debug'
            profile = products / 'codecov/default.profdata'
            profile.parent.mkdir(parents=True)
            profile.write_bytes(b'fresh unit coverage')
            export = profile.with_name('Cadence.json')
            export.write_text('{}')
            for name in ('Cadence', 'CadenceTests.xctest/Contents/MacOS/CadenceTests'):
                p = products / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b'object')
                p.chmod(0o755)
            (products / 'unrelated-secret.env').write_text('must not be transferred')
            report_path = root / 'summary.json'
            expected = self.identity()
            report = {'passed': True, 'mode': 'tests-only', 'verificationContext': expected['context'],
                      'sourceInputsSHA256': expected['sourceInputsSHA256'],
                      'testInputsSHA256': expected['testInputsSHA256'], 'unitCoverageExport': str(export),
                      'startedAt': datetime.datetime.fromtimestamp(1, datetime.timezone.utc).isoformat(), 'seconds': 2}
            report_path.write_text(json.dumps(report))
            (root / 'tests.log').write_text('fresh tests')
            with patch('ci_stages.identity', return_value=expected):
                export_unit(report_path, root / 'unit.tar.gz', root)
            unpack(root / 'unit.tar.gz', root / 'received', file_hash(root / 'unit.tar.gz'))
            validate(root / 'received', 'unit', expected)
            self.assertFalse((root / 'received/products/unrelated-secret.env').exists())
            os.utime(profile, (0, 0))
            with patch('ci_stages.identity', return_value=expected), self.assertRaisesRegex(ValueError, 'stale'):
                export_unit(report_path, root / 'stale.tar.gz', root)
