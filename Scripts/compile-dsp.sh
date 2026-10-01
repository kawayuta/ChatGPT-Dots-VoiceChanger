# Shared by synthetic tests. Call after task_root/task_tools (or task_developer)
# and task_sdk have been set. No download or system configuration.
dvc_compile_dsp() {
    local dvc_folder="$1" dvc_mode="${2:-plain}"
    local dvc_toolchain="${task_tools:-$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin}"
    local -a dvc_flags
    dvc_flags=()
    if [[ "$dvc_mode" == undefined ]]; then dvc_flags=(-fsanitize=undefined -fno-sanitize-recover=all); fi
    mkdir -p "$dvc_folder"
    "$dvc_toolchain/clang" -std=c11 -Wall -Wextra -Werror -O2 -g -isysroot "$task_sdk" \
        -mmacosx-version-min=14.2 "${dvc_flags[@]}" -I "$task_root/Sources" \
        -c "$task_root/Sources/VoiceDSP.c" -o "$dvc_folder/VoiceDSP.o"
    "$dvc_toolchain/clang++" -std=c++17 -O2 -g -isysroot "$task_sdk" \
        -mmacosx-version-min=14.2 "${dvc_flags[@]}" -DSIGNALSMITH_USE_ACCELERATE=1 \
        -I "$task_root/Sources" -I "$task_root/Vendor/Signalsmith" \
        -c "$task_root/Sources/SpeechDSP.cpp" -o "$dvc_folder/SpeechDSP.o"
}
