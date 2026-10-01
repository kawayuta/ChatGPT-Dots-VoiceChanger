#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_clang="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
mkdir -p "$task_root/build" "$task_root/TestResults"
task_mode="${1:-standard}"
case "$task_mode" in
    standard) task_modes=(plain undefined) ;;
    all) task_modes=(plain undefined address thread) ;;
    plain|undefined|address|thread) task_modes=("$task_mode") ;;
    *) print 'Usage: zsh Scripts/test.sh [standard|all|plain|undefined|address|thread]'; exit 2 ;;
esac
for task_sanitizer in "${task_modes[@]}"; do
    task_flags=()
    if [[ "$task_sanitizer" != plain ]]; then task_flags=("-fsanitize=$task_sanitizer" -fno-sanitize-recover=all); fi
    "$task_clang" -std=c11 -Wall -Wextra -Werror -g -O1 -isysroot "$task_sdk" \
        -mmacosx-version-min=14.2 "${task_flags[@]}" -I "$task_root/Sources" \
        "$task_root/Tests/RealtimeBridgeTests.c" "$task_root/Sources/RealtimeBridge.c" \
        -framework CoreAudio -framework AudioToolbox -lpthread \
        -o "$task_root/build/bridge-tests-$task_sanitizer"
    python3 "$task_root/Scripts/run-test.py" "$task_root/build/bridge-tests-$task_sanitizer" "$task_root/TestResults/bridge-$task_sanitizer.log"
done
