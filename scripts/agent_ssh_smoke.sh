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
REMOTE_MOCK_PIDS=""
STATE="$WORK/state"
RPC_OUT=""
RPC_CODE=0
# Environment smoke bookkeeping. These are filled only for the deterministic
# id this script creates, so cleanup can never remove anything else.
ENV_ID="env_ssh_smoke_1"
ENV_CONTAINER="monexus-env-$ENV_ID"
ENV_REMOTE_HOME=""
ENV_DOCKER_READY=0
ENV_STARTED=0
ENV_SKIP_REASON="no Docker daemon"
RECIPE_TRUST_FILE=""
RECIPE_JSON=""

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
events_have() { # label type subject haystack
  if printf '%s\n' "$4" | grep -F -- "type=$2" | grep -Fq -- "subject=$3"; then
    pass "$1"
  else
    fail "$1 (missing type=$2 for $3)" "$4"
  fi
}
events_lack() { # label type subject haystack
  if printf '%s\n' "$4" | grep -F -- "type=$2" | grep -Fq -- "subject=$3"; then
    fail "$1 (unexpected type=$2 for $3)" "$4"
  else
    pass "$1"
  fi
}

cleanup() {
  if [ -n "$HOST_PID" ]; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  for pid in $REMOTE_MOCK_PIDS; do
    kill -9 "$pid" 2>/dev/null || true
  done
  if [ -n "$SSHD_PID" ]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  # Only the deterministic environment this script created is eligible for
  # emergency cleanup. The normal path asserts that destroy already removed it.
  if [ "$ENV_STARTED" -eq 1 ]; then
    docker rm -f "$ENV_CONTAINER" >/dev/null 2>&1 || true
    if [ -n "${ENV_REMOTE_HOME:-}" ]; then
      rm -rf "$ENV_REMOTE_HOME/.monexus/environments/$ENV_ID" 2>/dev/null || true
    fi
    if [ -n "${REMOTE_ROOT_P:-}" ]; then
      rm -rf "$REMOTE_ROOT_P-monexus-scratch-$ENV_ID" 2>/dev/null || true
    fi
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

wait_pid_file() { # path
  local path="$1" tries=0
  while [ "$tries" -lt 200 ]; do
    if [ -s "$path" ]; then return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

local_ssh_pid() { # unique-needle-in-remote-argv
  local needle="$1" pid
  for pid in $(pgrep -x -P "$HOST_PID" ssh 2>/dev/null); do
    if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -Fq -- "$needle"; then
      printf '%s' "$pid"
      return 0
    fi
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
printf '\n== 2b. signed recipe + Docker preflight for the SSH environment ==\n'
# ---------------------------------------------------------------------------
# The environment section below is opt-in on a reachable Docker daemon and a
# pre-existing nginx:alpine image with a repo digest. It is skipped with a
# visible reason otherwise, matching the deterministic provider tests.
SSH_CLIENT=(
  ssh -i "$SSH_TMP/client_ed25519" -p "$SSH_PORT"
  -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KH"
  "$REAL_USER@127.0.0.1"
)
if ! docker info >/dev/null 2>&1; then
  ENV_SKIP_REASON="no reachable Docker daemon"
elif ! "${SSH_CLIENT[@]}" docker info >/dev/null 2>&1; then
  ENV_SKIP_REASON="docker is not reachable over the temp sshd"
else
  ENV_REMOTE_HOME="$("${SSH_CLIENT[@]}" 'printf %s "$HOME"' 2>/dev/null || true)"
  # The temp sshd and the host share one daemon, so the local image lookup is
  # the same image the remote runner will pull by digest.
  IMAGE_LINE="$(docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' nginx:alpine \
    2>/dev/null | grep -m1 '@sha256:' || true)"
  if [ -z "${ENV_REMOTE_HOME:-}" ]; then
    ENV_SKIP_REASON="the remote home directory could not be resolved"
  elif [ -z "$IMAGE_LINE" ]; then
    ENV_SKIP_REASON="nginx:alpine with a repo digest is not available locally"
  else
    IMAGE_REF="${IMAGE_LINE%@*}"
    IMAGE_DIGEST="${IMAGE_LINE#*@}"
    mkdir -p "$WORK/recipe"
    if python3 -I - "$WORK/recipe" "$IMAGE_REF" "$IMAGE_DIGEST" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

root, image_ref, image_digest = sys.argv[1], sys.argv[2], sys.argv[3]
key = os.path.join(root, "signing_key")
subprocess.run(
    ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", key],
    check=True,
)
public_key = subprocess.check_output(
    ["ssh-keygen", "-y", "-f", key], text=True
).strip()
content = {
    "schema_version": 1,
    "name": "ssh-tiny",
    "version": "1.0.0",
    "image": {"ref": image_ref, "digest": image_digest},
    "mounts": [{"source": "workspace", "target": "/workspace", "mode": "rw"}],
    "lifecycle": {
        "prepare": {"argv": ["/bin/true"], "timeout_s": 5},
        "start": {"argv": ["/bin/true"], "timeout_s": 5},
        "stop": {"argv": ["/bin/true"], "timeout_s": 5},
    },
    "source": {
        "kind": "local_file",
        "path": "/srv/recipes/ssh-tiny.json",
        "author": "ssh-smoke",
        "created_at": "2026-02-01T00:00:00Z",
    },
}
canonical = json.dumps(
    content, sort_keys=True, separators=(",", ":"), ensure_ascii=False
)
payload = "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()
payload_path = os.path.join(root, "payload")
with open(payload_path, "w", encoding="utf-8") as handle:
    handle.write(payload)
os.chmod(payload_path, 0o600)
subprocess.run(
    [
        "ssh-keygen", "-q", "-Y", "sign", "-f", key, "-n",
        "monexus-recipe-v1", payload_path,
    ],
    check=True,
)
with open(payload_path + ".sig", "r", encoding="utf-8") as handle:
    armored = handle.read()
signature = "".join(
    line.strip() for line in armored.splitlines() if not line.startswith("-----")
)
document = dict(content)
document["signature"] = {
    "key_id": "ssh-smoke-key",
    "alg": "ed25519",
    "sig": signature,
}
recipe_path = os.path.join(root, "recipe.json")
with open(recipe_path, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
os.chmod(recipe_path, 0o600)
trust_path = os.path.join(root, "trust.json")
with open(trust_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "keys": [
                {
                    "key_id": "ssh-smoke-key",
                    "public_key": public_key,
                    "added_at": "2026-01-01T00:00:00Z",
                }
            ]
        },
        handle,
    )
os.chmod(trust_path, 0o600)
PY
    then
      RECIPE_JSON="$WORK/recipe/recipe.json"
      RECIPE_TRUST_FILE="$WORK/recipe/trust.json"
      ENV_DOCKER_READY=1
      pass 'signed recipe fixture generated for the SSH environment'
      pass 'Docker is reachable over the temp sshd and nginx:alpine is local'
    else
      ENV_SKIP_REASON="the signed recipe fixture could not be generated"
    fi
  fi
fi
if [ "$ENV_DOCKER_READY" -ne 1 ]; then
  printf 'SKIP  SSH environment lifecycle: %s\n' "$ENV_SKIP_REASON"
fi

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
if start_host "$STATE" MONEXUS_AGENT_SSH=1 "MONEXUS_RECIPE_TRUST=${RECIPE_TRUST_FILE:-}"; then
  pass 'host restarted with MONEXUS_AGENT_SSH=1 and the recipe trust store'
else
  fail 'host restarted with MONEXUS_AGENT_SSH=1 and the recipe trust store'
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
printf '\n== 4b. bounded stderr log + multi-line private-key redaction ==\n'
# ---------------------------------------------------------------------------
BOUND_PARAMS="$(jq -n --arg aid 'mock-ssh-bounded' --arg cmd "$NODE_BIN" \
  --arg script "$MOCK_ACP" --arg ws "$WS_ID" \
  '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script,"--stderr","--stderr-flood","--stderr-key"],cwd:"",workspace_id:$ws,prompt:"bounded stderr",memory_limit:0,env:{}}')"
rpc_call agent.start "$BOUND_PARAMS"
SID_B="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_B" ] && pass "bounded-stderr agent.start returned $SID_B" || fail 'bounded-stderr agent.start' "$RPC_OUT"
BOUND_LOG="$STATE/logs/agent-$SID_B.stderr.log"
if poll_file "$BOUND_LOG" 'MOCK-STDERR-FLOOD-END'; then
  pass 'the stderr flood reached the bounded log'
else
  fail 'the stderr flood reached the bounded log' "$(cat "$BOUND_LOG" 2>/dev/null || true)"
fi
if poll_file "$BOUND_LOG" '-----BEGIN PRIVATE KEY-----[redacted]'; then
  pass 'the multi-line private-key block is redacted to a marker'
else
  fail 'the multi-line private-key block is redacted' "$(cat "$BOUND_LOG" 2>/dev/null || true)"
fi
BOUND_BYTES="$(stat -c %s "$BOUND_LOG" 2>/dev/null || echo 0)"
if [ "$BOUND_BYTES" -ge 1 ] && [ "$BOUND_BYTES" -le 2048 ]; then
  pass "stderr log stays within AGENT_STDERR_CAP ($BOUND_BYTES <= 2048 bytes)"
else
  fail "stderr log stays within AGENT_STDERR_CAP (got $BOUND_BYTES bytes)"
fi
not_contains 'old stderr lines were dropped by the bound' 'MOCK-STDERR-READY' "$(cat "$BOUND_LOG" 2>/dev/null || true)"
not_contains 'no private-key body line in the bounded log' 'FAKE-KEY-BODY' "$(cat "$BOUND_LOG" 2>/dev/null || true)"
BOUND_TRANSCRIPT="$(rpc agent.read "$(read_params "$SID_B")")"
not_contains 'no private-key body line in the ACP transcript' 'FAKE-KEY-BODY' "$BOUND_TRANSCRIPT"

rpc_call agent.stop "$(jq -n --arg id "$SID_B" '{session_id:$id}')"
contains 'the bounded-stderr session stops cleanly' '"ok":true' "$RPC_OUT"
BOUND_SESSIONS="$(rpc agent.list '{"agent_id":"mock-ssh-bounded"}')"
BOUND_REC="$(printf '%s' "$BOUND_SESSIONS" | jq -c --arg id "$SID_B" '(.sessions // []) | map(select(.id==$id)) | .[0]')"
BOUND_TAIL="$(printf '%s' "$BOUND_REC" | jq -r '.stderr_tail // empty')"
contains 'stderr_tail keeps the most recent marker' 'MOCK-STDERR-FLOOD-END' "$BOUND_TAIL"
contains 'stderr_tail keeps the private-key marker' '-----BEGIN PRIVATE KEY-----[redacted]' "$BOUND_TAIL"
not_contains 'stderr_tail has no private-key body line' 'FAKE-KEY-BODY' "$BOUND_TAIL"
not_contains 'stderr_tail dropped the oldest lines with the bound' 'MOCK-STDERR-READY' "$BOUND_TAIL"
TAIL_BYTES="$(printf '%s' "$BOUND_TAIL" | wc -c)"
if [ "$TAIL_BYTES" -le 2048 ]; then
  pass "stderr_tail stays within AGENT_STDERR_CAP ($TAIL_BYTES <= 2048 bytes)"
else
  fail "stderr_tail stays within AGENT_STDERR_CAP (got $TAIL_BYTES bytes)"
fi

# ---------------------------------------------------------------------------
printf '\n== 4c. lost: the local ssh client dies mid-turn ==\n'
# ---------------------------------------------------------------------------
# ADR-0011: losing the transport must end the session as `lost`, never as a
# success. The mock stays in-flight (--hang), the test kills the local ssh
# child of the host, and the remote mock is reaped by cleanup.
LOST_PID_FILE="$WORK/mock-hang-lost.pid"
LOST_PARAMS="$(jq -n --arg aid 'mock-ssh-lost' --arg cmd "$NODE_BIN" \
  --arg script "$MOCK_ACP" --arg ws "$WS_ID" --arg pidfile "$LOST_PID_FILE" \
  '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script,"--stderr","--cwd","--hang","--pid-file",$pidfile],cwd:"",workspace_id:$ws,prompt:"hang until the transport dies",memory_limit:0,env:{}}')"
rpc_call agent.start "$LOST_PARAMS"
SID_LOST="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_LOST" ] && pass "lost-scenario agent.start returned $SID_LOST" || fail 'lost-scenario agent.start' "$RPC_OUT"
eq 'the lost-scenario turn starts running' 'running' "$(printf '%s' "$RPC_OUT" | jq -r '.session.state // empty')"
if wait_pid_file "$LOST_PID_FILE"; then
  pass 'the remote mock is in flight and published its pid'
else
  fail 'the remote mock is in flight and published its pid'
fi
LOST_REMOTE_PID="$(tr -dc '0-9' <"$LOST_PID_FILE" 2>/dev/null)"
REMOTE_MOCK_PIDS="$REMOTE_MOCK_PIDS $LOST_REMOTE_PID"
LOST_SSH_PID="$(local_ssh_pid "$LOST_PID_FILE")"
if [ -n "$LOST_SSH_PID" ]; then
  pass "the local ssh client is a child of the host (pid $LOST_SSH_PID)"
  kill -9 "$LOST_SSH_PID" 2>/dev/null || true
else
  fail 'the local ssh client is a child of the host'
fi
if poll_state "$SID_LOST" lost; then pass 'killing the local ssh client reaches lost'; else fail 'killing the local ssh client reaches lost' "$RPC_OUT"; fi
eq 'lost session stop_reason is lost' 'lost' "$(printf '%s' "$RPC_OUT" | jq -r '.stop_reason // empty')"
contains 'lost session last_error is readable' 'remote agent connection lost' "$(printf '%s' "$RPC_OUT" | jq -r '.last_error // empty')"
not_contains 'a lost session is never reported as idle' '"state":"idle"' "$RPC_OUT"

# ---------------------------------------------------------------------------
printf '\n== 4d. interrupted: the remote agent exits mid-turn ==\n'
# ---------------------------------------------------------------------------
# The local ssh client survives; the remote mock exits with a normal non-255
# status (3), which is exactly the "remote process exited mid-turn" case.
INT_PID_FILE="$WORK/mock-hang-interrupted.pid"
INT_PARAMS="$(jq -n --arg aid 'mock-ssh-interrupted' --arg cmd "$NODE_BIN" \
  --arg script "$MOCK_ACP" --arg ws "$WS_ID" --arg pidfile "$INT_PID_FILE" \
  '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script,"--stderr","--cwd","--hang","--pid-file",$pidfile],cwd:"",workspace_id:$ws,prompt:"exit mid-turn",memory_limit:0,env:{}}')"
rpc_call agent.start "$INT_PARAMS"
SID_INTERRUPTED="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_INTERRUPTED" ] && pass "interrupted-scenario agent.start returned $SID_INTERRUPTED" || fail 'interrupted-scenario agent.start' "$RPC_OUT"
eq 'the interrupted-scenario turn starts running' 'running' "$(printf '%s' "$RPC_OUT" | jq -r '.session.state // empty')"
if wait_pid_file "$INT_PID_FILE"; then
  pass 'the remote mock is in flight and published its pid'
else
  fail 'the remote mock is in flight and published its pid'
fi
INT_REMOTE_PID="$(tr -dc '0-9' <"$INT_PID_FILE" 2>/dev/null)"
REMOTE_MOCK_PIDS="$REMOTE_MOCK_PIDS $INT_REMOTE_PID"
INT_SSH_PID="$(local_ssh_pid "$INT_PID_FILE")"
if [ -n "$INT_SSH_PID" ]; then
  pass "the local ssh client is still alive (pid $INT_SSH_PID)"
else
  fail 'the local ssh client is still alive'
fi
kill -TERM "$INT_REMOTE_PID" 2>/dev/null || true
if poll_state "$SID_INTERRUPTED" interrupted; then pass 'the remote exit mid-turn reaches interrupted'; else fail 'the remote exit mid-turn reaches interrupted' "$RPC_OUT"; fi
eq 'interrupted session stop_reason is interrupted' 'interrupted' "$(printf '%s' "$RPC_OUT" | jq -r '.stop_reason // empty')"
contains 'interrupted session last_error is readable' 'remote agent exited mid-turn' "$(printf '%s' "$RPC_OUT" | jq -r '.last_error // empty')"
not_contains 'an interrupted session is never reported as idle' '"state":"idle"' "$RPC_OUT"

# ---------------------------------------------------------------------------
printf '\n== 4e. regression: a clean turn followed by EOF stays exited ==\n'
# ---------------------------------------------------------------------------
# The mock answers session/prompt normally and then exits 0; the ACP response
# settles the turn first, so the later EOF must keep the existing `exited`
# state rather than being mistaken for a failure.
CLEAN_PARAMS="$(jq -n --arg aid 'mock-ssh-clean' --arg cmd "$NODE_BIN" \
  --arg script "$MOCK_ACP" --arg ws "$WS_ID" \
  '{agent_id:$aid,mode:"acp",command:$cmd,args:[$script,"--exit-after-turn"],cwd:"",workspace_id:$ws,prompt:"clean turn then eof",memory_limit:0,env:{}}')"
rpc_call agent.start "$CLEAN_PARAMS"
SID_CLEAN="$(printf '%s' "$RPC_OUT" | jq -r '.session.id // empty')"
[ -n "$SID_CLEAN" ] && pass "clean-turn agent.start returned $SID_CLEAN" || fail 'clean-turn agent.start' "$RPC_OUT"
eq 'the clean-turn scenario starts running' 'running' "$(printf '%s' "$RPC_OUT" | jq -r '.session.state // empty')"
if poll_state "$SID_CLEAN" exited; then pass 'a completed turn followed by EOF stays exited'; else fail 'a completed turn followed by EOF stays exited' "$RPC_OUT"; fi
eq 'the clean-turn stop_reason is exited' 'exited' "$(printf '%s' "$RPC_OUT" | jq -r '.stop_reason // empty')"

EVENTS="$("$HOST_BIN" subscribe --state-dir "$STATE" --since 0 --max-events 3000 --timeout-ms 6000 2>&1)"
events_have 'the lost session emitted agent.session.lost' 'agent.session.lost' "$SID_LOST" "$EVENTS"
events_lack 'the lost session emitted no false exited event' 'agent.session.exited' "$SID_LOST" "$EVENTS"
events_have 'the interrupted session emitted agent.session.interrupted' 'agent.session.interrupted' "$SID_INTERRUPTED" "$EVENTS"
events_lack 'the interrupted session emitted no false exited event' 'agent.session.exited' "$SID_INTERRUPTED" "$EVENTS"
events_have 'the clean turn still emitted agent.session.exited' 'agent.session.exited' "$SID_CLEAN" "$EVENTS"

# ---------------------------------------------------------------------------
printf '\n== 4f. environment create/start/exec/stop/destroy over SSH ==\n'
# ---------------------------------------------------------------------------
if [ "$ENV_DOCKER_READY" -eq 1 ]; then
  ENV_STARTED=1
  ENV_RECIPE_REF='ssh-tiny@1.0.0'
  ENV_REMOTE_DIR="$ENV_REMOTE_HOME/.monexus/environments/$ENV_ID"
  ENV_REMOTE_ENV="$ENV_REMOTE_DIR/env"
  ENV_SCRATCH="$REMOTE_ROOT_P-monexus-scratch-$ENV_ID"

  rpc_call recipe.import "$(jq -n --arg text "$(cat "$RECIPE_JSON")" \
    '{recipe:$text,source:"ssh-smoke"}')"
  eq 'recipe.import trusts the signed SSH recipe' 'ssh-tiny' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.recipe.name // empty')"
  eq 'recipe state is trusted' 'trusted' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.recipe.state // empty')"

  # The recipe's prepare hook makes the plan high risk: create must ask first.
  ENV_CREATE_ONE="$(jq -n --arg ws "$WS_ID" --arg recipe "$ENV_RECIPE_REF" \
    --arg eid "$ENV_ID" \
    '{workspace_id:$ws,recipe:$recipe,environment_id:$eid,client_request_id:"ssh-env-create-1"}')"
  rpc_call environment.create "$ENV_CREATE_ONE"
  if [ "$RPC_CODE" -ne 0 ]; then
    pass 'high-risk environment.create is refused until approved'
  else
    fail 'high-risk environment.create is refused until approved' "$RPC_OUT"
  fi
  contains 'the refusal names approval_required' 'approval_required' "$RPC_OUT"

  PENDING="$(rpc decision.list '{"status":"pending"}')"
  CREATE_DEC="$(printf '%s' "$PENDING" | jq -r --arg mid "$MACHINE_ID" \
    '.decisions[] | select(.kind=="environment_approval" and .action=="environment.create" and .machine_id==$mid) | .id' |
    tail -n 1)"
  [ -n "$CREATE_DEC" ] && pass "create approval is pending as $CREATE_DEC" ||
    fail 'create approval is pending' "$PENDING"
  eq 'create approval is bound to the SSH machine' "$MACHINE_ID" \
    "$(printf '%s' "$PENDING" | jq -r --arg id "$CREATE_DEC" \
      '.decisions[] | select(.id==$id) | .machine_id')"
  eq 'create approval has a plan digest' 'true' \
    "$(printf '%s' "$PENDING" | jq -r --arg id "$CREATE_DEC" \
      '.decisions[] | select(.id==$id) | (.plan_digest|length > 0)')"

  APPROVED="$(rpc decision.respond "$(jq -n --arg id "$CREATE_DEC" \
    '{decision_id:$id,option_id:"approve",text:"approved by the SSH smoke"}')")"
  contains 'create approval is answered' '"status":"answered"' "$APPROVED"
  contains 'create approval offers approve/deny' 'approve,deny' \
    "$(printf '%s' "$PENDING" | jq -r --arg id "$CREATE_DEC" \
      '.decisions[] | select(.id==$id) | [.options[].option_id] | join(",")')"

  ENV_CREATE_TWO="$(jq -n --arg ws "$WS_ID" --arg recipe "$ENV_RECIPE_REF" \
    --arg eid "$ENV_ID" --arg approval "$CREATE_DEC" \
    '{workspace_id:$ws,recipe:$recipe,environment_id:$eid,approval_id:$approval,client_request_id:"ssh-env-create-2"}')"
  rpc_call environment.create "$ENV_CREATE_TWO"
  eq 'approved environment.create returns running' 'running' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.state // empty')"
  eq 'create used the requested environment id' "$ENV_ID" \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.id // empty')"
  eq 'create used the SSH machine' "$MACHINE_ID" \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.machine_id // empty')"
  eq 'create derived the managed container name' "$ENV_CONTAINER" \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.container_name // empty')"
  RECIPE_HASH="$(printf '%s' "$RPC_OUT" | jq -r '.environment.recipe_hash // empty')"
  eq 'create recorded the verified recipe hash' 'true' \
    "$(printf '%s' "$RPC_OUT" | jq -r '(.environment.recipe_hash // "") | startswith("sha256:")')"

  DECISIONS="$(rpc decision.list '{}')"
  CREATE_CONSUMED="$(printf '%s' "$DECISIONS" | jq -r --arg id "$CREATE_DEC" \
    '.decisions[] | select(.id==$id) | .consumed_at')"
  [ -n "$CREATE_CONSUMED" ] && pass 'create approval was consumed once' ||
    fail 'create approval was consumed once' "$DECISIONS"

  LABELS="$(docker inspect --format '{{json .Config.Labels}}' "$ENV_CONTAINER" 2>/dev/null || true)"
  contains 'container carries the managed label' '"monexus.managed":"true"' "$LABELS"
  contains 'container carries the environment id label' "\"monexus.environment_id\":\"$ENV_ID\"" "$LABELS"
  contains 'container carries the workspace id label' "\"monexus.workspace_id\":\"$WS_ID\"" "$LABELS"
  contains 'container carries the recipe hash label' "\"monexus.recipe_hash\":\"$RECIPE_HASH\"" "$LABELS"
  MOUNTS_JSON="$(docker inspect --format '{{json .Mounts}}' "$ENV_CONTAINER" 2>/dev/null || true)"
  contains 'workspace is the registered remote root' "$REMOTE_ROOT_P" "$MOUNTS_JSON"
  contains 'workspace is mounted at /workspace' '"/workspace"' "$MOUNTS_JSON"
  eq 'remote environment directory is 0700' '700' \
    "$("${SSH_CLIENT[@]}" stat -c '%a' "$ENV_REMOTE_DIR" 2>/dev/null || true)"
  if "${SSH_CLIENT[@]}" "test ! -e '$ENV_REMOTE_ENV'" 2>/dev/null; then
    pass 'the env-file is removed after create'
  else
    fail 'the env-file is removed after create'
  fi

  rpc_call environment.exec "$(jq -n --arg eid "$ENV_ID" \
    '{environment_id:$eid,exec_id:"ssh-exec-1",argv:["sh","-c","printf ssh-env-ok"],timeout_s:60}')"
  eq 'environment.exec exits 0 over SSH' '0' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.exit_code')"
  contains 'environment.exec stdout crossed SSH' 'ssh-env-ok' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.stdout // empty')"
  eq 'environment.exec did not time out' 'false' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.timed_out')"
  eq 'environment.exec was not cancelled' 'false' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.cancelled')"

  rpc_call environment.doctor "$(jq -n --arg eid "$ENV_ID" '{environment_id:$eid}')"
  eq 'environment.doctor reports healthy' 'true' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.healthy')"
  eq 'environment.doctor observes running' 'running' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.state // empty')"

  rpc_call environment.stop "$(jq -n --arg eid "$ENV_ID" '{environment_id:$eid}')"
  eq 'environment.stop moves to stopped' 'stopped' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.state // empty')"
  eq 'stopped container is not running' 'false' \
    "$(docker inspect --format '{{.State.Running}}' "$ENV_CONTAINER" 2>/dev/null || true)"
  if docker inspect --type container "$ENV_CONTAINER" >/dev/null 2>&1; then
    pass 'stop kept the container'
  else
    fail 'stop kept the container'
  fi

  # Starting a stopped environment with a start hook asks once as well.
  rpc_call environment.start "$(jq -n --arg eid "$ENV_ID" \
    '{environment_id:$eid,client_request_id:"ssh-env-start-1"}')"
  if [ "$RPC_CODE" -ne 0 ]; then
    pass 'environment.start with a start hook is refused until approved'
  else
    fail 'environment.start with a start hook is refused until approved' "$RPC_OUT"
  fi
  contains 'start refusal names approval_required' 'approval_required' "$RPC_OUT"
  PENDING_START="$(rpc decision.list '{"status":"pending"}')"
  START_DEC="$(printf '%s' "$PENDING_START" | jq -r --arg mid "$MACHINE_ID" \
    '.decisions[] | select(.kind=="environment_approval" and .action=="environment.start" and .machine_id==$mid) | .id' |
    tail -n 1)"
  [ -n "$START_DEC" ] && pass "start approval is pending as $START_DEC" ||
    fail 'start approval is pending' "$PENDING_START"
  rpc_call decision.respond "$(jq -n --arg id "$START_DEC" \
    '{decision_id:$id,option_id:"approve",text:"start approved by the SSH smoke"}')"
  contains 'start approval is answered' '"status":"answered"' "$RPC_OUT"
  rpc_call environment.start "$(jq -n --arg eid "$ENV_ID" --arg approval "$START_DEC" \
    '{environment_id:$eid,approval_id:$approval,client_request_id:"ssh-env-start-2"}')"
  eq 'approved environment.start returns running' 'running' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.state // empty')"
  eq 'restarted container is running' 'true' \
    "$(docker inspect --format '{{.State.Running}}' "$ENV_CONTAINER" 2>/dev/null || true)"
  START_CONSUMED="$(rpc decision.list '{}' | jq -r --arg id "$START_DEC" \
    '.decisions[] | select(.id==$id) | .consumed_at')"
  [ -n "$START_CONSUMED" ] && pass 'start approval was consumed once' ||
    fail 'start approval was consumed once'

  rpc_call environment.exec "$(jq -n --arg eid "$ENV_ID" \
    '{environment_id:$eid,exec_id:"ssh-exec-2",argv:["sh","-c","printf ssh-env-restarted"],timeout_s:60}')"
  eq 'exec works again after start' '0' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.exit_code')"
  contains 'restarted exec stdout crossed SSH' 'ssh-env-restarted' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.stdout // empty')"

  rpc_call environment.destroy "$(jq -n --arg eid "$ENV_ID" \
    '{environment_id:$eid,client_request_id:"ssh-env-destroy-1"}')"
  eq 'environment.destroy tombstones the record' 'destroyed' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.state // empty')"
  eq 'destroy cleanup succeeded' 'true' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.cleanup_ok // empty')"
  if docker inspect --type container "$ENV_CONTAINER" >/dev/null 2>&1; then
    fail 'destroy left no managed container'
  else
    pass 'destroy left no managed container'
  fi
  if "${SSH_CLIENT[@]}" "test ! -e '$ENV_REMOTE_DIR'" 2>/dev/null; then
    pass 'destroy removed the remote environment directory'
  else
    fail 'destroy removed the remote environment directory'
  fi
  if "${SSH_CLIENT[@]}" "test ! -e '$ENV_SCRATCH'" 2>/dev/null; then
    pass 'destroy removed the derived scratch directory'
  else
    fail 'destroy removed the derived scratch directory'
  fi
  rpc_call environment.destroy "$(jq -n --arg eid "$ENV_ID" \
    '{environment_id:$eid,client_request_id:"ssh-env-destroy-2"}')"
  eq 'repeated destroy stays idempotent' 'destroyed' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.state // empty')"
  rpc_call environment.get "$(jq -n --arg eid "$ENV_ID" '{environment_id:$eid}')"
  eq 'the destroyed environment keeps its tombstone' 'destroyed' \
    "$(printf '%s' "$RPC_OUT" | jq -r '.environment.state // empty')"
else
  printf 'SKIP  SSH environment lifecycle checks: %s\n' "$ENV_SKIP_REASON"
fi

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
