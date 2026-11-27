#!/usr/bin/env bash
# MoNexus M4 — Agent session (ACP) / permission Decision / memory smoke test.
#
# TEST HARNESS ONLY. Everything runs against a temp state dir and a temp HOME;
# the mock ACP agent is a JavaScript test double under tests/agent and is never
# linked into monexus-host. No model credentials are read or logged.
#
# Covers: probe readiness (ok + auth failure), AGENTS.md read-only, MEMORY.md
# audited writes, start/inject/stream/send, permission -> Decision -> answer ->
# ACP continue, stop + memory snapshot artifact, resume via session/load,
# stdout fallback, and host-restart reconcile. The real claude-code-acp adapter
# is probed once when M4_REAL_ACP=1 (otherwise reported as skipped).
#
# Usage:
#   bash scripts/agent_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/agent_smoke.sh
#   M4_REAL_ACP=1 bash scripts/agent_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
REAL_USER="$(id -un)"
REAL_HOME="${M4_REAL_HOME:-${HOME:-}}"
if [ -z "$REAL_HOME" ]; then
  REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
fi
if [ -z "$REAL_HOME" ] && command -v dscl >/dev/null 2>&1; then
  REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m4-smoke.XXXXXX")"
mkdir -p "$WORK/home"
export HOME="$WORK/home"
export MONEXUS_ACP_TIMEOUT_MS="${MONEXUS_ACP_TIMEOUT_MS:-20000}"

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  printf 'node is required for the mock ACP agent\n' >&2
  exit 2
fi
export PATH="$(dirname "$NODE_BIN"):$PATH"

MOCK_ACP="$ROOT/tests/agent/mock_acp_agent.mjs"
MOCK_STDOUT="$ROOT/tests/agent/mock_stdout_agent.mjs"

PASSED=0
FAILED=0
SKIPPED=0
HOST_PID=""
STATE="$WORK/state"
RPC_OUT=""
RPC_CODE=0
DEC_ID=""

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
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi
}
mode_of() { # path
  stat -c %a "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}

cleanup() {
  if [ -n "$HOST_PID" ]; then kill "$HOST_PID" 2>/dev/null || true; wait "$HOST_PID" 2>/dev/null || true; fi
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

crash_host() { # simulate a hard host crash: no graceful finalize
  if [ -n "$HOST_PID" ]; then
    kill -9 "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
    HOST_PID=""
  fi
}

rpc() { # method params-json
  "$HOST_BIN" rpc --state-dir "$STATE" --method "$1" --params "$2" 2>&1
}
rpc_call() { # method params-json -> RPC_OUT/RPC_CODE
  RPC_OUT="$(rpc "$1" "$2")"
  RPC_CODE=$?
}

probe_params() { # agent_id env_json
  local env_json="${2:-}"
  [ -z "$env_json" ] && env_json='{}'
  jq -n --arg aid "$1" --arg cmd "$NODE_BIN" --arg script "$MOCK_ACP" \
    --argjson env "$env_json" \
    '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script],cwd:"",env:$env}'
}

start_params() { # agent_id prompt env_json
  local env_json="${3:-}"
  [ -z "$env_json" ] && env_json='{}'
  jq -n --arg aid "$1" --arg prompt "$2" --arg cmd "$NODE_BIN" --arg script "$MOCK_ACP" \
    --argjson env "$env_json" \
    '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script],cwd:"",prompt:$prompt,memory_limit:4096,env:$env}'
}

read_params() { # session_id cursor
  jq -n --arg id "$1" --argjson c "${2:-0}" '{session_id:$id,cursor:$c}'
}

# Poll agent.read until the transcript contains `needle` (whole transcript is
# returned for cursor 0). Sets RPC_OUT to the last read result.
poll_text() { # session_id needle
  local sid="$1" needle="$2" tries=0 out=""
  while [ "$tries" -lt 200 ]; do
    out="$(rpc agent.read "$(read_params "$sid" 0)")"
    if printf '%s' "$out" | grep -Fq -- "$needle"; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

# Poll agent.read until the projected state equals `want`.
poll_state() { # session_id want
  local sid="$1" want="$2" tries=0 out="" state=""
  while [ "$tries" -lt 200 ]; do
    out="$(rpc agent.read "$(read_params "$sid" 0)")"
    state="$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)"
    if [ "$state" = "$want" ]; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

# Poll decision.list for the first pending decision of a session.
poll_pending_decision() { # session_id
  local sid="$1" tries=0 out="" id=""
  while [ "$tries" -lt 200 ]; do
    out="$(rpc decision.list "$(jq -n --arg sid "$sid" '{status:"pending",session_id:$sid}')")"
    id="$(printf '%s' "$out" | jq -r '(.decisions // []) | .[0].id // empty' 2>/dev/null)"
    if [ -n "$id" ]; then DEC_ID="$id"; RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

mkdir -p "$STATE"
printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s\nnode=%s\n\n' "$WORK" "$NODE_BIN"

if start_host "$STATE"; then pass 'host started on a temp state dir'; else fail 'host started'; fi

# ---------------------------------------------------------------------------
printf '== 1. readiness: ACP mock probe ok / auth failure -> Decision ==\n'
# ---------------------------------------------------------------------------
rpc_call agent.probe "$(probe_params mock '{}')"
contains 'mock ACP probe succeeds' '"ok":true' "$RPC_OUT"
eq 'probe reports the mock agent name' 'mock-acp-agent' "$(printf '%s' "$RPC_OUT" | jq -r '.readiness.agent_name // empty')"
eq 'probe records loadSession support' 'true' "$(printf '%s' "$RPC_OUT" | jq -r '.readiness.load_session')"
contains 'probe records the initialize + session/new handshake' 'session/new ok' "$(printf '%s' "$RPC_OUT" | jq -r '.readiness.detail // empty')"

rpc_call agent.probe "$(probe_params mock-auth '{"MOCK_ACP_FAIL":"auth"}')"
eq 'auth-failing probe is not ready' 'false' "$(printf '%s' "$RPC_OUT" | jq -r '.readiness.ok')"
eq 'auth failure is classified as required' 'required' "$(printf '%s' "$RPC_OUT" | jq -r '.readiness.auth // empty')"

AUTH_DEC="$(rpc decision.list '{"status":"pending"}')"
AUTH_DEC_ID="$(printf '%s' "$AUTH_DEC" | jq -r '(.decisions // []) | map(select(.kind=="readiness" and .agent_id=="mock-auth")) | .[0].id // empty')"
[ -n "$AUTH_DEC_ID" ] && pass "readiness failure created Decision $AUTH_DEC_ID" || fail 'readiness failure created a Decision' "$AUTH_DEC"
rpc_call decision.respond "$(jq -n --arg id "$AUTH_DEC_ID" '{decision_id:$id,option_id:"",text:"owner saw the login prompt",answered_by:"owner"}')"
eq 'readiness Decision can be answered in the inbox' 'answered' "$(printf '%s' "$RPC_OUT" | jq -r '.decision.status // empty')"

# ---------------------------------------------------------------------------
printf '\n== 2. agent home: AGENTS.md read-only, MEMORY.md audited write ==\n'
# ---------------------------------------------------------------------------
AGENTS_READ="$(rpc agent.memory.read '{"agent_id":"mock","file":"AGENTS.md"}')"
contains 'AGENTS.md exists with the read-only contract' 'read-only operating contract' "$AGENTS_READ"
eq 'AGENTS.md is mode 0444' '444' "$(mode_of "$STATE/agents/mock/AGENTS.md")"
rpc_call agent.memory.write '{"agent_id":"mock","file":"AGENTS.md","content":"hacked","actor":"owner"}'
[ "$RPC_CODE" -ne 0 ] && pass 'writing AGENTS.md is refused' || fail 'writing AGENTS.md is refused' "$RPC_OUT"
contains 'AGENTS.md refusal is readable' 'Unsupported' "$RPC_OUT"

rpc_call agent.memory.write "$(jq -n '{agent_id:"mock",file:"MEMORY.md",content:"# MEMORY.md\nSMOKE-MEMORY: prefers concise replies\n",actor:"owner"}')"
contains 'MEMORY.md write acknowledges it' '"ok":true' "$RPC_OUT"
contains 'MEMORY.md write is audited with a digest' '"digest":"fnv-' "$RPC_OUT"
MEM_READ="$(rpc agent.memory.read '{"agent_id":"mock","file":"MEMORY.md"}')"
contains 'MEMORY.md reads back the new text' 'SMOKE-MEMORY: prefers concise replies' "$MEM_READ"

# ---------------------------------------------------------------------------
printf '\n== 3. ACP session: start + memory injection + streaming + send ==\n'
# ---------------------------------------------------------------------------
rpc_call agent.start "$(start_params mock 'hello memory' '')"
SID="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID" ] && pass "agent.start returned $SID" || fail 'agent.start returned a session' "$RPC_OUT"
eq 'session starts in running state' 'running' "$(printf '%s' "$RPC_OUT" | jq -r '.session.state')"
eq 'session records the ACP session id' 'mock-session-1' "$(printf '%s' "$RPC_OUT" | jq -r '.session.acp_session_id')"
eq 'session reports injected memory' 'true' "$(printf '%s' "$RPC_OUT" | jq -r '.session.memory_injected')"
[ "$(printf '%s' "$RPC_OUT" | jq -r '.session.memory_bytes')" -gt 0 ] && pass 'memory_bytes is positive' || fail 'memory_bytes is positive' "$RPC_OUT"

if poll_text "$SID" 'MEMORY_SEEN'; then pass 'adapter saw MEMORY.md in the injected prompt'; else fail 'adapter saw MEMORY.md' "$RPC_OUT"; fi
if poll_text "$SID" 'AGENTS_SEEN'; then pass 'adapter saw AGENTS.md in the injected prompt'; else fail 'adapter saw AGENTS.md' "$RPC_OUT"; fi
if poll_text "$SID" 'BLOCK_SEEN'; then pass 'adapter saw the MoNexus context block'; else fail 'adapter saw the context block' "$RPC_OUT"; fi
if poll_text "$SID" 'MOCK#1'; then pass 'transcript contains streamed ACP chunks'; else fail 'transcript contains streamed chunks' "$RPC_OUT"; fi
contains 'thought chunks are surfaced' '[thought]' "$RPC_OUT"
if poll_state "$SID" idle; then pass 'session returns to idle after the turn'; else fail 'session returns to idle' "$RPC_OUT"; fi
CURSOR="$(printf '%s' "$RPC_OUT" | jq -r '.cursor')"
INCR="$(rpc agent.read "$(read_params "$SID" "$CURSOR")")"
eq 'agent.read is incremental at the cursor' '' "$(printf '%s' "$INCR" | jq -r '.text')"

rpc_call agent.send "$(jq -n --arg id "$SID" '{session_id:$id,text:"second turn"}')"
contains 'agent.send acknowledges the follow-up' '"ok":true' "$RPC_OUT"
if poll_text "$SID" 'MOCK#2'; then pass 'follow-up prompt produced a second turn'; else fail 'follow-up turn' "$RPC_OUT"; fi
if poll_state "$SID" idle; then pass 'second turn finished'; else fail 'second turn finished' "$RPC_OUT"; fi

# ---------------------------------------------------------------------------
printf '\n== 4. permission -> Decision -> inbox answer -> ACP continues ==\n'
# ---------------------------------------------------------------------------
rpc_call agent.send "$(jq -n --arg id "$SID" '{session_id:$id,text:"please ask permission before acting"}')"
contains 'permission turn accepted' '"ok":true' "$RPC_OUT"
if poll_pending_decision "$SID"; then pass "permission created Decision $DEC_ID"; else fail 'permission created a Decision' "$RPC_OUT"; fi
eq 'pending decision kind is permission' 'permission' "$(printf '%s' "$RPC_OUT" | jq -r '.decisions[0].kind')"
eq 'pending decision lists both ACP options' '2' "$(printf '%s' "$RPC_OUT" | jq -r '.decisions[0].options | length')"
contains 'decision detail carries the tool call' 'mock tool call' "$(printf '%s' "$RPC_OUT" | jq -r '.decisions[0].detail')"
if poll_state "$SID" waiting_decision; then pass 'session state is waiting_decision'; else fail 'session state is waiting_decision' "$RPC_OUT"; fi
PERM_DEC="$DEC_ID"

rpc_call decision.respond "$(jq -n --arg id "$PERM_DEC" '{decision_id:$id,option_id:"allow_once",text:"",answered_by:"owner"}')"
eq 'permission answer is persisted as answered' 'answered' "$(printf '%s' "$RPC_OUT" | jq -r '.decision.status // empty')"
eq 'permission answer selected the ACP option' 'allow_once' "$(printf '%s' "$RPC_OUT" | jq -r '.decision.option_id // empty')"
eq 'permission answer was delivered to ACP' '' "$(printf '%s' "$RPC_OUT" | jq -r '.decision.delivery_error // empty')"
if poll_text "$SID" 'PERMISSION selected:allow_once'; then pass 'adapter continued after the inbox answer'; else fail 'adapter continued after the answer' "$RPC_OUT"; fi
if poll_state "$SID" idle; then pass 'session resumes after the permission answer'; else fail 'session resumes after the answer' "$RPC_OUT"; fi
AFTER="$(rpc decision.list "$(jq -n --arg sid "$SID" '{status:"pending",session_id:$sid}')")"
eq 'no pending decisions remain for the session' '[]' "$(printf '%s' "$AFTER" | jq -c '.decisions // []')"

# ---------------------------------------------------------------------------
printf '\n== 5. stop + MEMORY snapshot diff artifact ==\n'
# ---------------------------------------------------------------------------
rpc_call agent.memory.write "$(jq -n '{agent_id:"mock",file:"MEMORY.md",content:"# MEMORY.md\nSMOKE-MEMORY: updated during the M4 session\n",actor:"owner"}')"
contains 'in-session MEMORY.md write is audited' '"ok":true' "$RPC_OUT"
rpc_call agent.stop "$(jq -n --arg id "$SID" '{session_id:$id}')"
contains 'agent.stop acknowledges the session' '"ok":true' "$RPC_OUT"
SESSIONS="$(rpc agent.list '{"agent_id":"mock"}')"
STOPPED="$(printf '%s' "$SESSIONS" | jq -c --arg id "$SID" '(.sessions // []) | map(select(.id==$id)) | .[0]')"
eq 'stopped session state is stopped' 'stopped' "$(printf '%s' "$STOPPED" | jq -r '.state')"
eq 'stopped session stop_reason is cancelled' 'cancelled' "$(printf '%s' "$STOPPED" | jq -r '.stop_reason')"
eq 'stop produced one memory artifact' '1' "$(printf '%s' "$STOPPED" | jq -r '.artifacts | length')"
ART_PATH="$STATE/agents/mock/artifacts/$SID-memory.diff"
[ -f "$ART_PATH" ] && pass 'memory diff artifact exists on disk' || fail 'memory artifact exists' "$ART_PATH"
contains 'artifact contains the changed memory line' 'SMOKE-MEMORY: updated during the M4 session' "$(cat "$ART_PATH" 2>/dev/null)"
eq 'artifact file is mode 0600' '600' "$(mode_of "$ART_PATH")"

# ---------------------------------------------------------------------------
printf '\n== 6. resume via session/load ==\n'
# ---------------------------------------------------------------------------
rpc_call agent.resume "$(jq -n --arg id "$SID" '{session_id:$id}')"
eq 'resume returns the session to idle' 'idle' "$(printf '%s' "$RPC_OUT" | jq -r '.session.state // empty')"
eq 'resume cleared the stop reason' '' "$(printf '%s' "$RPC_OUT" | jq -r '.session.stop_reason // empty')"
rpc_call agent.send "$(jq -n --arg id "$SID" '{session_id:$id,text:"after resume"}')"
contains 'resumed session accepts a prompt' '"ok":true' "$RPC_OUT"
if poll_text "$SID" 'MOCK#1 start'; then pass 'resumed ACP process streams a new turn'; else fail 'resumed process streams' "$RPC_OUT"; fi
rpc_call agent.stop "$(jq -n --arg id "$SID" '{session_id:$id}')"
contains 'resumed session stops cleanly' '"ok":true' "$RPC_OUT"

rpc_call agent.resume "$(jq -n --arg id "$SID" '{session_id:$id}')"
contains 'resume after stop re-opens the same ACP session id' '"acp_session_id":"mock-session-1"' "$RPC_OUT"
rpc_call agent.stop "$(jq -n --arg id "$SID" '{session_id:$id}')"

# ---------------------------------------------------------------------------
printf '\n== 7. stdout fallback: raw lines + EOF finalize ==\n'
# ---------------------------------------------------------------------------
STDOUT_PARAMS="$(jq -n --arg cmd "$NODE_BIN" --arg script "$MOCK_STDOUT" '{agent_id:"mock-stdout",mode:"stdout",command:$cmd,args:[$script],cwd:"",prompt:"",memory_limit:0,env:{}}')"
rpc_call agent.start "$STDOUT_PARAMS"
SID_S="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_S" ] && pass "stdout agent.start returned $SID_S" || fail 'stdout agent.start' "$RPC_OUT"
if poll_text "$SID_S" 'STDOUT-MOCK line 3'; then pass 'stdout lines reach the transcript'; else fail 'stdout lines reach the transcript' "$RPC_OUT"; fi
if poll_state "$SID_S" exited; then pass 'stdout EOF finalizes the session as exited'; else fail 'stdout EOF finalizes the session' "$RPC_OUT"; fi
eq 'stdout session stop_reason is exited' 'exited' "$(rpc agent.read "$(read_params "$SID_S" 0)" | jq -r '.stop_reason')"

# ---------------------------------------------------------------------------
printf '\n== 8. host restart: live sessions close, pending decisions expire ==\n'
# ---------------------------------------------------------------------------
rpc_call agent.start "$(start_params mock-restart 'please permission before restart' '')"
SID_R="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_R" ] && pass "restart-test session $SID_R started" || fail 'restart-test session started' "$RPC_OUT"
if poll_pending_decision "$SID_R"; then pass "restart-test Decision $DEC_ID is pending"; else fail 'restart-test Decision is pending' "$RPC_OUT"; fi
RESTART_DEC="$DEC_ID"
crash_host
if start_host "$STATE"; then pass 'host restarted after a hard crash'; else fail 'host restarted'; fi
RESTARTED="$(rpc agent.read "$(read_params "$SID_R" 0)")"
eq 'interrupted session is marked exited' 'exited' "$(printf '%s' "$RESTARTED" | jq -r '.state')"
eq 'interrupted session stop_reason is host_restarted' 'host_restarted' "$(printf '%s' "$RESTARTED" | jq -r '.stop_reason')"
PENDING_AFTER="$(rpc decision.list '{"status":"pending"}')"
not_contains 'the interrupted session decision is no longer pending' "$RESTART_DEC" "$PENDING_AFTER"
EXPIRED="$(rpc decision.list '{"status":"expired"}')"
contains 'the interrupted session decision is expired' "$RESTART_DEC" "$EXPIRED"

# ---------------------------------------------------------------------------
printf '\n== 9. events: the whole slice is replayable ==\n'
# ---------------------------------------------------------------------------
EVENTS="$("$HOST_BIN" subscribe --state-dir "$STATE" --since 0 --max-events 800 --timeout-ms 6000 2>&1)"
contains 'replay includes agent.readiness.ok' 'type=agent.readiness.ok' "$EVENTS"
contains 'replay includes agent.readiness.failed' 'type=agent.readiness.failed' "$EVENTS"
contains 'replay includes agent.session.started' 'type=agent.session.started' "$EVENTS"
contains 'replay includes agent.session.output' 'type=agent.session.output' "$EVENTS"
contains 'replay includes agent.session.resumed' 'type=agent.session.resumed' "$EVENTS"
contains 'replay includes agent.session.stopped' 'type=agent.session.stopped' "$EVENTS"
contains 'replay includes agent.session.exited' 'type=agent.session.exited' "$EVENTS"
contains 'replay includes decision.requested' 'type=decision.requested' "$EVENTS"
contains 'replay includes decision.responded' 'type=decision.responded' "$EVENTS"
contains 'replay includes decision.expired' 'type=decision.expired' "$EVENTS"
contains 'replay includes agent.memory.updated' 'type=agent.memory.updated' "$EVENTS"
contains 'replay includes agent.artifact.created' 'type=agent.artifact.created' "$EVENTS"

# ---------------------------------------------------------------------------
printf '\n== 10. real claude-code-acp adapter (opt-in, one probe) ==\n'
# ---------------------------------------------------------------------------
if [ "${M4_REAL_ACP:-0}" != "1" ]; then
  skip 'real ACP adapter not requested (M4_REAL_ACP=1 to probe; needs a logged-in agent account)'
else
  REAL_STATE="$WORK/real-state"
  mkdir -p "$REAL_STATE"
  HOME="$REAL_HOME" "$HOST_BIN" serve --state-dir "$REAL_STATE" --heartbeat-ms 60000 >"$REAL_STATE/.log" 2>&1 &
  REAL_PID=$!
  REAL_STARTED=0
  for _ in $(seq 1 100); do
    if "$HOST_BIN" status --state-dir "$REAL_STATE" >/dev/null 2>&1; then REAL_STARTED=1; break; fi
    kill -0 "$REAL_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [ "$REAL_STARTED" -ne 1 ]; then
    skip 'real adapter UNVERIFIED: host with the real HOME did not start'
  else
    REAL_OUT="$(HOME="$REAL_HOME" "$HOST_BIN" rpc --state-dir "$REAL_STATE" --method agent.probe --params '{"agent_id":"claude","mode":"acp","command":"","args":[],"env":{}}' 2>&1)"
    if printf '%s' "$REAL_OUT" | jq -e '.readiness.ok == true' >/dev/null 2>&1; then
      pass "real claude-code-acp readiness ok ($(printf '%s' "$REAL_OUT" | jq -r '.readiness.agent_name // "?"') $(printf '%s' "$REAL_OUT" | jq -r '.readiness.agent_version // ""'))"
    else
      REASON="$(printf '%s' "$REAL_OUT" | jq -r '.readiness.error // .' 2>/dev/null | head -c 300)"
      skip "real adapter UNVERIFIED: ${REASON:-no result}"
    fi
    kill "$REAL_PID" 2>/dev/null || true
    wait "$REAL_PID" 2>/dev/null || true
  fi
fi

stop_host
summary
