#!/bin/zsh
set -eu
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_tools="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
task_arch=$(uname -m)
mkdir -p "$task_root/build/ModuleCache" "$task_root/TestResults"
"$task_tools/clang" -isysroot "$task_sdk" -mmacosx-version-min=14.2 -c "$task_root/Sources/ProcessSupport.c" -o "$task_root/build/ProcessSupport.o"
"$task_tools/swiftc" -sdk "$task_sdk" -target "$task_arch-apple-macos14.2" -module-cache-path "$task_root/build/ModuleCache" \
    -import-objc-header "$task_root/Sources/ProcessSupport.h" -parse-as-library \
    "$task_root/Sources/AudioInventory.swift" "$task_root/Tools/InspectionProbe.swift" "$task_root/build/ProcessSupport.o" \
    -o "$task_root/build/InspectionProbe"
task_temp=$(mktemp "$task_root/TestResults/inspection.XXXXXX")
trap 'rm -f "$task_temp"' EXIT
"$task_root/build/InspectionProbe" "$@" > "$task_temp"
mv "$task_temp" "$task_root/TestResults/verified-inspection.json"
cat "$task_root/TestResults/verified-inspection.json"
