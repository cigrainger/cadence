# SPDX-License-Identifier: AGPL-3.0-or-later
import copy
import hashlib
from pathlib import Path
import tempfile
import subprocess
import unittest
from check_repository import check_path, check_swift_mode, make_bom, public_files, validate_components


class RepositoryTests(unittest.TestCase):
    def test_new_untracked_sources_are_checked_but_ignored_work_is_not(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['git', 'init', '--quiet', root], check=True)
            (root / 'README.md').write_text('tracked')
            subprocess.run(['git', 'add', 'README.md'], cwd=root, check=True)
            (root / '.gitignore').write_text('private.txt\n')
            (root / 'private.txt').write_text('ignored fixture')
            (root / 'new.swift').write_text('// new source')
            files = {path.relative_to(root).as_posix() for path in public_files(root)}
            self.assertIn('new.swift', files)
            self.assertIn('README.md', files)
            self.assertNotIn('private.txt', files)

    def test_swift_5_fallbacks_cannot_silently_return(self):
        self.assertEqual(check_swift_mode('swiftLanguageModes: [.v6]'), [])
        self.assertTrue(check_swift_mode('swiftLanguageModes: [.v5]'))
        self.assertTrue(check_swift_mode('swiftLanguageModes: [.v6], swiftSettings: [.swiftLanguageMode(.v5)]'))
    def test_private_and_generated_paths_are_rejected(self):
        for path in ['Research/model.json', '.env.local', 'private/score.json', 'keys/signing.p12',
                     'Docs/book.pdf', 'recordings/take.json', 'dist/Cadence.app/Contents/MacOS/Cadence']:
            self.assertIsNotNone(check_path(path), path)
        self.assertIsNone(check_path('Resources/ImportExamples/piano.pdf'))
        self.assertIsNone(check_path('Sources/MusicCore/Score/EditorScore.swift'))

    def test_code_cannot_inherit_soundbank_license_exception(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'notice').write_text('license')
            manifest = {'components': [{'id': 'new-code', 'kind': 'library', 'license': 'GPL-2.0-only',
                                        'version': '1', 'notice': 'notice'}], 'assets': []}
            self.assertTrue(validate_components(manifest, root))
            manifest['components'][0].update(id='timgm6mb', kind='data')
            self.assertEqual(validate_components(manifest, root), [])

    def test_vendor_hash_change_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'bundle').write_bytes(b'original')
            manifest = {'components': [], 'assets': [{'path': 'bundle', 'sha256': hashlib.sha256(b'original').hexdigest()}]}
            self.assertEqual(validate_components(manifest, root), [])
            (root / 'bundle').write_bytes(b'changed')
            self.assertTrue(validate_components(manifest, root))

    def test_unknown_versions_remain_visible_in_bom(self):
        manifest = {'scope': 'runtime', 'limitations': 'incomplete', 'assets': [], 'components': [
            {'id': 'bundle-child', 'name': 'child', 'kind': 'library', 'license': 'MIT',
             'source': 'https://example.org', 'versionEvidence': 'Not published'}]}
        bom = make_bom(manifest, '1')
        self.assertNotIn('version', bom['components'][0])
        self.assertEqual(bom['compositions'][0]['aggregate'], 'incomplete')
        self.assertEqual(bom['components'][0]['properties'][0]['value'], 'Not published')
