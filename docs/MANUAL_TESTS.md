# Hardware and live-call acceptance

This checklist complements software tests. An unchecked item is pending. Do not mark a build complete based on compilation, controls screenshots, algorithmic latency, or synthetic pitch alone.

Start with wired/USB headphones and modest volume. Keep the app's selected output visible, use a non-personal test conversation, and do not record call audio. Permission prompts and actual call initiation are performed by the user.

## Record a test condition

Keep private notes for date, app build, macOS, ChatGPT version, device type/connection, tap/capture/playback rates/channel counts, enabled effects and settings, and result. Public summaries must omit personal device names/UIDs, paths, PIDs, conversation text and recordings. Preserve a preset before changing an existing sound.

## Live path

- [x] Earlier Bluetooth raw route: user heard ChatGPT once and Stop restored original audio.
- [x] Current Signalsmith path: user reported natural sound in a real ChatGPT call.
- [ ] Current build: Start processing with Pitch +3 only; height changes, speech timing remains comfortable; Stop restores original.
- [ ] Current build: use Check route, then effects and Stop repeatedly; no original/processed overlap, feedback, abrupt loudness increase or clipping.
- [ ] Hold Pitch fixed, adjust Formant ±2; vocal resonance changes independently. Compare preservation on/off; EQ remains separately labeled.
- [ ] Play music in an unrelated app at ordinary volume during processing; it remains unchanged. Stop and compare that music separately.
- [ ] Confirm OS input/output defaults stay unchanged. In the actual call, check that the user's mic remains normal; the voice changer must not request microphone access.
- [ ] Include silence, interruptions and back-and-forth speech. Check stuttering, echo and conversational usability.
- [ ] Generate an ordinary ChatGPT notification when appropriate; determine whether it shares a captured audio process. Document the process-level limit even if a particular notification is not heard.
- [ ] Cute · Soft: listen at the same original ChatGPT voice, compare with Neutral/original and save a renamed custom variant if desired. Preset names do not guarantee a particular perceived voice.

## Lifecycle and failures

For each row, test both whether processing stops/disarms safely and whether original ChatGPT audio is actually heard afterward. Capture resource counters and inventory changes are supporting evidence, not substitutes for listening.

| Condition | Required outcome | Status |
| --- | --- | --- |
| 20 real start/stop cycles | Each Start is single and Stop restores original; no private-device accumulation | Pending |
| Double Start / Stop during preparation | Serial startup and cancellation; no capture left muted | Pending |
| Permission denied, then reallowed in normal Settings | Denial leaves stopped; explicit retry works after user permission | Pending |
| Permission revoked while running | Stop on detectable error; verify original and document any silent-callback limit | Pending |
| ChatGPT quits and restarts | Safe stop on old identity; refresh validates new PIDs/objects before a new session | Pending; coordinate with user to avoid disrupting unrelated work |
| Audio helper restarts | Existing tap never expands; old session stops and new identity is reverified | Pending |
| Selected output disconnects / reconnects | Safe stop, no silent fallback to another speaker, explicit verification before restart | Error/disarm observed once; audible restoration and reconnection pending |
| Wired/Bluetooth/system default switch | Stop and restore original; rates/channels are reread before explicit restart | Pending |
| Device sample-rate/buffer change | Stop and rebuild from fresh formats | Pending |
| Sleep and wake | Capture ends; no stale route resumes automatically after the detected error | Pending |
| Engine/capture/render failure | Supervisor releases capture and original becomes audible | Policy fixture passed; hardware pending |
| Window closes / menu controls reopen | App stays resident; controls and preset edits remain available | Pending |
| Menu-bar Quit / Command-Q | Synchronous teardown; original returns, no owned private-device remnants | Pending |
| Force quit / crash during active tap | OS restores original; no owned aggregate/tap remains | Pending |

Use only the app's own private aggregate/tap identifiers when checking cleanup. Do not remove unrelated devices or restart/kill another app without coordinating with the user. No root commands, injected code, permission-DB edits or security disabling are part of this test plan.

## Device matrix and measurements

| Output | Raw comparison | Pitch/formant quality | Added latency median/p95 | Dropouts / echo | Live CPU / RSS |
| --- | --- | --- | --- | --- | --- |
| Wired / USB headphones | Pending | Pending | Unmeasured | Unmeasured | Unmeasured |
| Bluetooth headphones | Earlier raw success | Favorable current-DSP user report | Unmeasured | Full test pending | Unmeasured |
| Speakers | Pending | Pending | Unmeasured | Unmeasured | Unmeasured |

Bluetooth microphone/profile transitions are separate conditions. Speaker echo may alter ChatGPT's echo cancellation or interruption behavior even though this app never captures a mic.

For added wired latency, use a consented **synthetic** calibration source played by a separate small test application and a measurement-only build restricted to its verified process. The shipping app must remain restricted to the verified official desktop app. A hardware loopback/measurement recorder can compare the source reference and physical output for that synthetic signal; it must never record personal conversation audio or silently broaden shipping capture. This measurement harness and hardware procedure have not yet been executed.

Collect at least 30 synthetic markers, subtract the measured unprocessed device baseline, and report method, device/rates, median, p95, and loss count. Exclude network and ChatGPT response time. Algorithmic/node latency is not this measurement. Initial target: ≤150 ms; >200 ms or difficult conversation requires improvement or a discussed design change.

Measure live process CPU over a representative stable interval, state whether percentage is relative to one core, and record RSS trend plus capture/DSP underflow/overflow/reset/invalid counters. Count audible dropouts separately. Run a 60-minute synthetic hardware playback after the software soak; inspect latency trend and memory, then ordinary actual Voice including silence and interruptions. All of these physical values remain unmeasured.
