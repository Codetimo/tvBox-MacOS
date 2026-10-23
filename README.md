# tvBox-MacOS

A personal, local-first macOS player for user-provided IPTV/M3U and TVBox/影视仓 JSON sources.

## MVP scope

- Import a source from an HTTPS URL or local file
- Parse IPTV extended M3U live channels
- Parse the static `lives` section from TVBox/影视仓 JSON
- Search, group, favorite and play channels
- Keep the last known good snapshot locally
- Play HLS/HTTP streams with AVPlayer

The MVP deliberately does not execute remote Spider JAR, JavaScript, Python, WebView click scripts or arbitrary parser code.

## Build

Requires Xcode 15+ and macOS 13+.

```bash
swift build
swift test
```

Open the package in Xcode for the SwiftUI app target.

## Source reference

The initial source is supplied by the user and is treated as configuration input at runtime:

`https://9280.kstore.vip/newwex.json`

It is not bundled into the app, and credentials or signed URLs must not be committed.

## Architecture

- `Domain.swift`: canonical source and channel models
- `SourceAdapters.swift`: bounded M3U and static TVBox JSON adapters
- `Playback.swift`: AVPlayer seam
- `TVBoxMacOSApp.swift`: SwiftUI shell

## Packaging

```bash
scripts/package_app.sh
codesign --verify --deep --strict "$HOME/Applications/TVBoxMacOS.app"
```

Packaging replaces the single app at `~/Applications/TVBoxMacOS.app`; custom output
directories are no longer accepted. Temporary staging is cleaned up automatically.
Do not retain additional `.app` copies in release or backup directories. If a ZIP is
needed, replace `dist/TVBoxMacOS-macOS-arm64.zip` instead of creating dated copies.

## macOS playback compatibility

The player page groups routes and episodes into adaptive, multiline buttons below
the video. The bottom control bar includes seeking, fullscreen, volume, and mute.
Return opens a separate black fullscreen window sharing the same AVPlayer; Escape
returns to the embedded player without restarting playback.

Some Spider resources named `.mp4` actually contain Matroska. The app checks the
media header and streams those resources through a bundled FFmpeg 7.1 process:
video is copied, audio is converted to AAC, and a loopback-only HTTP server serves
fragmented MP4/HLS. This path keeps 120 recent segments (roughly 8–12 minutes);
the progress bar uses the original file duration, with buffered ranges shown
separately. Seeking outside the current cache restarts remuxing near the requested
keyframe while preserving the player, volume, and pause state. If the original
duration is unavailable, proportional seeking is disabled instead of presenting
the cache length as the full duration. Switching episodes or quitting terminates
the process and deletes its temporary files. Unsupported codecs and failed
upstream requests remain explicit errors.

`scripts/package_app.sh` prepares and bundles the media runtime automatically.
For development, run `scripts/setup_media_runtime.sh` once. The script pins
imageio-ffmpeg 0.6.0 wheels and verifies their published SHA-256 before extracting
the standalone executable; it does not install Python dependencies. FFmpeg
license and source references are in `ThirdParty/FFmpeg`.

`swift test` includes the loopback HTTP/Range and episode-matching regressions.
The H.264 Matroska integration test runs when the media runtime is installed and
otherwise reports a skip. Real provider playback still requires separate testing.
