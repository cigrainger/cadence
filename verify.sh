#!/bin/zsh
set -euo pipefail
task_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$task_dir/Scripts/verify.py" "$@"
