# Build, signing and audio permission

## Toolchain

The tested build uses full Xcode 26.2, Swift 6.2.3 and macOS SDK 26.2 on Apple Silicon. Source uses SwiftUI, AppKit, Core Audio, AVFAudio/AudioToolbox, Security, libproc and Accelerate plus bundled MIT-licensed Signalsmith headers. No package fetch, system driver, installed audio plug-in, paid voice API or third-party package manager is needed.

Build deployment is macOS 14.2 and both arm64/x86_64. Runtime validation on Intel/older macOS is pending. New SDK declarations, such as the macOS 26 process-restoration property, are runtime-guarded; the current source still requires an SDK that declares them. A standalone Command Line Tools setup has not been validated as a replacement for full Xcode.

```sh
zsh Scripts/build.sh Release
zsh Scripts/run.sh Release
```

For a different installed Xcode or output directory, without changing `xcode-select`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DOTS_DERIVED_DATA="$PWD/build/MyDerivedData"
zsh Scripts/build.sh Release
zsh Scripts/run.sh Release
```

Open `DotsVoiceChanger.xcodeproj` with the shared DotsVoiceChanger scheme for Xcode development. The project has no Swift package dependencies. Python 3 is used by test timeouts, result analysis and security review; building and running the app do not require a Python package installation. The scripts do not update macOS, SDKs or Xcode.

## Local signature and distribution

Build scripts use an ad-hoc signature. This is a locally built development app, with no validated downloadable release, Developer ID signature or notarization. No signing keys or credentials are included. The app has no microphone/audio-input entitlement, and no invented capture entitlement is used. `NSAudioCaptureUsageDescription` supplies the permission purpose.

For public binaries, the owner must choose a signing identity, enable the supported distribution configuration, archive/sign with Developer ID, submit using Apple's normal notarization workflow, staple and verify the result on a separate Mac. Do not assume the ad-hoc build's runtime/signing flags satisfy that process. Credentials belong in Keychain or a protected distribution environment, never this repository. No enrollment, signing upload or fee was initiated here.

Apple lists Developer Program membership at **US$99 per year**, with local prices/taxes and possible eligibility exceptions described by Apple. Local source building does not purchase membership. See [Apple's program](https://developer.apple.com/programs/) and [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Do not bypass Gatekeeper, SIP or TCC to distribute or run a build.

## Permission and first route check

The app explains that it captures selected, verified ChatGPT output to adjust pitch/tone and play it locally. It requests no mic input. Audio and conversation text are not saved or transmitted. No API key is needed.

1. Open the official desktop app and start a Voice conversation yourself.
2. Keep automatic application off for the first route check. Choose a wired/USB output in Dots Voice Changer.
3. Confirm **My desktop voice call is running** and choose **Check route**.
4. Read and approve the normal macOS audio-capture prompt yourself if shown. The developer/agent does not click approval or edit the permission database.
5. Confirm single playback, then Stop and verify the original. Only then test effects with a small pitch shift.

The category name for capture permission can vary by macOS version. Use System Settings → Privacy & Security and the screen/system-audio capture category displayed by your OS. The exact category wording and revoke/regrant flow are not independently verified on every supported OS. A broader permission category does not broaden this app's verified process target. Rebuilt ad-hoc identities can cause macOS to ask again.

If permission is denied, leave processing stopped, review the error and enable permission yourself in normal Settings before explicitly retrying. If a chosen output disappears, reconnect it or choose another explicitly; do not assume a route is still active. Errors stop capture and disarm automatic mode.

## Reproducible checks

```sh
zsh Scripts/test.sh standard
zsh Scripts/test-dsp.sh
zsh Scripts/test-realtime-dsp.sh
zsh Scripts/test-presets.sh
zsh Scripts/test-health.sh
zsh Scripts/test-offline.sh
zsh Scripts/soak.sh 3600
python3 Scripts/security-check.py
```

Run these from the repository in a normal Terminal with Xcode available. The offline/soak engine requires normal access to the macOS Audio Unit registry. Restrictive agent execution sandboxes can deny this registry; changing system security settings is not the remedy. Standard/UBSan checks and ASan/TSan runtime limitations are separated in [results](TEST_RESULTS.md).

`zsh Scripts/inspect.sh` reads the installed app, signed processes and connected audio devices without capturing audio. Its output is private and Git-ignored. Test fixtures synthesize their audio; no actual call recording is used. Do not upload raw TestResults or build logs.

## Documentation preview

```sh
zsh Scripts/build.sh Release
zsh Scripts/prepare-ui-preview.sh
```

Open the prepared app in `build/UIPreview/` manually. It has a distinct preview bundle ID and skips preference loading, process inspection, activity timers and capture. Start/Save are disabled. Documentation screenshots show generic USB device labels and the stopped state; they are not live-call evidence. Close/quit the preview afterward; it never changes the user's saved sounds.

## Stop and uninstall

Use **Stop & hear original**, the emergency button or **Command + .** to release capture and disarm automatic mode. Menu-bar Quit or Command-Q tears down before exiting. Closing the normal controls window keeps the app resident.

If the app becomes unresponsive, force-quit and check original ChatGPT playback. Forced-exit recovery is still a pending acceptance case. Restart the target app if necessary after coordinating with any other work. Never delete unrelated audio devices or rewrite system routing to repair this app.

Quit, then move the built `.app` to Trash. Optionally move these local settings to Trash:

- `~/Library/Application Support/io.github.kawayuta.DotsVoiceChanger/`
- `~/Library/Preferences/io.github.kawayuta.DotsVoiceChanger.plist`

Remove the app's capture permission in normal System Settings if desired. There are no installed drivers, plug-ins, background services or login items. Your source checkout can be kept for rebuilding or moved to Trash separately.
