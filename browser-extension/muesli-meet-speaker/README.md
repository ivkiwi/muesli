# Guesli Meet Speaker Bridge

Unpacked Chromium extension for local testing.

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked: `browser-extension/muesli-meet-speaker`.
4. Join Google Meet with Guesli running.

The extension sends only active speaker name samples, visible Meet participant names, and the current Meet URL to `http://127.0.0.1:1477/v1/meet-speaker`.
