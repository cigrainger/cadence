#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Bind a packaged app to the source/resource inputs in its corresponding source archive."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source_digest(root=ROOT):
    files = [root / name for name in ('Package.swift', 'Package.resolved', 'build.sh', 'LICENSE')]
    for folder in ('Sources', 'Resources', 'LICENSES', 'Scripts'):
        files.extend(path for path in (root / folder).rglob('*')
                     if path.is_file() and '__pycache__' not in path.parts
                     and path.name != '.DS_Store' and path.suffix != '.pyc')
    digest = hashlib.sha256()
    for path in sorted(files):
        if path.is_symlink():
            raise ValueError('Release inputs must not be symlinks: ' + str(path.relative_to(root)))
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def verify_app_inputs(app, expected):
    provenance = json.loads((app / 'Contents/Resources/BuildProvenance.json').read_text())
    if provenance.get('sourceInputsSHA256') != expected:
        raise ValueError('The app was built from different source inputs. Rebuild before packaging.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--expected')
    args = parser.parse_args()
    digest = source_digest()
    if args.app:
        if args.expected != digest:
            raise ValueError('Build inputs changed during compilation; rebuild the app.')
        (args.app / 'Contents/Resources/BuildProvenance.json').write_text(
            json.dumps({'sourceInputsSHA256': digest}, indent=2) + '\n')
    else:
        print(digest)


if __name__ == '__main__': main()
