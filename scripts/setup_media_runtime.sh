#!/bin/bash
set -euo pipefail

# 固定版本并校验 PyPI 发布的 SHA-256；只提取独立 FFmpeg，不安装 Python 包。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="${TVBOX_MEDIA_RUNTIME:-$HOME/Library/Application Support/TVBoxMacOS/runtime/media}"
mkdir -p "$RUNTIME_DIR"
case "$(uname -m)" in
  arm64)
    URL='https://files.pythonhosted.org/packages/40/5c/f3d8a657d362cc93b81aab8feda487317da5b5d31c0e1fdfd5e986e55d17/imageio_ffmpeg-0.6.0-py3-none-macosx_11_0_arm64.whl'
    SHA256='b1ae3173414b5fc5f538a726c4e48ea97edc0d2cdc11f103afee655c463fa742'
    ;;
  x86_64)
    URL='https://files.pythonhosted.org/packages/da/58/87ef68ac83f4c7690961bce288fd8e382bc5f1513860fc7f90a9c1c1c6bf/imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl'
    SHA256='9d2baaf867088508d4a3458e61eeb30e945c4ad8016025545f66c4b5aaef0a61'
    ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
ARCHIVE="$RUNTIME_DIR/imageio-ffmpeg-0.6.0.whl"
if ! test -f "$ARCHIVE" || ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --silent --show-error --location --retry 2 --continue-at - --max-time 600 "$URL" -o "$ARCHIVE.download"
  echo "$SHA256  $ARCHIVE.download" | shasum -a 256 -c -
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
BINARY="$(unzip -Z1 "$ARCHIVE" | awk '/^imageio_ffmpeg\/binaries\/ffmpeg-/ {print; exit}')"
test -n "$BINARY"
unzip -p "$ARCHIVE" "$BINARY" > "$RUNTIME_DIR/ffmpeg.tmp"
chmod +x "$RUNTIME_DIR/ffmpeg.tmp"
"$RUNTIME_DIR/ffmpeg.tmp" -version >/dev/null
mv "$RUNTIME_DIR/ffmpeg.tmp" "$RUNTIME_DIR/ffmpeg"
for NAME in COPYING.GPLv3 LICENSE; do
  ENTRY="$(unzip -Z1 "$ARCHIVE" | awk -v name="$NAME" '$0 ~ "/" name "$" {print; exit}')"
  if test -n "$ENTRY"; then unzip -p "$ARCHIVE" "$ENTRY" > "$RUNTIME_DIR/$NAME"; fi
done
cp "$SCRIPT_DIR/../ThirdParty/FFmpeg/COPYING.GPLv3" "$SCRIPT_DIR/../ThirdParty/FFmpeg/NOTICE.txt" "$RUNTIME_DIR/"
"$RUNTIME_DIR/ffmpeg" -version | head -3
