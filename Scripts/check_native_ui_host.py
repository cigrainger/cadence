#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Cadence contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check SwiftUI window geometry before compiling Cadence's full native suite."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parents[1]
output = root / '.verification/ui-host'
app = output / 'Cadence.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump({'CFBundleIdentifier': 'com.cadence.verification.gui-host.' + uuid.uuid4().hex, 'CFBundleExecutable': 'Cadence',
                  'CFBundleName': 'Cadence UI probe', 'CFBundlePackageType': 'APPL',
                  'NSPrincipalClass': 'NSApplication', 'LSMinimumSystemVersion': '14.0'}, file)
env = dict(os.environ)
env.pop('LLVM_PROFILE_FILE', None)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                str(root / 'Scripts/native_ui_probe.swift'),
                str(root / 'Sources/Cadence/App/WorkspaceWindowLayout.swift'),
                '-o', str(macos / 'Cadence')], env=env, check=True, timeout=60)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
# The control records the old fixed geometry; it may succeed on a large display.
# Only the actual screen-fitting policy is required to pass on every GUI host.
for name, flags in [('legacy-geometry', ['--legacy-minimum']),
                    ('workspace-without-inspector', ['--workspace-minimum']),
                    ('workspace-with-inspector', ['--workspace-minimum', '--inspector']),
                    ('gui-host', [])]:
    result = subprocess.run([str(macos / 'Cadence'), *flags, '--snapshot', str(output / (name + '.json'))],
                            env=env, capture_output=True, text=True, timeout=15)
    print(name + ':\n' + result.stderr, flush=True)
    if name == 'gui-host' and result.returncode:
        sys.exit(result.returncode)
print('SwiftUI screen-fitting preflight passed.', flush=True)
