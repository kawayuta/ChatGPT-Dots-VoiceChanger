# Architecture and API availability

## Flow

```mermaid
flowchart LR
  A[Verified ChatGPT processes] --> T[Private inclusive process tap]
  T --> D[Private tap-only aggregate]
  D --> R[Fixed-capacity C SPSC ring]
  R --> S[AVAudioSourceNode]
  S --> P[Signalsmith pitch and independent formant]
  P --> E[Three-band EQ]
  E --> C[Stereo-linked compressor]
  C --> G[Gain and peak protection]
  G --> O[App-selected output unit]
```

All effects run in one private in-process Audio Unit. Check route connects the source directly to the mixer, bypassing that unit. It still uses app-only playback gain. There is no microphone or physical input subdevice in either path.

## Selection

`AudioInventory.swift` reads `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID`, bundle strings, and output-activity flags. It separately verifies installed and running signatures, canonical paths, helper ancestry, and process start timestamps. Root PID reuse is not sufficient to preserve identity. An empty, ambiguous, unsigned, unrelated, or changed set is never accepted for an existing session.

The selected bundle identifier comes from the installed signed app. `com.openai.codex` is a discovery hint for the current official app, not unconditional capture authority. The product name and OpenAI signing team are additional checks; neither substitutes for live path and ancestry validation. A future official app/signing change can fail closed until verified and updated.

## Formats and clocks

The actual tap and aggregate stream formats are read. The C bridge supports mono/stereo packed little-endian Int16/24/32 and Float32/64, interleaved or planar. Unsupported layouts fail before capture. The custom Audio Unit uses planar Float32 mono/stereo. Hardware mono output is downmixed explicitly with `(L + R) / 2`, avoiding a doubled duplicate stereo signal.

Capacity is approximately 250 ms plus 4096 frames. Normal target headroom is 40 ms **after** the requested render block, plus interpolation look-ahead. Startup waits for that reserve. Stale backlogs are discarded rather than allowed to grow indefinitely. Underflow fades to silence and reprimes; overflow drops the new block. Counters are atomics read off the audio thread.

The tap-only aggregate enables sub-tap drift compensation. Separate capture/playback clocks are also handled by a bounded ring-occupancy servo (up to ±0.05% correction) with fractional interpolation. AVAudioEngine converts nominal sample rates to the selected device. This small clock correction is separate from the intentional pitch shift; nominal speech rate is 1.0. Ring occupancy alone is not a proof of end-to-end latency or every device's clock behavior.

## DSP

Apple's AVAudioUnitTimePitch was evaluated first, including rate 1.0 and higher-overlap/coherence settings. Synthetic pitch tests passed, but the user found actual voice robotic. The production path now uses pinned Signalsmith Stretch 1.3.2 with Linear 0.6.4 and Accelerate, following the user's approval. TimePitch is not connected in the current app.

The in-process custom AU is registered using public `AUAudioUnit.registerSubclass`. It is not an installed Audio Unit plug-in. All render storage and FFT setups are preallocated. The render block captures a stable C context and does not allocate, lock, log, write files, update UI, or send Objective-C messages. Control and telemetry cross the boundary through bounded atomic values.

`SpeechDSP.cpp` configures an 80 ms spectral window and 20 ms hop, with equal input/output frame counts. The combined library input/output algorithmic delay is 80 ms at tested voice rates. This is not measured device latency. FFTs and processing storage are prepared and warmed before capture. The wrapper uses deterministic initialization rather than a random-device read. `VoiceDSP.c` supplies fixed 128-frame scratch chunks; arbitrary callback sizes are subdivided without allocating.

Pitch, independent user formant, and preservation transition over about 40 ms. For linear pitch shifting, the internal envelope shift is `userFormant − pitch × preservationMix`. A bounded, fixed-storage original-signal period estimate supplies a coarse formant reference when confidence is sufficient; otherwise the library's rough estimate remains. This does not detect speech, calls, identity, or microphone activity.

Formants approximate the vocal spectral envelope. They are distinct from the subsequent EQ and do not reconstruct a vocal tract or clone a voice. Stereo spectral processing can create small transient/phase differences; it is not claimed to preserve bit-identical noisy channels. Synthetic resonance accuracy and subjective naturalness are separate evidence.

A linked, bounded spectral-energy normalization compares delayed original power with processed power to avoid extreme attenuation on sparse spectra. It uses fixed power-history storage, a 25 ms power average, and a 40 ms gain transition, bounded to 0.125–8. It is separate from the optional compressor and is not automatic compressor makeup. Final output is still subject to gain and peak protection.

EQ implements the RBJ cookbook biquads. The compressor uses a stereo-linked peak detector, 6 dB soft knee, explicit attack/release, and no makeup gain. Final peak protection limits linked peaks to 0.98 and invalid samples produce a supervised stop.

## Lifecycle and supervision

State: Stopped → Preparing → Checking route / Processing → Restoring → Stopped or Error. All resource mutations run on one serial lifecycle queue. Startup can be cancelled by a generation token checked before playback and capture starts. No callback uses that control lock.

Playback is started before the tap is read. The monitor checks callback progress over two seconds, engine state, invalid layouts/samples, repeated underflow/overflow/backlog resets, and verified identity/device continuity. Silence still advances callbacks and is valid. A quality fault stops capture instead of continuing to mute the source with unreliable playback.

Stop silences/stops processed playback before restoring original process output, stops/destroys the IOProc, destroys the aggregate and tap, and frees the ring only after callbacks are stopped. An emergency public tap-description unmute is attempted if capture stop fails. Unconfirmed callback teardown quarantines memory and blocks restart. Sleep/wake and engine/output/rate/buffer/stream changes cause a stop, not reuse of a stale route. Forced crash recovery remains an OS behavior requiring a real-device test.

Automatic mode is separate from capture supervision. A one-second non-realtime poll verifies output-active process identity on two consecutive observations. Original sound can play while initial verification and preparation finish. It has no Voice-call API or amplitude-based speech detector. It stops on inactive output and is disarmed on Stop or detected audio error. Closing the controls window does not stop the app; menu-bar Quit runs synchronous teardown. An unavailable saved output is retained as unavailable, requiring reconnection or an explicit choice instead of silently falling back to speakers.

## API boundary

| API / feature | Deployment condition |
| --- | --- |
| Process tap creation/destruction, CATapDescription, process-object properties | macOS 14.2 public Core Audio tap API; minimum project deployment 14.2 |
| Inclusive stereo process selection, private tap, mutedWhenTapped | Tap API, explicitly configured; no global/exclusion fallback |
| `isProcessRestoreEnabled = false` | Only inside `#available(macOS 26.0, *)`; needs an SDK declaring it |
| Bundle-ID target selection / process restoration introduced in newer SDK | Not used as capture authority; exact verified process objects are passed |
| SwiftUI MenuBarExtra | macOS 13+, covered by deployment 14.2 |
| AVAudioSourceNode, engine manual rendering, private AU subclass registration | Public AVFAudio APIs predating deployment minimum |
| Accelerate FFT / libproc identity / Security signing checks | Public platform APIs; runtime checked |

SDK 26.2 declarations and dual-architecture compilation were verified. Availability annotations and a successful deployment-target build do not establish runtime validation on older macOS or Intel hardware.

The SDK declares CATapDescription itself earlier than 14.2, but the required AudioHardwareCreateProcessTap/DestroyProcessTap functions are available from 14.2. The earlier class annotation does not lower this application's deployment minimum.
