#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_tools="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
mkdir -p "$task_root/TestResults"
source "$task_root/Scripts/compile-dsp.sh"
for task_mode in plain undefined; do
    dvc_compile_dsp "$task_root/build/realtime-$task_mode" "$task_mode"
    task_flags=()
    if [[ "$task_mode" == undefined ]]; then task_flags=(-fsanitize=undefined -fno-sanitize-recover=all); fi
    "$task_tools/clang++" -std=c++17 -O2 -g -isysroot "$task_sdk" -mmacosx-version-min=14.2 \
        "${task_flags[@]}" -I "$task_root/Sources" "$task_root/Tests/RealtimeDSPTests.cpp" \
        "$task_root/build/realtime-$task_mode/VoiceDSP.o" "$task_root/build/realtime-$task_mode/SpeechDSP.o" \
        -framework Accelerate -o "$task_root/build/realtime-dsp-tests-$task_mode"
    python3 "$task_root/Scripts/run-test.py" "$task_root/build/realtime-dsp-tests-$task_mode" "$task_root/TestResults/realtime-dsp-$task_mode.log"
done
