#!/usr/bin/env bash
# MoNexus M6 — recovery & safety smoke: the recovery matrix, stop reasons,
# unified Decision queue, audit and secret redaction.
#
# TEST HARNESS ONLY. Faults are injected through a fake `ssh` on PATH that
# executes the requested remote command locally (via /bin/sh) and can be told
# to "disconnect" through a mode file. tmux is required for the durable-run
# scenarios; they are skipped (not failed) when it is absent.
#
# Usage:
#   bash scripts/recovery_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/recovery_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
REAL_USER="$(id -un)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m6-smoke.XXXXXX")"
mkdir -p "$WORK/home" "$WORK/tmux" "$WORK/fake" "$WORK/bin"
export HOME="$WORK/home"
export TMUX_TMPDIR="$WORK/tmux"
# Match a user tmux configured to keep dead panes; scenario 5b asserts that a
# dead pane without an exit marker is classified `lost`, never `running`.
printf 'set -g remain-on-exit on\n' >"$HOME/.tmux.conf"
export FAKE_SSH_DIR="$WORK/fake"
printf 'ok\n' >"$FAKE_SSH_DIR/mode"
export PATH="$WORK/bin:$ROOT/.moon/bin:$PATH"

PASSED=0
FAILED=0
SKIPPED=0
HOST_PID=""
STATE="$WORK/state"

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "--- output ---" "$2" "--------------" >&2; fi
}
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s\n' "$1"; }
contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then pass "$1"; else fail "$1 (missing: $2)" "$3"; fi
}
not_contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then fail "$1 (unexpected: $2)" "$3"; else pass "$1"; fi
}
eq() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2)" "$3"; fi
}

cleanup() {
  stop_host
  if command -v tmux >/dev/null 2>&1; then
    tmux ls 2>/dev/null | sed -n 's/:.*//p' | while read -r s; do
      case "$s" in monexus-run-*) tmux kill-session -t "$s" 2>/dev/null || true ;; esac
    done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

summary() {
  printf '\nSUMMARY  passed=%d failed=%d skipped=%d\n' "$PASSED" "$FAILED" "$SKIPPED"
  [ "$FAILED" -eq 0 ]
}

if [ ! -x "$HOST_BIN" ]; then
  printf 'host binary missing: %s\nrun: moon build --target native\n' "$HOST_BIN" >&2
  exit 2
fi
for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s is required for this smoke test\n' "$tool" >&2
    exit 2
  fi
done

# --- fake ssh: local execution with an injectable disconnect -----------------
cat >"$WORK/bin/ssh" <<'FAKE_SSH'
#!/bin/sh
set -u
dir="${FAKE_SSH_DIR:?}"
if [ "${1:-}" = "-G" ]; then
  printf 'hostname fakehost\nuser %s\nport 22\nidentityfile none\n' "${USER:-smoke}"
  exit 0
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-F|-l) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ] || { echo "fake ssh: missing destination" >&2; exit 255; }
_dest="$1"; shift
_cmd="${1:-}"
_mode="$(cat "$dir/mode" 2>/dev/null || echo ok)"
if [ "$_mode" = "disconnect" ]; then
  echo "Connection reset by peer" >&2
  exit 255
fi
cd / || exit 255
exec /bin/sh -c "$_cmd"
FAKE_SSH
chmod +x "$WORK/bin/ssh"

start_host() { # state_dir
  local state="$1"
  MONEXUS_MAX_PARALLEL=1 \
  MONEXUS_RECOVERY_POLL_MS=50 \
  MONEXUS_RECOVERY_UNVERIFIABLE_MS=1200 \
    "$HOST_BIN" serve --state-dir "$state" --heartbeat-ms 60000 >"$state/.log" 2>&1 &
  HOST_PID=$!
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if "$HOST_BIN" status --state-dir "$state" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then cat "$state/.log" >&2 || true; return 1; fi
    tries=$((tries + 1)); sleep 0.1
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

rpc() { # method params-json [state_dir]
  local state="${3:-$STATE}"
  "$HOST_BIN" rpc --state-dir "$state" --method "$1" --params "$2" 2>&1
}

run_status() { # run_id
  rpc run.get "$(jq -n --arg id "$1" '{run_id:$id}')" | jq -r '.run.status // "missing"'
}

wait_run() { # run_id expected timeout_tenths
  local run_id="$1" want="$2" timeout="${3:-150}" seen=""
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    seen="$(run_status "$run_id")"
    [ "$seen" = "$want" ] && return 0
    case "$seen" in succeeded|failed|cancelled|lost) : ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  printf 'wait_run: %s stayed %s (wanted %s)\n' "$run_id" "$seen" "$want" >&2
  return 1
}

wait_task_runs() { # task_id count timeout_tenths
  local task="$1" want="$2" timeout="${3:-100}" i=0 got=0
  while [ "$i" -lt "$timeout" ]; do
    got="$(rpc run.list "$(jq -n --arg tk "$task" '{task_id:$tk}')" | jq -r '.runs | length')"
    [ "$got" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

new_task() { # title
  rpc task.create "$(jq -n --arg pj "$PROJECT" --arg ws "$WS" --arg t "$1" \
    '{title:$t,project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id'
}

mkdir -p "$STATE"
command -v tmux >/dev/null 2>&1 && TMUX_OK=1 || TMUX_OK=0

printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s tmux=%s\n\n' "$WORK" "$TMUX_OK"

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email smoke@example.invalid
git -C "$REPO" config user.name Smoke
printf 'hello m6\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'initial'

if start_host "$STATE"; then pass 'host started on a temp state dir'; else fail 'host started'; exit 1; fi

PROJECT="$(rpc project.create "$(jq -n '{name:"m6"}' )" | jq -r '.project.id // empty')"
[ -n "$PROJECT" ] && pass 'project.create returned an id' || fail 'project.create returned an id'
WS="$(rpc workspace.open "$(jq -n --arg root "$REPO" '{machine_id:"",root:$root}')" | jq -r '.workspace.id // empty')"
[ -n "$WS" ] && pass 'local workspace opened' || fail 'local workspace opened'

# ---------------------------------------------------------------------------
printf '\n== 1. desktop exit: the durable run continues ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'desktop exit (tmux missing)'
else
  T1="$(new_task 'desktop exit')"
  R1="$(rpc run.create "$(jq -n --arg tk "$T1" --arg ws "$WS" \
    '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 1; echo desktop-exit-ok\"",idempotency_key:"m6/desktop"}')" | jq -r '.run.id')"
  sleep 0.4
  eq 'run is running before the client leaves' 'running' "$(run_status "$R1")"
  # The "desktop" is gone from here on: no polling calls until the run ends.
  sleep 1.4
  wait_run "$R1" succeeded 150 && pass 'run succeeds without a desktop client' || fail 'run succeeds without a desktop client' "$(rpc run.get "$(jq -n --arg id "$R1" '{run_id:$id}')")"
  D1="$(rpc run.get "$(jq -n --arg id "$R1" '{run_id:$id}')")"
  eq 'run used a durable tmux session' 'tmux' "$(printf '%s' "$D1" | jq -r '.run.durable')"
  contains 'desktop run output is an artifact' 'desktop-exit-ok' "$(printf '%s' "$D1" | jq -r '.artifacts[].id' >/dev/null; rpc artifact.read "$(jq -n --arg id "$(printf '%s' "$D1" | jq -r '.artifacts[0].id')" '{artifact_id:$id}')")"
  eq 'nested sh -c command wrote the exit marker' '0' "$(cat "$(printf '%s' "$D1" | jq -r '.run.exit_path')" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
printf '\n== 2. host crash: startup reconcile reattaches tmux ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'host crash reattach (tmux missing)'
else
  T2="$(new_task 'host crash')"
  R2="$(rpc run.create "$(jq -n --arg tk "$T2" --arg ws "$WS" \
    '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 2; echo crash-survived\"",idempotency_key:"m6/crash"}')" | jq -r '.run.id')"
  sleep 0.5
  eq 'run is mid-flight before the crash' 'running' "$(run_status "$R2")"
  kill -9 "$HOST_PID" 2>/dev/null || true
  wait "$HOST_PID" 2>/dev/null || true
  HOST_PID=""
  pass 'host killed with SIGKILL while the run was running'
  if start_host "$STATE"; then pass 'host restarted on the same state dir'; else fail 'host restarted'; fi
  wait_run "$R2" succeeded 200 && pass 'reconciled run reattached and succeeded' || fail 'reconciled run succeeded' "$(rpc run.get "$(jq -n --arg id "$R2" '{run_id:$id}')")"
  EV2="$(rpc events.list '{"since":0,"limit":2000}')"
  [ "$(printf '%s' "$EV2" | jq '[.events[] | select(.type=="run.recovered" and (.payload.action=="run.reconcile.reconnect"))] | length')" -ge 1 ] \
    && pass 'startup reconcile recorded run.reconcile.reconnect' || fail 'run.reconcile.reconnect event exists' "$EV2"
  AUD2="$(rpc audit.list '{"limit":500}')"
  [ "$(printf '%s' "$AUD2" | jq '[.audit[] | select(.action=="recovery.reconnect")] | length')" -ge 1 ] \
    && pass 'reconnect wrote an audit record' || fail 'recovery.reconnect audit exists' "$AUD2"
fi

# ---------------------------------------------------------------------------
printf '\n== 2b. host crash + missing tmux session: lost then one retry ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'lost-session recovery (tmux missing)'
else
  T2B="$(new_task 'session gone')"
  R2B="$(rpc run.create "$(jq -n --arg tk "$T2B" --arg ws "$WS" \
    '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 6; echo retry-ok\"",idempotency_key:"m6/session-gone"}')" | jq -r '.run.id')"
  SESS=""
  _i=0
  while [ "$_i" -lt 30 ]; do
    SESS="$(rpc run.get "$(jq -n --arg id "$R2B" '{run_id:$id}')" 2>/dev/null | jq -r '.run.tmux_session // ""')"
    [ -n "$SESS" ] && break
    sleep 0.1
    _i=$((_i + 1))
  done
  kill -9 "$HOST_PID" 2>/dev/null || true
  wait "$HOST_PID" 2>/dev/null || true
  HOST_PID=""
  if [ -n "$SESS" ] && [ "$SESS" != "null" ]; then
    tmux kill-session -t "$SESS" 2>/dev/null || true
    pass 'tmux session removed while the host was down'
  else
    fail 'run recorded a tmux session' "$SESS"
  fi
  start_host "$STATE" >/dev/null 2>&1 || fail 'host restarted after session loss'
  wait_run "$R2B" lost 150 && pass 'missing session is marked lost at startup' || fail 'missing session is lost' "$(run_status "$R2B")"
  eq 'lost run keeps stop_reason=lost' 'lost' "$(rpc run.get "$(jq -n --arg id "$R2B" '{run_id:$id}')" | jq -r '.run.stop_reason')"
  if wait_task_runs "$T2B" 2 150; then pass 'lost run was retried exactly once'; else fail 'lost run was retried exactly once'; fi
  RETRY2B="$(rpc run.list "$(jq -n --arg tk "$T2B" '{task_id:$tk}')" | jq -r --arg id "$R2B" '.runs[] | select(.retried_from==$id) | .id' | head -n1)"
  [ -n "$RETRY2B" ] && pass 'retry run points back with retried_from' || fail 'retry run has retried_from'
  wait_run "$RETRY2B" succeeded 250 && pass 'retry attempt succeeded on its own' || fail 'retry attempt succeeded' "$(run_status "$RETRY2B")"
fi

# ---------------------------------------------------------------------------
printf '\n== fake ssh machine setup ==\n'
# ---------------------------------------------------------------------------
ADD_OUT="$("$HOST_BIN" machine add --state-dir "$STATE" \
  --name fake-remote --host fakehost --port 22 --user "$REAL_USER" \
  --use-ssh-config false --host-key-policy accept-new 2>&1)"
MACHINE_ID="$(printf '%s' "$ADD_OUT" | sed -n 's/^id=//p' | head -n 1)"
[ -n "$MACHINE_ID" ] && pass "machine.add (fake ssh) returned $MACHINE_ID" || fail 'machine.add (fake ssh) returned an id' "$ADD_OUT"
PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$MACHINE_ID" --timeout-seconds 10 2>&1)"
contains 'fake ssh machine probes online' 'status=online' "$PROBE_OUT"
RWS="$(rpc workspace.open "$(jq -n --arg m "$MACHINE_ID" --arg root "$REPO" '{machine_id:$m,root:$root}')" | jq -r '.workspace.id // empty')"
[ -n "$RWS" ] && pass 'remote workspace opened through fake ssh' || fail 'remote workspace opened'

# ---------------------------------------------------------------------------
printf '\n== 3. short SSH disconnect: run is not failed ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'short SSH disconnect (tmux missing)'
elif [ -z "$RWS" ]; then
  skip 'short SSH disconnect (no fake machine)'
else
  T3="$(new_task 'short drop')"
  R3="$(rpc run.create "$(jq -n --arg tk "$T3" --arg ws "$RWS" --arg m "$MACHINE_ID" \
    '{task_id:$tk,workspace_id:$ws,machine_id:$m,mode:"command",command:"sh -c \"sleep 3; echo short-drop-ok\"",idempotency_key:"m6/short-drop"}')" | jq -r '.run.id')"
  sleep 0.5
  printf 'disconnect\n' >"$FAKE_SSH_DIR/mode"
  sleep 0.6
  printf 'ok\n' >"$FAKE_SSH_DIR/mode"
  wait_run "$R3" succeeded 250 && pass 'short SSH drop is tolerated; run succeeds' || fail 'short SSH drop run succeeded' "$(rpc run.get "$(jq -n --arg id "$R3" '{run_id:$id}')")"
  DEC3="$(rpc decision.list '{"status":"","session_id":""}')"
  eq 'short drop raised no recovery Decision' '0' "$(printf '%s' "$DEC3" | jq -r --arg id "$R3" '[.decisions[] | select(.run_id==$id and .kind=="recovery")] | length')"
fi

# ---------------------------------------------------------------------------
printf '\n== 4. remote machine silent: unverifiable, Decision, no auto retry ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'remote silence (tmux missing)'
elif [ -z "$RWS" ]; then
  skip 'remote silence (no fake machine)'
else
  T4="$(new_task 'remote silence')"
  R4="$(rpc run.create "$(jq -n --arg tk "$T4" --arg ws "$RWS" --arg m "$MACHINE_ID" \
    '{task_id:$tk,workspace_id:$ws,machine_id:$m,mode:"command",command:"sh -c \"sleep 8; echo never-observed\"",idempotency_key:"m6/silent"}')" | jq -r '.run.id')"
  sleep 0.5
  printf 'disconnect\n' >"$FAKE_SSH_DIR/mode"
  wait_run "$R4" lost 120 && pass 'unobservable run becomes lost' || fail 'unobservable run becomes lost' "$(run_status "$R4")"
  D4="$(rpc run.get "$(jq -n --arg id "$R4" '{run_id:$id}')")"
  eq 'stop_reason is unverifiable' 'unverifiable' "$(printf '%s' "$D4" | jq -r '.run.stop_reason')"
  eq 'unverifiable run was never auto-retried' '1' "$(rpc run.list "$(jq -n --arg tk "$T4" '{task_id:$tk}')" | jq -r '.runs | length')"
  DEC4="$(rpc decision.list '{"status":"","session_id":""}')"
  D4ID="$(printf '%s' "$DEC4" | jq -r --arg id "$R4" '.decisions[] | select(.run_id==$id and .kind=="recovery") | .id' | head -n1)"
  [ -n "$D4ID" ] && pass 'recovery Decision raised for the owner' || fail 'recovery Decision raised' "$DEC4"
  eq 'recovery Decision sits in Needs you' 'needs_you' "$(printf '%s' "$DEC4" | jq -r --arg id "$D4ID" '.decisions[] | select(.id==$id) | .inbox' | head -n1)"
  eq 'Decision knows the run status' 'lost' "$(printf '%s' "$DEC4" | jq -r --arg id "$D4ID" '.decisions[] | select(.id==$id) | .run_status' | head -n1)"
  printf 'ok\n' >"$FAKE_SSH_DIR/mode"
  rpc decision.respond "$(jq -n --arg id "$D4ID" '{decision_id:$id,option_id:"retry",text:"",answered_by:"owner"}')" >/dev/null
  if wait_task_runs "$T4" 2 100; then pass 'owner retry created exactly one new attempt'; else fail 'owner retry created one new attempt'; fi
  RETRY4="$(rpc run.list "$(jq -n --arg tk "$T4" '{task_id:$tk}')" | jq -r --arg id "$R4" '.runs[] | select(.retried_from==$id) | .id' | head -n1)"
  eq 'retry attempt is attempt 2' '2' "$(rpc run.get "$(jq -n --arg id "$RETRY4" '{run_id:$id}')" | jq -r '.run.attempt')"
  SECOND="$(rpc decision.respond "$(jq -n --arg id "$D4ID" '{decision_id:$id,option_id:"retry",text:"",answered_by:"owner"}')")"
  contains 'duplicate Decision answer is rejected' 'already answered' "$SECOND"
  eq 'duplicate answer did not create another run' '2' "$(rpc run.list "$(jq -n --arg tk "$T4" '{task_id:$tk}')" | jq -r '.runs | length')"
  wait_run "$RETRY4" succeeded 250 && pass 'owner-approved retry succeeded' || fail 'owner-approved retry succeeded' "$(run_status "$RETRY4")"
  DEC4B="$(rpc decision.list '{"status":"","session_id":""}')"
  eq 'answered retry moves to handled once work finishes' 'handled' "$(printf '%s' "$DEC4B" | jq -r --arg id "$D4ID" '.decisions[] | select(.id==$id) | .inbox' | head -n1)"
fi

# ---------------------------------------------------------------------------
printf '\n== 5. exited != 0: retry once, then a Decision ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'exited retry (tmux missing)'
else
  T5="$(new_task 'exit 7')"
  R5="$(rpc run.create "$(jq -n --arg tk "$T5" --arg ws "$WS" \
    '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"exit 7\"",idempotency_key:"m6/exited"}')" | jq -r '.run.id')"
  wait_run "$R5" failed 150 && pass 'exit 7 fails the first attempt' || fail 'exit 7 fails the first attempt'
  eq 'first stop reason is exited' 'exited' "$(rpc run.get "$(jq -n --arg id "$R5" '{run_id:$id}')" | jq -r '.run.stop_reason')"
  wait_task_runs "$T5" 2 100 && pass 'exited run is retried exactly once' || fail 'exited run is retried exactly once'
  RETRY5="$(rpc run.list "$(jq -n --arg tk "$T5" '{task_id:$tk}')" | jq -r --arg id "$R5" '.runs[] | select(.retried_from==$id) | .id' | head -n1)"
  wait_run "$RETRY5" failed 150 && pass 'second exit 7 does not loop forever' || fail 'second attempt failed'
  DEC5="$(rpc decision.list '{"status":"","session_id":""}')"
  D5ID="$(printf '%s' "$DEC5" | jq -r --arg id "$RETRY5" '.decisions[] | select(.run_id==$id and .kind=="recovery") | .id' | head -n1)"
  [ -n "$D5ID" ] && pass 'retry exhaustion raised a recovery Decision' || fail 'retry exhaustion Decision' "$DEC5"
  contains 'recovery Decision explains the exit' 'exited' "$(printf '%s' "$DEC5" | jq -r --arg id "$D5ID" '.decisions[] | select(.id==$id) | .detail')"
  eq 'retry exhaustion never exceeds two attempts' '2' "$(rpc run.list "$(jq -n --arg tk "$T5" '{task_id:$tk}')" | jq -r '.runs | length')"
  rpc decision.respond "$(jq -n --arg id "$D5ID" '{decision_id:$id,option_id:"fail",text:"",answered_by:"owner"}')" >/dev/null
  DEC5B="$(rpc decision.list '{"status":"","session_id":""}')"
  eq 'owner fail moves the Decision to handled' 'handled' "$(printf '%s' "$DEC5B" | jq -r --arg id "$D5ID" '.decisions[] | select(.id==$id) | .inbox' | head -n1)"
fi

# ---------------------------------------------------------------------------
printf '\n== 5b. remain-on-exit: dead pane without exit marker is lost, not running ==\n'
# ---------------------------------------------------------------------------
if [ "$TMUX_OK" != "1" ]; then
  skip 'remain-on-exit dead pane (tmux missing)'
else
  # Make the isolated server keep dead panes, like a user tmux configured with
  # `set -g remain-on-exit on`; the old bug was a Run stuck in `running`
  # forever because has-session stayed true after the pane died.
  tmux start-server 2>/dev/null || true
  tmux set-option -g remain-on-exit on 2>/dev/null || true
  eq 'tmux remain-on-exit is enabled for this scenario' 'on' \
    "$(tmux show-options -g remain-on-exit 2>/dev/null | awk '{print $2}')"
  T5B="$(new_task 'remain-on-exit dead pane')"
  # The command kills the wrapper shell before it can write the exit marker.
  # The pane then dies while tmux keeps the session listed.
  R5B="$(rpc run.create "$(jq -n --arg tk "$T5B" --arg ws "$WS" \
    '{task_id:$tk,workspace_id:$ws,mode:"command",command:"kill $PPID",idempotency_key:"m6/dead-pane"}')" | jq -r '.run.id')"
  wait_run "$R5B" lost 120 && pass 'dead pane without an exit marker becomes lost' || fail 'dead pane becomes lost, not running forever' "$(run_status "$R5B")"
  D5B="$(rpc run.get "$(jq -n --arg id "$R5B" '{run_id:$id}')")"
  eq 'dead pane stop_reason is lost' 'lost' "$(printf '%s' "$D5B" | jq -r '.run.stop_reason')"
  contains 'dead pane detail names the pane' 'pane' "$(printf '%s' "$D5B" | jq -r '.run.last_error')"
  SESS5B="$(printf '%s' "$D5B" | jq -r '.run.tmux_session')"
  wait_task_runs "$T5B" 2 100 && pass 'dead pane is retried exactly once' || fail 'dead pane retry created one attempt'
  RETRY5B="$(rpc run.list "$(jq -n --arg tk "$T5B" '{task_id:$tk}')" | jq -r --arg id "$R5B" '.runs[] | select(.retried_from==$id) | .id' | head -n1)"
  wait_run "$RETRY5B" lost 120 && pass 'retry also dies without a marker and stops' || fail 'retry dead pane becomes lost' "$(run_status "$RETRY5B")"
  eq 'dead pane never exceeds two attempts' '2' "$(rpc run.list "$(jq -n --arg tk "$T5B" '{task_id:$tk}')" | jq -r '.runs | length')"
  DEC5B="$(rpc decision.list '{"status":"","session_id":""}')"
  D5BID="$(printf '%s' "$DEC5B" | jq -r --arg id "$RETRY5B" '.decisions[] | select(.run_id==$id and .kind=="recovery") | .id' | head -n1)"
  [ -n "$D5BID" ] && pass 'dead pane raised a recovery Decision' || fail 'dead pane recovery Decision' "$DEC5B"
  eq 'dead pane Decision sits in Needs you' 'needs_you' "$(printf '%s' "$DEC5B" | jq -r --arg id "$D5BID" '.decisions[] | select(.id==$id) | .inbox' | head -n1)"
  if tmux has-session -t "$SESS5B" 2>/dev/null; then
    fail 'dead pane session is torn down after settlement' "$SESS5B"
  else
    pass 'dead pane session is torn down after settlement'
  fi
  rpc decision.respond "$(jq -n --arg id "$D5BID" '{decision_id:$id,option_id:"fail",text:"",answered_by:"owner"}')" >/dev/null
fi

# ---------------------------------------------------------------------------
printf '\n== 6. policy approval, deny, audit and secret redaction ==\n'
# ---------------------------------------------------------------------------
T6="$(new_task 'policy')"
DENY="$(rpc run.create "$(jq -n --arg tk "$T6" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sudo echo token=supersecretvalue",idempotency_key:"m6/deny"}')")"
contains 'critical command is denied before a Run exists' 'denied by policy' "$DENY"

T7="$(new_task 'approval')"
ASK="$(rpc run.create "$(jq -n --arg tk "$T7" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"rm -f marker.txt",idempotency_key:"m6/approval"}')")"
R7="$(printf '%s' "$ASK" | jq -r '.run.id')"
eq 'high-risk command starts waiting for approval' 'waiting_approval' "$(printf '%s' "$ASK" | jq -r '.run.status')"
DEC7="$(rpc decision.list '{"status":"","session_id":""}')"
D7ID="$(printf '%s' "$DEC7" | jq -r --arg id "$R7" '.decisions[] | select(.run_id==$id and .kind=="approval") | .id' | head -n1)"
[ -n "$D7ID" ] && pass 'approval Decision is in the unified queue' || fail 'approval Decision exists' "$DEC7"
eq 'approval Decision is Needs you' 'needs_you' "$(printf '%s' "$DEC7" | jq -r --arg id "$D7ID" '.decisions[] | select(.id==$id) | .inbox' | head -n1)"
rpc decision.respond "$(jq -n --arg id "$D7ID" '{decision_id:$id,option_id:"approve",text:"",answered_by:"owner"}')" >/dev/null
wait_run "$R7" succeeded 200 && pass 'approved high-risk run executes and succeeds' || fail 'approved run succeeded' "$(run_status "$R7")"
DEC7B="$(rpc decision.list '{"status":"","session_id":""}')"
eq 'approval Decision becomes handled after the run' 'handled' "$(printf '%s' "$DEC7B" | jq -r --arg id "$D7ID" '.decisions[] | select(.id==$id) | .inbox' | head -n1)"

T8="$(new_task 'secret output')"
R8="$(rpc run.create "$(jq -n --arg tk "$T8" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"echo API_KEY=supersecretvalue\"",idempotency_key:"m6/secret"}')" | jq -r '.run.id')"
wait_run "$R8" succeeded 150 && pass 'secret-echo run succeeds' || fail 'secret-echo run succeeds'
ART8="$(rpc run.get "$(jq -n --arg id "$R8" '{run_id:$id}')" | jq -r '.artifacts[0].id')"
ARTXT="$(rpc artifact.read "$(jq -n --arg id "$ART8" '{artifact_id:$id}')" | jq -r '.text')"
not_contains 'run artifact does not leak the secret' 'supersecretvalue' "$ARTXT"
contains 'run artifact shows the redaction marker' '[redacted]' "$ARTXT"

# Duplicate dispatch is idempotent.
R8B="$(rpc run.create "$(jq -n --arg tk "$T8" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"echo API_KEY=supersecretvalue\"",idempotency_key:"m6/secret"}')" | jq -r '.run.id')"
eq 'duplicate dispatch returns the same Run' "$R8" "$R8B"

AUDIT="$(rpc audit.list '{"limit":500}')"
[ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select(.action=="policy.deny" and .outcome=="denied")] | length')" -ge 1 ] \
  && pass 'policy deny wrote an audit record' || fail 'policy deny audit exists' "$AUDIT"
[ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select(.action=="policy.approve" and .outcome=="approved")] | length')" -ge 1 ] \
  && pass 'policy approval wrote an audit record' || fail 'policy approval audit exists' "$AUDIT"
[ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select(.action=="decision.respond" and (.decision_id|length)>0)] | length')" -ge 1 ] \
  && pass 'Decision answers carry an audit record with decision_id' || fail 'decision.respond audit exists' "$AUDIT"
[ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select((.action=="run.stop" or .action=="recovery.escalate") and (.run_id|length)>0)] | length')" -ge 1 ] \
  && pass 'stop/recovery actions carry an audit record with run_id' || fail 'recovery audit with run_id' "$AUDIT"
[ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select((.id|length)==0 or (.action|length)==0 or (.actor|length)==0 or (.subject|length)==0 or (.outcome|length)==0 or (.ts|length)==0)] | length')" -eq 0 ] \
  && pass 'every audit record has the required fields' || fail 'audit fields are complete' "$AUDIT"
not_contains 'audit stream never carries the secret' 'supersecretvalue' "$AUDIT"

summary
