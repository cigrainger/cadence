# SPDX-License-Identifier: AGPL-3.0-or-later
import json
from pathlib import Path
import subprocess
import unittest
import tempfile
from build_inputs import source_digest, verify_app_inputs
from unittest.mock import patch

import notarise
import signing

DEVELOPER = '''Identifier=com.cadence.music
CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=5+7 location=embedded
Authority=Developer ID Application: Example (ABCDE12345)
Authority=Developer ID Certification Authority
TeamIdentifier=ABCDE12345
Timestamp=17 Oct 2026 at 10:00:00
'''


class SigningTests(unittest.TestCase):
    def test_release_requires_distribution_identity_timestamp_and_runtime(self):
        self.assertEqual(signing.signature_metadata(DEVELOPER, {})['signing'], 'Developer ID Application')
        for invalid in [DEVELOPER.replace('Developer ID Application:', 'Apple Development:'),
                        DEVELOPER.replace('Identifier=com.cadence.music', 'Identifier=other.app'),
                        DEVELOPER.replace('flags=0x10000', 'flags=0x0'),
                        DEVELOPER.replace('Timestamp=', 'Signed Time='),
                        DEVELOPER.replace('TeamIdentifier=ABCDE12345', 'TeamIdentifier=not set')]:
            with self.assertRaises(ValueError):
                signing.signature_metadata(invalid, {})
        with self.assertRaises(ValueError):
            signing.signature_metadata(DEVELOPER, {'com.apple.security.get-task-allow': True})

    def test_adhoc_build_is_never_labelled_notarised(self):
        description = 'Identifier=com.cadence.music\nCodeDirectory flags=0x10002(adhoc,runtime)\nSignature=adhoc'
        self.assertEqual(signing.signature_metadata(description, {}), {'signing': 'ad-hoc', 'notarised': False})

    def test_signing_never_falls_back_when_identity_is_invalid_or_signing_fails(self):
        with patch.object(signing, 'run') as run:
            with self.assertRaises(ValueError):
                signing.sign(Path('/tmp/Cadence.app'), 'Apple Development: Example')
            run.assert_not_called()
            run.side_effect = subprocess.CalledProcessError(1, ['codesign'])
            with self.assertRaises(subprocess.CalledProcessError):
                signing.sign(Path('/tmp/Cadence.app'), 'Developer ID Application: Example (ABCDE12345)')
            self.assertEqual(run.call_count, 1)
            self.assertIn('--timestamp', run.call_args.args)

    def test_ticket_and_gatekeeper_are_both_required(self):
        with patch.object(signing, 'inspect', return_value={'signing': 'Developer ID Application', 'notarised': False}):
            with patch.object(signing, 'run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaises(ValueError):
                    signing.release_metadata(Path('/tmp/app'), require_notarised=True)
            with patch.object(signing, 'run', side_effect=[subprocess.CompletedProcess([], 0),
                    subprocess.CalledProcessError(1, ['spctl'])]):
                with self.assertRaises(subprocess.CalledProcessError):
                    signing.release_metadata(Path('/tmp/app'), require_notarised=True)
            with patch.object(signing, 'run', return_value=subprocess.CompletedProcess([], 0)):
                self.assertTrue(signing.release_metadata(Path('/tmp/app'), True)['notarised'])

    def test_apple_rejection_or_unknown_state_never_means_success(self):
        for response in ({}, {'status': 'Invalid'}, {'status': 'In Progress'}, {'status': 'accepted'}):
            with self.assertRaises(ValueError): notarise.accepted(response)
        notarise.accepted({'status': 'Accepted'})

    def test_notarisation_refuses_adhoc_before_any_upload(self):
        with patch.object(notarise, 'inspect', return_value={'signing': 'ad-hoc'}), patch.object(notarise, 'run') as run:
            with self.assertRaises(ValueError): notarise.notarise(Path('/tmp/app'), 'profile')
            run.assert_not_called()

    def test_resume_never_uploads_again_and_only_staples_accepted_submission(self):
        submission = '60f73248-4097-46b4-9738-ef9751f95826'
        for status in ['Accepted', 'Invalid']:
            with patch.object(notarise, 'inspect', return_value={'signing': 'Developer ID Application'}), \
                 patch.object(notarise, 'release_metadata', return_value={'notarised': True}) as verified, \
                 patch.object(notarise, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps({'status': status}).encode())) as run:
                if status == 'Accepted':
                    notarise.notarise(Path('/tmp/app'), 'profile', submission)
                    self.assertEqual(run.call_args_list[1].args[:3], ('xcrun', 'stapler', 'staple'))
                    verified.assert_called_once()
                else:
                    with self.assertRaises(ValueError): notarise.notarise(Path('/tmp/app'), 'profile', submission)
                    verified.assert_not_called()
                    self.assertEqual(run.call_count, 1)
                self.assertFalse(any('submit' in call.args for call in run.call_args_list))

    def test_timeout_retains_submission_id_without_claiming_acceptance(self):
        submission = '60f73248-4097-46b4-9738-ef9751f95826'
        with patch.object(notarise, 'inspect', return_value={'signing': 'Developer ID Application'}), \
             patch.object(notarise, 'run', return_value=subprocess.CompletedProcess([], 1)) as run:
            with self.assertRaisesRegex(RuntimeError, submission): notarise.notarise(Path('/tmp/app'), 'profile', submission)
            self.assertEqual(run.call_count, 1)


class BuildProvenanceTests(unittest.TestCase):
    def test_source_resource_and_manifest_changes_invalidate_the_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('Package.swift', 'Package.resolved', 'build.sh', 'LICENSE'):
                (root / name).write_text(name)
            (root / 'Sources').mkdir(); (root / 'Resources').mkdir()
            source = root / 'Sources/App.swift'; source.write_text('initial')
            before = source_digest(root)
            source.write_text('changed')
            self.assertNotEqual(source_digest(root), before)
            source.write_text('initial')
            self.assertEqual(source_digest(root), before)
            (root / 'Resources/sound').write_bytes(b'new sound')
            self.assertNotEqual(source_digest(root), before)
            source.unlink(); source.symlink_to(root / 'Package.swift')
            with self.assertRaises(ValueError): source_digest(root)

    def test_stale_or_missing_app_provenance_cannot_be_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory); resources = app / 'Contents/Resources'; resources.mkdir(parents=True)
            with self.assertRaises(FileNotFoundError): verify_app_inputs(app, 'current')
            (resources / 'BuildProvenance.json').write_text(json.dumps({'sourceInputsSHA256':'stale'}))
            with self.assertRaises(ValueError): verify_app_inputs(app, 'current')
            verify_app_inputs(app, 'stale')
