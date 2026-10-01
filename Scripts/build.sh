#!/bin/zsh
set -eu
task_root="${0:A:h:h}"
task_configuration="${1:-Debug}"
case "$task_configuration" in Debug|Release) ;; *) print 'Usage: zsh Scripts/build.sh [Debug|Release]'; exit 2 ;; esac
task_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_derived="${DOTS_DERIVED_DATA:-$task_root/build/DerivedData}"
[[ -d "$task_sdk" && -x "$task_developer/usr/bin/xcodebuild" ]] || { print 'Full Xcode with a macOS SDK is required. Set DEVELOPER_DIR to your Xcode.app/Contents/Developer path.'; exit 1; }
mkdir -p "$task_root/build/ModuleCache" "$task_root/TestResults"
DEVELOPER_DIR="$task_developer" "$task_developer/usr/bin/xcodebuild" \
    -project "$task_root/DotsVoiceChanger.xcodeproj" -scheme DotsVoiceChanger \
    -configuration "$task_configuration" -destination 'generic/platform=macOS' \
    -derivedDataPath "$task_derived" \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    SDKROOT="$task_sdk" CLANG_MODULE_CACHE_PATH="$task_root/build/ModuleCache" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build \
    > "$task_root/TestResults/build.log" 2>&1 || { tail -50 "$task_root/TestResults/build.log"; exit 1; }
tail -8 "$task_root/TestResults/build.log"
print "App: $task_derived/Build/Products/$task_configuration/DotsVoiceChanger.app"
