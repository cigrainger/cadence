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
from native_arguments import native_arguments

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
# Include a presence flag before the output option: leaving it unpaired can
# turn the output path into an OS open request and suppress the initial scene.
result = subprocess.run([str(macos / 'Cadence'), *native_arguments(['--gui-probe', '--snapshot', output / 'gui-host.json'])],
                        env=env, capture_output=True, text=True, timeout=15)
print('gui-host:\n' + result.stderr, flush=True)
if result.returncode:
    sys.exit(result.returncode)
print('SwiftUI screen-fitting preflight passed.', flush=True)
