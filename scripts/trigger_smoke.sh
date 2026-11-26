#!/usr/bin/env bash
# MoNexus A3.2 — trigger acceptance smoke test.
#
# TEST HARNESS ONLY. Everything runs against a temp state dir and a temp HOME.
# The mock ACP agent is a JavaScript test double under tests/agent and is never
# linked into monexus-host. No model credentials are read or logged. The script
# needs no privileges, fixed ports or host-level changes, so it runs locally and
# in CI.
#
# Covers ADR-0014 §5/§7/§8 and docs/v0.2-plan.md §2.3 acceptance 1-5:
#   - create / disable / expire, and trigger.* off by default
#   - trigger Task -> ready Task -> agent Run -> ACP permission -> owner
#     Decision -> run outcome (allow, deny, expired); a trigger cannot create an
#     approval exemption or answer the Decision
#   - disable stops new Tasks but leaves an existing Run running
#   - event fires exactly once across duplicate delivery / cursor regression /
#     host restart; ignore_self; cascade depth 8; bounded ping-pong
#   - schedule slot fires once, duplicate ticks and restarts do not replay it;
#     downtime skip / coalesce_once policies
#   - signed webhook success, replay, nonce reuse, stale timestamp, bad
#     signature, bounded rate burst and one coalesced rate_limited audit
#   - audit links source / fire_key / Task / Run; secrets never enter events or
#     logs; key file is 0600
#
# Usage:
#   bash scripts/trigger_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/trigger_smoke.sh
#
# Requirements: jq, curl, openssl (HMAC), python3 (SQLite inspection), node
# (mock ACP). The host binary is the native debug build by default.
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
MOCK_ACP="$ROOT/tests/agent/mock_acp_agent.mjs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-trigger-smoke.XXXXXX")"
STATE="$WORK/state"
OFF_STATE="$WORK/off-state"
WS_DIR="$WORK/ws"
mkdir -p "$WORK/home" "$STATE" "$OFF_STATE" "$WS_DIR" "$WORK/bin"
echo hi >"$WS_DIR/README.md"
export HOME="$WORK/home"
export MONEXUS_ACP_TIMEOUT_MS="${MONEXUS_ACP_TIMEOUT_MS:-20000}"
# Make the per-trigger webhook bucket the binding one so one burst can prove
# the bound without creating hundreds of Tasks; the key/global capacities stay
# larger than the trigger burst of 20, so the same run cannot exceed them.
export MONEXUS_WEBHOOK_RATE_TRIGGER_PER_MIN=5
export MONEXUS_WEBHOOK_RATE_KEY_PER_MIN=600
export MONEXUS_WEBHOOK_RATE_GLOBAL_PER_MIN=3000
export MONEXUS_WEBHOOK_FRESHNESS_S=300

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  printf 'node is required for the mock ACP agent\n' >&2
  exit 2
fi
# The trigger's default agent command is `npx -y @zed-industries/claude-code-acp`;
# this shim routes it to the local mock without network access.
cat >"$WORK/bin/npx" <<SHIM
#!/bin/sh
exec "$NODE_BIN" "$MOCK_ACP" "\$@"
SHIM
chmod +x "$WORK/bin/npx"
export PATH="$WORK/bin:$(dirname "$NODE_BIN"):$PATH"

PASSED=0
FAILED=0
SKIPPED=0
HOST_PID=""
OFF_PID=""
RPC_OUT=""
DB="$STATE/monexus.db"

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "--- output ---" "$2" "--------------" >&2; fi
}
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s\n' "$1"; }
eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi
}
ge() {
  if [ "$3" -ge "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 (expected >= $2, got: $3)"; fi
}
le() {
  if [ "$3" -le "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 (expected <= $2, got: $3)"; fi
}
contains() {
  if printf '%s' "$3" | grep -Fq -- "$2"; then pass "$1"; else fail "$1 (missing: $2)" "$3"; fi
}
contains_ci() {
  if printf '%s' "$3" | grep -Fiq -- "$2"; then pass "$1"; else fail "$1 (missing: $2)" "$3"; fi
}
not_contains() {
  if printf '%s' "$3" | grep -Fq -- "$2"; then fail "$1 (unexpected: $2)" "$3"; else pass "$1"; fi
}

cleanup() {
  if [ -n "$HOST_PID" ]; then kill "$HOST_PID" 2>/dev/null || true; wait "$HOST_PID" 2>/dev/null || true; fi
  if [ -n "$OFF_PID" ]; then kill "$OFF_PID" 2>/dev/null || true; wait "$OFF_PID" 2>/dev/null || true; fi
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
for tool in jq curl openssl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s is required for this smoke test\n' "$tool" >&2
    exit 2
  fi
done

rpc() { # method params-json
  "$HOST_BIN" rpc --state-dir "$STATE" --method "$1" --params "$2" 2>&1
}
rpc_off() {
  "$HOST_BIN" rpc --state-dir "$OFF_STATE" --method "$1" --params "$2" 2>&1
}

start_host() {
  local log="$STATE/.log"
  "$HOST_BIN" serve --state-dir "$STATE" --trigger-enabled true \
    --heartbeat-ms 60000 >>"$log" 2>&1 &
  HOST_PID=$!
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if "$HOST_BIN" status --state-dir "$STATE" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then tail -30 "$log" >&2 || true; return 1; fi
    tries=$((tries + 1)); sleep 0.1
  done
  tail -30 "$log" >&2 || true
  return 1
}

stop_host() {
  if [ -n "$HOST_PID" ]; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
    HOST_PID=""
  fi
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
plus_seconds_iso() {
  python3 - "$1" <<'PY'
import datetime
import sys
seconds = float(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
print((now + datetime.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
PY
}
host_port() { jq -r '.port' "$STATE/host.json"; }

db_count() { # sql [bind args...]
  local sql="$1"
  shift
  python3 - "$DB" "$sql" "$@" <<'PY'
import sqlite3
import sys
db, sql, *args = sys.argv[1:]
conn = sqlite3.connect(db)
row = conn.execute(sql, args).fetchone()
print(0 if row is None or row[0] is None else row[0])
PY
}

fire_param() { jq -n --arg id "$1" '{trigger_id:$id}'; }
get_trigger() { rpc trigger.get "$(fire_param "$1")"; }
fire_count() {
  get_trigger "$1" | jq -r '(.recent_fires // []) | length' 2>/dev/null || echo 0
}
task_count() { rpc task.list '{}' | jq -r '(.tasks // []) | length' 2>/dev/null || echo 0; }
run_status() {
  rpc run.get "$(jq -n --arg id "$1" '{run_id:$id}')" | jq -r '.run.status // empty'
}

poll_fires() { # trigger_id minimum
  local id="$1" want="$2" tries=0 out="" n=0
  while [ "$tries" -lt 600 ]; do
    out="$(get_trigger "$id")"
    n="$(printf '%s' "$out" | jq -r '(.recent_fires // []) | length' 2>/dev/null || echo 0)"
    if [ "$n" -ge "$want" ]; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

poll_trigger_state() { # trigger_id state
  local id="$1" want="$2" tries=0 out="" state=""
  while [ "$tries" -lt 150 ]; do
    out="$(get_trigger "$id")"
    state="$(printf '%s' "$out" | jq -r '.trigger.state // empty' 2>/dev/null)"
    if [ "$state" = "$want" ]; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

poll_pending_decision() { # run_id
  local rid="$1" tries=0 out="" did=""
  while [ "$tries" -lt 300 ]; do
    out="$(rpc decision.list "$(jq -n --arg rid "$rid" '{status:"pending",run_id:$rid}')")"
    did="$(printf '%s' "$out" | jq -r '(.decisions // [])[0].id // empty' 2>/dev/null)"
    if [ -n "$did" ]; then
      DEC_ID="$did"
      DEC_JSON="$(printf '%s' "$out" | jq -c '(.decisions // [])[0]')"
      RPC_OUT="$out"
      return 0
    fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

poll_run_terminal() { # run_id
  local rid="$1" tries=0 out="" st=""
  while [ "$tries" -lt 300 ]; do
    out="$(rpc run.get "$(jq -n --arg id "$rid" '{run_id:$id}')")"
    st="$(printf '%s' "$out" | jq -r '.run.status // empty' 2>/dev/null)"
    case "$st" in
      succeeded|failed|cancelled|lost) RPC_OUT="$out"; return 0 ;;
    esac
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

poll_decision_status() { # run_id status
  local rid="$1" want="$2" tries=0 out="" st=""
  while [ "$tries" -lt 150 ]; do
    out="$(rpc decision.list "$(jq -n --arg rid "$rid" '{run_id:$rid}')")"
    st="$(printf '%s' "$out" | jq -r --arg want "$want" \
      '[(.decisions // [])[] | select(.status == $want)] | length' 2>/dev/null || echo 0)"
    if [ "$st" != "0" ]; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

wait_create_window() {
  local s
  while :; do
    s="$(date +%S)"; s=$((10#$s))
    if [ "$s" -ge 50 ] && [ "$s" -le 56 ]; then return 0; fi
    sleep 0.5
  done
}

# ---------------------------------------------------------------------------
# 1. Feature flag off by default
# ---------------------------------------------------------------------------
"$HOST_BIN" serve --state-dir "$OFF_STATE" --heartbeat-ms 60000 \
  >"$OFF_STATE/.log" 2>&1 &
OFF_PID=$!
off_ready=0
for _ in $(seq 1 100); do
  if "$HOST_BIN" status --state-dir "$OFF_STATE" >/dev/null 2>&1; then off_ready=1; break; fi
  sleep 0.1
done
if [ "$off_ready" = 1 ]; then
  OFF_CREATE="$(rpc_off trigger.create \
    '{"name":"off","type":"webhook","target":{"title_template":"x"},"source":{},"enabled":true}')"
  contains_ci "trigger.create is unsupported when trigger.enabled is off" \
    "unsupported" "$OFF_CREATE"
  OFF_PORT="$(jq -r '.port' "$OFF_STATE/host.json")"
  OFF_HOOK="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$OFF_PORT/hooks/trg_off" \
    -H 'Content-Type: application/json' --data-binary '{}' || true)"
  eq "webhook route is a uniform 401 when trigger.enabled is off" 401 "$OFF_HOOK"
  pass "the A3 flag stays off unless --trigger-enabled is passed"
else
  fail "off-by-default host did not start" "$(tail -20 "$OFF_STATE/.log" 2>/dev/null)"
fi
kill "$OFF_PID" 2>/dev/null || true
wait "$OFF_PID" 2>/dev/null || true
OFF_PID=""

# ---------------------------------------------------------------------------
# 2. Main host + workspace
# ---------------------------------------------------------------------------
if ! start_host; then
  fail "trigger-enabled host did not start"
  summary
  exit 1
fi
pass "trigger-enabled host started on a loopback port"

OPEN="$(rpc workspace.open "$(jq -n --arg root "$WS_DIR" '{machine_id:"",root:$root}')")"
WS="$(printf '%s' "$OPEN" | jq -r '.workspace.id // empty')"
if [ -n "$WS" ]; then pass "workspace opened for trigger targets"; else
  fail "workspace.open failed" "$OPEN"; summary; exit 1
fi

# ---------------------------------------------------------------------------
# 3. Create / disable / expire
# ---------------------------------------------------------------------------
BASIC_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"basic",type:"webhook",
    target:{title_template:"B {{title}}",workspace_id:$ws},
    source:{payload_fields:["title"]},enabled:true}')")"
BASIC="$(printf '%s' "$BASIC_JSON" | jq -r '.trigger.id // empty')"
if [ -n "$BASIC" ]; then pass "trigger.create returns a trigger id"; else
  fail "trigger.create failed" "$BASIC_JSON"; summary; exit 1
fi
eq "a new trigger is enabled" true \
  "$(printf '%s' "$BASIC_JSON" | jq -r '.trigger.enabled')"
DISABLE_JSON="$(rpc trigger.disable "$(fire_param "$BASIC")")"
eq "trigger.disable returns enabled=false" false \
  "$(printf '%s' "$DISABLE_JSON" | jq -r '.trigger.enabled')"
DISABLED_LIST="$(rpc trigger.list '{"state":"disabled"}')"
eq "trigger.list state=disabled contains the trigger" 1 \
  "$(printf '%s' "$DISABLED_LIST" | jq -r --arg id "$BASIC" \
    '[(.triggers // [])[] | select(.id == $id)] | length')"
DISABLED_FIRE="$(rpc trigger.fire "$(fire_param "$BASIC")")"
contains "a disabled trigger cannot fire a new Task" "disabled" "$DISABLED_FIRE"

EXPIRES_AT="$(plus_seconds_iso 3)"
EXP_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" --arg exp "$EXPIRES_AT" \
  '{name:"expiring",type:"webhook",
    target:{title_template:"E {{title}}",workspace_id:$ws},
    source:{payload_fields:["title"]},enabled:true,expires_at:$exp}')")"
EXP="$(printf '%s' "$EXP_JSON" | jq -r '.trigger.id // empty')"
if [ -n "$EXP" ]; then
  if poll_trigger_state "$EXP" expired; then
    pass "an expired trigger is reported as state=expired"
  else
    fail "trigger did not reach state=expired" "$RPC_OUT"
  fi
  EXPIRED_FIRE="$(rpc trigger.fire "$(fire_param "$EXP")")"
  contains "an expired trigger cannot fire a new Task" "expired" "$EXPIRED_FIRE"
else
  fail "trigger.create with expires_at failed" "$EXP_JSON"
fi

# ---------------------------------------------------------------------------
# 4. End-to-end: trigger Task -> agent Run -> permission Decision -> outcome
# ---------------------------------------------------------------------------
CHAIN_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"chain",type:"webhook",
    target:{title_template:"Chain {{title}}",
            goal_template:"please request permission before acting",
            agent_id:"mock",workspace_id:$ws,start_run:true},
    source:{payload_fields:["title"]},enabled:true}')")"
CHAIN="$(printf '%s' "$CHAIN_JSON" | jq -r '.trigger.id // empty')"
if [ -n "$CHAIN" ]; then pass "start_run trigger created"; else
  fail "start_run trigger.create failed" "$CHAIN_JSON"; summary; exit 1
fi

# target validation still rejects privileged fields: a trigger cannot ask for an
# approval/command exemption.
GRANT_TRY="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"grant-try",type:"webhook",
    target:{title_template:"g",workspace_id:$ws,approval:true},
    source:{payload_fields:["title"]},enabled:true}')")"
contains "trigger targets cannot carry approval/command fields" \
  "forbidden field" "$GRANT_TRY"

fire_chain() { # label
  local label="$1"
  local fire task run creation_status
  fire="$(rpc trigger.fire "$(fire_param "$CHAIN")")"
  task="$(printf '%s' "$fire" | jq -r '.task_id // empty')"
  run="$(printf '%s' "$fire" | jq -r '.run_id // empty')"
  if [ -z "$task" ] || [ -z "$run" ]; then
    fail "$label: trigger.fire did not return task+run" "$fire"
    CHAIN_TASK=""; CHAIN_RUN=""
    return 1
  fi
  creation_status="$(python3 - "$DB" "$task" <<'PY'
import sqlite3
import sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute(
    "select json_extract(payload_json, '$.status') from events "
    "where type='task.created' and json_extract(payload_json, '$.id')=?",
    (sys.argv[2],),
).fetchone()
print("" if row is None or row[0] is None else row[0])
PY
)"
  eq "$label: trigger Task commits with status=ready when start_run=true" \
    "ready" "$creation_status"
  CHAIN_TASK="$task"; CHAIN_RUN="$run"
  return 0
}

# 4a. Denied Decision -> not successful
if fire_chain "deny"; then
  if poll_pending_decision "$CHAIN_RUN"; then
    pass "triggered Run requests an ACP permission Decision"
    eq "the Decision carries the triggered Run id" "$CHAIN_RUN" \
      "$(printf '%s' "$DEC_JSON" | jq -r '.run_id')"
    eq "the Decision kind is permission" "permission" \
      "$(printf '%s' "$DEC_JSON" | jq -r '.kind')"
    eq "the Decision is pending until the owner answers" "pending" \
      "$(printf '%s' "$DEC_JSON" | jq -r '.status')"
    eq "a trigger-created Run is running while the Decision is pending" "running" \
      "$(printf '%s' "$DEC_JSON" | jq -r '.run_status')"
    DENY_DEC="$DEC_ID"
    rpc decision.respond "$(jq -n --arg d "$DENY_DEC" \
      '{decision_id:$d,option_id:"reject_once",answered_by:"owner"}')" >/dev/null
    if poll_run_terminal "$CHAIN_RUN"; then
      eq "a denied permission Decision fails the Run" "failed" \
        "$(printf '%s' "$RPC_OUT" | jq -r '.run.status')"
      contains "the Run error names the denied Decision" \
        "permission denied by owner" \
        "$(printf '%s' "$RPC_OUT" | jq -r '.run.last_error')"
      not_contains "a denied Run is not successful" "succeeded" \
        "$(printf '%s' "$RPC_OUT" | jq -r '.run.status')"
    else
      fail "denied Run did not reach a terminal state" "$RPC_OUT"
    fi
    eq "the Decision records the owner as the answerer" "owner" \
      "$(rpc decision.list "$(jq -n --arg rid "$CHAIN_RUN" '{run_id:$rid}')" \
        | jq -r '(.decisions // [])[0].answered_by')"
  else
    fail "no permission Decision appeared for the triggered Run" "$RPC_OUT"
  fi
fi
DENY_TASK="$CHAIN_TASK"; DENY_RUN="$CHAIN_RUN"

# 4b. Allowed Decision -> successful Run
if fire_chain "allow"; then
  if poll_pending_decision "$CHAIN_RUN"; then
    ALLOW_DEC="$DEC_ID"
    rpc decision.respond "$(jq -n --arg d "$ALLOW_DEC" \
      '{decision_id:$d,option_id:"allow_once",answered_by:"owner"}')" >/dev/null
    if poll_run_terminal "$CHAIN_RUN"; then
      eq "an allowed permission Decision lets the Run succeed" "succeeded" \
        "$(printf '%s' "$RPC_OUT" | jq -r '.run.status')"
      eq "the successful Run stops at the evidence gate" "verified" \
        "$(printf '%s' "$RPC_OUT" | jq -r '.run.stop_reason')"
    else
      fail "allowed Run did not reach a terminal state" "$RPC_OUT"
    fi
  else
    fail "no permission Decision appeared for the allow case" "$RPC_OUT"
  fi
fi
ALLOW_TASK="$CHAIN_TASK"; ALLOW_RUN="$CHAIN_RUN"

# 4c. Expired Decision -> not successful
if fire_chain "expire"; then
  if poll_pending_decision "$CHAIN_RUN"; then
    SESSION_ID="$(rpc run.get "$(jq -n --arg id "$CHAIN_RUN" '{run_id:$id}')" \
      | jq -r '.run.session_id // empty')"
    if [ -n "$SESSION_ID" ]; then
      rpc agent.stop "$(jq -n --arg sid "$SESSION_ID" '{session_id:$sid}')" >/dev/null
      if poll_decision_status "$CHAIN_RUN" expired; then
        pass "ending the session expires the pending permission Decision"
      else
        fail "pending Decision did not expire" "$RPC_OUT"
      fi
      if poll_run_terminal "$CHAIN_RUN"; then
        eq "an expired permission Decision fails the Run" "failed" \
          "$(printf '%s' "$RPC_OUT" | jq -r '.run.status')"
        contains "the Run error names the expired Decision" \
          "permission decision expired" \
          "$(printf '%s' "$RPC_OUT" | jq -r '.run.last_error')"
      else
        fail "expired Run did not reach a terminal state" "$RPC_OUT"
      fi
    else
      fail "triggered Run has no session id to end" "$RPC_OUT"
    fi
  else
    fail "no permission Decision appeared for the expire case" "$RPC_OUT"
  fi
fi
EXPIRE_RUN="$CHAIN_RUN"

# 4d. Disable stops new Tasks but does not cancel the existing Run
if fire_chain "disable"; then
  if poll_pending_decision "$CHAIN_RUN"; then
    KEEP_TASK="$CHAIN_TASK"; KEEP_RUN="$CHAIN_RUN"; KEEP_DEC="$DEC_ID"
    rpc trigger.disable "$(fire_param "$CHAIN")" >/dev/null
    eq "disable leaves the existing trigger-created Run running" "running" \
      "$(run_status "$KEEP_RUN")"
    KEEP_TASK_JSON="$(rpc task.get "$(jq -n --arg id "$KEEP_TASK" '{task_id:$id}')")"
    eq "disable leaves the existing trigger-created Task" "$KEEP_TASK" \
      "$(printf '%s' "$KEEP_TASK_JSON" | jq -r '.task.id')"
    KEEP_FIRE="$(rpc trigger.fire "$(fire_param "$CHAIN")")"
    contains "disable rejects new fires" "disabled" "$KEEP_FIRE"
    rpc decision.respond "$(jq -n --arg d "$KEEP_DEC" \
      '{decision_id:$d,option_id:"allow_once",answered_by:"owner"}')" >/dev/null
    if poll_run_terminal "$KEEP_RUN"; then
      eq "the pre-disable Run still succeeds after its owner answer" "succeeded" \
        "$(printf '%s' "$RPC_OUT" | jq -r '.run.status')"
    else
      fail "pre-disable Run did not finish" "$RPC_OUT"
    fi
  else
    fail "no permission Decision appeared for the disable case" "$RPC_OUT"
  fi
fi

# 4e. Audit links for the triggered chain
if [ -n "$ALLOW_RUN" ]; then
  CHAIN_GET="$(get_trigger "$CHAIN")"
  EQUAL_FIRE="$(printf '%s' "$CHAIN_GET" | jq -c --arg t "$ALLOW_TASK" \
    '[(.recent_fires // [])[] | select(.task_id == $t)][0] // {}')"
  eq "trigger.get links the manual fire to its Task" "$ALLOW_TASK" \
    "$(printf '%s' "$EQUAL_FIRE" | jq -r '.task_id')"
  eq "trigger.get links the manual fire to its Run" "$ALLOW_RUN" \
    "$(printf '%s' "$EQUAL_FIRE" | jq -r '.run_id')"
  eq "trigger.get records the manual source" "manual" \
    "$(printf '%s' "$EQUAL_FIRE" | jq -r '.source')"
  contains "trigger.get records the manual fire_key" "manual:" \
    "$(printf '%s' "$EQUAL_FIRE" | jq -r '.fire_key')"
  AUD="$(rpc audit.list "$(jq -n --arg rid "$ALLOW_RUN" '{run_id:$rid,limit:100}')")"
  eq "audit.list has a trigger.run.start record for the Run" 1 \
    "$(printf '%s' "$AUD" | jq -r --arg rid "$ALLOW_RUN" \
      '[(.audit // [])[] | select(.action == "trigger.run.start" and .run_id == $rid)] | length')"
  AUD_DETAIL="$(printf '%s' "$AUD" | jq -r --arg rid "$ALLOW_RUN" \
    '[(.audit // [])[] | select(.action == "trigger.run.start" and .run_id == $rid)][0].detail // ""')"
  contains "trigger.run.start detail carries source" "source=" "$AUD_DETAIL"
  contains "trigger.run.start detail carries fire_key" "fire_key=" "$AUD_DETAIL"
  contains "trigger.run.start detail carries task_id" "task_id=" "$AUD_DETAIL"
  eq "trigger.run.start targets the Task" "$ALLOW_TASK" \
    "$(printf '%s' "$AUD" | jq -r --arg rid "$ALLOW_RUN" \
      '[(.audit // [])[] | select(.action == "trigger.run.start" and .run_id == $rid)][0].target')"
  eq "the trigger-fired event links source/fire_key/Task" 1 \
    "$(db_count "select count(*) from events where type='trigger.fired' and json_extract(payload_json,'\$.task_id')=? and json_extract(payload_json,'\$.source')='manual' and json_extract(payload_json,'\$.fire_key')!=''" "$ALLOW_TASK")"
  eq "the trigger fire ledger links the Run (audit view)" "$ALLOW_RUN" \
    "$(printf '%s' "$EQUAL_FIRE" | jq -r '.run_id')"
fi

# ---------------------------------------------------------------------------
# 5. Event triggers: exactly once across replay, ignore_self, cascade bounds
# ---------------------------------------------------------------------------
EV_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"event-once",type:"event",
    target:{title_template:"Ev {{event_type}}",workspace_id:$ws},
    source:{event_type:"task.created",ignore_self:true},enabled:true}')")"
EV="$(printf '%s' "$EV_JSON" | jq -r '.trigger.id // empty')"
SEED_JSON="$(rpc task.create '{"title":"event-seed"}')"
SEED="$(printf '%s' "$SEED_JSON" | jq -r '.task.id // empty')"
if [ -n "$EV" ]; then
  if poll_fires "$EV" 1; then
    pass "an event trigger creates exactly one Task for a matching event"
    EV_FIRE="$(printf '%s' "$RPC_OUT" | jq -c '(.recent_fires // [])[0]')"
  else
    fail "event trigger did not fire" "$RPC_OUT"; EV_FIRE="{}"
  fi
  sleep 1
  eq "the event trigger still has exactly one fire" 1 "$(fire_count "$EV")"
  eq "the event-created Task is planned without start_run" "planned" \
    "$(rpc task.get "$(jq -n --arg id "$(printf '%s' "$EV_FIRE" | jq -r '.task_id')" '{task_id:$id}')" \
      | jq -r '.task.status')"
  EV_EVENT_ID="$(printf '%s' "$EV_FIRE" | jq -r '.event_id')"
  EV_SEQ="$(python3 - "$DB" "$EV_EVENT_ID" <<'PY'
import sqlite3
import sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute("select seq from events where id=?", (sys.argv[2],)).fetchone()
print(row[0] if row else -1)
PY
)"
  if [ "$EV_SEQ" -gt 0 ]; then
    TASKS_BEFORE_REPLAY="$(task_count)"
    stop_host
    python3 - "$DB" "$EV_SEQ" <<'PY'
import sqlite3
import sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("update meta set value=? where key='trigger.event_cursor'",
             (str(int(sys.argv[2]) - 1),))
conn.commit()
PY
    start_host || fail "host did not restart after cursor regression"
    sleep 2
    eq "cursor regression does not duplicate the fired Task" 1 "$(fire_count "$EV")"
    eq "the Task count is unchanged after cursor regression" \
      "$TASKS_BEFORE_REPLAY" "$(task_count)"
    ge "dedupe_hits increments on a replay" 1 \
      "$(get_trigger "$EV" | jq -r '.trigger.dedupe_hits // 0')"
    stop_host; start_host || fail "host did not restart a second time"
    sleep 2
    eq "a plain restart does not replay the persisted cursor" 1 "$(fire_count "$EV")"
    pass "event exactly-once survived duplicate delivery, cursor regression and restarts"
    rpc trigger.disable "$(fire_param "$EV")" >/dev/null
    POST_DISABLE_TASKS="$(task_count)"
    rpc task.create '{"title":"after-event-disable"}' >/dev/null
    sleep 0.8
    eq "a disabled event trigger creates no new Task" \
      "$((POST_DISABLE_TASKS + 1))" "$(task_count)"
    eq "a disabled event trigger does not fire" 1 "$(fire_count "$EV")"
  else
    fail "cannot locate the seed event sequence for cursor regression" "$EV_EVENT_ID"
  fi
fi

# ignore_self: the trigger's own Task event does not match it again.
IGN_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"ignore-self",type:"event",
    target:{title_template:"Ign {{event_type}}",workspace_id:$ws},
    source:{event_type:"task.created",ignore_self:true},enabled:true}')")"
IGN="$(printf '%s' "$IGN_JSON" | jq -r '.trigger.id // empty')"
IGN_BEFORE="$(task_count)"
rpc task.create '{"title":"ignore-self-seed"}' >/dev/null
if poll_fires "$IGN" 1; then
  sleep 1
  eq "ignore_self yields exactly one fire for the seed event" 1 "$(fire_count "$IGN")"
  eq "ignore_self adds only the single seeded Task plus its one fire" 2 \
    "$(( $(task_count) - IGN_BEFORE ))"
else
  fail "ignore_self trigger did not fire" "$RPC_OUT"
fi
rpc trigger.disable "$(fire_param "$IGN")" >/dev/null

# cascade depth: a self-matching trigger stops at depth 8.
DEPTH_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"cascade-depth",type:"event",
    target:{title_template:"Depth {{event_type}}",workspace_id:$ws},
    source:{event_type:"task.created",ignore_self:false},enabled:true}')")"
DEPTH="$(printf '%s' "$DEPTH_JSON" | jq -r '.trigger.id // empty')"
DEPTH_BEFORE="$(task_count)"
rpc task.create '{"title":"depth-seed"}' >/dev/null
if poll_fires "$DEPTH" 8; then
  sleep 1
  DEPTH_GET="$(get_trigger "$DEPTH")"
  eq "cascade depth stops at 8 fires" 8 \
    "$(printf '%s' "$DEPTH_GET" | jq -r '(.recent_fires // []) | length')"
  eq "the deepest fired Task is depth 8" 8 \
    "$(db_count "select max(cast(json_extract(payload_json,'\$.depth') as integer)) from events where type='trigger.fired' and json_extract(payload_json,'\$.trigger_id')=?" "$DEPTH")"
  eq "the depth cap records a cascade_depth rejection" 1 \
    "$(db_count "select count(*) from events where type='trigger.rejected' and json_extract(payload_json,'\$.reason')='cascade_depth' and json_extract(payload_json,'\$.trigger_id')=?" "$DEPTH")"
  eq "cascade depth creates only its seed plus eight bounded Tasks" 9 \
    "$(( $(task_count) - DEPTH_BEFORE ))"
else
  fail "cascade-depth trigger did not reach depth 8" "$RPC_OUT"
fi
rpc trigger.disable "$(fire_param "$DEPTH")" >/dev/null

# ping-pong: two cross-matching triggers stay bounded and stop on disable.
PP_A_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"pp-a",type:"event",
    target:{title_template:"A {{event_type}}",workspace_id:$ws},
    source:{event_type:"task.created",ignore_self:false},enabled:true}')")"
PP_A="$(printf '%s' "$PP_A_JSON" | jq -r '.trigger.id // empty')"
PP_B_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"pp-b",type:"event",
    target:{title_template:"B {{event_type}}",workspace_id:$ws},
    source:{event_type:"task.created",ignore_self:false},enabled:true}')")"
PP_B="$(printf '%s' "$PP_B_JSON" | jq -r '.trigger.id // empty')"
PP_BEFORE="$(task_count)"
rpc task.create '{"title":"ping-pong-seed"}' >/dev/null
sleep 4
PP_DELTA=$(( $(task_count) - PP_BEFORE ))
le "a trigger ping-pong creates only a bounded number of Tasks" 70 "$PP_DELTA"
ge "the ping-pong actually produced Tasks" 1 "$PP_DELTA"
eq "ping-pong depth never exceeds the cascade cap" 0 \
  "$(db_count "select count(*) from events where type='trigger.fired' and cast(json_extract(payload_json,'\$.depth') as integer) > 8")"
rpc trigger.disable "$(fire_param "$PP_A")" >/dev/null
rpc trigger.disable "$(fire_param "$PP_B")" >/dev/null
PP_FROZEN="$(task_count)"
sleep 2
eq "disabling the ping-pong triggers stops new Tasks" "$PP_FROZEN" "$(task_count)"
pass "a trigger ping-pong is bounded by the depth cap and per-trigger rate limit"

# ---------------------------------------------------------------------------
# 6. Schedule triggers: slot once, downtime skip and coalesce_once
# ---------------------------------------------------------------------------
wait_create_window
SCHED_AT="$(date -u +%T)"
SKIP_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"sched-skip",type:"schedule",
    target:{title_template:"Skip {{scheduled_for}}",workspace_id:$ws},
    source:{schedule_kind:"every",interval_minutes:1,missed:"skip"},
    enabled:true}')")"
SKIP_TRIG="$(printf '%s' "$SKIP_JSON" | jq -r '.trigger.id // empty')"
COAL_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"sched-coalesce",type:"schedule",
    target:{title_template:"Coalesce {{scheduled_for}}",workspace_id:$ws},
    source:{schedule_kind:"every",interval_minutes:1,missed:"coalesce_once"},
    enabled:true}')")"
COAL="$(printf '%s' "$COAL_JSON" | jq -r '.trigger.id // empty')"
if [ -n "$SKIP_TRIG" ] && [ -n "$COAL" ]; then
  if poll_fires "$SKIP_TRIG" 1 && poll_fires "$COAL" 1; then
    pass "both schedule triggers fired their first slot (created at $SCHED_AT UTC)"
  else
    fail "schedule trigger did not fire its first slot" "$RPC_OUT"
  fi
  sleep 2
  eq "a duplicate scheduler tick does not repeat the slot" 1 "$(fire_count "$SKIP_TRIG")"
  eq "a duplicate scheduler tick does not repeat the coalesce slot" 1 "$(fire_count "$COAL")"
  SKIP_FIRE="$(get_trigger "$SKIP_TRIG" | jq -c '(.recent_fires // [])[0]')"
  eq "the schedule fire is linked to its Task" "planned" \
    "$(rpc task.get "$(jq -n --arg id "$(printf '%s' "$SKIP_FIRE" | jq -r '.task_id')" '{task_id:$id}')" \
      | jq -r '.task.status')"
  contains "the schedule fire key is slot:<scheduled_for_ms>" "slot:" \
    "$(printf '%s' "$SKIP_FIRE" | jq -r '.fire_key')"
  SCHED_TASKS_BEFORE="$(task_count)"
  stop_host
  sleep 125
  start_host || fail "host did not restart after schedule downtime"
  sleep 3
  SKIP_N="$(fire_count "$SKIP_TRIG")"
  COAL_GET="$(get_trigger "$COAL")"
  COAL_N="$(printf '%s' "$COAL_GET" | jq -r '(.recent_fires // []) | length')"
  eq "skip leaves the fired slot un-replayed after downtime" 1 "$SKIP_N"
  eq "coalesce_once creates exactly one catch-up Task" 2 "$COAL_N"
  eq "the catch-up fire is marked coalesced" true \
    "$(printf '%s' "$COAL_GET" | jq -r '[(.recent_fires // [])[] | select(.coalesced == true)] | length == 1')"
  eq "downtime creates only the one coalesced catch-up Task" \
    "$((SCHED_TASKS_BEFORE + 1))" "$(task_count)"
  eq "skip records one missed_window rejection with two missed slots" 2 \
    "$(db_count "select max(cast(json_extract(payload_json,'\$.missed_count') as integer)) from events where type='trigger.rejected' and json_extract(payload_json,'\$.reason')='missed_window' and json_extract(payload_json,'\$.trigger_id')=?" "$SKIP_TRIG")"
  NEXT_SKIP="$(get_trigger "$SKIP_TRIG" | jq -r '.trigger.next_fire_at // ""')"
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  if [ -n "$NEXT_SKIP" ] && [[ "$NEXT_SKIP" > "$NOW_ISO" ]]; then
    pass "the skip trigger advanced its next_fire_at into the future"
  else
    fail "the skip trigger did not advance its next_fire_at" "$NEXT_SKIP vs $NOW_ISO"
  fi
  sleep 2
  eq "no further replay after the restart settles" "$SKIP_N" "$(fire_count "$SKIP_TRIG")"
  rpc trigger.disable "$(fire_param "$SKIP_TRIG")" >/dev/null
  rpc trigger.disable "$(fire_param "$COAL")" >/dev/null
else
  fail "schedule trigger.create failed" "$SKIP_JSON $COAL_JSON"
fi

# ---------------------------------------------------------------------------
# 7. Webhook: signature, replay, stale, nonce reuse, rate bound, secrets
# ---------------------------------------------------------------------------
HOOK_JSON="$(rpc trigger.create "$(jq -n --arg ws "$WS" \
  '{name:"hook",type:"webhook",
    target:{title_template:"H {{title}}",workspace_id:$ws},
    source:{payload_fields:["title"]},enabled:true}')")"
WID="$(printf '%s' "$HOOK_JSON" | jq -r '.trigger.id // empty')"
KEY_JSON="$(rpc trigger.source.add "$(jq -n --arg id "$WID" '{trigger_id:$id,name:"smoke"}')")"
KID="$(printf '%s' "$KEY_JSON" | jq -r '.key_id // empty')"
SECRET="$(printf '%s' "$KEY_JSON" | jq -r '.secret // empty')"
PORT="$(host_port)"
if [ -n "$WID" ] && [ -n "$KID" ] && [ -n "$SECRET" ]; then
  pass "webhook trigger and signing key created"
else
  fail "webhook key creation failed" "$KEY_JSON"; summary; exit 1
fi
eq "the webhook secret is 32 bytes of hex" 64 "${#SECRET}"
KEY_FILE="$STATE/secrets/webhook/$KID.key"
if [ -f "$KEY_FILE" ]; then
  KEY_MODE="$(stat -c '%a' "$KEY_FILE" 2>/dev/null || stat -f '%Lp' "$KEY_FILE" 2>/dev/null || echo '?')"
  eq "the webhook key file is mode 0600" 600 "$KEY_MODE"
  if [ "$(cat "$KEY_FILE")" = "$SECRET" ]; then
    pass "the key file holds the raw hex secret"
  else
    fail "the key file does not match the issued secret"
  fi
else
  fail "webhook key file is missing" "$KEY_FILE"
fi

sign_body() { # timestamp nonce body -> lowercase hex signature
  printf 'monexus-webhook-v1\n%s\n%s\n%s\n%s\n%s' \
    "$KID" "$WID" "$1" "$2" "$3" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SECRET" | awk '{print $NF}'
}
HOOK_CODE=""
HOOK_BODY=""
HOOK_HEADERS=""
post_hook() { # timestamp nonce delivery body signature
  rm -f "$WORK/hook.body" "$WORK/hook.hdr"
  HOOK_CODE="$(curl -sS -D "$WORK/hook.hdr" -o "$WORK/hook.body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/hooks/$WID" \
    -H 'Content-Type: application/json' \
    -H "X-Monexus-Key-Id: $KID" \
    -H "X-Monexus-Timestamp: $1" \
    -H "X-Monexus-Nonce: $2" \
    -H "X-Monexus-Delivery-Id: $3" \
    -H "X-Monexus-Signature: v1=$5" \
    --data-binary "$4" 2>/dev/null || echo 000)"
  HOOK_BODY="$(cat "$WORK/hook.body" 2>/dev/null || true)"
  HOOK_HEADERS="$(cat "$WORK/hook.hdr" 2>/dev/null || true)"
}

TS="$(now_ms)"
N1="smoke-nonce-aaaaaaaaaaaa-1"
B1='{"title":"webhook-hello"}'
S1="$(sign_body "$TS" "$N1" "$B1")"
post_hook "$TS" "$N1" "delivery-1" "$B1" "$S1"
eq "a correctly signed webhook is accepted with 202" 202 "$HOOK_CODE"
HOOK_TASK="$(printf '%s' "$HOOK_BODY" | jq -r '.task_id // empty')"
eq "the accepted webhook is not marked duplicate" false \
  "$(printf '%s' "$HOOK_BODY" | jq -r '.duplicate')"
eq "the webhook Task renders a declared payload field" "H webhook-hello" \
  "$(rpc task.get "$(jq -n --arg id "$HOOK_TASK" '{task_id:$id}')" | jq -r '.task.title')"
HOOK_GET="$(get_trigger "$WID")"
HOOK_FIRE="$(printf '%s' "$HOOK_GET" | jq -c --arg t "$HOOK_TASK" \
  '[(.recent_fires // [])[] | select(.task_id == $t)][0] // {}')"
eq "the webhook fire records source=webhook" "webhook" \
  "$(printf '%s' "$HOOK_FIRE" | jq -r '.source')"
eq "the webhook fire records the key id" "$KID" \
  "$(printf '%s' "$HOOK_FIRE" | jq -r '.key_id')"
contains "the webhook fire key is delivery:<id>" "delivery:" \
  "$(printf '%s' "$HOOK_FIRE" | jq -r '.fire_key')"

post_hook "$TS" "$N1" "delivery-1" "$B1" "$S1"
eq "a repeated delivery is accepted idempotently" 202 "$HOOK_CODE"
eq "a repeated delivery returns the original Task" "$HOOK_TASK" \
  "$(printf '%s' "$HOOK_BODY" | jq -r '.task_id')"
eq "a repeated delivery is flagged duplicate" true \
  "$(printf '%s' "$HOOK_BODY" | jq -r '.duplicate')"

N2="smoke-nonce-aaaaaaaaaaaa-2"
B2='{"title":"nonce-reuse"}'
S2="$(sign_body "$TS" "$N2" "$B2")"
post_hook "$TS" "$N2" "delivery-2" "$B2" "$S2" >/dev/null
# same nonce, different body and thus a different signature
S2B="$(sign_body "$TS" "$N2" '{"title":"nonce-reuse-other"}')"
post_hook "$TS" "$N2" "delivery-3" '{"title":"nonce-reuse-other"}' "$S2B"
eq "reusing a nonce with a different body is a uniform 401" 401 "$HOOK_CODE"
eq "nonce reuse is audited" 1 \
  "$(db_count "select count(*) from events where type='trigger.rejected' and json_extract(payload_json,'\$.reason')='nonce_reuse' and json_extract(payload_json,'\$.trigger_id')=?" "$WID")"

TS_OLD="$(python3 -c 'import time; print(int(time.time() * 1000) - 400000)')"
N3="smoke-nonce-aaaaaaaaaaaa-3"
B3='{"title":"stale"}'
S3="$(sign_body "$TS_OLD" "$N3" "$B3")"
post_hook "$TS_OLD" "$N3" "delivery-stale" "$B3" "$S3"
eq "a stale timestamp is a uniform 401" 401 "$HOOK_CODE"
eq "the stale timestamp is audited" 1 \
  "$(db_count "select count(*) from events where type='trigger.rejected' and json_extract(payload_json,'\$.reason')='stale_timestamp' and json_extract(payload_json,'\$.trigger_id')=?" "$WID")"

N4="smoke-nonce-aaaaaaaaaaaa-4"
B4='{"title":"bad-signature"}'
post_hook "$TS" "$N4" "delivery-badsig" "$B4" "deadbeef"
eq "a bad signature is a uniform 401" 401 "$HOOK_CODE"
eq "the bad signature is audited" 1 \
  "$(db_count "select count(*) from events where type='trigger.rejected' and json_extract(payload_json,'\$.reason')='invalid_signature' and json_extract(payload_json,'\$.trigger_id')=?" "$WID")"

# A burst: the trigger bucket has burst 20 and refills at 5/min; the success,
# replay and nonce-reuse requests above consumed three tokens.
HOOK_TASKS_BEFORE_BURST="$(task_count)"
ACCEPTED=0
LIMITED=0
RETRY_HEADER=""
for i in $(seq 1 30); do
  N="smoke-nonce-burst-$(printf '%024d' "$i")"
  B="{\"title\":\"burst-$i\"}"
  S="$(sign_body "$TS" "$N" "$B")"
  post_hook "$TS" "$N" "delivery-burst-$i" "$B" "$S"
  case "$HOOK_CODE" in
    202) ACCEPTED=$((ACCEPTED + 1)) ;;
    429)
      LIMITED=$((LIMITED + 1))
      if printf '%s' "$HOOK_HEADERS" | grep -qi '^retry-after: *1'; then
        RETRY_HEADER="yes"
      fi
      ;;
  esac
done
ge "the webhook burst is stopped by the trigger bucket" 1 "$LIMITED"
le "accepted webhook burst requests stay within the per-trigger burst" 20 "$ACCEPTED"
ge "some burst requests were accepted before the limit" 1 "$ACCEPTED"
eq "over-limit webhook replies carry Retry-After" "yes" "${RETRY_HEADER:-no}"
eq "the coalesced rate_limited audit appears at most once per trigger" 1 \
  "$(db_count "select count(*) from events where type='trigger.rejected' and json_extract(payload_json,'\$.reason')='rate_limited' and json_extract(payload_json,'\$.trigger_id')=?" "$WID")"
HOOK_N="$(fire_count "$WID")"
le "the fire ledger keeps only accepted unique webhook deliveries" 20 "$HOOK_N"
ge "the fire ledger records the accepted deliveries" "$ACCEPTED" "$HOOK_N"

REVOKE="$(rpc trigger.source.revoke "$(jq -n --arg kid "$KID" '{key_id:$kid}')")"
contains "trigger.source.revoke succeeds" "true" "$REVOKE"
post_hook "$TS" "$N2" "delivery-2" "$B2" "$S2"
eq "a revoked webhook key is a uniform 401" 401 "$HOOK_CODE"
HOOK_TASKS_AFTER_REVOKE="$(task_count)"
rpc trigger.disable "$(fire_param "$WID")" >/dev/null
post_hook "$TS" "$N2" "delivery-2" "$B2" "$S2"
eq "a disabled webhook trigger is a uniform 401" 401 "$HOOK_CODE"
eq "revocation and disable create no new Tasks" "$HOOK_TASKS_AFTER_REVOKE" "$(task_count)"
DISABLED_SOURCE_ADD="$(rpc trigger.source.add "$(jq -n --arg id "$WID" '{trigger_id:$id,name:"again"}')")"
contains "a disabled webhook trigger cannot mint keys" "disabled" "$DISABLED_SOURCE_ADD"

# Secret hygiene: never in events, never in logs, never in the DB outside the
# dedicated key file, never in trigger.get.
eq "the secret never appears in any event payload" 0 \
  "$(db_count "select count(*) from events where payload_json like ?" "%$SECRET%")"
if grep -aqF -- "$SECRET" "$DB" "$STATE/.log" 2>/dev/null; then
  fail "the webhook secret leaked into the database or host log"
else
  pass "the webhook secret is absent from the database file and host log"
fi
not_contains "the secret never appears in trigger.get" "$SECRET" "$(get_trigger "$WID")"

# ---------------------------------------------------------------------------
# 8. Final cross-check: audit links and a clean summary
# ---------------------------------------------------------------------------
eq "no trigger-created Task ever ran a forbidden command field" 0 \
  "$(db_count "select count(*) from events where type='trigger.fired' and json_extract(payload_json,'\$.task_id')=''")"
eq "every trigger.fired event carries a non-empty fire_key" 0 \
  "$(db_count "select count(*) from events where type='trigger.fired' and json_extract(payload_json,'\$.fire_key')=''")"
eq "every trigger-created Task has a trigger.fired link" 0 \
  "$(db_count "select count(*) from events where type='task.created' and json_extract(payload_json,'\$.origin.trigger_id') is not null and json_extract(payload_json,'\$.id') not in (select json_extract(payload_json,'\$.task_id') from events where type='trigger.fired')")"

summary
