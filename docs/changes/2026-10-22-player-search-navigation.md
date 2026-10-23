# 播放页搜索完成后展示影视结果

## 原因与内容

“正在播放”页的顶部搜索原先只更新结果，没有切换到结果所在的“影视”页。
本次在 `ChannelBrowserView.searchMovies()` 中记录搜索是否从播放页发起，在搜索结束、清除搜索中状态后切换到影视页，直接使用本次已加载的结果，不重复请求。

## 关键决策

- 点击搜索按钮和按回车使用同一个入口。
- 空关键词和搜索中的重复提交继续提前返回，不触发跳转。
- 搜索无结果或失败也展示影视页中的空状态及提示。
- 仅在搜索发起时和结束时均处于播放页的情况下跳转，避免结束时将用户从其他页面拉走。
- 搜索解析、站源查询和播放器控制逻辑不变。

## 验证与边界

- `swift test`：编译成功，73 项测试通过，0 失败，无跳过。
- `git diff --check`：通过。
- 本次未新增 UI 自动化测试。部署后通过辅助功能进入“正在播放”页，测试使用的 CCTV1 地址返回 `AVFoundationErrorDomain (-11800)`；后续窗口辅助功能读取异常，未完成搜索跳转的端到端验证。

## 构建与本机发布

- 执行 `scripts/package_app.sh "$PWD/dist/search-navigation-release"`，Release 构建和打包成功。
- 已部署到 `~/Applications/TVBoxMacOS.app` 和 `dist/TVBoxMacOS.app`，退出旧实例并启动安装目录中的新版。
- 两处部署与暂存发布版的可执行文件 SHA-256 一致，`codesign --verify --deep --strict` 均通过。使用项目现有的 ad-hoc 签名，没有 Apple 公证。
- ZIP 发布包：`dist/TVBoxMacOS-2026-10-22-search-navigation-macos-arm64.zip`；旁附 `.sha256` 校验文件，ZIP 完整性校验通过。
- 保留项目原有 `1.0.0` 应用版本号，发布包文件名使用日期与变更名称区分。
- 未上传 GitHub Releases，未创建远程标签或推送提交。

## 回滚

移除新增的播放页来源标记与 `defer` 中的页面切换，保留原有搜索状态清理即可恢复原行为。
旧应用保存在 `dist/backups/20261022-123232/`，退出当前应用后可从对应的 `installed-TVBoxMacOS.app` 或 `dist-TVBoxMacOS.app` 恢复部署。
