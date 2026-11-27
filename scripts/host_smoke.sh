#!/usr/bin/env bash
# M1 host smoke test: start host -> status -> subscribe -> auth/lock checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$(mktemp -d /tmp/monexus-smoke.XXXXXX)"
HOST_LOG="$STATE_DIR/host.log"
HOST_PID=""

cleanup() {
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill -TERM "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  rm -rf "$STATE_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$HOST_LOG" ]]; then
    echo "--- host log ---" >&2
    cat "$HOST_LOG" >&2
  fi
  exit 1
}

cd "$ROOT"
export PATH="$HOME/.moon/bin:${PATH}"
echo "[1/6] build host"
# Scope this build to the host OS; a root-wide build also compiles the other
# platform's desktop entry and fails on Linux/macOS respectively.
packages="$(bash "$ROOT/scripts/native_packages.sh")" || exit 1
moon build --target native $packages >/dev/null

BIN="$(find "$ROOT/_build/native" -type f -path '*monexus/host/host.exe' | head -n 1)"
[[ -n "$BIN" && -x "$BIN" ]] || fail "host binary not found; run moon build --target native"

echo "[2/6] start host on a random loopback port"
"$BIN" serve --state-dir "$STATE_DIR" --heartbeat-ms 200 >"$HOST_LOG" 2>&1 &
HOST_PID=$!
for _ in $(seq 1 100); do
  [[ -f "$STATE_DIR/host.json" ]] && break
  sleep 0.1
done
[[ -f "$STATE_DIR/host.json" ]] || fail "host.json was not written"

MODE="$(stat -c '%a' "$STATE_DIR/host.json" 2>/dev/null || stat -f '%Lp' "$STATE_DIR/host.json" 2>/dev/null || echo '?')"
[[ "$MODE" == "600" ]] || fail "host.json mode is $MODE, expected 600"
echo "      host.json mode=$MODE pid=$HOST_PID"

echo "[3/6] client status"
STATUS="$("$BIN" status --state-dir "$STATE_DIR")"
echo "$STATUS" | grep -q '^host online$' || fail "status did not report online"
echo "$STATUS" | grep -q '^ws_url=ws://127\.0\.0\.1:' || fail "status missing ws_url"

echo "[4/6] subscribe receives a heartbeat event"
EVENTS="$("$BIN" subscribe --state-dir "$STATE_DIR" --timeout-ms 4000 --max-events 1)"
echo "$EVENTS" | grep -q 'type=host.heartbeat' || fail "no heartbeat event received"

echo "[5/6] second instance is rejected by the single-instance lock"
set +e
SECOND="$("$BIN" serve --state-dir "$STATE_DIR" 2>&1)"
SECOND_CODE=$?
set -e
[[ "$SECOND_CODE" -ne 0 ]] || fail "second instance unexpectedly started"
echo "$SECOND" | grep -q 'already running' || fail "second instance did not report the lock"

echo "[6/6] wrong Bearer token is rejected with 401"
WS_URL="$("$BIN" status --state-dir "$STATE_DIR" | sed -n 's/^ws_url=//p')"
python3 - "$WS_URL" <<'PY'
import base64
import os
import socket
import sys
import urllib.parse

url = urllib.parse.urlparse(sys.argv[1])
host = url.hostname
port = url.port or 80
path = url.path or "/"
key = base64.b64encode(os.urandom(16)).decode()
request = (
    f"GET {path} HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    "Authorization: Bearer wrong-token\r\n"
    "\r\n"
)
with socket.create_connection((host, port), timeout=5) as sock:
    sock.sendall(request.encode())
    response = sock.recv(4096).decode(errors="replace")
status_line = response.splitlines()[0] if response else ""
if " 401 " not in status_line:
    raise SystemExit(f"expected 401, got: {status_line!r}")
print("      401 received")
PY

echo "PASS: host smoke test"
