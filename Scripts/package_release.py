#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Package a clean, version-matched build and corresponding source. Does not publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

from signing import release_metadata
from build_inputs import source_digest, verify_app_inputs

ROOT = Path(__file__).resolve().parents[1]


def run(*command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download_archive(record, destination):
    if not record['url'].startswith('https://'):
        raise ValueError('Dependency sources must use HTTPS')
    # Download archives as opaque source assets; never execute or extract upstream scripts.
    request = urllib.request.Request(record['url'], headers={'User-Agent': 'Cadence-release-source/1'})
    with urllib.request.urlopen(request, timeout=120) as response, destination.open('wb') as target:
        if not response.geturl().startswith('https://'):
            raise ValueError('Refusing a non-HTTPS source redirect')
        length = 0
        while chunk := response.read(1024 * 1024):
            length += len(chunk)
            if length > 64 * 1024 * 1024:
                raise ValueError('Dependency source exceeds 64 MiB')
            target.write(chunk)
    if digest(destination) != record['sha256']:
        raise ValueError('Dependency source checksum mismatch: ' + destination.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-notarised', action='store_true', help='Refuse unsigned or unstapled public assets')
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    if run('git', 'status', '--porcelain', capture_output=True, text=True).stdout.strip():
        raise RuntimeError('Commit or remove untracked changes before packaging a public release')
    commit = run('git', 'rev-parse', 'HEAD', capture_output=True, text=True).stdout.strip()
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version): raise ValueError('Expected a numeric release version')
    binary_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(binary_info.get(k) != info[k] for k in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')):
        raise ValueError('App identity/version does not match the checked-out source')
    inputs_digest = source_digest()
    verify_app_inputs(app, inputs_digest)
    signing = release_metadata(app, require_notarised=args.require_notarised)
    arches = run('lipo', '-archs', str(app / 'Contents/MacOS/Cadence'), capture_output=True, text=True).stdout.split()
    if not arches or set(arches) - {'arm64', 'x86_64'}: raise ValueError('Unexpected Mach-O architecture')
    architecture = 'universal' if len(arches) == 2 else arches[0]
    # Reject an output containing old assets; never mix releases or delete an arbitrary directory.
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()): raise ValueError('Release output must be empty')
    run(sys.executable, 'Scripts/check_repository.py', '--sbom', str(output / 'cadence.cdx.json'))
    with tempfile.TemporaryDirectory(prefix='cadence-release-') as temporary:
        stage = Path(temporary) / f'Cadence-{version}-source'; stage.mkdir()
        # Keep the Git archive opaque, avoiding extraction of unchecked paths or symlinks.
        run('git', 'archive', '--format=tar.gz', '--prefix=cadence/', '-o', str(stage / 'cadence.tar.gz'), 'HEAD')
        sources = stage / 'dependency-sources'; sources.mkdir()
        manifest = json.loads((ROOT / 'Dependencies/components.json').read_text())
        for component in manifest['components']:
            if 'archive' in component:
                download_archive(component['archive'], sources / (component['id'] + '-source.tar.gz'))
        (stage / 'README.txt').write_text(
            f'Cadence {version}\nGit commit: {commit}\n\n'
            'Extract cadence.tar.gz, then follow README.md and Docs/RELEASING.md.\n'
            'Dependency source archives retain their original licenses and layouts.\n'
            'ZIPFoundation is fetched by the pinned SwiftPM package when building; its matching source is also here.\n'
            'The OSMD source archive is provided for inspecting/rebuilding the bundled notation renderer.\n'
            'Upstream does not supply a resolved transitive lockfile; see THIRD_PARTY.md.\n'
            'The sound bank in the application source is itself editable SF2 source.\n')
        with tarfile.open(output / f'Cadence-{version}-source.tar.gz', 'w:gz') as archive:
            archive.add(stage, arcname=stage.name)
    run('ditto', '-c', '-k', '--keepParent', '--norsrc', str(app), str(output / f'Cadence-{version}-macOS-{architecture}.zip'))
    shutil.copy2(ROOT / f'Docs/Releases/{version}.md', output / 'RELEASE-NOTES.md')
    (output / 'BUILD.json').write_text(json.dumps({'version': version, 'commit': commit, 'architectures': arches,
        'sourceInputsSHA256': inputs_digest, **signing}, indent=2) + '\n')
    assets = sorted(p for p in output.iterdir() if p.is_file())
    (output / 'SHA256SUMS.txt').write_text(''.join(f'{digest(path)}  {path.name}\n' for path in assets))
    print(f'Packaged {version} ({architecture}) from {commit}')


if __name__ == '__main__':
    main()
