# HEVC hev1 MP4 兼容播放修复

## 原因与范围

2026-10-22 用《给阿嬷的情书》实测时，剧透和花卷的百度线路返回有效 MP4，FFmpeg 能解码，但 AVFoundation 无法取得视频轨（AVError -11869）。两条视频的 HEVC sample entry 均为 `hev1`；已有兼容流程只识别 Matroska，未处理这种 MP4。

本次只修复客户端容器/编码标记兼容性，不改变 Spider 查询、网盘账户或外部站点状态。

## 主要变更与关键决策

- 新增 `MP4CompatibilityProbe`，沿 `moov/trak/mdia/minf/stbl/stsd` 读取第一条视频轨 sample entry，仅 `hev1` 触发兼容播放；普通 `avc1`、`hvc1` 保持原生路径，不按文件名或任意字节中的字符串猜测。
- 支持尾部 moov、64 位 box 长度和 mvhd v0/v1 时长。跳过 mdat 和大型 sample table；最多 8 次、每次 64 KiB 的读取，限制 box 数并在读取前检查探测期限。不支持偏移 Range、格式错误或超出探测预算时保留原生尝试机会。
- 扩展有界媒体读取以支持偏移 Range，并验证 `Content-Range` 起点，拒绝将忽略 Range 的文件头误作尾部数据。
- 复用现有 FFmpeg → 本地 HLS → AVPlayer 管线：视频 `copy`，HEVC 标为 `hvc1`，音频仍按原兼容流程转 AAC；没有新增第三方依赖或整片下载。
- 保留原片时长与跳转偏移，初次播放和后续 seek 复用兼容信息。界面根据资源显示 MKV/HEVC 兼容播放，错误文案不再把所有兼容资源称作 MKV。
- 发布版本更新为 1.0.2。

## 验证结果

- 最终 `swift test`：102 项通过，0 失败、0 跳过。
- 新增回归覆盖 hev1/hvc1/avc1 区分、品牌及负载误匹配、尾部 moov、64 位时长、截断/非法长度、过多 box、大型 sample table、备用视频轨，以及忽略或错误 Range 起点。
- 本地生成真实 hev1 视频，使用生产 HLS 转封装流程从第 4 秒跳转，验证原片 8 秒时长、输出时间轴归零、hvc1 视频格式，以及 AVFoundation 解码 320×180 画面。
- 真实剧透百度原画：搜索/详情/player 均 200，媒体 Range 206；新代码自动识别 hev1，时长 7114.88 秒，从第 60 秒启动生产转封装流程，输出由 AVFoundation 解码为 3840×2160，存在音轨。
- 真实花卷百度原画 #01：搜索/详情/player 均 200，媒体 Range 206；新代码自动识别 hev1，时长 7117.044 秒，从第 60 秒启动同一流程，输出由 AVFoundation 解码为 1920×1080，存在音轨。
- 真实线路通过临时 XCTest 调用生产类验证；临时用例及包含播放 URL/请求头的文件已移出仓库或删除，常规测试不依赖第三方站点。未宣称完成 GUI 整片播放或人工听音验收。

## 风险与回滚

- 兼容播放需要打包的 FFmpeg；服务器不支持偏移读取、元数据超限或未知编码仍可能无法自动识别。
- 视频不重编码；字幕和多音轨选择仍沿用原有兼容流程的边界。
- 此修复不代表搜索异常、空详情或网盘登录/空间问题已修复。
- 旧版备份：`/Users/jackstrak/Documents/tbBox-MacOS/dist/backups/hev1-20261022-173631`；退出新版后，用其中的 `installed-TVBoxMacOS.app` / `dist-TVBoxMacOS.app` 恢复对应目录即可。本轮未改变 Bridge 代码或账户数据。

## 发布结果

- Release Swift 编译、Bridge APK 重建及资源打包成功，现有 SDK/API 弃用警告仍存在。
- `dist/TVBoxMacOS.app` 与 `~/Applications/TVBoxMacOS.app` 均更新为 1.0.2，安装目录中的新版已启动。
- 两处可执行文件 SHA-256：`35a8e8fe3d353870bc8edf0a4d39a4e3d68981b30a4abaca9a73e70035fd9815`。
- 发布包：`dist/TVBoxMacOS-1.0.2-20261022-macos-arm64.zip`，附 `.sha256`；SHA-256 为 `ded9e5a49513c386eab31382b918aff5a1a8cbfe13cafbdf0c9f9edb35c86406`。
- 两处应用 `codesign --verify --deep --strict`、ZIP 完整性、shell 语法及 `git diff --check` 通过；仍使用项目原有 ad-hoc 签名。
- 安装后首次启动遇到旧模拟器仍在退出、launcher 锁尚未释放；待旧进程退出后重新打开应用，认证 `/health` 返回 200。该部署时序现象未混入本次媒体兼容代码修改。
- 脱敏实测摘要位于 `dist/validation/20261022-hev1-fix.json`。未提交、推送或发布远程 Release。
