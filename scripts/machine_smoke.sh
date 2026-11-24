#!/usr/bin/env bash
# MoNexus M2 — machine registry + SSH probe smoke test.
#
# TEST HARNESS ONLY. It starts an ephemeral, non-root sshd on a random
# loopback port plus a fake `ssh` binary for error classification. It never
# writes to the real user's ~/.ssh: every add passes an explicit temp
# known_hosts file, and the script snapshots ~/.ssh before/after to prove it.
#
# Usage:
#   bash scripts/machine_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/machine_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
REAL_USER="$(id -un)"
REAL_SSH_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)/.ssh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m2-smoke.XXXXXX")"
mkdir -p "$WORK/home" "$WORK/bin"
export HOME="$WORK/home"
export PATH="$ROOT/.moon/bin:$PATH"

PASSED=0
FAILED=0
SKIPPED=0
SSHD_PID=""
HOST_PID=""

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "--- output ---" "$2" "--------------" >&2; fi
}
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s\n' "$1"; }

contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then
    pass "$1"
  else
    fail "$1 (missing: $2)" "$3"
  fi
}

not_contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then
    fail "$1 (unexpected: $2)" "$3"
  else
    pass "$1"
  fi
}

cleanup() {
  if [ -n "$HOST_PID" ]; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  if [ -n "$SSHD_PID" ]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh_snapshot() {
  if [ -d "$REAL_SSH_DIR" ]; then
    find "$REAL_SSH_DIR" -maxdepth 1 -type f -printf '%f %s %T@\n' 2>/dev/null | sort
  fi
}
SSH_BEFORE="$(ssh_snapshot)"

summary() {
  printf '\nSUMMARY  passed=%d failed=%d skipped=%d\n' \
    "$PASSED" "$FAILED" "$SKIPPED"
  [ "$FAILED" -eq 0 ]
}

if [ ! -x "$HOST_BIN" ]; then
  printf 'host binary missing: %s\nrun: moon build --target native\n' "$HOST_BIN" >&2
  exit 2
fi

start_host() { # state_dir
  local state="$1"
  "$HOST_BIN" serve --state-dir "$state" --heartbeat-ms 60000 \
    >"$state/.log" 2>&1 &
  HOST_PID=$!
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if "$HOST_BIN" status --state-dir "$state" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
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
  if [ -n "$HOST_PID" ]; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
    HOST_PID=""
  fi
}

machine_id_from() { # text
  printf '%s\n' "$1" | sed -n 's/^id=//p' | head -n 1
}

printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s\n\n' "$WORK"

printf '== 1. loopback sshd (ephemeral, non-root) ==\n'
SSHD_BIN="$(command -v sshd || true)"
[ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ] && SSHD_BIN=/usr/sbin/sshd
if [ -z "$SSHD_BIN" ]; then
  skip 'ephemeral sshd is not installed; loopback probe section skipped'
elif ! command -v ssh >/dev/null 2>&1; then
  skip 'ssh client missing; loopback probe section skipped'
else
  SSH_TMP="$WORK/sshd"
  mkdir -p "$SSH_TMP"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_TMP/host_ed25519"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_TMP/client_ed25519"
  cp "$SSH_TMP/client_ed25519.pub" "$SSH_TMP/authorized_keys"
  chmod 600 "$SSH_TMP/authorized_keys"
  SSH_PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo $((20000 + RANDOM % 20000)))"
  cat > "$SSH_TMP/sshd_config" <<EOF
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
    if kill -0 "$SSHD_PID" 2>/dev/null &&
      ss -ltn 2>/dev/null | grep -Fq "127.0.0.1:$SSH_PORT"; then
      READY=1
      break
    fi
    sleep 0.1
  done
  if [ "$READY" -eq 1 ]; then
    pass "ephemeral sshd on 127.0.0.1:$SSH_PORT"
  else
    fail 'ephemeral sshd did not start' "$(cat "$SSH_TMP/sshd.log" 2>/dev/null || true)"
  fi

  if [ "$READY" -eq 1 ]; then
    STATE="$WORK/state-loop"
    mkdir -p "$STATE"
    KH="$WORK/known_hosts-loop"
    if start_host "$STATE"; then
      pass 'host started with SQLite state dir'
    else
      fail 'host started'
    fi
    [ -f "$STATE/monexus.db" ] && pass 'monexus.db created' || fail 'monexus.db created'

    ADD_OUT="$("$HOST_BIN" machine add --state-dir "$STATE" \
      --name loopback --host 127.0.0.1 --port "$SSH_PORT" \
      --user "$REAL_USER" --identity "$SSH_TMP/client_ed25519" \
      --use-ssh-config false --host-key-policy accept-new \
      --known-hosts-file "$KH" 2>&1)"
    ADD_CODE=$?
    if [ "$ADD_CODE" -eq 0 ]; then pass 'machine add exit 0'; else fail 'machine add exit 0' "$ADD_OUT"; fi
    contains 'add stored an id' 'id=mch_' "$ADD_OUT"
    contains 'add recorded ssh -G hostname' 'ssh_effective.hostname=127.0.0.1' "$ADD_OUT"
    contains 'add recorded ssh -G port' "ssh_effective.port=$SSH_PORT" "$ADD_OUT"
    contains 'add recorded explicit use_ssh_config' 'use_ssh_config=false' "$ADD_OUT"
    ID="$(machine_id_from "$ADD_OUT")"
    [ -n "$ID" ] && pass 'machine id parsed' || fail 'machine id parsed' "$ADD_OUT"

    LIST_OUT="$("$HOST_BIN" machine list --state-dir "$STATE" 2>&1)"
    contains 'list shows the new machine' "machine id=$ID" "$LIST_OUT"
    contains 'list status is unknown before probe' 'status=unknown' "$LIST_OUT"

    PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$ID" \
      --timeout-seconds 15 2>&1)"
    PROBE_CODE=$?
    if [ "$PROBE_CODE" -eq 0 ]; then pass 'machine probe exit 0'; else fail 'machine probe exit 0' "$PROBE_OUT"; fi
    contains 'probe status online' 'status=online' "$PROBE_OUT"
    contains 'probe os' 'profile.os=Linux' "$PROBE_OUT"
    contains 'probe arch' 'profile.arch=' "$PROBE_OUT"
    contains 'probe hostname' 'profile.hostname=' "$PROBE_OUT"
    contains 'probe shell' 'profile.shell=' "$PROBE_OUT"
    contains 'probe max_parallel' 'profile.max_parallel=' "$PROBE_OUT"
    contains 'probe found git' 'profile.tool.git=' "$PROBE_OUT"

    LIST_OUT="$("$HOST_BIN" machine list --state-dir "$STATE" 2>&1)"
    contains 'list status online after probe' 'status=online' "$LIST_OUT"

    EVENTS="$("$HOST_BIN" subscribe --state-dir "$STATE" --since 0 \
      --max-events 3 --timeout-ms 4000 2>&1)"
    contains 'events include machine.registered' 'type=machine.registered' "$EVENTS"
    contains 'events include machine.connected' 'type=machine.connected' "$EVENTS"
    contains 'events include machine.probed' 'type=machine.probed' "$EVENTS"

    stop_host
    if start_host "$STATE"; then
      pass 'host restarted on the same state dir'
    else
      fail 'host restarted'
    fi
    LIST_OUT="$("$HOST_BIN" machine list --state-dir "$STATE" 2>&1)"
    contains 'machine survives a host restart' "machine id=$ID" "$LIST_OUT"
    contains 'probe result survives a host restart' 'status=online' "$LIST_OUT"
    PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$ID" \
      --timeout-seconds 15 2>&1)"
    contains 're-probe after restart still online' 'status=online' "$PROBE_OUT"
    contains 're-probe after restart returns the profile' 'profile.os=Linux' "$PROBE_OUT"

    REMOVE_OUT="$("$HOST_BIN" machine remove --state-dir "$STATE" --id "$ID" 2>&1)"
    REMOVE_CODE=$?
    if [ "$REMOVE_CODE" -eq 0 ]; then pass 'machine remove exit 0'; else fail 'machine remove exit 0' "$REMOVE_OUT"; fi
    contains 'remove echoes the id' "machine removed id=$ID" "$REMOVE_OUT"
    LIST_OUT="$("$HOST_BIN" machine list --state-dir "$STATE" 2>&1)"
    contains 'list is empty after remove' 'machines=0' "$LIST_OUT"
    not_contains 'removed machine is not listed' "machine id=$ID" "$LIST_OUT"

    PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$ID" 2>&1)"
    PROBE_CODE=$?
    if [ "$PROBE_CODE" -ne 0 ]; then pass 'probing a removed machine fails'; else fail 'probing a removed machine fails' "$PROBE_OUT"; fi
    contains 'removed probe reason is NotFound' 'NotFound' "$PROBE_OUT"

    EVENTS="$("$HOST_BIN" subscribe --state-dir "$STATE" --since 0 \
      --max-events 5 --timeout-ms 4000 2>&1)"
    contains 'events include machine.removed (tombstone)' 'type=machine.removed' "$EVENTS"

    stop_host
  fi
fi

printf '\n== 2. fake ssh: readable Unauthorized/Timeout/NotFound/degraded ==\n'
cat > "$WORK/bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
# Fake ssh for smoke tests. Emulates `ssh -G` and classifiable failures.
mode=""
dest=""
skip=0
for ((i=1; i<=$#; i++)); do
  a="${!i}"
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -G) mode="g" ;;
    -o|-p|-i|-F) skip=1 ;;
    -*) : ;;
    *) dest="$a"; break ;;
  esac
done
host="${dest##*@}"
user="${dest%@*}"
[ "$user" = "$dest" ] && user="fakeuser"
if [ "$mode" = "g" ]; then
  printf 'hostname %s\nuser %s\nport 22\nidentityfile ~/.ssh/id_rsa\n' "$host" "$user"
  exit 0
fi
case "$host" in
  auth.invalid)
    printf 'fakeuser@auth.invalid: Permission denied (publickey).\n' >&2
    exit 255 ;;
  missing.invalid)
    printf 'ssh: Could not resolve hostname missing.invalid: Name or service not known\n' >&2
    exit 255 ;;
  timedout.invalid)
    printf 'ssh: connect to host timedout.invalid port 22: Connection timed out\n' >&2
    exit 255 ;;
  degraded.invalid)
    printf 'HOSTNAME=partial\n'
    exit 0 ;;
  *)
    printf 'OS=Linux\nARCH=fake\nKERNEL=0\nHOSTNAME=fakehost\nSHELL=/bin/sh\nCPUS=4\nDOCKER=\nGUI=no\nTOOL=git=\n'
    exit 0 ;;
esac
FAKE_SSH
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

FAKE_STATE="$WORK/state-fake"
mkdir -p "$FAKE_STATE"
KH="$WORK/known_hosts-fake"
if start_host "$FAKE_STATE"; then
  pass 'fake-ssh host started'
else
  fail 'fake-ssh host started'
fi

fake_add() { # host
  "$HOST_BIN" machine add --state-dir "$FAKE_STATE" \
    --host "$1" --user tester --identity "$WORK/home/key" \
    --use-ssh-config false --known-hosts-file "$KH" 2>&1
}

AUTH_OUT="$(fake_add auth.invalid)"
contains 'fake add uses ssh -G without touching the network' 'ssh_effective.hostname=auth.invalid' "$AUTH_OUT"
AUTH_ID="$(machine_id_from "$AUTH_OUT")"
PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$FAKE_STATE" --id "$AUTH_ID" --timeout-seconds 2 2>&1)"
PROBE_CODE=$?
if [ "$PROBE_CODE" -ne 0 ]; then pass 'auth failure exits non-zero'; else fail 'auth failure exits non-zero' "$PROBE_OUT"; fi
contains 'auth failure is Unauthorized' 'Unauthorized' "$PROBE_OUT"
LIST_OUT="$("$HOST_BIN" machine list --state-dir "$FAKE_STATE" 2>&1)"
contains 'auth failure sets offline' 'status=offline' "$LIST_OUT"
contains 'auth failure stored as readable reason' 'last_error=Unauthorized: SSH authentication failed' "$LIST_OUT"

MISSING_ID="$(machine_id_from "$(fake_add missing.invalid)")"
PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$FAKE_STATE" --id "$MISSING_ID" --timeout-seconds 2 2>&1)"
contains 'resolve failure is NotFound' 'NotFound' "$PROBE_OUT"
LIST_OUT="$("$HOST_BIN" machine list --state-dir "$FAKE_STATE" 2>&1)"
contains 'resolve failure stored as readable reason' 'last_error=NotFound: SSH host could not be resolved' "$LIST_OUT"

TIMEOUT_ID="$(machine_id_from "$(fake_add timedout.invalid)")"
PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$FAKE_STATE" --id "$TIMEOUT_ID" --timeout-seconds 2 2>&1)"
contains 'connect timeout is Timeout' 'Timeout' "$PROBE_OUT"
LIST_OUT="$("$HOST_BIN" machine list --state-dir "$FAKE_STATE" 2>&1)"
contains 'timeout stored as readable reason' 'last_error=Timeout: SSH connection timed out' "$LIST_OUT"

DEGRADED_ID="$(machine_id_from "$(fake_add degraded.invalid)")"
PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$FAKE_STATE" --id "$DEGRADED_ID" --timeout-seconds 2 2>&1)"
PROBE_CODE=$?
if [ "$PROBE_CODE" -eq 0 ]; then pass 'degraded probe still succeeds'; else fail 'degraded probe still succeeds' "$PROBE_OUT"; fi
contains 'incomplete profile is degraded' 'status=degraded' "$PROBE_OUT"
contains 'degraded profile reports what it saw' 'profile.hostname=partial' "$PROBE_OUT"

EVENTS="$("$HOST_BIN" subscribe --state-dir "$FAKE_STATE" --since 0 \
  --max-events 9 --timeout-ms 4000 2>&1)"
contains 'fake events include machine.disconnected' 'type=machine.disconnected' "$EVENTS"
contains 'fake events include machine.probed' 'type=machine.probed' "$EVENTS"

REMOVE_OUT="$("$HOST_BIN" machine remove --state-dir "$FAKE_STATE" --id "$AUTH_ID" 2>&1)"
contains 'fake machine remove works' "machine removed id=$AUTH_ID" "$REMOVE_OUT"

stop_host
if start_host "$FAKE_STATE"; then
  pass 'fake-ssh host restarted on the same state dir'
else
  fail 'fake-ssh host restarted'
fi
LIST_OUT="$("$HOST_BIN" machine list --state-dir "$FAKE_STATE" 2>&1)"
contains 'failure state survives a restart' "machine id=$MISSING_ID" "$LIST_OUT"
contains 'failure reason survives a restart' 'last_error=NotFound: SSH host could not be resolved' "$LIST_OUT"
not_contains 'removed fake machine stays removed' "machine id=$AUTH_ID" "$LIST_OUT"
stop_host

printf '\n== 3. user ~/.ssh guard ==\n'
SSH_AFTER="$(ssh_snapshot)"
if [ "$SSH_BEFORE" = "$SSH_AFTER" ]; then
  pass 'user ~/.ssh was not modified'
else
  fail 'user ~/.ssh was modified' "$SSH_AFTER"
fi

summary
