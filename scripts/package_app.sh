#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TVBoxMacOS.app"
INSTALL_DIR="$HOME/Applications"
if [[ $# -gt 0 ]]; then
  echo "Usage: scripts/package_app.sh (replaces $INSTALL_DIR/$APP_NAME; custom output directories are no longer supported)" >&2
  exit 2
fi
FINAL_APP_PATH="$INSTALL_DIR/$APP_NAME"

cd "$PROJECT_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/TVBoxMacOS"

# 在隐藏的临时目录完成构建和签名；失败时清理临时产物，保留已安装应用。
mkdir -p "$INSTALL_DIR"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.tvbox-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_PATH="$STAGING_DIR/$APP_NAME"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/TVBoxMacOS"
# 资源保留仓库布局，setup/build/launcher 的相对路径在 App 内同样有效。
RESOURCE_DIR="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCE_DIR/scripts/spider-service" "$RESOURCE_DIR/Bridge"
cp "$PROJECT_DIR/scripts/setup_spider_runtime.sh" "$PROJECT_DIR/scripts/build_spider_bridge.sh" "$PROJECT_DIR/scripts/setup_media_runtime.sh" "$RESOURCE_DIR/scripts/"
cp "$PROJECT_DIR/scripts/spider-service/launch.sh" "$RESOURCE_DIR/scripts/spider-service/"
ditto "$PROJECT_DIR/Bridge" "$RESOURCE_DIR/Bridge"
ditto "$PROJECT_DIR/ThirdParty" "$RESOURCE_DIR/ThirdParty"
chmod +x "$RESOURCE_DIR/scripts/"*.sh "$RESOURCE_DIR/scripts/spider-service/launch.sh"
# 独立、固定版本的 MKV 兼容组件，与 App 一起部署。
"$PROJECT_DIR/scripts/setup_media_runtime.sh"
MEDIA_RUNTIME="$HOME/Library/Application Support/TVBoxMacOS/runtime/media"
mkdir -p "$RESOURCE_DIR/media"
cp "$MEDIA_RUNTIME/ffmpeg" "$MEDIA_RUNTIME/NOTICE.txt" "$RESOURCE_DIR/media/"
for LICENSE_FILE in COPYING.GPLv3 LICENSE; do
  if test -f "$MEDIA_RUNTIME/$LICENSE_FILE"; then cp "$MEDIA_RUNTIME/$LICENSE_FILE" "$RESOURCE_DIR/media/"; fi
done
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>影视仓 Mac</string>
<key>CFBundleName</key><string>TVBoxMacOS</string>
<key>CFBundleIdentifier</key><string>com.codetimo.tvbox-macos</string>
<key>CFBundleVersion</key><string>1.0.0</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleExecutable</key><string>TVBoxMacOS</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
# 本地只保留固定安装入口，不创建日期目录、dist APP 或备份 APP。
if [[ -e "$FINAL_APP_PATH" || -L "$FINAL_APP_PATH" ]]; then
  INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FINAL_APP_PATH/Contents/Info.plist")"
  if [[ -L "$FINAL_APP_PATH" || "$INSTALLED_ID" != "com.codetimo.tvbox-macos" ]]; then
    echo "Refusing to replace unexpected app: $FINAL_APP_PATH" >&2
    exit 1
  fi
  rm -rf "$FINAL_APP_PATH"
fi
mv "$APP_PATH" "$FINAL_APP_PATH"
echo "Installed: $FINAL_APP_PATH"
