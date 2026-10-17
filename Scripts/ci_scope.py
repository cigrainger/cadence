#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Select the Mac gate only when a change can affect the app or its checks."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TEXT_ONLY = {'README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md'}


def needs_native(paths):
    if not paths:
        return True
    for name in paths:
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or not path.parts:
            return True
        if name not in TEXT_ONLY and path.parts[0] not in {'Docs', 'site'}:
            return True
    return False


def changed_paths(event_name, event, root=ROOT):
    if event_name == 'pull_request':
        base = event['pull_request']['base']['sha']
        head = event['pull_request']['head']['sha']
    elif event_name == 'push':
        base, head = event['before'], event['after']
    else:
        return None  # Manual, unknown and first-push events run the full gate.
    if not all(isinstance(ref, str) and re.fullmatch(r'[0-9a-f]{40}', ref) and set(ref) != {'0'}
               for ref in (base, head)):
        return None
    if event_name == 'pull_request':
        base = subprocess.check_output(['git', 'merge-base', base, head], cwd=root).decode().strip()
    # A move from Sources/ to Docs/ must include the deleted source path.
    # Rename detection's destination-only listing would incorrectly skip it.
    data = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', base, head], cwd=root)
    return [name for name in data.decode().split('\0') if name]


def select_native(event_name, event, root=ROOT):
    try:
        return needs_native(changed_paths(event_name, event, root))
    except (KeyError, TypeError, ValueError, UnicodeError, subprocess.CalledProcessError, OSError):
        return True  # Incomplete history/metadata never opts out of native checks.


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        native = select_native(os.environ.get('GITHUB_EVENT_NAME', ''), event)
    except (KeyError, ValueError, OSError):
        native = True
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        output.write(f'native={str(native).lower()}\n')
    print('Full native verification required: ' + str(native).lower())


if __name__ == '__main__':
    main()
