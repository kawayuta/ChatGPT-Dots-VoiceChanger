# Primary sources and implementation decisions

Reviewed during development on 2026-10-01/02. Product eligibility, Apple API behavior, library behavior and project acceptance targets are separate claims. Links may change; the installed SDK and pinned source establish the build's actual declarations and code.

## Desktop Voice eligibility

- [OpenAI: ChatGPT Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice) distinguishes Voice in Chat and Voice in Desktop. Availability can depend on app/version, account/plan and workspace. An older retirement notice alone does not establish current desktop behavior.
- [OpenAI: downloading the macOS app](https://help.openai.com/en/articles/9275200-downloading-the-chatgpt-macos-app) describes the current desktop product and installation requirements.

This project separately reads the installed bundle, signature, root executable and helper ancestry. The user's actual live call is evidence on that installation, not a guarantee for every ChatGPT version. There is no general-browser fallback.

## Apple public APIs

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription).
- [CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior).
- [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription).
- [AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch), evaluated as the initial candidate; no longer the current pitch path.

Some developer web pages require JavaScript and were not fully text-readable in the research tool. Installed **SDK 26.2** headers were read and the actual APIs compiled for both architectures. Relevant headers are relative to `SDKROOT/System/Library/Frameworks/CoreAudio.framework/Headers/`:

| Declaration | Verified implication |
| --- | --- |
| `AudioHardwareTapping.h`: Create/DestroyProcessTap | macOS 14.2 API availability establishes the deployment minimum. |
| `CATapDescription.h`: process inclusion/exclusion, stereo mixdown | `isExclusive = false` includes the explicitly verified object set. An empty or unknown target set is rejected. |
| Tap mute behavior declaration | `mutedWhenTapped` suppresses original output while the tap is being read; it does not establish processed playback health. |
| New `bundleIDs` / `processRestoreEnabled` declarations | macOS 26.0. Bundle-ID restoration is not used as capture authority; automatic process restoration is explicitly disabled when that property is available. |
| `AudioHardwareBase.h` | Process object/PID/bundle/output-state and tap format properties are read independently. PID is not an AudioObjectID. |

See [API availability](ARCHITECTURE.md). No private API, injection, virtual driver, microphone subdevice, root operation or default-device rewrite is used.

## Bundled DSP and provenance

- [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch): pitch/time processing and approximate independent formant compensation. Its primary source describes limits of formant correction and latency; the app uses equal input/output sizes to preserve rate.
- [Pinned Stretch source](https://github.com/Signalsmith-Audio/signalsmith-stretch/tree/a670068d9aeb64913331d5cc29337b19a457a7df): **1.3.2**, MIT.
- [Pinned Signalsmith Linear source](https://github.com/Signalsmith-Audio/linear/tree/de55e6a50ffcf6f8f43f649692d94691c7025151): **0.6.4**, MIT, with Accelerate support.
- [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/): primary biquad equations used for the separate tonal EQ.

The vendor directory contains only required unmodified headers/backends and license notices. [The manifest](../Vendor/Signalsmith/manifest.json) records upstream commits and SHA-256 hashes. The app bundles both MIT notices. The coarse original-period estimate, control smoothing, bounded spectral-energy normalization, EQ, compressor, bridge and supervision are project code rather than claims about the upstream implementation.

Other researched candidates were [Rubber Band](https://breakfastquay.com/rubberband/) ([integration and licensing](https://breakfastquay.com/rubberband/integration.html)) and [SoundTouch licensing](https://soundtouch.surina.net/license.html). They are not dependencies. The user approved Signalsmith before its integration; no dependency is installed into system folders.

## Signing and acceptance

[Apple Developer Program](https://developer.apple.com/programs/) and [macOS notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) cover future public binary distribution. Current builds are ad-hoc development builds; source publication is separate from a signed/notarized binary release.

The 1% pitch/duration error, ≤150 ms wired added-latency goal, >200 ms review threshold, 20 hardware cycles and 60-minute soak are project acceptance criteria supplied by the owner. They are not Apple/OpenAI/library performance promises. [Test results](TEST_RESULTS.md) state what was actually measured and what remains unverified.
