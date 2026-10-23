# 直播列表恢复与 TLS 故障区分

## 排查证据

2026-10-22 本机源库中，`9280.kstore.vip` 快照含 307 个频道，`dxawi.github.io` 快照只有 4 个 `Live` 分组条目。后者实际是频道列表及 Android 代理入口，被旧代码在展开失败后保留成了可播放频道：

- 3 个条目使用 `ghp.ci` 包装 GitHub 原始地址；本机验证镜像 TLS 握手失败，curl 返回 35，与界面 `NSURLErrorDomain(-1200)` 一致。
- 解开 URL 中已明确指定的原始仓库，IPV6①、IPV6②返回 HTTP 200 的有效 M3U；IPV4 的原始文件返回 HTTP 404。
- 牛播一指向 `127.0.0.1:9978/proxy`，该 Android TVBox 内部代理在本机未监听。
- 其余 307 个频道并非全部失效：CCTV1、CGTN 英语、苏州 4K 等抽样返回有效 HLS；部分其他提供商存在 404、空响应或连接失败，属于独立上游问题。

## 额外发现：旧频道 ID 冲突

真实窗口验收发现收藏 CGTN 后显示 CCTV1、频道卡片文字复用异常。检查持久化文件确认首源 307 个频道的 ID 全部是同一个未展开的插值模板字符串 `(source.id.uuidString)|(name)|(url.absoluteString)`。

`SourceStore.load` 现在仅为模板坏值、空值或冲突 ID 生成唯一身份并原子保存。正常唯一 ID 保持不变，所有频道 URL、请求头、名称、分组及源配置不变；重复加载结果稳定。不会修改或删除 `favoriteChannelIDs` 配置，也不猜测歧义旧 ID 原本对应哪个频道。若用户旧收藏本身使用了无法区分频道的坏 ID，需要重新选择具体频道；本次检查用户原有直播收藏为 0。

## 修改

- 对 `ghp.ci/raw.githubusercontent.com/...` 仅恢复 URL 明确携带的同一 GitHub 仓库地址，保留路径编码与查询参数，使用正常 HTTPS 验证；不选择新的直播来源。
- 正确展开 M3U 与 TVBox TXT 频道列表；支持列表相对 URL 和 `EXTVLCOPT` 请求头，父级 UA 等请求头传递到频道。
- HLS 保持单一可播放地址，不展开为独立分片频道；经过回源的 HLS 使用原始仓库地址，不再留下失败镜像地址。
- 失效 GitHub 列表和不受支持的 Android 本地代理只显示来源错误，不再伪装为视频频道。未知普通流遇到网络故障仍保留，避免误删真实频道。
- 启动后仅修复旧快照里的上述占位条目，无需重新添加源；已有展开频道保持不变。保存前检查源仍存在且未被用户修改，沿用 `SourceStore.upsert` 保留已有频道身份与收藏引用。
- 播放错误补充 TLS/证书分类说明和错误码，提示检查源、系统时间与代理，不关闭证书校验，也不暴露签名 URL。

## 验证

- `swift test --filter 'LivePlaylistRecoveryTests|SourceCorrectnessTests'`：首轮 17 项通过；增加 HLS 回源、嵌套 HLS 基准地址和 HTML 错误页回归后，最终 `swift test --filter LivePlaylistRecoveryTests`：9 项通过、0 失败。
- debug 应用真实启动触发旧库迁移：`dxawi.github.io` 从 4 个占位恢复为 222 个频道、解析版本 `tvbox-json-3`；`9280.kstore.vip` 的 307 个已有频道及解析版本保持不变（主 agent 检查持久化文件确认）。
- `swift test --filter 'SourceIdentityMigrationTests|SourceCorrectnessTests'`：13 项通过，覆盖坏模板、跨源冲突、生成 ID 碰撞、正常收藏身份保留和重启稳定性。
- 主 agent 通过真实 `AVPlayer` + `AVPlayerItemVideoOutput` 验证本机已保存频道：CGTN 英语 ready、推进 12.504 秒、取得 5 帧；苏州 4K ready、推进 1.091 秒、取得 12 帧；CCTV1（101.35.240.114 入口）ready、推进 6.412 秒、取得 5 帧；均无播放错误。
- 原始仓库列表 HTTP 可用不代表其中所有频道可用，IPv6 频道仍取决于当前网络 IPv6 可达性；本次不宣称全部频道已经恢复。

## 风险与回滚

回源后频道数量会随上游列表内容变化。源配置地址保持原样，失效列表有明确警告，可在上游恢复后重新导入。回滚代码不会删除原始源配置；已有真实频道和 Cookie 不受影响。最终窗口操作及打包验证由本次集成记录补充。
