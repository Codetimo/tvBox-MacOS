# 工程修复本机部署 1.0.3

## 原因与内容

根据用户“编译部署打包”的要求，将当前工作区的工程修复及已有改动构建成本机版本。工程改动与测试详情见 [工程审查问题修复](2026-10-23-engineering-review-fixes.md)；该记录中的“未部署”描述为修复阶段状态，本次完成后续部署。

- `scripts/package_app.sh` 的应用版本与构建版本更新为 `1.0.3`。
- 退出旧应用后运行 `scripts/package_app.sh`，重新构建 release 程序和 Bridge APK，打包 FFmpeg 并完成 ad-hoc 签名。
- 替换 `/Users/jackstrak/Applications/TVBoxMacOS.app`，未保留旧 APP 备份，也未修改用户源库、收藏或凭据文件。
- 替换固定产物 `dist/TVBoxMacOS-macOS-arm64.zip` 及 `.sha256`，压缩包大小为 22,542,472 字节。

## 验证

- 打包脚本成功退出；`codesign --verify --deep --strict` 通过，安装包 Info.plist 版本为 `1.0.3`。
- ZIP 完整性检查通过，其中主程序和 Bridge APK 的 SHA-256 均与已安装文件一致。
- ZIP SHA-256：`173021cf6027f3fd2fd6c43cd80318d810c2ea8614a1c37f6e10bb05091fa46a`。
- 已启动安装路径下的 `Contents/MacOS/TVBoxMacOS`；认证 Bridge health 返回 `ready=true`、`engine=android-dex`、`restartRequired=false`。启动时 `loadedPackageVersions=0`，此健康检查不代表已加载第三方站源。
- 打包前完成的 166 项 Swift 测试无失败、无跳过，6 组 Java 回归通过；本次仅修改版本号，未重复运行整套测试。
- `git diff --check`、打包脚本语法和压缩包校验文件检查通过；安装目录及 dist 下仅有固定路径的一份 TVBox APP，构建和压缩临时目录已清理。

## 边界

本次为本机 ad-hoc 签名部署，未公证、提交或发布到远程。真实第三方站源的搜索、详情、播放及扫码登录未在部署阶段重新验收。保留已有工作区改动；如需回退，应重新构建对应代码版本并替换固定安装路径，不累积备份 APP。
