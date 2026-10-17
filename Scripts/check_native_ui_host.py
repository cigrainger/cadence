#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Cadence contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check the graphical host before compiling Cadence's full native suite."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = root / '.verification/ui-host'
app = output / 'Cadence.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump({'CFBundleIdentifier': 'com.cadence.music', 'CFBundleExecutable': 'Cadence',
                  'CFBundleName': 'Cadence UI probe', 'CFBundlePackageType': 'APPL',
                  'NSPrincipalClass': 'NSApplication', 'LSMinimumSystemVersion': '14.0'}, file)
env = dict(os.environ)
env.pop('LLVM_PROFILE_FILE', None)
for source, destination in [('native_preview.swift', output / 'native-preview'),
                            ('native_ui_probe.swift', macos / 'Cadence')]:
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(root / 'Scripts' / source), '-o', str(destination)], env=env, check=True, timeout=60)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
report = output / 'gui-host.json'
result = subprocess.run([str(output / 'native-preview'), str(macos / 'Cadence'), '--snapshot', str(report)],
                        env=env, capture_output=True, text=True, timeout=55)
print(result.stderr, flush=True)
if result.returncode:
    sys.exit(result.returncode)
print('SwiftUI GUI host preflight passed.', flush=True)
