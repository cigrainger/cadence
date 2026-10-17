#!/bin/zsh
set -euo pipefail

task_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
task_build="${CADENCE_BUILD_DIR:-$task_dir/.build}"
export CLANG_MODULE_CACHE_PATH="$task_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build/module-cache"
cd "$task_dir"
swift build --configuration release --disable-sandbox --scratch-path "$task_build"
task_bin="$(swift build --configuration release --show-bin-path --scratch-path "$task_build")"
task_destination="${CADENCE_APP_PATH:-$task_dir/dist/Cadence.app}"
mkdir -p "$(dirname "$task_destination")"
task_app="$(mktemp -d "$(dirname "$task_destination")/.cadence-build.XXXXXX")/Cadence.app"
trap 'rm -rf "${task_app:h}"' EXIT
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/Cadence" "$task_app/Contents/MacOS/Cadence"
cp "$task_dir/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_dir/Resources/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
cp -R "$task_dir/Resources/Brand" "$task_app/Contents/Resources/"
cp -R "$task_dir/LICENSES" "$task_app/Contents/Resources/"
cp -R "$task_dir/Resources/SoundBanks" "$task_app/Contents/Resources/"
cp -R "$task_dir/Resources/ScoreViewer" "$task_app/Contents/Resources/"
cp -R "$task_dir/Resources/EditorViewer" "$task_app/Contents/Resources/"
cp -R "$task_dir/Resources/ImportExamples" "$task_app/Contents/Resources/"
cp "$task_dir/LICENSE" "$task_app/Contents/Resources/Cadence-LICENSE.txt"
cp "$task_dir/Resources/Third-party notices.txt" "$task_app/Contents/Resources/"
for task_resource in "$task_bin"/*.bundle(N); do
    cp -R "$task_resource" "$task_app/Contents/Resources/"
done
codesign --force --sign - --options runtime --entitlements "$task_dir/Resources/Entitlements.plist" "$task_app"
# Only replace a recognised Cadence bundle; never remove an arbitrary output directory.
if [[ -e "$task_destination" ]]; then
    [[ -f "$task_destination/Contents/Info.plist" ]] || { print -u2 "Output is not an app bundle"; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_destination/Contents/Info.plist")" == "com.cadence.music" ]] || { print -u2 "Output is not Cadence"; exit 1; }
    rm -rf "$task_destination"
fi
mv "$task_app" "$task_destination"
print "Built: $task_destination"
