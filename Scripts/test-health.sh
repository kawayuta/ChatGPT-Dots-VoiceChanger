#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
mkdir -p "$task_root/build/ModuleCache" "$task_root/TestResults"
"$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" -sdk "$task_sdk" \
    -module-cache-path "$task_root/build/ModuleCache" -parse-as-library \
    "$task_root/Sources/SessionHealth.swift" "$task_root/Tests/SessionHealthTests.swift" -o "$task_root/build/health-tests"
python3 "$task_root/Scripts/run-test.py" "$task_root/build/health-tests" "$task_root/TestResults/health.log"
