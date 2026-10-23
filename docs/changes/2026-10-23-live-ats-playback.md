# 修复安装版直播被 ATS 拦截

## 原因与关键决策

用户反馈 CCTV2（央视IPV4）播放失败，显示 `AVFoundationErrorDomain (-11800)`。本机保存的入口经过两次 HTTP 重定向返回有效 HLS。相同地址在命令行 AVPlayer 中可以解码，但把同一探测程序放入使用现有 Info.plist 的临时 App 包后，CCTV2、CCTV1、CCTV3 都立即失败，底层错误均为 `NSOSStatusErrorDomain (-1022)`。原因是安装包缺少 App Transport Security（ATS）媒体例外，先前仅在命令行验证媒体未覆盖此差异。

## 修改

- `scripts/package_app.sh` 生成 `NSAppTransportSecurity.NSAllowsArbitraryLoadsForMedia = true`，允许 AVFoundation 加载用户导入的 HTTP 媒体及其 CDN 重定向。未启用全局或网页的任意加载许可，未修改 TLS 证书验证。
- `playbackFailureMessage` 在有界错误链内识别 URL 和 OSStatus 两种域的 `-1022`，提示应用网络配置问题并显示底层错误码，避免误报为源失效；继续隐藏签名 URL。
- 增加直接和嵌套 ATS 错误的回归测试。

## 验证

- 同一临时 App 包只增加媒体例外后，CCTV2、CCTV1、CCTV3 均为 ready，播放时间分别达到 10.38、6.40、6.42 秒，各取得 5 个视频帧，无播放错误。
- `swift test`：167 项通过，0 失败，无跳过（含新增 ATS 回归）；`bash -n scripts/package_app.sh` 和 `git diff --check` 通过。
- `scripts/package_app.sh` 成功替换 `/Users/jackstrak/Applications/TVBoxMacOS.app`；`codesign --verify --deep --strict` 通过，安装包 Info.plist 确认包含媒体例外。
- 重启后进程实际来自上述固定安装路径。通过直播页面点击 CCTV2（央视IPV4），实际窗口截图显示 CCTV2 财经直播画面，时间从 `00:12` 推进至 `00:17`，未出现错误弹层，重启后的 Playback 日志无错误。声音未进行听感验收。
- 未生成额外发布 APP 或 ZIP；测试使用的临时探测 App 已清理。

## 风险与回滚

此配置允许用户选择的 HTTP 媒体以明文传输；HTTP 源自身仍可能失效，本次不保证所有第三方频道可用。需要回滚时移除媒体例外后重新打包，但相关 HTTP 直播会再次被 ATS 拦截。源库、收藏及登录配置不变。
