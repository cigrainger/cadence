#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Submit a Developer ID build, or resume a submission, then staple and verify it."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

from signing import inspect, release_metadata, run


def accepted(response):
    if response.get('status') != 'Accepted':
        raise ValueError('Apple has not accepted this submission: ' + str(response.get('status', 'unknown')))


def notarise(app, profile, submission=None):
    if inspect(app)['signing'] != 'Developer ID Application':
        raise ValueError('Build with CADENCE_SIGNING_IDENTITY before requesting notarisation')
    if not profile.strip():
        raise ValueError('A Keychain profile is required')
    with tempfile.TemporaryDirectory(prefix='cadence-notary-') as folder:
        if submission is None:
            archive = Path(folder) / 'Cadence.zip'
            run('ditto', '-c', '-k', '--keepParent', '--norsrc', str(app), str(archive))
            response = json.loads(run('xcrun', 'notarytool', 'submit', str(archive),
                '--keychain-profile', profile, '--output-format', 'json').stdout)
            submission = str(uuid.UUID(response['id']))
        else:
            submission = str(uuid.UUID(submission))
        # Print the ID before waiting. A timeout never triggers a duplicate submission.
        print(f'Submission: {submission}\nResume with --submission {submission} if interrupted.', flush=True)
        result = run('xcrun', 'notarytool', 'wait', submission, '--keychain-profile', profile,
                     '--timeout', '20m', '--output-format', 'json', check=False)
        if result.returncode:
            raise RuntimeError(f'Notarisation has not completed. Resume submission {submission}; '
                               'use notarytool info/log with your Keychain profile for details.')
        accepted(json.loads(result.stdout))
    # Stapler fetches the ticket for THIS code signature, even when resuming an ID.
    run('xcrun', 'stapler', 'staple', str(app))
    metadata = release_metadata(app, require_notarised=True)
    print('Accepted, stapled and Gatekeeper-verified. Package this app now; do not rebuild it.')
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--profile', default='cadence-notary', help='Existing Keychain profile name')
    parser.add_argument('--submission', help='Resume an existing submission without uploading again')
    args = parser.parse_args()
    try:
        notarise(args.app.resolve(), args.profile, args.submission)
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
