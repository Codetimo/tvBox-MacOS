#!/bin/bash
set -euo pipefail

# 一次性准备本地 Android Spider 运行时。运行时文件放在用户目录，不写入仓库。
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="${TVBOX_RUNTIME_DIR:-$HOME/Library/Application Support/TVBoxMacOS/runtime}"
SDK_DIR="$RUNTIME_DIR/android-sdk"
TOOLS_DIR="$SDK_DIR/cmdline-tools/latest"
JDK_DIR="$RUNTIME_DIR/jdk-17"
BRIDGE_DIR="$PROJECT_DIR/Bridge"

mkdir -p "$RUNTIME_DIR" "$SDK_DIR/cmdline-tools"

if [ ! -x "$JDK_DIR/bin/java" ]; then
  archive="$RUNTIME_DIR/jdk.tar.gz"
  # Use a direct vendor archive. The Adoptium redirect API is occasionally
  # unavailable behind enterprise DNS/proxies; Corretto publishes the same
  # OpenJDK 17 toolchain for Apple Silicon without that redirect.
  curl --http1.1 -L --fail --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
    --silent --show-error \
    "https://corretto.aws/downloads/latest/amazon-corretto-17-aarch64-macos-jdk.tar.gz" \
    -o "$archive"
  extracted="$RUNTIME_DIR/jdk-extracted"
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted"
  jdk_root="$(find "$extracted" -maxdepth 1 -type d \( -name 'jdk-*' -o -name 'amazon-corretto-*' \) | head -1)"
  test -n "$jdk_root"
  if [ -x "$jdk_root/Contents/Home/bin/java" ]; then
    mv "$jdk_root/Contents/Home" "$JDK_DIR"
  else
    mv "$jdk_root" "$JDK_DIR"
  fi
fi

export JAVA_HOME="$JDK_DIR"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_AVD_HOME="$RUNTIME_DIR/avd"
mkdir -p "$ANDROID_AVD_HOME"

if [ ! -x "$TOOLS_DIR/bin/sdkmanager" ]; then
  archive="$RUNTIME_DIR/commandlinetools.zip"
  curl --http1.1 -L --fail --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
    --silent --show-error \
    "https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip" -o "$archive"
  staging="$RUNTIME_DIR/cmdline-tools-staging"
  mkdir -p "$staging"
  unzip -q -o "$archive" -d "$staging"
  mkdir -p "$TOOLS_DIR"
  cp -R "$staging/cmdline-tools/." "$TOOLS_DIR/"
fi

# command-line-tools 11.x uses eval for its JVM arguments. Preserve the
# quoted Application Support path so Java does not treat `Support/...` as a
# second main-class argument.
python3 - "$TOOLS_DIR/bin/sdkmanager" "$TOOLS_DIR/bin/avdmanager" <<'PY'
import pathlib, sys
for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    text = path.read_text()
    text = text.replace("DEFAULT_JVM_OPTS='-Dcom.android.sdklib.toolsdir=$APP_HOME'",
                        "DEFAULT_JVM_OPTS='-Dcom.android.sdklib.toolsdir=\"$APP_HOME\"'")
    text = text.replace("DEFAULT_JVM_OPTS='-Dcom.android.sdkmanager.toolsdir=$APP_HOME'",
                        "DEFAULT_JVM_OPTS='-Dcom.android.sdkmanager.toolsdir=\"$APP_HOME\"'")
    path.write_text(text)
PY

SDKMANAGER="$TOOLS_DIR/bin/sdkmanager"
yes | "$SDKMANAGER" --sdk_root="$SDK_DIR" --licenses >/dev/null || true
"$SDKMANAGER" --sdk_root="$SDK_DIR" "platform-tools" "emulator" "platforms;android-35" "build-tools;35.0.0" "system-images;android-35;google_apis;arm64-v8a"

# platform-tools 37.0.1 currently crashes its macOS adb daemon on some
# macOS 27 arm64 hosts. Pin the stable 35.0.2 client for emulator lifecycle
# and APK installation; it remains compatible with Android 35.
if ! "$SDK_DIR/platform-tools/adb" version 2>/dev/null | grep -q '35.0.2'; then
  platformArchive="$RUNTIME_DIR/platform-tools_r35.0.2-darwin.zip"
  curl --http1.1 -L --fail --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
    --silent --show-error \
    "https://dl.google.com/android/repository/platform-tools_r35.0.2-darwin.zip" -o "$platformArchive"
  python3 - "$platformArchive" "$SDK_DIR" <<'PY'
import os, shutil, sys, zipfile
archive, sdk = sys.argv[1:]
target = os.path.join(sdk, "platform-tools")
if os.path.exists(target):
    shutil.rmtree(target)
with zipfile.ZipFile(archive) as source:
    source.extractall(sdk)
for name in ("adb", "fastboot"):
    path = os.path.join(target, name)
    if os.path.exists(path):
        os.chmod(path, 0o755)
PY
fi

if ! "$JAVA_HOME/bin/java" -version >/dev/null 2>&1; then
  echo "JDK 17 不可用" >&2
  exit 1
fi

if ! "$TOOLS_DIR/bin/avdmanager" list avd | grep -q '^Name: tvbox-spider$'; then
  echo no | "$TOOLS_DIR/bin/avdmanager" create avd \
    --name tvbox-spider \
    --package 'system-images;android-35;google_apis;arm64-v8a' \
    --device pixel_6 \
    --force
fi

echo "Spider 运行时已准备：$RUNTIME_DIR"
