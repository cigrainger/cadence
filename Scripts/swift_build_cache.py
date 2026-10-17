#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Reuse compiler work, never verification results, across matching macOS hosts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from native_coverage import reset_unit_coverage

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inputs(root):
    paths = [root / 'Package.swift', root / 'Package.resolved']
    paths += [path for folder in ('Sources', 'Tests') for path in (root / folder).rglob('*') if path.is_file()]
    if any(path.is_symlink() for path in paths):
        raise ValueError('Build cache inputs must not be symlinks')
    return paths


def fingerprint(root=ROOT):
    # No broad restore prefix may cross an SDK, OS image, architecture, path,
    # dependency or build-flag change. Incremental builds still check sources.
    commands = [('xcrun', 'swift', '--version'), ('xcodebuild', '-version'),
                ('sw_vers', '-buildVersion'), ('uname', '-m')]
    identity = [str(root.resolve()), os.environ.get('ImageVersion', '')]
    identity += [subprocess.check_output(command, text=True).strip() for command in commands]
    identity += [digest(root / name) for name in
                 ('Package.swift', 'Package.resolved', 'build.sh', 'Scripts/verify.py',
                  'Scripts/native_coverage.py', 'Scripts/swift_build_cache.py')]
    return hashlib.sha256(json.dumps(identity).encode()).hexdigest()


def record(root, scratch):
    scratch.mkdir(parents=True, exist_ok=True)
    # Profiles and exported results are not reusable build products. The full
    # verifier also clears profiles independently before every unit-test run.
    reset_unit_coverage(scratch)
    state = {str(path.relative_to(root)): {'sha256': digest(path), 'mtimeNS': path.stat().st_mtime_ns}
             for path in inputs(root)}
    (scratch / 'source-times.json').write_text(json.dumps({'version': 1, 'files': state}) + '\n')


def restore(root, scratch):
    manifest = scratch / 'source-times.json'
    if not manifest.is_file():
        return 0
    if manifest.stat().st_size > 5_000_000:
        raise ValueError('Invalid build-cache source manifest')
    state = json.loads(manifest.read_text())
    if state.get('version') != 1 or not isinstance(state.get('files'), dict):
        raise ValueError('Unsupported build-cache source manifest')
    restored = 0
    # Iterate known current inputs, never paths supplied by a cache manifest.
    # A fresh checkout changes mtimes even when content is identical. Restore
    # only byte-identical inputs; changed/new inputs retain their fresh mtime.
    for path in inputs(root):
        entry = state['files'].get(str(path.relative_to(root)), {})
        timestamp = entry.get('mtimeNS')
        if type(timestamp) is int and 0 < timestamp < 2**63 and entry.get('sha256') == digest(path):
            os.utime(path, ns=(path.stat().st_atime_ns, timestamp), follow_symlinks=False)
            restored += 1
    return restored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('fingerprint', 'record', 'restore'))
    parser.add_argument('--scratch', type=Path, default=ROOT / '.verification/build')
    args = parser.parse_args()
    if args.action == 'fingerprint':
        print(fingerprint())
    elif args.action == 'record':
        record(ROOT, args.scratch)
    else:
        print(f'Reused source timestamps for {restore(ROOT, args.scratch)} byte-identical build inputs.')


if __name__ == '__main__':
    main()
