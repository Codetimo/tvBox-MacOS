# Repository Guidelines

## Project Structure & Module Organization

- `Package.swift` defines the Swift 5.9 executable and test target for macOS 13+.
- `Sources/TVBoxMacOS/` contains the SwiftUI app, domain models, source adapters/storage, playback, login, and Spider service integration. Keep parsing, UI, and playback responsibilities separate.
- `Tests/TVBoxMacOSTests/` contains XCTest suites and inline fixtures.
- `Bridge/src/main/java/` contains the Android Java service and CatVod compatibility classes; its manifest lives in `Bridge/src/main/`.
- `scripts/` prepares runtimes, builds the Bridge, and packages the app. `ThirdParty/` holds third-party materials and notices; packaged resources are assembled by `scripts/package_app.sh`.

## Build, Test, and Development Commands

Use Xcode 15+ on macOS. Run commands from the repository root:

- `swift build`: compile the development executable.
- `swift run TVBoxMacOS`: launch locally; alternatively open `Package.swift` in Xcode.
- `swift test`: run all XCTest suites, matching CI on `macos-14`.
- `swift test --filter SourceAdapterTests`: run a focused suite.
- `scripts/setup_media_runtime.sh`: download and verify FFmpeg for media integration tests.
- `scripts/setup_spider_runtime.sh`: provision the Android/JDK runtime; the current setup targets Apple Silicon.
- `scripts/build_spider_bridge.sh`: rebuild the APK after runtime setup.
- `scripts/package_app.sh "$PWD/dist"`: build and ad-hoc sign the release app in `dist/`; omitting the argument installs into `~/Applications`.

## Coding Style & Naming Conventions

Follow existing Swift and Java style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` methods/properties. Match filenames to their primary responsibility. Document new methods and non-obvious lifecycle or compatibility logic. Prefer focused changes and existing dependencies. No SwiftLint or SwiftFormat configuration is currently present.

## Testing Guidelines

Name suites `*Tests.swift` and methods `test<Behavior>`. Add regression coverage for changed parsing, authentication, routing, and cleanup behavior. No numeric coverage threshold is configured. The Matroska integration test skips without FFmpeg; report skips explicitly. For Spider/playback changes, verify service health and actual search/detail/playback separately. Preserve site metadata and ensure one failing source does not block others.

## Commit & Pull Request Guidelines

History uses prefixes such as `feat:`, `fix:`, `test:`, and `ci:` with short imperative subjects. Keep commits focused. PRs should explain behavior changes, link relevant issues, list verification and runtime prerequisites, and include screenshots for UI changes. State unverified provider behavior explicitly.

## Security & Configuration

Never commit cookies, authentication tokens, signed URLs, or local runtime caches. Keep Bridge endpoints loopback-only and authenticated with `X-TVBox-Token`. Preserve download validation, bounded retries, and process cleanup.
