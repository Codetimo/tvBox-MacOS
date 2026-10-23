# tvBox-MacOS

[English](README.md) | [简体中文](README.zh-CN.md)

一款以本地使用为主的个人 macOS 播放器，支持用户自行提供的 IPTV/M3U 播放列表及 TVBox/影视仓 JSON 配置。

## 当前功能

- 导入远程或本地 M3U、TVBox JSON，区分 IPTV 频道列表与 HLS 媒体播放列表。
- 浏览、搜索、收藏和播放直播频道；重新导入时保留已有频道及收藏的 ID。
- 搜索已配置的 CMS 和 CatVod `csp_*` Spider 站点，支持普通搜索（`quickSearch=0`）。
- 通过仅监听本机回环地址、带身份认证的 Android Bridge 获取 Spider 详情并解析播放地址。
- 使用原生界面展示夸克、百度网盘登录二维码，并将客户端凭据存储在 macOS 钥匙串中。
- 通过 AVPlayer 播放直连媒体，使用随应用提供的 FFmpeg 兼容 Matroska，使用 WebKit 打开实际的 HTML 播放页面。

应用会在专用 Android 模拟器中执行用户配置的 Spider 包。目前不支持任意 JavaScript/Python 适配器，也不支持需要外部解析器（`parse`、`jx`、`playUrl`）的 Spider 返回结果。

请仅添加可信来源。模拟器用于解决运行环境兼容性问题，不能保证远程代码包的安全。

## 环境要求

- macOS 13 或更高版本。
- Xcode 15 或更高版本；项目使用 Swift 5.9 的包配置。
- 当前 Android Spider 运行时准备脚本面向 Apple Silicon，使用 JDK 17、Android 35 和 ARM64 模拟器镜像。不要将其视为已支持 Intel Mac 的完整 Spider 方案。
- 首次准备运行时需要联网下载相关组件。

## 构建与运行

在仓库根目录执行：

```bash
swift build
swift run TVBoxMacOS
```

也可以使用 Xcode 打开 `Package.swift`，运行 SwiftUI 应用。

需要使用 Spider 站点时，先准备 Android/JDK 运行时：

```bash
scripts/setup_spider_runtime.sh
```

开发时需要兼容播放 Matroska 或运行相关集成测试，可先准备媒体运行时：

```bash
scripts/setup_media_runtime.sh
```

运行时默认保存在 `~/Library/Application Support/TVBoxMacOS/runtime`，不写入仓库。应用打包脚本会自动准备并内置媒体运行时。

## 源配置参考

项目最初使用的配置地址由用户提供，仅作为运行时输入：

<https://9280.kstore.vip/newwex.json>

该配置未内置于应用中。第三方站点的可用性需要实际验证，请勿将凭据、Cookie、认证令牌或带签名的媒体 URL 提交到仓库。

## 项目结构与架构

| 路径 | 职责 |
| --- | --- |
| `Package.swift` | Swift 应用与测试目标配置 |
| `Sources/TVBoxMacOS/` | SwiftUI 界面、源管理、搜索、播放、登录及 Spider 集成 |
| `Tests/TVBoxMacOSTests/` | XCTest 测试与内联测试数据 |
| `Bridge/` | Android Java 服务、DEX 加载及原生库兼容层 |
| `scripts/` | 运行时准备、Bridge 构建、测试和应用打包 |
| `ThirdParty/` | 第三方材料、许可证及说明 |
| `docs/changes/` | 项目变更记录 |

主要模块：

- `Domain.swift`、`SourceAdapters.swift`、`SourceStore.swift`：领域模型、源解析和最近一次成功的本地快照。
- `SourceLoader.swift`、`SearchPipeline.swift`：目录、CMS 和 Spider 请求，各类请求分别限制并发。结果逐步展示，取消搜索时保留已完成的结果；CMS 搜索摘要在选中后加载详情。
- `SpiderService.swift`：多个窗口共享由应用管理的服务；可取消的调用方复用同一次启动操作，并持续监测服务健康状态。
- `Bridge/`：Android DEX 和原生库兼容。健康检查与有界 Spider 执行分离，请求总时限为 20 秒，超时返回明确错误。忽略中断的任务在实际退出前仍占用执行配额。
- `Playback.swift`、`MediaProbe.swift`、`MediaCompatibility.swift`：限制探测数据量的媒体识别、原生播放及 Matroska 转封装。

Bridge 按 SHA-256 内容哈希保存不可变的包版本目录。配置了 MD5 的包会校验 MD5；未配置 MD5 的地址会在五分钟后的下一次请求中重新验证，扫码登录进行期间延后更新。原生库路径与包内容哈希保持一致。

目前所有包仍运行在同一个 Android 进程内，尚未实现完整的进程隔离。JNI 崩溃或多个包永久阻塞时，需要重启服务所在进程。接口、配额、缓存与恢复机制详见 [Bridge 文档](Bridge/README.md)。

## 测试与本机打包

准备好 Android/JDK 运行时后，在仓库根目录执行：

```bash
swift test
scripts/test_spider_bridge.sh
scripts/package_app.sh
codesign --verify --deep --strict "$HOME/Applications/TVBoxMacOS.app"
```

打包脚本会重新构建 Bridge APK 并随应用携带，避免运行时遗留的旧 APK 遮蔽 Java 修复。

本机打包遵循单应用替换规则：

- 固定替换 `~/Applications/TVBoxMacOS.app`，不接受自定义输出目录。
- 使用隐藏临时目录构建和签名，脚本退出时自动清理临时产物。
- 不在发布目录、日期目录或备份目录保留额外 `.app` 副本。
- 如需额外生成 ZIP，仅替换 `dist/TVBoxMacOS-macOS-arm64.zip` 及对应校验文件，不累积带日期的压缩包；打包脚本本身不生成 ZIP。

打包完成后，通过固定路径启动：

```bash
open "$HOME/Applications/TVBoxMacOS.app"
```

应用使用本地临时签名（ad-hoc），不代表已通过 Apple 公证。CI 分别执行 Swift 测试以及基于 JDK 17 / Android 35 的 Bridge 构建与测试。

测试通过或服务健康检查通过，不能替代真实站点的搜索、详情、媒体解码以及手机扫码确认；这些需要分别验收。

## macOS 播放兼容性

播放页在视频下方以可自适应换行的按钮展示线路和选集。底部控制栏提供进度跳转、全屏、音量和静音操作。按回车可进入独立的黑色全屏窗口，与原窗口共享同一个 AVPlayer；按 Escape 返回内嵌播放器，不重新开始播放。

部分 Spider 资源虽然以 `.mp4` 命名，实际内容却是 Matroska。应用会探测媒体头，包括公共 CDN 地址，并使用随应用提供的 FFmpeg 7.1 进行流式转封装：复制视频轨道，将音频转换为 AAC，再通过仅监听本机回环地址的 HTTP 服务输出分片 MP4/HLS。

该路径保留最近 120 个分片，约 8–12 分钟。进度条使用原始文件的完整时长，并单独展示已缓冲区间。跳转到缓存之外时，会在目标关键帧附近重新开始转封装，同时保留播放器、音量和暂停状态。如果无法取得原始时长，会禁用按比例跳转，避免将缓存长度误当作完整片长。

切换选集或退出应用时，会终止相关进程并清理临时文件。不支持的编码和上游请求失败仍会显示明确错误。

媒体运行时脚本固定使用 `imageio-ffmpeg 0.6.0` 的 wheel 文件，提取前验证发布的 SHA-256；只提取独立可执行文件，不安装 Python 依赖。FFmpeg 许可证与源码参考见 [ThirdParty/FFmpeg](ThirdParty/FFmpeg)。

`swift test` 包含本机 HTTP/Range 和选集匹配回归测试。H.264 Matroska 集成测试在已安装媒体运行时时执行，否则报告跳过。真实站点播放仍需单独验证。

## 参与开发

代码风格、测试要求、安全约束和变更留痕规则见 [AGENTS.md](AGENTS.md)。涉及业务逻辑、接口、配置或架构的修改，应在 `docs/changes/` 中记录原因、主要内容、验证结果及必要风险，以实际差异和验证结果为准。
