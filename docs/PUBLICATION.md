# Publication checklist

This repository publishes development source and honest test evidence. It does not provide a validated signed binary release. Source publication is authorized separately from declaring the full live-call acceptance complete.

## Repository presentation

Suggested description:

> Native macOS voice effects for verified ChatGPT desktop audio: pitch, formant, EQ, compression and presets. Local processing; development build.

Suggested topics: `macos`, `swift`, `swiftui`, `coreaudio`, `audio`, `dsp`, `pitch-shifting`, `formant-shifting`, `voice-changer`, `chatgpt`, `signalsmith`.

Use screenshots of the isolated native preview with generic device labels. Do not use real-call screenshots, personal device names, user preset files or an artificially Processing screen. Keep the development/verification status near the top of the README. No OpenAI endorsement is implied.

## Before committing or pushing

- Review the explicit staged filenames and complete diff; no personal paths, credentials, recordings, device inventory, user presets or diagnostic/build artifacts.
- Run `python3 Scripts/security-check.py`. This is a heuristic; inspect images and source manually as well.
- Keep `build/`, `TestResults/`, `LocalArtifacts/`, signing material, preference files and audio artifacts Git-ignored.
- Verify bundled source hashes and retain both MIT licenses in the repository and app resources.
- Verify documentation links/images and source-build instructions. Separate measured results from pending cases.
- Build universal Release and run checks appropriate to changes. Do not relabel failed sanitizer runtimes as passing.
- Verify the destination remote and branch. Use a normal push; never force-push or rewrite the owner's history.
- If the remote advanced, review and integrate its changes without overwriting other work.

## Before a public binary release

Complete [hardware acceptance](MANUAL_TESTS.md), including current-DSP audible processing, other-app/mic isolation, all restoration paths, physical latency and device transitions. Test older supported macOS and Intel before making broad runtime claims. Record all limitations.

Prepare Developer ID signing and notarization separately, verify the download on another Mac, include notices and stop/uninstall instructions, and obtain the owner's approval for binary publication. Do not publish secrets or notarization credentials. See [build/signing](BUILD_AND_PERMISSIONS.md).

Updating description/topics does not imply hardware acceptance. Avoid release tags or release binaries until the relevant release gate passes and the owner authorizes that action.
