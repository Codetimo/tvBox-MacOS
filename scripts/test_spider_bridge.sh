#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_JDK="$HOME/Library/Application Support/TVBoxMacOS/runtime/jdk-17"
JDK_DIR="${TVBOX_JDK_DIR:-${JAVA_HOME:-$RUNTIME_JDK}}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tvbox-bridge-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
"$JDK_DIR/bin/javac" -encoding UTF-8 -d "$BUILD_DIR" \
  "$ROOT_DIR/Bridge/src/main/java/com/tvbox/bridge/RequestExecutor.java" \
  "$ROOT_DIR/Bridge/src/main/java/com/tvbox/bridge/PackageCache.java" \
  "$ROOT_DIR/Bridge/src/test/java/com/tvbox/bridge/BridgeRegressionTests.java"
"$JDK_DIR/bin/java" -cp "$BUILD_DIR" com.tvbox.bridge.BridgeRegressionTests
