# Test results

Status as of **2026-10-02 JST**: development build **0.1.1 (2)**, with Signalsmith DSP. The user reported natural sound in a real ChatGPT call. Full hardware acceptance is pending; this document does not classify the app as a completed or universally compatible release.

## Observed environment

| Item | Observed value |
| --- | --- |
| Host | Mac Studio, M3 Ultra, 28 CPU cores, 96 GB memory, arm64 |
| macOS | 26.5.1, build 25F80 |
| Toolchain | Xcode 26.2 (17C52), Swift 6.2.3, macOS SDK 26.2 |
| Desktop app | ChatGPT 26.928.31416, build 12553, installed official signature validated |
| Installed bundle identity | `com.openai.codex`, OpenAI signing team `2DC432GLL2` |
| Live output used in listening reports | AirPods / Bluetooth headphones |
| Observed live formats | Capture 48 kHz stereo; Bluetooth playback changed from 48 kHz stereo to 24 kHz mono in Voice |
| Project deployment / build | macOS 14.2 minimum; universal arm64 + x86_64 compilation passed |

Process IDs, local device names/UIDs, user presets, and private inspection files are intentionally omitted. The actual Voice screen was not available to automated UI inspection; voice use and audible results rely on the user's live reports, alongside verified process metadata and this app's observed Processing state. Intel and older-macOS runtime tests remain pending.

## Live evidence

| Check | Result / scope |
| --- | --- |
| Process identity | Installed and running signatures, canonical executable, helper ancestry, and Core Audio process-object mapping verified on the host. |
| Raw route | User reported audio exactly once and Stop restoring the original, with Bluetooth headphones. A later raw-route comparison was described as natural. |
| Earlier Apple TimePitch path | User reported robotic sound despite synthetic pitch tests passing. Rejected as the final voice-quality solution. |
| Current Signalsmith path | User reported that the voice sounded natural during an actual call. Parameters were subsequently adjusted by the user, so this is not a controlled, parameter-matched A/B experiment. |
| Presets | Save and rename exercised in the native UI; Default loaded at launch. Existing saved presets were preserved. Cute · Soft was saved separately. |
| Automatic mode | Processing state observed after opt-in verified-output activity. This is output activity detection, not call detection. |
| Device interruption | Audio-property read error (`nsrt`, OSStatus 560947818 / `!obj`) caused Error and automatic mode off; a refresh showed the previous Bluetooth output unavailable. Audible recovery for this particular event was not independently confirmed. A subsequent source change retains an unavailable selected output rather than silently choosing speakers. |

Current-DSP Stop/quit/forced-exit restoration, microphone and other-app listening tests, physical latency, echo, and the complete transition matrix still need human/hardware verification. Prior raw-route success does not prove all of those cases.

## Automated checks that passed

| Check | Coverage / actual result |
| --- | --- |
| Release build | Universal arm64 + x86_64 with the shared Xcode scheme. Plist lint and strict deep ad-hoc signature verification passed. |
| Source provenance | All 9 bundled upstream headers/license files matched pinned SHA-256 entries. |
| PCM bridge, plain + UBSan | 40 cases: 44.1/48 kHz, mono/stereo, packed/planar Int16/24/32 and Float32/64. Malformed/unsupported layouts, underflow fade, overflow, stale discard, emergency silence passed. |
| Mono output | Unity downmix at 24/44.1/48 kHz; duplicate stereo channels are averaged, not doubled. |
| Buffer regression | 20,000 variable render callbacks without underflow/overflow; 12.8 million generated frames in concurrent SPSC stress. These are accelerated software tests. |
| DSP, plain + UBSan | Independent ±4-semitone formant shift on a synthetic three-resonance vowel at 24/44.1/48 kHz. Maximum resonance error 8.31% against the existing 10% criterion; F0 error under 0.14%. |
| DSP dynamics | Nominal +6 dB EQ test measurements 5.905–6.000 dB; compressor steady gain reduction 7.986 dB, matching the analytic expectation. Finite output, linked protection, and parameter changes passed. |
| DSP bypass | Fixed 80 ms processing delay; maximum sample reconstruction error about 5.2 × 10⁻⁸ on the fixture. Check route separately bypasses the entire effects unit. |
| Realtime DSP fixture | 18 mono/stereo cases at 8/11.025/12/22.05/24/44.1/48/96/192 kHz; 180 varying blocks per case, 1–4096 frames, generated vowel/noise/silence and parameter changes. C++ `new`/`new[]` count during processing/reset: 0. |
| Concurrent controls | Bounded atomic controls/telemetry under concurrent fixture load passed. This does not replace ThreadSanitizer. |
| Stereo balance | RMS ratio matched 0.5 within the 0.1% tolerance on a noisy fixture. Small transient/phase differences exist; bit-identical noisy channel output is not claimed. |
| Preset store | Save/load/update/rename, stable launch UUID, legacy preservation, invalid/duplicate names, unsupported-file preservation, mode 0600, absence of source/device/audio data, and insignificant slider round-trip differences passed. |
| Health policy | Silence remains valid; stalled callbacks, stopped engine, invalid formats/samples, repeated loss/backlog faults require stop. This is a policy test, not physical HAL restoration proof. |

The C bridge's 20 allocations/teardowns are **not** 20 physical start/stop cycles. Allocation instrumentation checks the C++ entry points used by this fixture, not every allocator inside Apple frameworks. DSP processing storage and ownership were also reviewed in source.

## Synthetic pitch and speed

`Scripts/test-offline.sh` generates a 10-second 440 Hz tone and uses the actual private Audio Unit in AVAudioEngine offline rendering. It tests 0, −3, +3, −12, and +12 semitones at 24/44.1/48 kHz, mono/stereo: **30 cases passed**.

Expected frequency is `440 × 2^(semitones / 12)`. Frequency is estimated over the steady region; active duration and onset use 10 ms RMS windows with startup/tail handling in the fixture.

| Metric | Measured result | Acceptance / limit |
| --- | --- | --- |
| Maximum steady frequency error | 0.479688% | Under 1% |
| Maximum 10-second duration error | 0.100000% | Under 1% |
| Offline onset delay | 80 ms at all tested voice rates | Software chain only; excludes tap, buffering, converters and physical output |
| Offline render wall time | 0.034–0.103 seconds for each 12-second tone fixture | Throughput measurement, not live CPU utilization |

Six synthetic-vowel comparisons at pitch ±3 found lower mean absolute log-resonance error with vocal-shape preservation enabled. This supports the envelope compensation on those fixtures; it is not a perceptual score for real speech.

## Current DSP 60-minute software soak

`Scripts/soak.sh 3600` completed with the new Signalsmith path: Pitch +3, independent Formant +2, preservation on, mid EQ +3 dB, compressor on, output gain 0.8. An independent software-paced producer ran at a +150 ppm capture-clock offset. Output was an offline engine; no physical device or call audio was used.

| Metric | Observed result |
| --- | --- |
| Elapsed time | 3600.000770 seconds |
| Steady underflows / overflows / backlog resets | 0 / 0 / 0 after the 5-second warmup |
| Format errors / DSP invalid samples | 0 / 0 |
| CPU, cumulative user + system time / elapsed | 5.26% of one core at the 3570-second sample; includes the test harness |
| Peak RSS | 21,889,024 bytes (20.88 MiB); plateaued after initial warmup |
| Maximum observed queued capture frames | 3572 at 48 kHz; bounded queue, not increasing without limit |
| Render blocks exceeding the fixture's 512/48000-second deadline | 3; no corresponding measured ring underflow |

This is a pass of the **software soak**, not a claim of 60 minutes of dropout-free hardware listening. Scheduling overruns are reported even when the test buffer absorbs them. CPU and RSS are fixture measurements, not the live SwiftUI app's process measurements. An earlier 60-minute Apple-DSP baseline also passed, but is not substituted for this current-DSP result.

## Checks that did not pass or remain unverified

AddressSanitizer hung before test main (bounded runner timeout); ThreadSanitizer also failed before test main on this host. They are not marked passing. Normal and undefined-behavior runs passed separately. No security protection was disabled to work around those runtimes.

Physical added latency median/p95, live CPU/RSS, perceived speed, interruption/echo, speaker and wired output, other-app/microphone non-interference, 20 HAL cycles, permission refusal/regrant/revocation, process/helper restart, sleep/wake, and forced-termination cleanup are pending. See [the manual matrix](MANUAL_TESTS.md). The target is ≤150 ms added latency on wired output; a result above 200 ms or difficult conversation requires further improvement or redesign. No unmeasured value is inferred from node latency or the offline 80 ms result.

Private raw logs live under ignored `TestResults/`. Public results are sanitized summaries. No personal conversation recordings are used as evidence or included here.
