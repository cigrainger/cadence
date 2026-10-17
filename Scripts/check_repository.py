#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Offline public-release hygiene, pinned-asset/license checks and CycloneDX inventory."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.build', '.swiftpm', '.verification', 'dist', 'node_modules', '__pycache__'}
ORIGINAL_INPUTS = {f'Resources/ImportExamples/{name}' for name in
                   ('chapter.pdf', 'compound.pdf', 'guitar.pdf', 'piano.pdf', 'pathway.epub')}
CODE_LICENSES = {'MIT', 'BSD-3-Clause', 'ISC', 'Apache-2.0', 'Zlib', 'MIT AND Zlib'}


def public_files(root):
    """Inspect tracked files when available; ignore generated directories before initial Git setup."""
    if (root / '.git').exists():
        result = subprocess.run(['git', 'ls-files', '-z'], cwd=root, check=True, capture_output=True)
        return [root / name for name in result.stdout.decode().split('\0') if name]
    return [p for p in root.rglob('*') if p.is_file() and not any(x in IGNORED for x in p.relative_to(root).parts)]


def check_path(path):
    parts = Path(path).parts
    lower = path.lower()
    if any(x in IGNORED or x.lower() in {'research', 'private', 'local-data', 'recordings'} for x in parts):
        return 'generated or private directory'
    if Path(path).suffix.lower() in {'.pdf', '.epub'} and path not in ORIGINAL_INPUTS:
        return 'document input outside the named original fixtures'
    if any(x.startswith('.env') and x != '.env.example' for x in parts):
        return 'environment file'
    if Path(path).suffix.lower() in {'.pem', '.p12', '.pfx', '.key', '.log', '.dmg', '.zip', '.mp3', '.wav'}:
        return 'credential, recording or generated artifact'
    if any(x.endswith(('.app', '.dSYM', '.xcarchive')) for x in parts):
        return 'build output'
    return None


def validate_components(manifest, root):
    errors = []
    ids = [c['id'] for c in manifest['components']]
    if len(ids) != len(set(ids)):
        errors.append('Duplicate dependency identifiers')
    for component in manifest['components']:
        license_id = component['license']
        is_bank = component['id'] == 'timgm6mb' and component['kind'] == 'data'
        if license_id not in CODE_LICENSES and not (is_bank and license_id == 'GPL-2.0-only'):
            errors.append(f"Unreviewed license: {component['id']} / {license_id}")
        if not (root / component['notice']).is_file():
            errors.append(f"Missing notice for {component['id']}")
        if not component.get('version') and not component.get('versionEvidence'):
            errors.append(f"Unexplained version gap: {component['id']}")
        if component.get('bundledIn') and component['bundledIn'] not in ids:
            errors.append(f"Unknown bundle owner: {component['id']}")
    for asset in manifest['assets']:
        path = root / asset['path']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
            errors.append(f"Vendored file changed without inventory review: {asset['path']}")
    return errors


def make_bom(manifest, version):
    components = []
    for c in manifest['components']:
        item = {'type': c['kind'], 'bom-ref': c['id'], 'name': c['name'],
                'licenses': [{'expression': c['license']}] if ' AND ' in c['license'] else [{'license': {'id': c['license']}}],
                'externalReferences': [{'type': 'distribution', 'url': c['source']}]}
        for key in ('version', 'purl'):
            if c.get(key): item[key] = c[key]
        properties = []
        for key in ('revision', 'bundledIn', 'versionEvidence'):
            if key in c: properties.append({'name': 'cadence:' + key, 'value': c[key]})
        if properties: item['properties'] = properties
        if 'archive' in c:
            item['externalReferences'].append({'type': 'distribution', 'url': c['archive']['url'],
                'hashes': [{'alg': 'SHA-256', 'content': c['archive']['sha256']}]})
        components.append(item)
    for asset in manifest['assets']:
        components.append({'type': 'file', 'bom-ref': 'file:' + asset['path'], 'name': asset['path'],
                           'hashes': [{'alg': 'SHA-256', 'content': asset['sha256']}]})
    return {'bomFormat': 'CycloneDX', 'specVersion': '1.5', 'version': 1,
            'metadata': {'component': {'type': 'application', 'bom-ref': 'cadence', 'name': 'Cadence',
                                     'version': version, 'licenses': [{'license': {'id': 'AGPL-3.0-or-later'}}]},
                         'properties': [{'name': 'cadence:scope', 'value': manifest['scope']},
                                        {'name': 'cadence:limitations', 'value': manifest['limitations']}]},
            'components': components,
            'dependencies': [{'ref': 'cadence', 'dependsOn': ['zipfoundation', 'osmd', 'timgm6mb']}],
            'compositions': [{'aggregate': 'incomplete', 'assemblies': ['cadence']}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sbom', type=Path, default=ROOT / '.verification/cadence.cdx.json')
    parser.add_argument('--skip-site', action='store_true')
    args = parser.parse_args()
    errors = []
    for path in public_files(ROOT):
        relative = path.relative_to(ROOT).as_posix()
        reason = check_path(relative)
        if reason: errors.append(f'{relative}: {reason}')
        if path.is_symlink(): errors.append(f'Symlink needs explicit review: {relative}')
        if path.suffix == '.swift' and relative.startswith(('Sources/', 'Tests/')):
            if 'SPDX-License-Identifier: AGPL-3.0-or-later' not in path.read_text()[:200]:
                errors.append(f'Missing source license: {relative}')
    manifest = json.loads((ROOT / 'Dependencies/components.json').read_text())
    errors.extend(validate_components(manifest, ROOT))
    resolved = json.loads((ROOT / 'Package.resolved').read_text())
    expected = next(c for c in manifest['components'] if c['id'] == 'zipfoundation')
    pins = resolved['pins']
    if len(pins) != 1 or pins[0]['identity'] != 'zipfoundation' or pins[0]['state'] != {
        'revision': expected['revision'], 'version': expected['version']}:
        errors.append('SwiftPM dependencies differ from the reviewed inventory')
    for name in ('LICENSE', 'LICENSING.md', 'THIRD_PARTY.md', 'SECURITY.md', 'README.md'):
        if not (ROOT / name).is_file(): errors.append(f'Missing public policy: {name}')
    if errors:
        for error in errors: print(error, file=sys.stderr)
        return 1
    version = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    args.sbom.parent.mkdir(parents=True, exist_ok=True)
    args.sbom.write_text(json.dumps(make_bom(manifest, version), indent=2) + '\n')
    if not args.skip_site:
        subprocess.run([sys.executable, str(ROOT / 'Scripts/build_site.py')], check=True)
    unknown = sum(not c.get('version') for c in manifest['components'])
    print(f'Repository policy passed; {len(manifest["components"])} components, '
          f'{len(manifest["assets"])} pinned assets. {unknown} upstream bundled versions remain unknown.')
    print(f'SBOM: {args.sbom}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
