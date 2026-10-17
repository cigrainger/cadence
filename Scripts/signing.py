#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Inspect and sign Cadence bundles. Secrets stay in the macOS Keychain."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True)


def signature_metadata(description, entitlements):
    """Fail closed on unfamiliar identities; a development cert isn't a release cert."""
    fields = dict(line.split('=', 1) for line in description.splitlines() if '=' in line)
    flags = re.search(r'\bflags=0x([0-9a-fA-F]+)', description)
    runtime = bool(flags and int(flags[1], 16) & 0x10000)
    authorities = [line.removeprefix('Authority=') for line in description.splitlines()
                   if line.startswith('Authority=')]
    if fields.get('Identifier') != 'com.cadence.music':
        raise ValueError('Only a Cadence application bundle can be released')
    if not runtime or entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('Release builds require hardened runtime and no debugger entitlement')
    if fields.get('Signature') == 'adhoc':
        return {'signing': 'ad-hoc', 'notarised': False}
    if not authorities or not authorities[0].startswith('Developer ID Application: '):
        raise ValueError('Use a Developer ID Application certificate, not Apple Development or Mac Distribution')
    if not fields.get('Timestamp') or not re.fullmatch(r'[A-Z0-9]{10}', fields.get('TeamIdentifier', '')):
        raise ValueError('Developer ID signing requires a secure timestamp and Team ID')
    return {'signing': 'Developer ID Application', 'teamID': fields['TeamIdentifier'], 'notarised': False}


def inspect(app):
    run('codesign', '--verify', '--deep', '--strict', str(app))
    details = run('codesign', '--display', '--verbose=4', str(app))
    entitlements = run('codesign', '--display', '--entitlements', ':-', str(app)).stdout
    return signature_metadata((details.stdout + details.stderr).decode(),
                              plistlib.loads(entitlements) if entitlements.strip() else {})


def release_metadata(app, require_notarised=False):
    metadata = inspect(app)
    ticket = run('xcrun', 'stapler', 'validate', str(app), check=False)
    if ticket.returncode == 0:
        if metadata['signing'] != 'Developer ID Application':
            raise ValueError('A ticket cannot establish Developer ID signing')
        # A stapled ticket alone is insufficient if Gatekeeper rejects the bundle.
        run('spctl', '--assess', '--type', 'execute', str(app))
        metadata['notarised'] = True
    if require_notarised and not metadata['notarised']:
        raise ValueError('A signed, stapled and Gatekeeper-accepted app is required')
    return metadata


def sign(app, identity):
    if identity != '-' and not identity.startswith('Developer ID Application: '):
        raise ValueError('Supply the full Developer ID Application identity, or - for local ad-hoc builds')
    args = ['codesign', '--force', '--sign', identity, '--options', 'runtime',
            '--entitlements', str(ROOT / 'Resources/Entitlements.plist')]
    if identity != '-':
        args.append('--timestamp')
    run(*args, str(app))
    metadata = inspect(app)
    if identity != '-' and metadata['signing'] != 'Developer ID Application':
        raise ValueError('Requested Developer ID signing did not succeed')
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    print(sign(args.app.resolve(), args.identity)['signing'])


if __name__ == '__main__':
    main()
