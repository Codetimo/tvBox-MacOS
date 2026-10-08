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
