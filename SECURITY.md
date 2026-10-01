# Security and privacy

Dots Voice Changer processes selected desktop-app output on the local Mac. The app has no network client, analytics, API credentials, conversation storage, microphone capture, virtual driver, login item, or injected code. The audio ring and processing buffers are bounded, transient memory.

## Capture boundary

Capture is granted only after verification of the installed official app's signature, signing identifier and public OpenAI signing team, exact executable path, process start identity, and helper ancestry within the app bundle. Names are discovery hints plus a product check; names alone never authorize capture. The installed bundle identifier is read dynamically.

The tap includes only the verified Core Audio process object IDs. It is private and non-exclusive (`isExclusive = false`, meaning include the listed set). The aggregate is private and tap-only. Neither global output nor microphone devices are included. The app does not rewrite OS audio defaults.

Process capture may include notifications and other sounds within those same processes. Automatic mode watches verified process output activity; it does not identify speech, conversation content, or Voice-call state. Automatic mode is opt-in and can be disarmed immediately with Stop.

## Failure handling and residual limits

Playback is prepared before tap reading begins. A non-realtime monitor checks callback progress, engine state, data loss, format errors, and invalid processing samples. Process/device changes stop the active session. Stop/quit first stops processed playback, then capture callbacks, then destroys the IOProc, aggregate, and tap before freeing shared buffers. If callback teardown cannot be confirmed, the buffer is quarantined and restarting is blocked to prevent use-after-free.

Detected errors disarm automatic mode. Silence is not used to infer failure or call state. Silent permission revocation with continuing callbacks and forced-termination OS recovery have not been fully validated. Review the manual tests and do not treat resource-lifetime design as completed hardware proof.

## Local data

Presets save only effect settings and names. Their directory is created with mode 0700 and files are set to 0600. Preferences also store the selected application path, output device UID, launch preset UUID, and automatic-mode choice. These stay on the user's Mac. Diagnostic UI can show local paths, process IDs, and device metadata; do not publish raw screenshots of that panel.

Test/probe scripts write ignored `TestResults/` and `build/`. Test audio is synthesized, never captured from a call. An inspection can contain identifying device names and paths. Keep those files private. Public documentation should contain only reviewed aggregate measurements and preview screenshots using generic device labels.

## Public-repository review

Run `python3 Scripts/security-check.py` before staging or sharing. This checks tracked and non-ignored untracked files for credential-like strings, personal absolute paths, signing credentials, and audio recordings. It reports filenames and line numbers without echoing matched values. It is a heuristic and does not replace source review.

Check staged content again before publication. Never upload user preferences/presets, call audio, device inventories, build logs, signing keys, tokens, `.env` files, or private test notes. Only code, reviewed documentation, generic screenshots, and reproducible test tools should be published.

No SIP, Gatekeeper, TCC, system permissions database, or security policy is modified. Local ad-hoc signing is not a notarized public distribution signature.

## Reporting

Do not put secrets, recordings, or identifying logs in public issues. Use a private repository security advisory if that channel is enabled by the owner. Share a minimal synthetic reproducer and sanitized numeric diagnostics. No private reporting endpoint has been configured yet.
