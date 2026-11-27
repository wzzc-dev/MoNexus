#!/usr/bin/env bash
# MoNexus V0.1 launcher.
#
#   monexus                 start/reuse the host, then open the desktop window
#   monexus start [flags]   same; --headless skips the window
#   monexus status          show host.json / host.status
#   monexus stop            stop a host started by this launcher
#   monexus host <args...>  run the host CLI (machine add, rpc, ...)
#   monexus version         print the product and component versions
#
# Works from the repository (release build first, then debug) and from an
# installed layout:
#   bin/monexus  bin/monexus-host  bin/monexus-desktop  share/monexus/
set -u -o pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
  Darwin) HOST_OS=macos; DESKTOP_DIR=macos_skia ;;
  Linux) HOST_OS=linux; DESKTOP_DIR=linux_skia ;;
  *) HOST_OS=unknown; DESKTOP_DIR=linux_skia ;;
esac
INSTALLED=0
if [[ -d "$SELF/../share/monexus" && -x "$SELF/monexus-host" ]]; then
  INSTALLED=1
  SHARE="$(cd "$SELF/../share/monexus" && pwd)"
  ROOT="$(cd "$SELF/.." && pwd)"
else
  ROOT="$(cd "$SELF/.." && pwd)"
  SHARE="$ROOT"
fi

pick_bin() { # candidate...
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

if [[ "$INSTALLED" == "1" ]]; then
  HOST_BIN="${MONEXUS_HOST_BIN:-$SELF/monexus-host}"
  DESKTOP_BIN="${MONEXUS_DESKTOP_BIN:-$SELF/monexus-desktop}"
else
  HOST_BIN="${MONEXUS_HOST_BIN:-$(pick_bin \
    "$ROOT/_build/native/release/build/monexus/host/host.exe" \
    "$ROOT/_build/native/debug/build/monexus/host/host.exe" || true)}"
  DESKTOP_BIN="${MONEXUS_DESKTOP_BIN:-$(pick_bin \
    "$ROOT/_build/native/release/build/monexus/desktop/$DESKTOP_DIR/$DESKTOP_DIR.exe" \
    "$ROOT/_build/native/debug/build/monexus/desktop/$DESKTOP_DIR/$DESKTOP_DIR.exe" || true)}"
fi

version_of() { # file
  if [[ -f "$1" ]]; then head -n 1 "$1" | tr -d '[:space:]'; else echo "unknown"; fi
}
VERSION="$(version_of "$SHARE/VERSION")"

usage() {
  cat <<'USAGE'
usage: monexus [start] [--headless] [--state-dir DIR] [--no-keep-alive]
       monexus status [--state-dir DIR]
       monexus stop [--state-dir DIR]
       monexus version
       monexus host <monexus-host args...>

start (default):
  Reuses an online host, otherwise starts `monexus-host serve` detached and
  waits for host.json, then opens the desktop window. The host keeps running
  after the window closes (keep-alive); pass --no-keep-alive to stop a host
  started by this invocation.

  --headless        do not open a window; print the host endpoint and exit
  --state-dir DIR   state directory (default $MONEXUS_STATE_DIR, else
                    $HOME/.monexus)
  --no-keep-alive   stop the host when the desktop exits

Platforms:
  Linux uses the Skia/Wayland or X11 entry; macOS uses the Skia/AppKit entry.
  A GUI login session is required for the macOS window.

Environment:
  MONEXUS_HOST_BIN, MONEXUS_DESKTOP_BIN  override component paths
USAGE
}

STATE_DIR=""
HEADLESS=0
KEEP_ALIVE=1
POSITIONAL=()
ARGS=("$@")
INDEX=0
while [[ "$INDEX" -lt "${#ARGS[@]}" ]]; do
  arg="${ARGS[$INDEX]}"
  case "$arg" in
    --state-dir) INDEX=$((INDEX + 1)); STATE_DIR="${ARGS[$INDEX]:-}" ;;
    --state-dir=*) STATE_DIR="${arg#--state-dir=}" ;;
    --headless|--no-desktop) HEADLESS=1 ;;
    --no-keep-alive) KEEP_ALIVE=0 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
  INDEX=$((INDEX + 1))
done
COMMAND="${POSITIONAL[0]:-start}"
if [[ "$COMMAND" == "start" && "${#POSITIONAL[@]}" -gt 1 ]]; then
  echo "monexus: unknown start argument: ${POSITIONAL[1]}" >&2
  exit 2
fi
if [[ -z "$STATE_DIR" ]]; then
  STATE_DIR="${MONEXUS_STATE_DIR:-${HOME:-}/.monexus}"
fi
if [[ -z "$STATE_DIR" || "$STATE_DIR" == "/.monexus" ]]; then
  echo "monexus: cannot determine the state directory (HOME is unset); pass --state-dir" >&2
  exit 2
fi
export MONEXUS_STATE_DIR="$STATE_DIR"
PID_FILE="$STATE_DIR/host.pid"
HOST_LOG="$STATE_DIR/logs/host.log"

require_host_bin() {
  if [[ -z "$HOST_BIN" || ! -x "$HOST_BIN" ]]; then
    echo "monexus: monexus-host binary not found." >&2
    echo "  build it with: moon build --target native --release" >&2
    echo "  or install the release tarball (see README 'Install')." >&2
    exit 1
  fi
}

host_online() {
  [[ -x "$HOST_BIN" ]] && "$HOST_BIN" status --state-dir "$STATE_DIR" >/dev/null 2>&1
}

json_string() { # key file
  sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$2" 2>/dev/null | head -n 1
}

file_mode() { # path
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}

print_endpoint() {
  local host_json="$STATE_DIR/host.json"
  if [[ -f "$host_json" ]]; then
    echo "state dir:  $STATE_DIR"
    echo "host.json:  $host_json (mode $(file_mode "$host_json"))"
    echo "endpoint:   $(json_string ws_url "$host_json")"
    if [[ -n "$(json_string token "$host_json")" ]]; then
      echo "token:      present (stored only in host.json; never printed)"
    else
      echo "token:      missing"
    fi
  else
    echo "state dir:  $STATE_DIR (host.json not written)"
  fi
}

wait_for_host() {
  local tries=0
  while [[ "$tries" -lt 150 ]]; do
    if host_online; then return 0; fi
    if [[ -f "$PID_FILE" ]] && ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
      return 1
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

start_host() {
  local started_here=0
  if host_online; then
    echo "monexus: host already running; reusing it"
    print_endpoint
    return 2
  fi
  if [[ ! -x "$HOST_BIN" ]]; then
    require_host_bin
  fi
  mkdir -p "$STATE_DIR/logs"
  # Detached so closing the window does not take the host down. keepAlive is
  # the default (architecture §7.2).
  nohup "$HOST_BIN" serve --state-dir "$STATE_DIR" >>"$HOST_LOG" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  started_here=1
  if ! wait_for_host; then
    echo "monexus: host did not become ready; last lines of $HOST_LOG:" >&2
    tail -n 20 "$HOST_LOG" >&2 2>/dev/null || true
    return 1
  fi
  echo "monexus: host started (pid $pid)"
  print_endpoint
  return 0
}

stop_host() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then pid="$(cat "$PID_FILE" 2>/dev/null || true)"; fi
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local tries=0
    while [[ "$tries" -lt 50 ]] && kill -0 "$pid" 2>/dev/null; do
      tries=$((tries + 1)); sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "monexus: host stopped (pid $pid)"
    return 0
  fi
  rm -f "$PID_FILE"
  if host_online; then
    echo "monexus: a host is online but was not started by this launcher." >&2
    echo "  stop it from the terminal that owns it (Ctrl-C), or find its pid." >&2
    return 1
  fi
  echo "monexus: host is not running"
  return 0
}

case "$COMMAND" in
  start|"")
    require_host_bin
    start_host
    started=$?
    if [[ "$started" == "1" ]]; then exit 1; fi
    if [[ "$HEADLESS" == "1" ]]; then
      echo
      echo "headless: host is running. Next steps:"
      echo "  monexus status"
      echo "  monexus host machine add --kind local"
      echo "  monexus host machine add --host <ssh-host> --user <user>"
      echo "  monexus host rpc --method host.status --params '{}'"
      echo "  monexus stop"
      exit 0
    fi
    if [[ -z "$DESKTOP_BIN" || ! -x "$DESKTOP_BIN" ]]; then
      echo "monexus: desktop binary not found." >&2
      echo "  build it with: moon build --target native --release" >&2
      exit 1
    fi
    if [[ "$HOST_OS" == "linux" && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
      echo "monexus: no display server found (DISPLAY and WAYLAND_DISPLAY are unset)." >&2
      echo "  The host is running. Use headless mode on this machine:" >&2
      echo "    monexus start --headless" >&2
      echo "    monexus status" >&2
      echo "    monexus host rpc --method host.status --params '{}'" >&2
      echo "  Or open the window under a display server:" >&2
      echo "    xvfb-run -a monexus" >&2
      exit 3
    fi
    echo "monexus: opening desktop ($DESKTOP_BIN)"
    "$DESKTOP_BIN"
    code=$?
    if [[ "$KEEP_ALIVE" == "0" && "$started" == "0" ]]; then
      stop_host || true
    fi
    exit "$code"
    ;;
  status)
    require_host_bin
    if ! host_online; then
      echo "monexus: host offline ($STATE_DIR)"
      print_endpoint
      exit 1
    fi
    "$HOST_BIN" status --state-dir "$STATE_DIR"
    print_endpoint
    ;;
  stop)
    require_host_bin
    stop_host
    ;;
  version|--version|-V)
    echo "monexus $VERSION"
    if [[ -x "$HOST_BIN" ]]; then "$HOST_BIN" version; else echo "monexus-host (not built)"; fi
    if [[ -x "$DESKTOP_BIN" ]]; then "$DESKTOP_BIN" --version; else echo "monexus-desktop (not built)"; fi
    ;;
  help|--help|-h)
    usage
    ;;
  host)
    require_host_bin
    exec "$HOST_BIN" "${POSITIONAL[@]:1}"
    ;;
  *)
    echo "monexus: unknown command: $COMMAND" >&2
    usage >&2
    exit 2
    ;;
esac
