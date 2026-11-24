#!/usr/bin/env bash
# MoNexus M5 — task/run scheduling, evidence gate, events and search smoke.
#
# TEST HARNESS ONLY. The SSH section starts an ephemeral, non-root sshd on a
# random loopback port with a temp HOME, exactly like the M3 smoke script. If
# sshd is unavailable that section is skipped; everything else still runs.
#
# Usage:
#   bash scripts/task_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/task_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
REAL_USER="$(id -un)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m5-smoke.XXXXXX")"
mkdir -p "$WORK/home"
export HOME="$WORK/home"
export PATH="$ROOT/.moon/bin:$PATH"

PASSED=0
FAILED=0
SKIPPED=0
HOST_PID=""
SSHD_PID=""
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
  if [ -n "$HOST_PID" ]; then kill "$HOST_PID" 2>/dev/null || true; wait "$HOST_PID" 2>/dev/null || true; fi
  if [ -n "$SSHD_PID" ]; then kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; fi
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
if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for this smoke test\n' >&2
  exit 2
fi

start_host() { # state_dir
  local state="$1"
  # One local slot so queueing is observable; the SSH machine keeps its own
  # capacity from the probe profile (default 4).
  MONEXUS_MAX_PARALLEL=1 "$HOST_BIN" serve --state-dir "$state" --heartbeat-ms 60000 >"$state/.log" 2>&1 &
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
  local run_id="$1" want="$2" timeout="${3:-100}" seen=""
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    seen="$(run_status "$run_id")"
    if [ "$seen" = "$want" ]; then return 0; fi
    case "$seen" in
      succeeded|failed|cancelled|lost) return 1 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  printf 'wait_run: %s stayed %s (wanted %s)\n' "$run_id" "$seen" "$want" >&2
  return 1
}

mkdir -p "$STATE"
printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s\n\n' "$WORK"

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email smoke@example.invalid
git -C "$REPO" config user.name Smoke
printf 'hello m5\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'initial'

if start_host "$STATE"; then pass 'host started on a temp state dir'; else fail 'host started'; fi

OPEN="$(rpc workspace.open "$(jq -n --arg root "$REPO" '{machine_id:"",root:$root}')")"
WS="$(printf '%s' "$OPEN" | jq -r '.workspace.id // empty')"
[ -n "$WS" ] && pass "workspace.open returned $WS" || fail 'workspace.open returned an id' "$OPEN"

# ---------------------------------------------------------------------------
printf '\n== 1. project / task / run: local happy path with verify[] ==\n'
# ---------------------------------------------------------------------------
PROJECT="$(rpc project.create "$(jq -n --arg ws "$WS" '{
  name:"demo",
  verify:["sh -c \"test -f README.md\"", "echo build-ok"]
}')")"
PJ="$(printf '%s' "$PROJECT" | jq -r '.project.id // empty')"
[ -n "$PJ" ] && pass "project.create returned $PJ" || fail 'project.create returned an id' "$PROJECT"
contains 'project.list includes the project' "$PJ" "$(rpc project.list '{}')"

TASK="$(rpc task.create "$(jq -n --arg pj "$PJ" --arg ws "$WS" '{
  title:"demo task", goal:"prove the gate", project_id:$pj, workspace_id:$ws, status:"ready"
}')")"
TK="$(printf '%s' "$TASK" | jq -r '.task.id // empty')"
[ -n "$TK" ] && pass "task.create returned $TK" || fail 'task.create returned an id' "$TASK"
eq 'verify[] is inherited from the project' '2' "$(printf '%s' "$TASK" | jq -r '.task.verify | length')"

CHILD="$(rpc task.create "$(jq -n --arg parent "$TK" --arg ws "$WS" '{
  title:"child task", parent_id:$parent, workspace_id:$ws, status:"planned"
}')")"
CHILD_ID="$(printf '%s' "$CHILD" | jq -r '.task.id // empty')"
[ -n "$CHILD_ID" ] && pass 'subtask created with parent_id' || fail 'subtask created' "$CHILD"
eq 'task.list filters by parent_id' "$CHILD_ID" "$(rpc task.list "$(jq -n --arg p "$TK" '{parent_id:$p}')" | jq -r '.tasks[0].id')"
contains 'task.get returns children' "$CHILD_ID" "$(rpc task.get "$(jq -n --arg id "$TK" '{task_id:$id}')" | jq -c '.children')"

RUN="$(rpc run.create "$(jq -n --arg tk "$TK" --arg ws "$WS" '{
  task_id:$tk, workspace_id:$ws, mode:"command",
  command:"sh -c \"echo changed >> README.md\"", idempotency_key:"demo/0"
}')")"
RID="$(printf '%s' "$RUN" | jq -r '.run.id // empty')"
[ -n "$RID" ] && pass "run.create returned $RID" || fail 'run.create returned an id' "$RUN"
eq 'new run starts queued' 'queued' "$(printf '%s' "$RUN" | jq -r '.run.status')"

RUN2="$(rpc run.create "$(jq -n --arg tk "$TK" --arg ws "$WS" '{
  task_id:$tk, workspace_id:$ws, mode:"command",
  command:"true", idempotency_key:"demo/0"
}')")"
eq 'idempotent dispatch returns the same run' "$RID" "$(printf '%s' "$RUN2" | jq -r '.run.id')"

if wait_run "$RID" succeeded 200; then pass 'run reached succeeded'; else fail 'run reached succeeded' "$(rpc run.get "$(jq -n --arg id "$RID" '{run_id:$id}')")"; fi
DETAIL="$(rpc run.get "$(jq -n --arg id "$RID" '{run_id:$id}')")"
eq 'run stop_reason records the gate' 'verified' "$(printf '%s' "$DETAIL" | jq -r '.run.stop_reason')"
eq 'two verify commands produced two evidence rows' '2' "$(printf '%s' "$DETAIL" | jq -r '.evidence | length')"
[ "$(printf '%s' "$DETAIL" | jq -r '.evidence | all(.passed == true)')" = "true" ] && pass 'every evidence row passed' || fail 'every evidence row passed' "$DETAIL"
[ "$(printf '%s' "$DETAIL" | jq -r '.artifacts | length >= 3')" = "true" ] && pass 'run + verify outputs are artifacts' || fail 'artifacts exist' "$DETAIL"
contains 'run detail carries the worktree diff' 'changed' "$(printf '%s' "$DETAIL" | jq -r '.diff')"
eq 'run bound itself to a worktree' 'true' "$(printf '%s' "$DETAIL" | jq -r '.run.worktree_id != ""')"

ART_ID="$(printf '%s' "$DETAIL" | jq -r '.artifacts[] | select(.size > 0) | .id' | head -n 1)"
ART="$(rpc artifact.read "$(jq -n --arg id "$ART_ID" '{artifact_id:$id}')")"
contains 'artifact.read returns the stored text' 'build-ok' "$(printf '%s' "$ART" | jq -r '.text')"
eq 'artifact.read is not truncated' 'false' "$(printf '%s' "$ART" | jq -r '.truncated')"

eq 'task rolled up to succeeded' 'succeeded' "$(rpc task.get "$(jq -n --arg id "$TK" '{task_id:$id}')" | jq -r '.task.status')"
eq 'task result summary counts runs' '1/1 runs succeeded' "$(rpc task.get "$(jq -n --arg id "$TK" '{task_id:$id}')" | jq -r '.task.result_summary')"

# ---------------------------------------------------------------------------
printf '\n== 2. per-machine max_parallel: queue, cancel, events cursor ==\n'
# ---------------------------------------------------------------------------
SLOW_TASK="$(rpc task.create "$(jq -n --arg pj "$PJ" --arg ws "$WS" '{title:"slow",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
SLOW_VERIFY="$(rpc task.get "$(jq -n --arg id "$SLOW_TASK" '{task_id:$id}')" | jq -r '.task.verify | length')"
eq 'slow task inherited verify[]' '2' "$SLOW_VERIFY"
S1="$(rpc run.create "$(jq -n --arg tk "$SLOW_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 2; echo one\"",idempotency_key:"slow/1"}')" | jq -r '.run.id')"
S2="$(rpc run.create "$(jq -n --arg tk "$SLOW_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 2; echo two\"",idempotency_key:"slow/2"}')" | jq -r '.run.id')"
sleep 0.4
ST1="$(run_status "$S1")"; ST2="$(run_status "$S2")"
[ "$ST1" = "running" ] || [ "$ST1" = "verifying" ] && pass "first slow run occupies the only local slot ($ST1)" || fail "first slow run occupies the slot (got $ST1)"
eq 'second slow run waits queued at max_parallel=1' 'queued' "$ST2"
S3="$(rpc run.create "$(jq -n --arg tk "$SLOW_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 5; echo three\"",idempotency_key:"slow/3"}')" | jq -r '.run.id')"
rpc run.cancel "$(jq -n --arg id "$S3" '{run_id:$id,reason:"smoke cancel"}')" >/dev/null
wait_run "$S1" succeeded 200 && pass 'queued overflow drains after the first run settles' || fail 'first slow run succeeded'
wait_run "$S2" succeeded 200 && pass 'second slow run started when a slot freed' || fail 'second slow run succeeded' "$(rpc run.get "$(jq -n --arg id "$S2" '{run_id:$id}')")"
eq 'cancelled run settles cancelled' 'cancelled' "$(run_status "$S3")"

EVENTS="$(rpc events.list '{"since":0,"limit":500}')"
contains 'event stream has run.queued' 'run.queued' "$EVENTS"
contains 'event stream has run.evidence' 'run.evidence' "$EVENTS"
contains 'event stream has artifact.created' 'artifact.created' "$EVENTS"
contains 'event stream has task.status.changed' 'task.status.changed' "$EVENTS"
NEXT="$(printf '%s' "$EVENTS" | jq -r '.next_seq')"
TAIL="$(rpc events.list "$(jq -n --argjson since "$NEXT" '{since:$since,limit:50}')")"
eq 'cursor at next_seq replays nothing' '0' "$(printf '%s' "$TAIL" | jq -r '.events | length')"
eq 'next_seq is stable' "$NEXT" "$(printf '%s' "$TAIL" | jq -r '.next_seq')"

# ---------------------------------------------------------------------------
printf '\n== 3. evidence gate failure -> Decision -> waive / fail / retry ==\n'
# ---------------------------------------------------------------------------
BAD_PJ="$(rpc project.create '{"name":"strict","verify":["sh -c \"echo lint-error; exit 3\""]}' | jq -r '.project.id')"
BAD_TASK="$(rpc task.create "$(jq -n --arg pj "$BAD_PJ" --arg ws "$WS" '{title:"strict task",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
BAD_RUN="$(rpc run.create "$(jq -n --arg tk "$BAD_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"echo main-ok",idempotency_key:"strict/1"}')" | jq -r '.run.id')"
if wait_run "$BAD_RUN" waiting_approval 200; then pass 'failed verify parks the run in waiting_approval'; else fail 'run waits for approval' "$(rpc run.get "$(jq -n --arg id "$BAD_RUN" '{run_id:$id}')")"; fi
BAD_DETAIL="$(rpc run.get "$(jq -n --arg id "$BAD_RUN" '{run_id:$id}')")"
eq 'failed evidence is recorded as failed' 'false' "$(printf '%s' "$BAD_DETAIL" | jq -r '.evidence[0].passed')"
contains 'failed evidence keeps its output artifact' 'lint-error' "$(printf '%s' "$BAD_DETAIL" | jq -r '.evidence[0].excerpt')"
eq 'task waits for the owner too' 'waiting_approval' "$(rpc task.get "$(jq -n --arg id "$BAD_TASK" '{task_id:$id}')" | jq -r '.task.status')"

PENDING="$(rpc decision.list '{"status":"pending"}')"
DEC="$(printf '%s' "$PENDING" | jq -r --arg run "$BAD_RUN" '.decisions[] | select(.run_id == $run) | .id' | head -n 1)"
[ -n "$DEC" ] && pass "verify Decision $DEC is pending" || fail 'verify Decision is pending' "$PENDING"
eq 'decision is a verify decision bound to the run' 'verify' "$(printf '%s' "$PENDING" | jq -r --arg id "$DEC" '.decisions[] | select(.id == $id) | .kind')"
eq 'decision offers waive/retry/fail' 'waive,retry,fail' "$(printf '%s' "$PENDING" | jq -r --arg id "$DEC" '.decisions[] | select(.id == $id) | [.options[].option_id] | join(",")')"

rpc decision.respond "$(jq -n --arg id "$DEC" '{decision_id:$id,option_id:"waive",text:"smoke accepts the lint finding"}')" >/dev/null
sleep 0.3
WAIVED="$(rpc run.get "$(jq -n --arg id "$BAD_RUN" '{run_id:$id}')")"
eq 'waiver settles the run succeeded' 'succeeded' "$(printf '%s' "$WAIVED" | jq -r '.run.status')"
eq 'waiver is stamped on the evidence' 'true' "$(printf '%s' "$WAIVED" | jq -r '.evidence[0].waived')"
eq 'waiver settles the task succeeded' 'succeeded' "$(rpc task.get "$(jq -n --arg id "$BAD_TASK" '{task_id:$id}')" | jq -r '.task.status')"

# fail option (a fresh task: a succeeded task refuses new runs)
FAIL_TASK="$(rpc task.create "$(jq -n --arg pj "$BAD_PJ" --arg ws "$WS" '{title:"strict fail task",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
FAIL_RUN="$(rpc run.create "$(jq -n --arg tk "$FAIL_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"echo main-ok",idempotency_key:"strict/2"}')" | jq -r '.run.id')"
wait_run "$FAIL_RUN" waiting_approval 200 >/dev/null 2>&1
FAIL_DEC="$(rpc decision.list '{"status":"pending"}' | jq -r --arg run "$FAIL_RUN" '.decisions[] | select(.run_id == $run) | .id' | head -n 1)"
rpc decision.respond "$(jq -n --arg id "$FAIL_DEC" '{decision_id:$id,option_id:"fail",text:"not acceptable"}')" >/dev/null
sleep 0.3
eq 'fail option settles the run failed' 'failed' "$(run_status "$FAIL_RUN")"

# retry option: the gate re-runs and asks again
RETRY_TASK="$(rpc task.create "$(jq -n --arg pj "$BAD_PJ" --arg ws "$WS" '{title:"strict retry task",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
RETRY_RUN="$(rpc run.create "$(jq -n --arg tk "$RETRY_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"echo main-ok",idempotency_key:"strict/3"}')" | jq -r '.run.id')"
wait_run "$RETRY_RUN" waiting_approval 200 >/dev/null 2>&1
RETRY_DEC="$(rpc decision.list '{"status":"pending"}' | jq -r --arg run "$RETRY_RUN" '.decisions[] | select(.run_id == $run) | .id' | head -n 1)"
rpc decision.respond "$(jq -n --arg id "$RETRY_DEC" '{decision_id:$id,option_id:"retry",text:"try again"}')" >/dev/null
sleep 0.5
# The gate still fails, so a fresh decision is requested.
NEW_DEC="$(rpc decision.list '{"status":"pending"}' | jq -r --arg run "$RETRY_RUN" '.decisions[] | select(.run_id == $run) | .id' | head -n 1)"
[ -n "$NEW_DEC" ] && [ "$NEW_DEC" != "$RETRY_DEC" ] && pass 'retry re-ran the gate and asked again' || fail 'retry asked again' "$(rpc decision.list '{"status":"pending"}')"
eq 'retry leaves the run waiting_approval' 'waiting_approval' "$(run_status "$RETRY_RUN")"
rpc run.cancel "$(jq -n --arg id "$RETRY_RUN" '{run_id:$id,reason:"cleanup"}')" >/dev/null
eq 'cancel settles the run cancelled' 'cancelled' "$(run_status "$RETRY_RUN")"
eq 'cancel expires the pending decision' 'expired' "$(rpc decision.list '{}' | jq -r --arg id "$NEW_DEC" '.decisions[] | select(.id == $id) | .status')"
contains 'event stream has decision.requested' 'decision.requested' "$(rpc events.list '{"since":0,"limit":500}')"

# ---------------------------------------------------------------------------
printf '\n== 4. search.sessions finds decision text ==\n'
# ---------------------------------------------------------------------------
SEARCH="$(rpc search.sessions '{"query":"smoke accepts the lint finding"}')"
eq 'search backend is reported' 'true' "$(printf '%s' "$SEARCH" | jq -r '.backend != ""')"
contains 'search finds the answered decision' "$DEC" "$(printf '%s' "$SEARCH" | jq -c '.hits')"
contains 'search hit carries a snippet' 'smoke accepts' "$(printf '%s' "$SEARCH" | jq -r '.hits[0].snippet')"
eq 'search with no match returns no hits' '0' "$(rpc search.sessions '{"query":"zzz-no-such-token"}' | jq -r '.hits | length')"
eq 'empty query returns no hits' '0' "$(rpc search.sessions '{"query":""}' | jq -r '.hits | length')"

# ---------------------------------------------------------------------------
printf '\n== 5. loopback SSH: one task runs locally and over SSH in parallel ==\n'
# ---------------------------------------------------------------------------
SSHD_BIN="$(command -v sshd || true)"
[ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ] && SSHD_BIN=/usr/sbin/sshd
if [ -z "$SSHD_BIN" ] || ! command -v ssh >/dev/null 2>&1; then
  skip 'ephemeral sshd/ssh unavailable; SSH contract section skipped'
else
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
    if kill -0 "$SSHD_PID" 2>/dev/null && ss -ltn 2>/dev/null | grep -Fq "127.0.0.1:$SSH_PORT"; then READY=1; break; fi
    sleep 0.1
  done
  if [ "$READY" -eq 1 ]; then pass "ephemeral sshd on 127.0.0.1:$SSH_PORT"; else fail 'ephemeral sshd did not start' "$(cat "$SSH_TMP/sshd.log" 2>/dev/null || true)"; fi
  if [ "$READY" -eq 1 ]; then
    KH="$WORK/known_hosts-loop"
    ADD_OUT="$("$HOST_BIN" machine add --state-dir "$STATE" \
      --name loopback --host 127.0.0.1 --port "$SSH_PORT" --user "$REAL_USER" \
      --identity "$SSH_TMP/client_ed25519" --use-ssh-config false \
      --host-key-policy accept-new --known-hosts-file "$KH" 2>&1)"
    MACHINE_ID="$(printf '%s' "$ADD_OUT" | sed -n 's/^id=//p' | head -n 1)"
    [ -n "$MACHINE_ID" ] && pass "machine.add returned $MACHINE_ID" || fail 'machine.add returned an id' "$ADD_OUT"
    PROBE_OUT="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$MACHINE_ID" --timeout-seconds 15 2>&1)"
    contains 'SSH machine probes online' 'status=online' "$PROBE_OUT"

    ROPEN="$(rpc workspace.open "$(jq -n --arg m "$MACHINE_ID" --arg root "$REPO" '{machine_id:$m,root:$root}')")"
    RWS="$(printf '%s' "$ROPEN" | jq -r '.workspace.id // empty')"
    [ -n "$RWS" ] && pass "SSH workspace.open returned $RWS" || fail 'SSH workspace.open returned an id' "$ROPEN"
    eq 'SSH workspace kind is ssh' 'ssh' "$(printf '%s' "$ROPEN" | jq -r '.workspace.kind')"

    DUAL_TASK="$(rpc task.create "$(jq -n --arg pj "$PJ" --arg ws "$WS" '{title:"dual",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
    L_RUN="$(rpc run.create "$(jq -n --arg tk "$DUAL_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 2; echo local-done\"",idempotency_key:"dual/local"}')" | jq -r '.run.id')"
    R_RUN="$(rpc run.create "$(jq -n --arg tk "$DUAL_TASK" --arg ws "$RWS" --arg m "$MACHINE_ID" '{task_id:$tk,workspace_id:$ws,machine_id:$m,mode:"command",command:"sh -c \"sleep 2; echo ssh-done\"",idempotency_key:"dual/ssh"}')" | jq -r '.run.id')"
    sleep 0.6
    L_ST="$(run_status "$L_RUN")"; R_ST="$(run_status "$R_RUN")"
    [ "$L_ST" = "running" ] || [ "$L_ST" = "verifying" ] && pass "local run is active ($L_ST)" || fail "local run is active (got $L_ST)"
    [ "$R_ST" = "running" ] || [ "$R_ST" = "verifying" ] && pass "SSH run runs in parallel ($R_ST)" || fail "SSH run runs in parallel (got $R_ST)"
    wait_run "$L_RUN" succeeded 300 && pass 'local run succeeded' || fail 'local run succeeded' "$(rpc run.get "$(jq -n --arg id "$L_RUN" '{run_id:$id}')")"
    wait_run "$R_RUN" succeeded 300 && pass 'SSH run succeeded' || fail 'SSH run succeeded' "$(rpc run.get "$(jq -n --arg id "$R_RUN" '{run_id:$id}')")"
    DUAL="$(rpc run.get "$(jq -n --arg id "$R_RUN" '{run_id:$id}')")"
    eq 'SSH run records the SSH machine' "$MACHINE_ID" "$(printf '%s' "$DUAL" | jq -r '.run.machine_id')"
    contains 'SSH verify evidence ran over the same contract' 'verify[1]' "$(printf '%s' "$DUAL" | jq -c '.evidence')"
    eq 'one task aggregates local + SSH runs' '2/2 runs succeeded' "$(rpc task.get "$(jq -n --arg id "$DUAL_TASK" '{task_id:$id}')" | jq -r '.task.result_summary')"
    eq 'dual task is succeeded' 'succeeded' "$(rpc task.get "$(jq -n --arg id "$DUAL_TASK" '{task_id:$id}')" | jq -r '.task.status')"
  fi
  kill "$SSHD_PID" 2>/dev/null || true
  wait "$SSHD_PID" 2>/dev/null || true
  SSHD_PID=""
fi

# ---------------------------------------------------------------------------
printf '\n== 6. event replay: projection rebuilt after a host restart ==\n'
# ---------------------------------------------------------------------------
stop_host
if start_host "$STATE"; then pass 'host restarted on the same state dir'; else fail 'host restarted'; fi
# stdout is block-buffered into a file, so the reconcile line may not be
# visible yet; the projection itself is what matters (unit-tested separately).
EVSEQ="$("$HOST_BIN" status --state-dir "$STATE" | sed -n 's/^event_seq=//p')"
[ -n "$EVSEQ" ] && [ "$EVSEQ" != "0" ] && pass "restart kept the event log (event_seq=$EVSEQ)" || fail 'restart kept the event log' "event_seq=$EVSEQ"
eq 'run survives the restart' 'succeeded' "$(run_status "$RID")"
eq 'task survives the restart' 'succeeded' "$(rpc task.get "$(jq -n --arg id "$TK" '{task_id:$id}')" | jq -r '.task.status')"
eq 'evidence survives the restart' '2' "$(rpc run.get "$(jq -n --arg id "$RID" '{run_id:$id}')" | jq -r '.evidence | length')"
eq 'search index survives the restart' 'true' "$(rpc search.sessions '{"query":"smoke accepts the lint finding"}' | jq -r '.hits | length > 0')"

# ---------------------------------------------------------------------------
printf '\n== 7. state machine rejects illegal transitions ==\n'
# ---------------------------------------------------------------------------
ILLEGAL="$(rpc task.cancel "$(jq -n --arg id "$TK" '{task_id:$id}')")"
contains 'cancelling a succeeded task is refused' 'Conflict' "$ILLEGAL"
DONE_CANCEL="$(rpc run.cancel "$(jq -n --arg id "$RID" '{run_id:$id}')")"
eq 'cancelling a succeeded run is a no-op' 'succeeded' "$(printf '%s' "$DONE_CANCEL" | jq -r '.run.status')"
BAD_CREATE="$(rpc task.create '{"title":"","status":"ready"}')"
contains 'task.create rejects an empty title' 'Invalid' "$BAD_CREATE"
INVALID_TASK="$(rpc task.create "$(jq -n --arg ws "$WS" '{title:"invalid target",workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
BAD_RUN="$(rpc run.create "$(jq -n --arg tk "$INVALID_TASK" --arg ws "$WS" '{task_id:$tk,workspace_id:$ws,mode:"command",command:""}')")"
contains 'run.create rejects an empty command' 'Invalid' "$BAD_RUN"
BAD_GET="$(rpc run.get '{"run_id":"run_missing"}')"
contains 'run.get reports a missing run' 'NotFound' "$BAD_GET"

stop_host
summary
