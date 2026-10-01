# Vendored Signalsmith sources

Unmodified headers from Signalsmith Stretch **1.3.2** and Signalsmith Linear
**0.6.4**. Both use the MIT license; notices are retained here and bundled in
the app's `THIRD_PARTY_NOTICES.txt`. See `manifest.json` for pinned commits,
upstream URLs, and SHA-256 hashes of each included file.

The app builds with Apple's Accelerate FFT backend. Required headers and its
portable fallback are included; upstream command-line programs, demos,
submodules, and optional third-party FFT backends are omitted. Build and runtime
never fetch dependencies. Updates require source review and renewed audio tests.
