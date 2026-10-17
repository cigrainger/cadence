#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin_arm64; expected=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
  Linux-x86_64) platform=linux_x64; expected=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
  *) echo 'Use a verified Gitleaks 8.30.1 installation on this platform.' >&2; exit 1 ;;
esac
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_${platform}.tar.gz" -o "$task_tmp/tool.tar.gz"
printf '%s  %s\n' "$expected" "$task_tmp/tool.tar.gz" | shasum -a 256 -c -
tar -xzf "$task_tmp/tool.tar.gz" -C "$task_tmp" gitleaks
# Scan only Git-managed public content; private ignored working data must not enter CI reports.
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  "$task_tmp/gitleaks" git --redact --no-banner --log-opts=--all .
fi
git archive --format=tar HEAD > "$task_tmp/source.tar"
mkdir "$task_tmp/source"
tar -xf "$task_tmp/source.tar" -C "$task_tmp/source"
"$task_tmp/gitleaks" dir --redact --no-banner "$task_tmp/source"
