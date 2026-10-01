#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_derived="${DOTS_DERIVED_DATA:-$task_root/build/DerivedData}"
task_source="$task_derived/Build/Products/Release/DotsVoiceChanger.app"
task_preview="$task_root/build/UIPreview/Dots Voice Changer Preview.app"
[[ -d "$task_source" ]] || { print 'Build Release first. DOTS_DERIVED_DATA must point to the same build folder.'; exit 1; }
mkdir -p "${task_preview:h}"
/usr/bin/ditto "$task_source" "$task_preview"
task_plist="$task_preview/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string io.github.kawayuta.DotsVoiceChanger.UIShowcase "$task_plist"
/usr/bin/plutil -replace CFBundleDisplayName -string 'Dots Voice Changer Preview' "$task_plist"
/usr/bin/plutil -replace DVCUIShowcase -bool true "$task_plist"
/usr/bin/codesign --force --sign - "$task_preview"
/usr/bin/codesign --verify --deep --strict "$task_preview"
print "Prepared: $task_preview"
print 'This preview skips preferences, process inspection, automatic timers, and audio capture. Open it manually for documentation screenshots.'
