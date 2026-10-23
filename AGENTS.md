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
- `scripts/package_app.sh`: build, ad-hoc sign, and replace the single installed app at `~/Applications/TVBoxMacOS.app`. Custom output directories are not supported.

## 本机打包规则

- 用户明确要求：以后打包是替换，不再留存多份 APP。
- 本机只保留 `~/Applications/TVBoxMacOS.app` 这一份最新可启动应用。不要在 `dist/`、日期发布目录或备份目录保留额外 `.app`。
- 使用脚本的隐藏临时目录完成构建和签名，成功后替换固定路径，临时产物随脚本退出清理。不额外备份旧 APP。
- 如需 ZIP，仅替换 `dist/TVBoxMacOS-macOS-arm64.zip` 及对应校验文件，不累积版本/日期命名的压缩包。
- 打包完成后检查实际启动路径，避免打开旧构建；清理范围仅限已确认的本项目/旧影视仓构建产物，不删除源代码或用户配置。

## Coding Style & Naming Conventions

Follow existing Swift and Java style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` methods/properties. Match filenames to their primary responsibility. Document new methods and non-obvious lifecycle or compatibility logic. Prefer focused changes and existing dependencies. No SwiftLint or SwiftFormat configuration is currently present.

## Testing Guidelines

Name suites `*Tests.swift` and methods `test<Behavior>`. Add regression coverage for changed parsing, authentication, routing, and cleanup behavior. No numeric coverage threshold is configured. The Matroska integration test skips without FFmpeg; report skips explicitly. For Spider/playback changes, verify service health and actual search/detail/playback separately. Preserve site metadata and ensure one failing source does not block others.

## Commit & Pull Request Guidelines

History uses prefixes such as `feat:`, `fix:`, `test:`, and `ci:` with short imperative subjects. Keep commits focused. PRs should explain behavior changes, link relevant issues, list verification and runtime prerequisites, and include screenshots for UI changes. State unverified provider behavior explicitly.

## Security & Configuration

Never commit cookies, authentication tokens, signed URLs, or local runtime caches. Keep Bridge endpoints loopback-only and authenticated with `X-TVBox-Token`. Preserve download validation, bounded retries, and process cleanup.

## 项目变更留痕

- 修改代码后，根据 Git diff 判断是否需要留痕。
- 涉及业务逻辑、接口、数据库、配置或架构的变更，记录到 `docs/changes/`；纯格式调整等无实质影响的改动可跳过。
- 记录变更原因、主要内容、关键决策、验证结果及必要的风险或回滚说明。
- 以实际代码差异和验证结果为准，不得编造；完成后检查记录与代码是否一致。
- 日常小改动保持轻量；重大跨模块改造再采用 OpenSpec 等结构化流程。
