# tvBox-MacOS

[English](README.md) | [简体中文](README.zh-CN.md)

A personal, local-first macOS player for user-provided IPTV/M3U and TVBox/影视仓 JSON sources.

## Current scope

- Import remote or local M3U/TVBox JSON; distinguish IPTV channel lists from HLS media playlists.
- Browse, search, favorite and play live channels; reimport preserves existing channel/favorite IDs.
- Search configured CMS and CatVod `csp_*` Spider sites, including ordinary (`quickSearch=0`) search.
- Resolve Spider detail/player responses through an authenticated Android Bridge on loopback.
- Show native Quark/Baidu QR login and store client credentials in macOS Keychain.
- Play direct media with AVPlayer, use bundled FFmpeg for Matroska, and open actual HTML playback pages in WebKit.

The app executes user-configured Android Spider packages inside its dedicated emulator.
Arbitrary JavaScript/Python adapters and Spider responses requiring external parsers (`parse`, `jx`, `playUrl`) remain unsupported.
Only add sources you trust; the emulator is a compatibility runtime, not a guarantee that remote packages are safe.

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

- `Domain.swift`, `SourceAdapters.swift`, `SourceStore.swift`: models, parsing and last successful local snapshots.
- `SourceLoader.swift`, `SearchPipeline.swift`: catalog/CMS/Spider requests and independently bounded catalog, CMS and Spider scheduling. Results stream in; cancelling keeps completed results. CMS summaries load detail on selection.
- `SpiderService.swift`: one app-owned service shared across windows; cancellable callers reuse a single startup operation and continuous health monitoring.
- `Bridge/`: Android DEX/native compatibility. HTTP health handling is separate from bounded Spider execution; 20-second request deadlines return explicit errors. A task ignoring interruption retains its admission slot until it exits.
- `Playback.swift`, `MediaProbe.swift`, `MediaCompatibility.swift`: bounded content probing, native playback and Matroska remuxing.

Bridge packages use immutable SHA-256 content directories. MD5-pinned packages are verified;
URLs without a pin are revalidated after five minutes on the next request, with revalidation
deferred during active QR login. Native library paths follow the package content hash.
The current Bridge still runs packages in one Android process: JNI process crashes and
multiple permanently blocked packages require restarting that service; full process isolation is not implemented.

## Validation and packaging

```bash
swift test
scripts/test_spider_bridge.sh
scripts/package_app.sh
codesign --verify --deep --strict "$HOME/Applications/TVBoxMacOS.app"
```

Packaging requires the Android/JDK runtime from `scripts/setup_spider_runtime.sh`, rebuilds
the Bridge APK and embeds it with the app so an older runtime APK cannot hide Java fixes.
It replaces the single app at `~/Applications/TVBoxMacOS.app`; custom output directories
are no longer accepted. Temporary staging is cleaned up automatically; do not retain
additional `.app` copies in release or backup directories. If a ZIP is needed, replace
`dist/TVBoxMacOS-macOS-arm64.zip` instead of creating dated copies.
It uses ad-hoc signing. CI runs Swift tests and a separate JDK 17/Android 35 Bridge build/test job.
Live provider search, detail, media decoding and phone scan confirmation are separate acceptance checks.

## macOS playback compatibility

The player page groups routes and episodes into adaptive, multiline buttons below
the video. The bottom control bar includes seeking, fullscreen, volume, and mute.
Return opens a separate black fullscreen window sharing the same AVPlayer; Escape
returns to the embedded player without restarting playback.

Some Spider resources named `.mp4` actually contain Matroska. The app probes the
media header, including public CDN URLs, and streams those resources through a bundled FFmpeg 7.1 process:
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
