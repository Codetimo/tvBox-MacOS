#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="${TVBOX_RUNTIME_DIR:-$HOME/Library/Application Support/TVBoxMacOS/runtime}"
SDK_DIR="${TVBOX_ANDROID_SDK_DIR:-$RUNTIME_DIR/android-sdk}"
JDK_DIR="${TVBOX_JDK_DIR:-$RUNTIME_DIR/jdk-17}"
BRIDGE_DIR="${TVBOX_BRIDGE_DIR:-$ROOT_DIR/Bridge}"
BUILD_DIR="$RUNTIME_DIR/bridge-build"

ANDROID_JAR="$SDK_DIR/platforms/android-35/android.jar"
JAVAC="$JDK_DIR/bin/javac"
D8="$SDK_DIR/build-tools/35.0.0/d8"
ZIPALIGN="$SDK_DIR/build-tools/35.0.0/zipalign"
APKSIGNER="$SDK_DIR/build-tools/35.0.0/apksigner"
AAPT2="$SDK_DIR/build-tools/35.0.0/aapt2"
KEYTOOL="$JDK_DIR/bin/keytool"
export JAVA_HOME="$JDK_DIR"
export PATH="$JAVA_HOME/bin:$PATH"
# CatVod expects these standard runtime libraries from its host application.
DEPS_DIR="$RUNTIME_DIR/bridge-deps"
mkdir -p "$DEPS_DIR"
for artifact in com/squareup/okhttp3/okhttp/3.12.13/okhttp-3.12.13 com/squareup/okio/okio/1.15.0/okio-1.15.0 com/google/code/gson/gson/2.10.1/gson-2.10.1 org/jsoup/jsoup/1.17.2/jsoup-1.17.2; do
  target="$DEPS_DIR/${artifact##*/}.jar"
  if [ ! -f "$target" ]; then
    curl -fLsS --retry 2 --connect-timeout 20 --max-time 180 "https://repo.maven.apache.org/maven2/$artifact.jar" -o "$target.part"
    "$JDK_DIR/bin/jar" tf "$target.part" >/dev/null
    mv "$target.part" "$target"
  fi
done

for required in "$ANDROID_JAR" "$JAVAC" "$D8" "$ZIPALIGN" "$APKSIGNER" "$AAPT2" "$BRIDGE_DIR/src/main/AndroidManifest.xml"; do
  test -e "$required" || { echo "missing bridge build input: $required" >&2; exit 1; }
done

mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex"
find "$BUILD_DIR/classes" -type f -delete
find "$BUILD_DIR/dex" -type f -delete

sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$BRIDGE_DIR/src/main/java" -name '*.java' -print | sort)
"$JAVAC" -source 8 -target 8 -encoding UTF-8 -cp "$ANDROID_JAR" -d "$BUILD_DIR/classes" "${sources[@]}"

jar cf "$BUILD_DIR/bridge.jar" -C "$BUILD_DIR/classes" .
"$D8" --lib "$ANDROID_JAR" --min-api 26 --output "$BUILD_DIR/dex" "$BUILD_DIR/bridge.jar" "$DEPS_DIR"/*.jar

unsigned="$BUILD_DIR/spider-bridge-unsigned.apk"
aligned="$BUILD_DIR/spider-bridge-aligned.apk"
rm -f "$unsigned" "$aligned" "$RUNTIME_DIR/spider-bridge.apk"
cp "$BRIDGE_DIR/src/main/AndroidManifest.xml" "$BUILD_DIR/AndroidManifest.xml"
# Android requires aapt2's binary manifest format; a plain ZIP/XML is not installable.
# Legacy native Spider loaders create writable DEX internally. API 34+ target
# enforcement rejects these before they can return a ClassLoader. Keep this
# dedicated emulator helper at API 33 compatibility; Android itself remains 35.
"$AAPT2" link \
  -I "$ANDROID_JAR" \
  --manifest "$BUILD_DIR/AndroidManifest.xml" \
  --min-sdk-version 26 \
  --target-sdk-version 33 \
  --auto-add-overlay \
  -o "$unsigned"
(cd "$BUILD_DIR/dex" && zip -q "$unsigned" classes.dex)
"$ZIPALIGN" -f 4 "$unsigned" "$aligned"

keystore="$RUNTIME_DIR/debug.keystore"
if [ ! -f "$keystore" ]; then
  "$KEYTOOL" -genkeypair -v -keystore "$keystore" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi
"$APKSIGNER" sign --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
  --out "$RUNTIME_DIR/spider-bridge.apk" "$aligned" >/dev/null
echo "Built $RUNTIME_DIR/spider-bridge.apk"
