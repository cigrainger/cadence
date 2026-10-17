# SPDX-License-Identifier: AGPL-3.0-or-later
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ci_scope import needs_native, select_native


class CIScopeTests(unittest.TestCase):
    def test_only_documentation_and_site_changes_skip_the_mac_gate(self):
        self.assertFalse(needs_native(['README.md', 'Docs/ROADMAP.md', 'site/assets/site.js']))
        for name in ('Sources/Cadence/A.swift', 'Tests/CadenceTests/A.swift', 'Resources/ScoreViewer/score.js',
                     'Scripts/verify.py', '.github/workflows/verify.yml', 'Package.swift', 'Package.resolved',
                     'build.sh', 'LICENSE', 'LICENSES/MIT.txt', 'Dependencies/components.json',
                     'Docs-other/file', '../Docs/foo', '/Docs/foo'):
            with self.subTest(path=name):
                self.assertTrue(needs_native(['Docs/README.md', name]))
        self.assertTrue(needs_native([]))

    def test_missing_malformed_initial_manual_and_unknown_events_run_the_full_gate(self):
        for name, event in [('workflow_dispatch', {}), ('unknown', {}), ('pull_request', {}),
                            ('push', {'before': '0' * 40, 'after': 'a' * 40}),
                            ('push', {'before': '--help', 'after': 'a' * 40})]:
            with self.subTest(event=name):
                self.assertTrue(select_native(name, event))
        with patch('ci_scope.subprocess.check_output', side_effect=subprocess.CalledProcessError(1, 'git')):
            self.assertTrue(select_native('push', {'before': 'a' * 40, 'after': 'b' * 40}))

    def test_real_git_diff_includes_source_deleted_by_a_rename_into_docs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            git('init')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'commit.gpgsign', 'false')
            git('config', 'core.hooksPath', '/dev/null')
            source = root / 'Sources/A.swift'
            source.parent.mkdir()
            source.write_text('original')
            git('add', '.')
            git('commit', '-m', 'original')
            before = git('rev-parse', 'HEAD')
            docs = root / 'Docs'
            docs.mkdir()
            source.rename(docs / 'A.md')
            git('add', '.')
            git('commit', '-m', 'move source into docs')
            after = git('rev-parse', 'HEAD')
            self.assertTrue(select_native('push', {'before': before, 'after': after}, root))
            (docs / 'A.md').write_text('documentation update')
            git('add', '.')
            git('commit', '-m', 'docs only')
            head = git('rev-parse', 'HEAD')
            self.assertFalse(select_native('push', {'before': after, 'after': head}, root))
            self.assertFalse(select_native('pull_request', {'pull_request': {'base': {'sha': after}, 'head': {'sha': head}}}, root))
            self.assertTrue(select_native('pull_request', {'pull_request': {'base': {'sha': before}, 'head': {'sha': head}}}, root))
