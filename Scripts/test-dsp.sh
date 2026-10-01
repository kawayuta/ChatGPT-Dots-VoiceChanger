#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_clang="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
mkdir -p "$task_root/build" "$task_root/TestResults"
source "$task_root/Scripts/compile-dsp.sh"
for task_sanitizer in plain undefined; do
    dvc_compile_dsp "$task_root/build/dsp-$task_sanitizer" "$task_sanitizer"
    task_flags=()
    if [[ "$task_sanitizer" != plain ]]; then task_flags=(-fsanitize=undefined -fno-sanitize-recover=all); fi
    "$task_clang" -std=c11 -Wall -Wextra -Werror -O2 -g -isysroot "$task_sdk" -mmacosx-version-min=14.2 \
        "${task_flags[@]}" -I "$task_root/Sources" "$task_root/Tests/VoiceDSPTests.c" "$task_root/build/dsp-$task_sanitizer/VoiceDSP.o" "$task_root/build/dsp-$task_sanitizer/SpeechDSP.o" \
        -lc++ -framework Accelerate -o "$task_root/build/voice-dsp-tests-$task_sanitizer"
    python3 "$task_root/Scripts/run-test.py" "$task_root/build/voice-dsp-tests-$task_sanitizer" "$task_root/TestResults/dsp-$task_sanitizer.log"
done
