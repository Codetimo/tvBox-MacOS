# 本机打包改为单一 APP 替换

## 原因与决策

用户在启动器看到多份影视仓应用，误开旧版后发现全屏自动隐藏未生效，明确要求清理多余 APP，并记住以后打包直接替换。

- 固定唯一安装入口：`~/Applications/TVBoxMacOS.app`。
- `scripts/package_app.sh` 不再接受其他输出目录；构建、资源组装和签名在隐藏临时目录内完成，验证成功后替换已安装 APP，不生成备份。退出时清理临时目录；构建失败时尚未替换的安装版保留。
- 替换前确认目标不是符号链接、Bundle ID 属于本项目，避免覆盖其他应用。
- 在 `AGENTS.md` 和 README 更新规则；本机持久记忆也记录了用户偏好，取代此前多目录部署和备份流程。
- 如需 ZIP，只替换 `dist/TVBoxMacOS-macOS-arm64.zip` 及对应 SHA-256 文件。

## 本机清理与验证

- 按 Bundle ID 确认后删除 17 份多余 APP：当前项目 13 份发布/备份副本，以及旧影视仓项目 4 份 macOS 构建产物。保留源代码、站源、登录配置与 iOS 产物。
- 逐一注销旧 Launch Services 入口，并清理一个已不存在的旧调试 APP 注册记录；重新注册唯一安装版。系统应用注册列表中仅剩一个影视仓 macOS 入口。
- 删除旧版本/日期 ZIP 及对应校验文件，重新生成固定名称 ZIP，完整性检查通过。
- `bash -n scripts/package_app.sh` 通过；实际执行无参数打包，Release 构建、Bridge 构建、替换安装及签名验证通过，隐藏临时目录已清理。记录：`/tmp/tvbox-single-install-package.log`。
- 已启动 `/Users/jackstrak/Applications/TVBoxMacOS.app/Contents/MacOS/TVBoxMacOS`，核实运行路径。
- 本次不改播放逻辑；全屏自动隐藏的测试和实机结果见同日 `fullscreen-controls-autohide` 记录。此前提到的备份与多目录产物已按本次用户要求删除。
- Git 提交仅包含本次全屏自动隐藏及打包清理相关差异，其他已有改动保留在工作区。将暂存区快照导出到临时目录单独运行 `swift test`：75 项通过，0 失败，无跳过；含其他待提交功能的完整工作区此前为 104 项通过。日志 `/tmp/tvbox-single-app-commit-tests.log`。
- 额外验证传入输出目录时脚本以退出码 2 拒绝执行，不创建 APP；`git diff --check` 与暂存区差异检查通过。

## 风险与恢复

不再保留可启动的旧 APP 备份。需要恢复旧版本时，应从 Git 对应版本重新构建并替换唯一安装路径；不可继续使用已删除的历史备份路径。
