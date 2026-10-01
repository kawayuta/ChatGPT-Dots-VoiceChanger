#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_tools="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
task_arch=$(uname -m)
mkdir -p "$task_root/build/soak" "$task_root/TestResults" "$task_root/build/ModuleCache"
source "$task_root/Scripts/compile-dsp.sh"
dvc_compile_dsp "$task_root/build/soak" plain
for task_source in ProcessSupport.c RealtimeBridge.c; do
    "$task_tools/clang" -O2 -isysroot "$task_sdk" -mmacosx-version-min=14.2 -I "$task_root/Sources" -c "$task_root/Sources/$task_source" -o "$task_root/build/soak/$task_source.o"
done
"$task_tools/clang" -O2 -isysroot "$task_sdk" -mmacosx-version-min=14.2 -I "$task_root/Sources" -c "$task_root/Tools/SoakFeed.c" -o "$task_root/build/soak/SoakFeed.o"
"$task_tools/clang" -fobjc-arc -O2 -isysroot "$task_sdk" -mmacosx-version-min=14.2 -I "$task_root/Sources" -c "$task_root/Sources/EffectsAudioUnit.m" -o "$task_root/build/soak/EffectsAudioUnit.o"
"$task_tools/swiftc" -O -sdk "$task_sdk" -target "$task_arch-apple-macos14.2" -module-cache-path "$task_root/build/ModuleCache" \
    -import-objc-header "$task_root/Tools/SoakBridgingHeader.h" -parse-as-library \
    "$task_root/Sources/AudioInventory.swift" "$task_root/Sources/EffectSettings.swift" "$task_root/Tools/SoakRunner.swift" \
    "$task_root/build/soak/ProcessSupport.c.o" "$task_root/build/soak/VoiceDSP.o" "$task_root/build/soak/SpeechDSP.o" "$task_root/build/soak/RealtimeBridge.c.o" "$task_root/build/soak/SoakFeed.o" "$task_root/build/soak/EffectsAudioUnit.o" \
    -lc++ -framework Accelerate -framework AudioToolbox -framework AVFAudio -lpthread -o "$task_root/build/soak-runner"
task_soak_log="$task_root/TestResults/soak-$(date -u +%Y%m%dT%H%M%SZ).log"
"$task_root/build/soak-runner" "${1:-3600}" | tee "$task_soak_log"
print "Result: $task_soak_log"
