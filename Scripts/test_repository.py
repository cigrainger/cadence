# SPDX-License-Identifier: AGPL-3.0-or-later
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
from check_repository import check_path, make_bom, validate_components


class RepositoryTests(unittest.TestCase):
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
