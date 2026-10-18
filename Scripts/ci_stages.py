#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Transfer fresh, source-bound outputs between jobs in one verification run.

These are evidence artifacts, not caches. A consumer rejects another attempt,
commit, checkout, toolchain or input tree, and independently reruns coverage and
native gates. The archive digest travels through job outputs, outside the archive.
"""
import argparse
import datetime
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import time

from build_inputs import ROOT, source_digest, test_inputs_digest, verify_app_inputs
from native_coverage import file_hash
from swift_build_cache import fingerprint


def require(condition, message):
    if not condition:
        raise ValueError(message)


def context(env=None):
    env = os.environ if env is None else env
    if env.get('GITHUB_ACTIONS') == 'true':
        values = {key: env.get(key, '') for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA')}
        require(re.fullmatch(r'[0-9]+', values['GITHUB_RUN_ID']) and
                re.fullmatch(r'[0-9]+', values['GITHUB_RUN_ATTEMPT']) and
                re.fullmatch(r'[0-9a-f]{40}', values['GITHUB_SHA']), 'Missing CI run identity')
        return values
    require(env.get('CADENCE_VERIFICATION_ID'), 'Prepared stages require an explicit verification identity')
    return {'local': env['CADENCE_VERIFICATION_ID']}


def identity(root=ROOT):
    return {'context': context(), 'sourceInputsSHA256': source_digest(root),
            'testInputsSHA256': test_inputs_digest(root), 'hostFingerprint': fingerprint(root)}


def inventory(folder):
    files = {}
    for path in sorted(folder.rglob('*')):
        require(not path.is_symlink(), 'Stage artifacts cannot contain symlinks')
        if path.is_file() and path != folder / 'stage.json':
            files[path.relative_to(folder).as_posix()] = file_hash(path)
    return files


def validate(folder, kind, expected):
    require(not (folder / 'stage.json').is_symlink(), 'Stage manifest cannot be a symlink')
    manifest = json.loads((folder / 'stage.json').read_text())
    require(manifest.get('version') == 1 and manifest.get('kind') == kind, 'Wrong prepared stage kind/version')
    require(manifest.get('identity') == expected, 'Prepared stage belongs to another run, host or input tree')
    require(manifest.get('files') and inventory(folder) == manifest['files'], 'Stage files changed or are missing')
    if kind == 'unit':
        report = json.loads((folder / 'summary.json').read_text())
        require(report.get('passed') is True and report.get('mode') == 'tests-only', 'Unit stage did not pass')
        require(report.get('verificationContext') == expected['context'], 'Unit result is from another attempt')
        for key in ('sourceInputsSHA256', 'testInputsSHA256'):
            require(report.get(key) == expected[key], 'Unit result inputs do not match')
    elif kind == 'release':
        verify_app_inputs(folder / 'Cadence.app', expected['sourceInputsSHA256'])
    else:
        raise ValueError('Unknown stage kind')
    return manifest


def seal(folder, kind, expected, seconds):
    manifest = {'version': 1, 'kind': kind, 'identity': expected, 'files': inventory(folder),
                'seconds': seconds, 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (folder / 'stage.json').write_text(json.dumps(manifest, indent=2) + '\n')
    validate(folder, kind, expected)


def archive(folder, destination):
    require(not destination.exists(), 'Refusing to reuse an existing stage archive')
    with tarfile.open(destination, 'w:gz', compresslevel=1) as output:
        for path in sorted(folder.rglob('*')):
            output.add(path, arcname=path.relative_to(folder).as_posix(), recursive=False)
    return file_hash(destination)


def unpack(archive_path, destination, expected_hash):
    require(re.fullmatch(r'[0-9a-f]{64}', expected_hash or ''), 'Missing archive digest from producer job')
    require(file_hash(archive_path) == expected_hash, 'Archive digest does not match producer output')
    require(not destination.exists(), 'Prepared-stage destination must be fresh')
    with tarfile.open(archive_path, 'r:gz') as source:
        members = source.getmembers()
        require(0 < len(members) <= 10000 and all(0 <= m.size <= 2_000_000_000 for m in members)
                and sum(m.size for m in members) <= 2_000_000_000,
                'Stage archive exceeds bounds')
        seen = set()
        for member in members:
            path = PurePosixPath(member.name)
            require(path.parts and not path.is_absolute() and '..' not in path.parts and
                    (member.isfile() or member.isdir()) and path.as_posix() not in seen,
                    'Unsafe or duplicate archive entry')
            seen.add(path.as_posix())
        destination.mkdir(parents=True)
        source.extractall(destination, filter='data')


def export_unit(report_path, destination, root=ROOT):
    expected = identity(root)
    report = json.loads(report_path.read_text())
    require(report.get('passed') is True and report.get('mode') == 'tests-only', 'Unit stage did not pass')
    require(report.get('verificationContext') == expected['context'], 'Unit stage is not from this run')
    for key in ('sourceInputsSHA256', 'testInputsSHA256'):
        require(report.get(key) == expected[key], 'Unit stage inputs changed')
    export = Path(report['unitCoverageExport'])
    products = export.parent.parent
    profile = export.with_name('default.profdata')
    started = datetime.datetime.fromisoformat(report['startedAt']).timestamp()
    require(export.stat().st_mtime >= started and profile.stat().st_mtime >= started,
            'Unit coverage export or profile is stale')
    tests = sorted(path for path in products.glob('*.xctest/Contents/MacOS/*')
                   if path.is_file() and os.access(path, os.X_OK))
    require(tests and (products / 'Cadence').is_file(), 'Missing matching instrumented objects')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        stage = Path(temp)
        for path in [products / 'Cadence', *tests, export, profile]:
            target = stage / 'products' / path.relative_to(products)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        shutil.copy2(report_path, stage / 'summary.json')
        shutil.copy2(report_path.with_name('tests.log'), stage / 'tests.log')
        seal(stage, 'unit', expected, report['seconds'])
        require(identity(root) == expected, 'Inputs changed while staging unit evidence')
        return archive(stage, destination)


def build_release(destination, scratch, root=ROOT):
    from verify import run, require_clean_swift
    expected = identity(root)
    started = time.monotonic()
    output = destination.parent
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as temp:
        stage = Path(temp)
        env = dict(os.environ, CADENCE_BUILD_DIR=str(scratch), CADENCE_APP_PATH=str(stage / 'Cadence.app'),
                   CADENCE_TIMINGS_PATH=str(output / 'release-timings.jsonl'))
        run([root / 'build.sh'], output / 'release-build.log', env, 900)
        require_clean_swift((output / 'release-build.log').read_text(), root)
        run(['codesign', '--verify', '--deep', '--strict', stage / 'Cadence.app'],
            output / 'release-signature.log', env, 30)
        require(identity(root) == expected, 'Inputs changed while building production')
        seal(stage, 'release', expected, round(time.monotonic() - started, 3))
        return archive(stage, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    unit = sub.add_parser('unit')
    unit.add_argument('--report', type=Path, required=True)
    unit.add_argument('--archive', type=Path, required=True)
    release = sub.add_parser('release')
    release.add_argument('--archive', type=Path, required=True)
    release.add_argument('--scratch', type=Path, required=True)
    extract = sub.add_parser('unpack')
    extract.add_argument('--archive', type=Path, required=True)
    extract.add_argument('--destination', type=Path, required=True)
    extract.add_argument('--expected', required=True)
    args = parser.parse_args()
    if args.action == 'unit':
        digest = export_unit(args.report.resolve(), args.archive.resolve())
    elif args.action == 'release':
        digest = build_release(args.archive.resolve(), args.scratch.resolve())
    else:
        unpack(args.archive, args.destination, args.expected)
        return
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write('sha256=' + digest + '\n')
    print(digest)


if __name__ == '__main__':
    main()
