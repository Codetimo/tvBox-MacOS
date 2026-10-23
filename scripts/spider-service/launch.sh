#!/bin/bash
set -euo pipefail

# 启动一个本服务专用的 Android 模拟器；已有同会话桥接服务会复用。
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="${TVBOX_RUNTIME_DIR:-$HOME/Library/Application Support/TVBoxMacOS/runtime}"
SDK_DIR="$RUNTIME_DIR/android-sdk"
EMULATOR_PORT="${TVBOX_EMULATOR_PORT:-5580}"
SERIAL="${TVBOX_ANDROID_SERIAL:-emulator-$EMULATOR_PORT}"
PORT="${TVBOX_SPIDER_PORT:-19190}"
TOKEN="${TVBOX_SPIDER_TOKEN:-}"
AVD_NAME="${TVBOX_AVD_NAME:-tvbox-spider}"
ADB="$SDK_DIR/platform-tools/adb"
EMULATOR="$SDK_DIR/emulator/emulator"
LOG_DIR="$RUNTIME_DIR/logs"
LOCK_DIR="$RUNTIME_DIR/spider-service.lock"
BRIDGE_APK="$RUNTIME_DIR/spider-bridge.apk"
# 发布包携带与 Swift 客户端同批构建的 APK，优先于旧运行时缓存。
if [ -f "$PROJECT_DIR/Bridge/spider-bridge.apk" ]; then
  BRIDGE_APK="$PROJECT_DIR/Bridge/spider-bridge.apk"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/spider-service-$(date +%Y%m%d-%H%M%S)-$$.log"
# 直接写入独立日志文件，避免 process substitution 的 tee 在宿主 App
# 退出后仍持有管道，导致 launcher 进程无法回收。
exec >>"$LOG_FILE" 2>&1
echo "[$(date)] starting Spider launcher (pid=$$, serial=$SERIAL, port=$PORT)"

export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_AVD_HOME="$RUNTIME_DIR/avd"
if [ -n "${TVBOX_ADB_SERVER_PORT:-}" ]; then
  export ANDROID_ADB_SERVER_PORT="$TVBOX_ADB_SERVER_PORT"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    *) shift;;
  esac
done
PARENT_PID="$PPID"
LAUNCHER_PID="$$"

# adb 在设备失联时可能一直等待；每次命令都有独立超时。
bounded() {
  local seconds="$1" command_pid timer_pid result
  shift
  "$@" & command_pid=$!
  ( sleep "$seconds"; kill -TERM "$command_pid" 2>/dev/null || true ) & timer_pid=$!
  if wait "$command_pid"; then result=0; else result=$?; fi
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  return "$result"
}

adb() { bounded 15 "$ADB" "$@"; }

# 业务线程不可回收时由 Bridge 显式请求进程重启，不能仅凭 HTTP 可达判断健康。
RESTART_REQUIRED=0
healthy() {
  local response
  RESTART_REQUIRED=0
  response="$(curl --silent --fail --max-time 2 -H "X-TVBox-Token: $TOKEN" "http://127.0.0.1:$PORT/health")" || return 1
  if printf '%s' "$response" | grep -Eq '"restartRequired"[[:space:]]*:[[:space:]]*true'; then
    RESTART_REQUIRED=1
    return 1
  fi
  printf '%s' "$response" | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true'
}

# Reuse a bridge left by an earlier launcher attempt with the same session
# token. Keep this process attached to the App so the existing service follows
# the same lifecycle and is not started a second time.
if healthy; then
  echo "[$(date)] Spider service already healthy; reusing existing bridge"
  while kill -0 "$PARENT_PID" 2>/dev/null; do sleep 2; done
  exit 0
fi


for required in "$ADB" "$EMULATOR"; do
  [ -x "$required" ] || { echo "missing Android runtime: $required" >&2; exit 78; }
done

# mkdir 是原子的，防止多个 App/launcher 同时占用同一个 AVD。
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Spider launcher already running (pid=$old_pid)" >&2
    exit 3
  fi
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR"
fi
echo "$$" > "$LOCK_DIR/pid"

EMULATOR_PID=""
WATCHDOG_PID=""
FORWARD_CREATED=0
cleanup() {
  status=$?
  trap - EXIT INT TERM
  set +e
  [ -z "$WATCHDOG_PID" ] || kill "$WATCHDOG_PID" 2>/dev/null
  if [ "$FORWARD_CREATED" = 1 ]; then
    bounded 5 "$ADB" -s "$SERIAL" forward --remove "tcp:$PORT" >/dev/null 2>&1
  fi
  # 仅终止本次创建的进程，不通过 serial 杀死可能由其他 App 启动的设备。
  if [ -n "$EMULATOR_PID" ] && kill -0 "$EMULATOR_PID" 2>/dev/null \
     && ps -p "$EMULATOR_PID" -o command= 2>/dev/null | grep -F -- "-avd $AVD_NAME" >/dev/null; then
    # serial 和命令行都匹配本次 AVD 后才请求 emulator 自己退出。
    bounded 5 "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    kill -TERM "$EMULATOR_PID" 2>/dev/null
    for _ in $(seq 1 10); do
      kill -0 "$EMULATOR_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$EMULATOR_PID" 2>/dev/null || true
    wait "$EMULATOR_PID" 2>/dev/null || true
  fi
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null
  echo "[$(date)] launcher stopped (status=$status)"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# 父 App 即便异常退出，也会在启动期间和运行期间触发清理。
(
  while kill -0 "$PARENT_PID" 2>/dev/null && kill -0 "$LAUNCHER_PID" 2>/dev/null; do sleep 2; done
  kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
) & WATCHDOG_PID=$!

adb start-server
if adb -s "$SERIAL" get-state >/dev/null 2>&1 || /usr/sbin/lsof -nP -iTCP:"$EMULATOR_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Android serial $SERIAL is already in use; refusing to control it" >&2
  exit 4
fi
if /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Local HTTP port $PORT is already in use" >&2
  exit 4
fi

echo "[$(date)] launching AVD $AVD_NAME on emulator port $EMULATOR_PORT"
# Keep the emulator's default quick-boot snapshot. A cold boot is only needed
# on the first launch; subsequent launcher starts can restore the ready AVD.
"$EMULATOR" -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -port "$EMULATOR_PORT" &
EMULATOR_PID=$!
BOOT_DEADLINE=$((SECONDS + 240))

device_ready=0
while [ "$SECONDS" -lt "$BOOT_DEADLINE" ]; do
  if adb -s "$SERIAL" get-state >/dev/null 2>&1; then device_ready=1; break; fi
  kill -0 "$EMULATOR_PID" 2>/dev/null || break
  sleep 1
done
[ "$device_ready" = 1 ] || { echo "Android device did not appear within 240 seconds" >&2; exit 1; }

boot_ready=0
while [ "$SECONDS" -lt "$BOOT_DEADLINE" ]; do
  if [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then boot_ready=1; break; fi
  kill -0 "$EMULATOR_PID" 2>/dev/null || break
  sleep 1
done
[ "$boot_ready" = 1 ] || { echo "Android boot timed out after 240 seconds" >&2; exit 1; }

if [ ! -f "$BRIDGE_APK" ]; then
  build_script="${TVBOX_BRIDGE_BUILD_SCRIPT:-$PROJECT_DIR/scripts/build_spider_bridge.sh}"
  [ -x "$build_script" ] || { echo "missing bridge APK and build script: $build_script" >&2; exit 1; }
  "$build_script"
fi
bounded 60 "$ADB" -s "$SERIAL" install -r "$BRIDGE_APK"
adb -s "$SERIAL" forward --no-rebind "tcp:$PORT" "tcp:$PORT"
FORWARD_CREATED=1
adb -s "$SERIAL" shell am start-foreground-service -n com.tvbox.bridge/.SpiderBridgeService --es token "$TOKEN" --ei port "$PORT"

# Probe the authenticated endpoint throughout the session, not just at boot.
for _ in $(seq 1 60); do
  if healthy; then
    echo "[$(date)] Spider service ready"
    failures=0
    recoveries=0
    recovery_window=$SECONDS
    while kill -0 "$PARENT_PID" >/dev/null 2>&1; do
      kill -0 "$EMULATOR_PID" 2>/dev/null || { echo "Android emulator exited" >&2; exit 1; }
      if healthy; then
        failures=0
      else
        failures=$((failures + 1))
        if [ "$failures" -ge 3 ] || [ "$RESTART_REQUIRED" = 1 ]; then
          if [ $((SECONDS - recovery_window)) -ge 300 ]; then recoveries=0; recovery_window=$SECONDS; fi
          recoveries=$((recoveries + 1))
          [ "$recoveries" -le 3 ] || { echo "Spider recovery limit reached (3 in 5 minutes)" >&2; exit 1; }
          echo "[$(date)] Spider health lost; restarting bridge (attempt=$recoveries)"
          adb -s "$SERIAL" logcat -d -b crash > "$LOG_DIR/bridge-crash-$(date +%Y%m%d-%H%M%S).log" 2>&1 || true
          adb -s "$SERIAL" shell am force-stop com.tvbox.bridge || true
          adb -s "$SERIAL" forward "tcp:$PORT" "tcp:$PORT" || true
          adb -s "$SERIAL" shell am start-foreground-service -n com.tvbox.bridge/.SpiderBridgeService --es token "$TOKEN" --ei port "$PORT" || true
          failures=0
        fi
      fi
      sleep 2
    done
    exit 0
  fi
  kill -0 "$EMULATOR_PID" 2>/dev/null || break
  sleep 1
done
echo "Android Spider service did not become healthy within 60 seconds" >&2
exit 1
