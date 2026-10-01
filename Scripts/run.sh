#!/bin/zsh
set -eu
task_root="${0:A:h:h}"
task_configuration="${1:-Debug}"
case "$task_configuration" in Debug|Release) ;; *) print 'Usage: zsh Scripts/run.sh [Debug|Release]'; exit 2 ;; esac
task_derived="${DOTS_DERIVED_DATA:-$task_root/build/DerivedData}"
task_app="$task_derived/Build/Products/$task_configuration/DotsVoiceChanger.app"
[[ -d "$task_app" ]] || { print 'Run zsh Scripts/build.sh first.'; exit 1; }
open "$task_app"
