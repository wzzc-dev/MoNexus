#!/usr/bin/env bash
# MoNexus M3 — workspace / worktree / lease / terminal smoke test.
#
# Thin OS wrapper around the native `services/smoke-harness` executable. Shell
# owns the temp HOME/state, fixture repository, ephemeral loopback sshd, host
# start/stop/restart and cleanup; MoonBit owns all RPC, JSON and assertions.
#
# The SSH section starts a non-root sshd on a random loopback port with a temp
# HOME and explicit temp known_hosts file. It never writes to the real user's
# ~/.ssh. If sshd/ssh/tmux are unavailable the harness reports SKIP.
#
# Usage:
#   bash scripts/workspace_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/workspace_smoke.sh
#   SMOKE_HARNESS_BIN=/path/to/smoke-harness.exe bash scripts/workspace_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_HOST_BIN="$ROOT/_build/native/debug/build/monexus/host/host.exe"
DEFAULT_HARNESS_BIN="$ROOT/_build/native/debug/build/monexus/smoke-harness/smoke-harness.exe"
HOST_BIN="${MONEXUS_SMOKE_HOST_BIN:-${HOST_BIN:-$DEFAULT_HOST_BIN}}"
HARNESS_BIN="${SMOKE_HARNESS_BIN:-$DEFAULT_HARNESS_BIN}"
MODE="${1:-}"

start_host() { # state_dir
  local state="$1"
  mkdir -p "$state"
  "$HOST_BIN" serve --state-dir "$state" --heartbeat-ms 60000 >"$state/.log" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$HOST_PIDFILE"
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if "$HOST_BIN" status --state-dir "$state" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$state/.log" >&2 || true
      return 1
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  cat "$state/.log" >&2 || true
  return 1
}

stop_host() {
  local pid=""
  if [ -f "$HOST_PIDFILE" ]; then
    pid="$(cat "$HOST_PIDFILE" 2>/dev/null || true)"
  fi
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    local tries=0
    while [ "$tries" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
      tries=$((tries + 1))
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$HOST_PIDFILE"
}

# The harness calls this mode between its local and restart-persistence
# sections. It must not tear down the temp fixture or sshd.
if [ "$MODE" = "--restart-host" ]; then
  set -euo pipefail
  STATE="${MONEXUS_SMOKE_STATE_DIR:-}"
  HOST_PIDFILE="${MONEXUS_SMOKE_HOST_PIDFILE:-}"
  if [ -z "$STATE" ] || [ -z "$HOST_PIDFILE" ]; then
    printf 'restart mode requires MONEXUS_SMOKE_STATE_DIR and MONEXUS_SMOKE_HOST_PIDFILE\n' >&2
    exit 2
  fi
  if [ ! -x "$HOST_BIN" ]; then
    printf 'host binary missing: %s\n' "$HOST_BIN" >&2
    exit 2
  fi
  stop_host
  start_host "$STATE"
  exit 0
fi

set -e

REAL_USER="$(id -un)"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_HOME" ] || REAL_HOME="${HOME:-/root}"
REAL_SSH_DIR="$REAL_HOME/.ssh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m3-smoke.XXXXXX")"
mkdir -p "$WORK/home"
export HOME="$WORK/home"
export PATH="$ROOT/.moon/bin:$PATH"

STATE="$WORK/state"
HOST_PIDFILE="$WORK/host.pid"
SSHD_PID=""
SSH_TMP=""
SECONDS=0

cleanup() {
  if [ -n "$SSHD_PID" ]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  stop_host
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -x "$HOST_BIN" ]; then
  printf 'host binary missing: %s\nrun: moon build --target native\n' "$HOST_BIN" >&2
  exit 2
fi
if [ ! -x "$HARNESS_BIN" ]; then
  printf 'smoke harness missing: %s\nrun: moon build --target native services/smoke-harness\n' "$HARNESS_BIN" >&2
  exit 2
fi

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" -c init.defaultBranch=master init -q
git -C "$REPO" config user.email smoke@example.invalid
git -C "$REPO" config user.name Smoke
printf 'hello m3\n' >"$REPO/README.md"
printf 'second\n' >"$REPO/notes.txt"
git -C "$REPO" add README.md notes.txt
git -C "$REPO" commit -qm 'initial'

export MONEXUS_SMOKE_WORK="$WORK"
export MONEXUS_SMOKE_STATE_DIR="$STATE"
export MONEXUS_SMOKE_REPO="$REPO"
export MONEXUS_SMOKE_REMOTE_ROOT="$REPO"
export MONEXUS_SMOKE_HOST_BIN="$HOST_BIN"
export MONEXUS_SMOKE_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
export MONEXUS_SMOKE_HOST_PIDFILE="$HOST_PIDFILE"
export MONEXUS_SMOKE_REAL_SSH_DIR="$REAL_SSH_DIR"
export MONEXUS_SMOKE_SSH_AVAILABLE=0
export MONEXUS_SMOKE_SSH_READY=0
export MONEXUS_SMOKE_SSH_PORT=0
export MONEXUS_SMOKE_SSH_USER="$REAL_USER"
export MONEXUS_SMOKE_SSH_IDENTITY=""
export MONEXUS_SMOKE_KNOWN_HOSTS=""
export MONEXUS_SMOKE_SSHD_LOG=""

SSHD_BIN="$(command -v sshd || true)"
if [ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ]; then
  SSHD_BIN=/usr/sbin/sshd
fi
if [ -z "$SSHD_BIN" ] || ! command -v ssh >/dev/null 2>&1 \
  || ! command -v ssh-keygen >/dev/null 2>&1 \
  || ! command -v tmux >/dev/null 2>&1; then
  export MONEXUS_SMOKE_SSH_AVAILABLE=0
else
  export MONEXUS_SMOKE_SSH_AVAILABLE=1
  SSH_TMP="$WORK/sshd"
  mkdir -p "$SSH_TMP"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_TMP/host_ed25519"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_TMP/client_ed25519"
  cp "$SSH_TMP/client_ed25519.pub" "$SSH_TMP/authorized_keys"
  chmod 600 "$SSH_TMP/authorized_keys"
  SSH_PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo $((20000 + RANDOM % 20000)))"
  cat >"$SSH_TMP/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $SSH_TMP/host_ed25519
PidFile $SSH_TMP/sshd.pid
AuthorizedKeysFile $SSH_TMP/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin no
AllowUsers $REAL_USER
LogLevel ERROR
EOF
  "$SSHD_BIN" -D -f "$SSH_TMP/sshd_config" -E "$SSH_TMP/sshd.log" &
  SSHD_PID=$!
  READY=0
  for _ in $(seq 1 100); do
    if kill -0 "$SSHD_PID" 2>/dev/null \
      && ss -ltn 2>/dev/null | grep -Fq "127.0.0.1:$SSH_PORT"; then
      READY=1
      break
    fi
    sleep 0.1
  done
  KNOWN_HOSTS="$WORK/known_hosts-loop"
  export MONEXUS_SMOKE_SSH_PORT="$SSH_PORT"
  export MONEXUS_SMOKE_SSH_IDENTITY="$SSH_TMP/client_ed25519"
  export MONEXUS_SMOKE_KNOWN_HOSTS="$KNOWN_HOSTS"
  export MONEXUS_SMOKE_SSHD_LOG="$SSH_TMP/sshd.log"
  if [ "$READY" -eq 1 ]; then
    export MONEXUS_SMOKE_SSH_READY=1
  fi
fi

mkdir -p "$STATE"
printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s\n\n' "$WORK"

if ! start_host "$STATE"; then
  printf 'host did not start\n' >&2
  exit 1
fi

set +e
"$HARNESS_BIN" workspace
STATUS=$?
set -e

ELAPSED="$(awk "BEGIN { printf \"%.2f\", $SECONDS }")"
printf 'SMOKE_ELAPSED=%s\n' "$ELAPSED"
exit "$STATUS"
