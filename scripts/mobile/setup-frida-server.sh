#!/usr/bin/env bash
# Push the frida-server binary that is baked into this image (version-matched to
# the frida CLI) to a connected Android device/emulator over adb, then start it.
#
# Usage (inside the ARTEX container, as the agent runs it through Bash):
#   bash /app/scripts/mobile/setup-frida-server.sh
#   ADB_SERIAL=emulator-5554 bash /app/scripts/mobile/setup-frida-server.sh
#
# Device prerequisites: adb connected (adb connect <host>:5555 for network
# devices) and root (adb root on emulator images, or su via Magisk on rooted
# devices). The script never installs anything on the host.
set -euo pipefail

FRIDA_VERSION="$(frida --version)"
FRIDA_SERVER_DIR="${FRIDA_SERVER_DIR:-/opt/frida-server-android}"
SERIAL_ARGS=()
if [ -n "${ADB_SERIAL:-}" ]; then
  SERIAL_ARGS=(-s "$ADB_SERIAL")
fi

command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
command -v frida >/dev/null || { echo "frida CLI not found" >&2; exit 1; }

echo "connected devices:"
adb "${SERIAL_ARGS[@]}" devices

ABI="$(adb "${SERIAL_ARGS[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$ABI" in
  arm64-v8a)   BAKED=arm64 ;;
  armeabi-v7a) BAKED=arm ;;
  x86_64)      BAKED=x86_64 ;;
  *) echo "unsupported device ABI: $ABI (supported: arm64-v8a, armeabi-v7a, x86_64)" >&2; exit 1 ;;
esac

SRC="$FRIDA_SERVER_DIR/frida-server-${FRIDA_VERSION}-android-${BAKED}"
if [ ! -f "$SRC" ]; then
  echo "no baked frida-server for abi '$BAKED' at $SRC" >&2
  echo "expected version ${FRIDA_VERSION}; check /opt/frida-server-android/" >&2
  exit 1
fi

echo "pushing frida-server ${FRIDA_VERSION} (${BAKED}) -> /data/local/tmp/frida-server"
adb "${SERIAL_ARGS[@]}" push "$SRC" /data/local/tmp/frida-server

# Start as root: try adb root first (emulator images), then su (rooted devices).
# A pre-existing frida-server (wrong version) is stopped first so the CLI and
# the server never drift apart.
adb "${SERIAL_ARGS[@]}" root >/dev/null 2>&1 || true
adb "${SERIAL_ARGS[@]}" shell "su -c 'pkill frida-server' >/dev/null 2>&1 || pkill frida-server >/dev/null 2>&1 || true"
adb "${SERIAL_ARGS[@]}" shell "su -c 'chmod 755 /data/local/tmp/frida-server' || chmod 755 /data/local/tmp/frida-server"
adb "${SERIAL_ARGS[@]}" shell "su -c 'nohup /data/local/tmp/frida-server >/dev/null 2>&1 &' || nohup /data/local/tmp/frida-server >/dev/null 2>&1 &"
sleep 2

echo "device processes visible through frida (first 10):"
frida-ps -U 2>/dev/null | head -11 || {
  echo "frida-ps -U failed: frida-server is not reachable." >&2
  echo "check root on the device (adb root / su) and try again." >&2
  exit 1
}
