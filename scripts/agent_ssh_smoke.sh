#!/usr/bin/env bash
# MoNexus PoC — mock ACP agent over SSH (`ssh -T`, no PTY).
#
# TEST HARNESS ONLY. It starts an ephemeral, non-root sshd on a random loopback
# port with a temp HOME, temp keys, temp authorized_keys and a temp known_hosts
# file. The host and the mock ACP agent are the normal binaries/scripts; the
# only difference is that the agent process is spawned through the
# ProcessLauncher::Ssh path behind `MONEXUS_AGENT_SSH=1`.
#
# Proves, in one run:
#   * without the gate an SSH workspace still gets the existing local-only error;
#   * with the gate the ACP chain (initialize -> session/new -> prompt ->
#     streamed chunks -> session/cancel) runs over `ssh -T`;
#   * stdin/stdout are duplex pipes (no PTY: the mock reports TTY=no), and the
#     remote cwd is the workspace root;
#   * stderr stays on its own pipe: markers appear in logs/agent-<id>.stderr.log
#     and stderr_tail, never in the ACP transcript;
#   * workspace.read/write through the normal SSH workspace provider still work;
#   * local agent sessions are unchanged;
#   * the user's real ~/.ssh is untouched (snapshot before/after).
#
# Usage:
#   bash scripts/agent_ssh_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/agent_ssh_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
REAL_USER="$(id -un)"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_SSH_DIR="$REAL_HOME/.ssh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-agent-ssh.XXXXXX")"
REMOTE_ROOT="$WORK/remote root"
mkdir -p "$WORK/home" "$REMOTE_ROOT"
export HOME="$WORK/home"
export MONEXUS_ACP_TIMEOUT_MS="${MONEXUS_ACP_TIMEOUT_MS:-20000}"

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ] && [ -x "$REAL_HOME/.nvm/versions/node/v26.13.0/bin/node" ]; then
  NODE_BIN="$REAL_HOME/.nvm/versions/node/v26.13.0/bin/node"
fi
if [ -z "$NODE_BIN" ]; then
  printf 'node is required for the mock ACP agent\n' >&2
  exit 2
fi
export PATH="$(dirname "$NODE_BIN"):$PATH"
MOCK_ACP="$ROOT/tests/agent/mock_acp_agent.mjs"
REMOTE_ROOT_P="$(cd "$REMOTE_ROOT" && pwd -P)"

PASSED=0
FAILED=0
HOST_PID=""
SSHD_PID=""
STATE="$WORK/state"
RPC_OUT=""
RPC_CODE=0

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "--- output ---" "$2" "--------------" >&2; fi
}
contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then pass "$1"; else fail "$1 (missing: $2)" "$3"; fi
}
not_contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then fail "$1 (unexpected: $2)" "$3"; else pass "$1"; fi
}
eq() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi
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
  printf '\nSUMMARY  passed=%d failed=%d\n' "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}

for tool in ssh ssh-keygen sshd jq; do
  if ! command -v "$tool" >/dev/null 2>&1 && [ ! -x "/usr/sbin/$tool" ]; then
    printf '%s is required for this smoke test\n' "$tool" >&2
    exit 2
  fi
done
if [ ! -x "$HOST_BIN" ]; then
  printf 'host binary missing: %s\nrun: moon build --target native\n' "$HOST_BIN" >&2
  exit 2
fi

start_host() { # state_dir [extra env assignment...]
  local state="$1"
  shift
  env "$@" "$HOST_BIN" serve --state-dir "$state" --heartbeat-ms 60000 \
    >"$state/.log" 2>&1 &
  HOST_PID=$!
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if "$HOST_BIN" status --state-dir "$state" >/dev/null 2>&1; then return 0; fi
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

rpc() { # method params-json
  "$HOST_BIN" rpc --state-dir "$STATE" --method "$1" --params "$2" 2>&1
}
rpc_call() {
  RPC_OUT="$(rpc "$1" "$2")"
  RPC_CODE=$?
}

read_params() { # session_id
  jq -n --arg id "$1" '{session_id:$id,cursor:0}'
}

poll_text() { # session_id needle [timeout-tries]
  local sid="$1" needle="$2" limit="${3:-200}" tries=0 out=""
  while [ "$tries" -lt "$limit" ]; do
    out="$(rpc agent.read "$(read_params "$sid")")"
    if printf '%s' "$out" | grep -Fq -- "$needle"; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

poll_state() { # session_id want
  local sid="$1" want="$2" tries=0 out="" state=""
  while [ "$tries" -lt 200 ]; do
    out="$(rpc agent.read "$(read_params "$sid")")"
    state="$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)"
    if [ "$state" = "$want" ]; then RPC_OUT="$out"; return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  RPC_OUT="$out"
  return 1
}

poll_file() { # path needle
  local path="$1" needle="$2" tries=0
  while [ "$tries" -lt 100 ]; do
    if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

mkdir -p "$STATE"
printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s\nnode=%s\nremote_root=%s\n\n' "$WORK" "$NODE_BIN" "$REMOTE_ROOT_P"

# ---------------------------------------------------------------------------
printf '== 1. ephemeral loopback sshd (non-root, temp keys) ==\n'
# ---------------------------------------------------------------------------
SSHD_BIN="$(command -v sshd || true)"
[ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ] && SSHD_BIN=/usr/sbin/sshd
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
LogLevel INFO
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
  summary
  exit 1
fi

# ---------------------------------------------------------------------------
printf '\n== 2. machine + SSH workspace through the normal providers ==\n'
# ---------------------------------------------------------------------------
KH="$WORK/known_hosts"
if start_host "$STATE"; then pass 'host started without MONEXUS_AGENT_SSH'; else fail 'host started'; fi

ADD_OUT="$("$HOST_BIN" machine add --state-dir "$STATE" \
  --name loopback --host 127.0.0.1 --port "$SSH_PORT" \
  --user "$REAL_USER" --identity "$SSH_TMP/client_ed25519" \
  --use-ssh-config false --host-key-policy accept-new \
  --known-hosts-file "$KH" 2>&1)"
ADD_CODE=$?
if [ "$ADD_CODE" -eq 0 ]; then pass 'machine add exit 0'; else fail 'machine add exit 0' "$ADD_OUT"; fi
MACHINE_ID="$(printf '%s\n' "$ADD_OUT" | sed -n 's/^id=//p' | head -n 1)"
[ -n "$MACHINE_ID" ] && pass "machine registered as $MACHINE_ID" || fail 'machine id parsed' "$ADD_OUT"
contains 'machine add recorded the explicit SSH target' "ssh_effective.hostname=127.0.0.1" "$ADD_OUT"

rpc_call workspace.open "$(jq -n --arg mid "$MACHINE_ID" --arg root "$REMOTE_ROOT_P" \
  '{target:$mid,root:$root}')"
WS_ID="$(printf '%s' "$RPC_OUT" | jq -r '.workspace.id // empty')"
[ -n "$WS_ID" ] && pass "workspace.open returned $WS_ID" || fail 'workspace.open returned an id' "$RPC_OUT"
eq 'workspace provider kind is ssh' 'ssh' "$(printf '%s' "$RPC_OUT" | jq -r '.workspace.kind // empty')"
eq 'workspace root is the remote path' "$REMOTE_ROOT_P" "$(printf '%s' "$RPC_OUT" | jq -r '.workspace.root // empty')"

rpc_call workspace.write "$(jq -n --arg ws "$WS_ID" --arg content "SSH-WORKSPACE-OK\n" \
  '{workspace_id:$ws,path:"ssh-smoke.txt",content:$content}')"
contains 'workspace.write acknowledges over SSH' '"ok":true' "$RPC_OUT"
if [ -f "$REMOTE_ROOT_P/ssh-smoke.txt" ]; then pass 'the write landed in the remote root'; else fail 'the write landed in the remote root'; fi
rpc_call workspace.read "$(jq -n --arg ws "$WS_ID" '{workspace_id:$ws,path:"ssh-smoke.txt"}')"
contains 'workspace.read returns the written text' 'SSH-WORKSPACE-OK' "$RPC_OUT"

# ---------------------------------------------------------------------------
printf '\n== 3. gate off: SSH-backed agent.start keeps the M4 local-only error ==\n'
# ---------------------------------------------------------------------------
SSH_START_PARAMS="$(jq -n --arg aid 'mock-ssh' --arg cmd "$NODE_BIN" \
  --arg script "$MOCK_ACP" --arg ws "$WS_ID" \
  '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script,"--stderr","--cwd"],cwd:"",workspace_id:$ws,prompt:"hello over ssh",memory_limit:4096,env:{}}')"
rpc_call agent.start "$SSH_START_PARAMS"
if [ "$RPC_CODE" -ne 0 ]; then pass 'worker without the gate refuses the SSH workspace'; else fail 'worker without the gate refused' "$RPC_OUT"; fi
contains 'refusal is the existing local-only error' 'agent sessions currently run only on local workspaces' "$RPC_OUT"
rpc_call agent.list '{"agent_id":"mock-ssh"}'
eq 'the refused request created no session' '0' "$(printf '%s' "$RPC_OUT" | jq -r '(.sessions // []) | length')"

# ---------------------------------------------------------------------------
printf '\n== 4. gate on: ACP over ssh -T (initialize/new/prompt/stream/cancel) ==\n'
# ---------------------------------------------------------------------------
stop_host
if start_host "$STATE" MONEXUS_AGENT_SSH=1; then
  pass 'host restarted with MONEXUS_AGENT_SSH=1'
else
  fail 'host restarted with MONEXUS_AGENT_SSH=1'
fi

rpc_call agent.start "$SSH_START_PARAMS"
SID="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID" ] && pass "agent.start over SSH returned $SID" || fail 'agent.start over SSH returned a session' "$RPC_OUT"
eq 'session records the SSH workspace' "$WS_ID" "$(printf '%s' "$RPC_OUT" | jq -r '.session.workspace_id // empty')"
eq 'session records the remote cwd as the workspace root' "$REMOTE_ROOT_P" "$(printf '%s' "$RPC_OUT" | jq -r '.session.cwd // empty')"
eq 'ACP initialize + session/new completed over SSH' 'mock-session-1' "$(printf '%s' "$RPC_OUT" | jq -r '.session.acp_session_id // empty')"
eq 'session starts running' 'running' "$(printf '%s' "$RPC_OUT" | jq -r '.session.state // empty')"

if poll_text "$SID" 'MOCK#1'; then pass 'streamed ACP chunks crossed ssh -T'; else fail 'streamed ACP chunks crossed ssh -T' "$RPC_OUT"; fi
contains 'remote cwd is the requested workspace directory' "CWD=$REMOTE_ROOT_P" "$RPC_OUT"
contains 'the remote stdio is a pipe pair (no PTY)' 'TTY=no' "$RPC_OUT"
if poll_text "$SID" ' BLOCK_SEEN'; then pass 'the injected MoNexus context crossed the transport'; else fail 'the injected context crossed the transport' "$RPC_OUT"; fi
if poll_state "$SID" idle; then pass 'the remote turn finished'; else fail 'the remote turn finished' "$RPC_OUT"; fi

STDERR_LOG="$STATE/logs/agent-$SID.stderr.log"
if poll_file "$STDERR_LOG" 'MOCK-STDERR-READY'; then pass 'stderr is captured in its own per-session log'; else fail 'stderr is captured in its own log' "$(cat "$STDERR_LOG" 2>/dev/null || true)"; fi
contains 'remote stderr reports the remote cwd' "cwd=$REMOTE_ROOT_P" "$(cat "$STDERR_LOG" 2>/dev/null || true)"
contains 'stderr is redacted before it reaches the log' 'MOCK-AUTH [redacted]' "$(cat "$STDERR_LOG" 2>/dev/null || true)"
not_contains 'the raw credential value never reaches the log' 'VALUE-987654321' "$(cat "$STDERR_LOG" 2>/dev/null || true)"
eq 'stderr log is mode 0600' '600' "$(stat -c %a "$STDERR_LOG" 2>/dev/null)"
TRANSCRIPT="$(rpc agent.read "$(read_params "$SID")")"
not_contains 'stderr never enters the ACP transcript' 'MOCK-STDERR-READY' "$TRANSCRIPT"
not_contains 'the credential value never enters the ACP transcript' 'VALUE-987654321' "$TRANSCRIPT"

# session/cancel must reach the remote adapter before the pipes close.
rpc_call agent.stop "$(jq -n --arg id "$SID" '{session_id:$id}')"
contains 'agent.stop acknowledges the SSH session' '"ok":true' "$RPC_OUT"
if poll_file "$STDERR_LOG" 'MOCK-CANCEL-RECEIVED'; then pass 'session/cancel reached the remote adapter'; else fail 'session/cancel reached the remote adapter' "$(cat "$STDERR_LOG" 2>/dev/null || true)"; fi

SESSIONS="$(rpc agent.list '{"agent_id":"mock-ssh"}')"
STOPPED="$(printf '%s' "$SESSIONS" | jq -c --arg id "$SID" '(.sessions // []) | map(select(.id==$id)) | .[0]')"
eq 'stopped SSH session state is stopped' 'stopped' "$(printf '%s' "$STOPPED" | jq -r '.state')"
eq 'stopped SSH session stop_reason is cancelled' 'cancelled' "$(printf '%s' "$STOPPED" | jq -r '.stop_reason')"
contains 'stderr_tail carries the startup marker' 'MOCK-STDERR-READY' "$(printf '%s' "$STOPPED" | jq -r '.stderr_tail // empty')"
contains 'stderr_tail carries the cancel marker' 'MOCK-CANCEL-RECEIVED' "$(printf '%s' "$STOPPED" | jq -r '.stderr_tail // empty')"
FINAL_READ="$(rpc agent.read "$(read_params "$SID")")"
not_contains 'cancelled transcript still has no stderr markers' 'MOCK-CANCEL-RECEIVED' "$FINAL_READ"

# ---------------------------------------------------------------------------
printf '\n== 5. transport evidence + local agent unchanged ==\n'
# ---------------------------------------------------------------------------
if grep -Fq "Accepted publickey for $REAL_USER" "$SSH_TMP/sshd.log" 2>/dev/null; then
  pass 'sshd log shows the public-key SSH session'
else
  fail 'sshd log shows the public-key SSH session' "$(cat "$SSH_TMP/sshd.log" 2>/dev/null || true)"
fi
if [ -f "$KH" ] && grep -Fq '127.0.0.1' "$KH"; then
  pass 'the dedicated temp known_hosts file was used'
else
  fail 'the dedicated temp known_hosts file was used' "$(cat "$KH" 2>/dev/null || true)"
fi

LOCAL_PARAMS="$(jq -n --arg aid 'mock-local' --arg cmd "$NODE_BIN" --arg script "$MOCK_ACP" \
  --arg cwd "$WORK/home" \
  '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script],cwd:$cwd,prompt:"local still works",memory_limit:0,env:{}}')"
rpc_call agent.start "$LOCAL_PARAMS"
SID_L="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_L" ] && pass "local agent.start still returns $SID_L" || fail 'local agent.start' "$RPC_OUT"
if poll_text "$SID_L" 'MOCK#1'; then pass 'local ACP agent still streams to the transcript'; else fail 'local ACP agent streams' "$RPC_OUT"; fi
rpc_call agent.stop "$(jq -n --arg id "$SID_L" '{session_id:$id}')"
contains 'local agent.stop still acknowledges' '"ok":true' "$RPC_OUT"

# ---------------------------------------------------------------------------
printf '\n== 6. user ~/.ssh guard ==\n'
# ---------------------------------------------------------------------------
stop_host
SSH_AFTER="$(ssh_snapshot)"
if [ "$SSH_BEFORE" = "$SSH_AFTER" ]; then
  pass 'user ~/.ssh was not modified'
else
  fail 'user ~/.ssh was modified' "$SSH_AFTER"
fi

summary
