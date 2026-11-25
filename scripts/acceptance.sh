#!/usr/bin/env bash
# MoNexus V0.1 end-to-end acceptance (M7).
#
# Runs against a throwaway HOME, a temp state dir and a temp loopback sshd.
# No external machine, real account or credential is contacted. The packaged
# tarball is built first and every product check runs through its installed
# layout; set ACCEPTANCE_SKIP_PACKAGE=1 to test the repository build instead.
#
# Output: one PASS/FAIL/SKIP row per requirement (a)-(h), plus packaging (P0),
# and a SUMMARY line. Exit code is non-zero when any row FAILs.
#
# Requirements: bash, jq, git, python3, sha256sum, tar. SSH parts need
# sshd/ssh-keygen (a loopback sshd). Recovery needs tmux. Desktop reconnect
# needs xvfb-run; it is reported SKIP (with a reason) when unavailable.
#
# Usage:
#   scripts/acceptance.sh
#   ACCEPTANCE_SKIP_PACKAGE=1 scripts/acceptance.sh
#   M7_REAL_ACP=1 scripts/acceptance.sh   # also probe a real ACP adapter
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME:?HOME is required to run the build toolchain}"
REAL_USER="$(id -un)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-acceptance.XXXXXX")"
mkdir -p "$WORK/home" "$WORK/tmux"
export HOME="$WORK/home"
export TMUX_TMPDIR="$WORK/tmux"
printf 'set -g remain-on-exit on\n' >"$HOME/.tmux.conf"

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  for candidate in "$REAL_HOME"/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ]; then NODE_BIN="$candidate"; break; fi
  done
fi
if [ -n "$NODE_BIN" ]; then
  export PATH="$(dirname "$NODE_BIN"):$PATH"
fi
export PATH="$REAL_HOME/.moon/bin:$PATH"
export MONEXUS_MAX_PARALLEL=4
export MONEXUS_RECOVERY_POLL_MS=100
export MONEXUS_RECOVERY_UNVERIFIABLE_MS=1500

STATE="$HOME/.monexus"
RESULTS="$WORK/results.txt"
: >"$RESULTS"
HOST_PID=""
FAKE_HOST_PID=""
DESKTOP_PID=""
SSHD_PID=""
M=""
HOST_BIN=""
DESKTOP_BIN=""
INSTALL=""

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$RESULTS"; }
pass() { record "$1" "$2" PASS "${3:-}"; printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() {
  record "$1" "$2" FAIL "${3:-}"
  printf 'FAIL  %-3s %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then printf '      %s\n' "$3" >&2; fi
}
skip() { record "$1" "$2" SKIP "${3:-}"; printf 'SKIP  %-3s %s (%s)\n' "$1" "$2" "${3:-}"; }

contains() { # id item needle haystack
  if printf '%s' "$4" | grep -Fq -- "$3"; then pass "$1" "$2"; else fail "$1" "$2" "missing: $3"; fi
}
not_contains() { # id item needle haystack
  if printf '%s' "$4" | grep -Fq -- "$3"; then fail "$1" "$2" "unexpected: $3"; else pass "$1" "$2"; fi
}
eq() { # id item expected actual
  if [ "$3" = "$4" ]; then pass "$1" "$2"; else fail "$1" "$2" "expected: $3 got: $4"; fi
}
wait_file_text() { # file needle timeout_tenths
  local file="$1" needle="$2" timeout="${3:-200}" i=0
  while [ "$i" -lt "$timeout" ]; do
    grep -Fq -- "$needle" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
count_text() { grep -Fc -- "$1" "$2" 2>/dev/null || true; }

cleanup() {
  if [ -n "$DESKTOP_PID" ]; then kill -TERM -- "-$DESKTOP_PID" 2>/dev/null || true; fi
  if [ -n "$FAKE_HOST_PID" ]; then kill "$FAKE_HOST_PID" 2>/dev/null || true; wait "$FAKE_HOST_PID" 2>/dev/null || true; fi
  if [ -n "$HOST_PID" ]; then kill "$HOST_PID" 2>/dev/null || true; wait "$HOST_PID" 2>/dev/null || true; fi
  if [ -n "$SSHD_PID" ]; then kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; fi
  if command -v tmux >/dev/null 2>&1; then
    tmux ls 2>/dev/null | sed -n 's/:.*//p' | while read -r s; do
      case "$s" in monexus-run-*) tmux kill-session -t "$s" 2>/dev/null || true ;; esac
    done
  fi
  if [ "${KEEP_ACCEPTANCE_WORK:-0}" = "1" ]; then
    printf '\nwork dir kept: %s\n' "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

summary() {
  printf '\n%-4s %-62s %-6s %s\n' ID ITEM RESULT NOTE
  printf '%-4s %-62s %-6s %s\n' -- -------------------------------------------------------------- ------ ----
  local fails=0
  while IFS=$'\t' read -r id item result note; do
    printf '%-4s %-62s %-6s %s\n' "$id" "$item" "$result" "$note"
    [ "$result" = "FAIL" ] && fails=$((fails + 1))
  done <"$RESULTS"
  local total
  total="$(wc -l <"$RESULTS" | tr -d ' ')"
  printf '\nSUMMARY  checks=%s failed=%s  result=%s\n' \
    "$total" "$fails" "$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)"
  [ "$fails" -eq 0 ]
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'acceptance: jq is required\n' >&2
  exit 2
fi
if [ -z "$NODE_BIN" ]; then
  printf 'acceptance: node is required (mock ACP agent)\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
printf '== P0. package: release build, fixed paths, install layout, checksum ==\n'
# ---------------------------------------------------------------------------
pick_bin() {
  local candidate
  for candidate in "$@"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}
if [ "${ACCEPTANCE_SKIP_PACKAGE:-0}" = "1" ]; then
  M="$ROOT/scripts/monexus.sh"
  HOST_BIN="$(pick_bin \
    "$ROOT/_build/native/release/build/monexus/host/host.exe" \
    "$ROOT/_build/native/debug/build/monexus/host/host.exe" || true)"
  DESKTOP_BIN="$(pick_bin \
    "$ROOT/_build/native/release/build/monexus/desktop/linux_skia/linux_skia.exe" \
    "$ROOT/_build/native/debug/build/monexus/desktop/linux_skia/linux_skia.exe" || true)"
  record P0 "package tarball + checksum + install layout" SKIP "ACCEPTANCE_SKIP_PACKAGE=1"
elif (cd "$ROOT" && HOME="$REAL_HOME" scripts/package.sh --out "$WORK/dist") >"$WORK/package.log" 2>&1; then
  TARBALL="$(find "$WORK/dist" -maxdepth 1 -name 'monexus-*.tar.gz' | head -n 1)"
  CHECKSUM="$TARBALL.sha256"
  if [ -n "$TARBALL" ] && [ -f "$CHECKSUM" ] &&
    (cd "$WORK/dist" && sha256sum -c "$(basename "$CHECKSUM")" >/dev/null 2>&1); then
    pass P0 "package tarball + checksum + install layout" "$(basename "$TARBALL")"
  else
    fail P0 "package tarball + checksum + install layout" "checksum missing or mismatched"
  fi
  if [ -n "$TARBALL" ]; then
    mkdir -p "$WORK/install"
    tar -xzf "$TARBALL" -C "$WORK/install"
    INSTALL="$WORK/install/$(basename "$TARBALL" .tar.gz)"
    M="$INSTALL/bin/monexus"
    HOST_BIN="$INSTALL/bin/monexus-host"
    DESKTOP_BIN="$INSTALL/bin/monexus-desktop"
  fi
  if [ -n "$INSTALL" ] &&
    [ -x "$M" ] && [ -x "$HOST_BIN" ] && [ -x "$DESKTOP_BIN" ] &&
    [ -f "$INSTALL/share/monexus/VERSION" ] &&
    [ "$("$M" version 2>/dev/null | head -n 1)" = "monexus $(head -n 1 "$ROOT/VERSION" | tr -d '[:space:]')" ]; then
    pass P0 "installed bin/ + share/ layout and --version"
  else
    fail P0 "installed bin/ + share/ layout and --version" "stage is incomplete"
  fi
else
  fail P0 "package tarball + checksum + install layout" "scripts/package.sh failed; see package.log"
  M="$ROOT/scripts/monexus.sh"
  HOST_BIN="$(pick_bin \
    "$ROOT/_build/native/release/build/monexus/host/host.exe" \
    "$ROOT/_build/native/debug/build/monexus/host/host.exe" || true)"
  DESKTOP_BIN="$(pick_bin \
    "$ROOT/_build/native/release/build/monexus/desktop/linux_skia/linux_skia.exe" \
    "$ROOT/_build/native/debug/build/monexus/desktop/linux_skia/linux_skia.exe" || true)"
fi
if [ -z "$HOST_BIN" ] || [ -z "$M" ] || [ ! -x "$HOST_BIN" ]; then
  printf 'acceptance: no host binary; aborting\n' >&2
  summary || true
  exit 1
fi
printf 'using launcher: %s\nusing host:     %s\n\n' "$M" "$HOST_BIN"

# ---------------------------------------------------------------------------
printf '== (a). one-command start (headless), state layout, offline/reconnect ==\n'
# ---------------------------------------------------------------------------
A_START="$WORK/a-start.log"
"$M" start --headless >"$A_START" 2>&1
A_CODE=$?
if [ "$A_CODE" -eq 0 ] && grep -Fq 'host.json:' "$A_START"; then
  pass a1 "monexus start --headless starts the host and reads host.json"
else
  fail a1 "monexus start --headless starts the host and reads host.json" "exit=$A_CODE"
fi
MODE="$(stat -c '%a' "$STATE/host.json" 2>/dev/null || echo '')"
eq a2 "host.json is mode 0600" 600 "$MODE"
MISSING=""
for item in agents artifacts logs monexus.db examples/hello-workspace/README.md examples/hello-workspace/AGENTS.md; do
  [ -e "$STATE/$item" ] || MISSING="$MISSING $item"
done
if [ -z "$MISSING" ]; then
  pass a3 "first run created agents/, artifacts/, db and the example workspace"
else
  fail a3 "first run created agents/, artifacts/, db and the example workspace" "missing:$MISSING"
fi
A_STATUS="$("$M" status 2>&1)"
contains a4 "monexus status reports host online and ws_url" "host online" "$A_STATUS"
contains a5 "host.json endpoint is readable" "ws_url=ws://127.0.0.1:" "$A_STATUS"

"$M" stop >"$WORK/a-stop.log" 2>&1
if "$M" status >/dev/null 2>&1; then
  fail a6 "host goes offline after monexus stop" "status still online"
else
  pass a6 "host goes offline after monexus stop"
fi
"$M" start --headless >"$WORK/a-restart.log" 2>&1
if "$M" status >/dev/null 2>&1 && grep -Fq 'host.json:' "$WORK/a-restart.log"; then
  pass a7 "monexus restarts and reconnects on the same state dir"
else
  fail a7 "monexus restarts and reconnects on the same state dir" "restart failed"
fi
env -u DISPLAY -u WAYLAND_DISPLAY "$M" start >"$WORK/a-nodisplay.log" 2>&1
NODISPLAY_CODE=$?
if [ "$NODISPLAY_CODE" -eq 3 ] && grep -Fq -- '--headless' "$WORK/a-nodisplay.log"; then
  pass a8 "no display gives a clear error and headless usage"
else
  fail a8 "no display gives a clear error and headless usage" "exit=$NODISPLAY_CODE"
fi
HOST_PID="$(cat "$STATE/host.pid" 2>/dev/null || true)"

rpc() { "$HOST_BIN" rpc --state-dir "${3:-$STATE}" --method "$1" --params "$2" 2>&1; }
run_status() { rpc run.get "$(jq -n --arg id "$1" '{run_id:$id}')" | jq -r '.run.status // "missing"'; }
wait_run() { # run_id want timeout_tenths
  local run_id="$1" want="$2" timeout="${3:-200}" i=0 seen=""
  while [ "$i" -lt "$timeout" ]; do
    seen="$(run_status "$run_id")"
    [ "$seen" = "$want" ] && return 0
    case "$seen" in succeeded|failed|cancelled|lost) return 1 ;; esac
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
poll_agent_text() { # session_id needle timeout_tenths
  local sid="$1" needle="$2" timeout="${3:-200}" i=0 out=""
  while [ "$i" -lt "$timeout" ]; do
    out="$(rpc agent.read "$(jq -n --arg id "$sid" '{session_id:$id,cursor:0}')")"
    if printf '%s' "$out" | grep -Fq -- "$needle"; then RPC_OUT="$out"; return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  RPC_OUT="$out"
  return 1
}

# ---------------------------------------------------------------------------
printf '\n== (b). register this machine and one SSH machine (loopback sshd) ==\n'
# ---------------------------------------------------------------------------
LOCAL_ADD="$("$HOST_BIN" machine add --state-dir "$STATE" --kind local --name "this machine" 2>&1)"
LOCAL_ID="$(printf '%s' "$LOCAL_ADD" | sed -n 's/^id=//p' | head -n 1)"
if [ -n "$LOCAL_ID" ] && printf '%s' "$LOCAL_ADD" | grep -Fq 'status=online'; then
  pass b1 "machine add --kind local registers this machine as online"
else
  fail b1 "machine add --kind local registers this machine as online" "$LOCAL_ADD"
fi
LOCAL_PROBE="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$LOCAL_ID" --timeout-seconds 5 2>&1)"
contains b2 "local machine probe returns its profile" "profile.os=" "$LOCAL_PROBE"

SSHD_BIN="$(command -v sshd || true)"
[ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ] && SSHD_BIN=/usr/sbin/sshd
SSH_OK=0
if [ -n "$SSHD_BIN" ] && command -v ssh-keygen >/dev/null 2>&1 && command -v ssh >/dev/null 2>&1; then
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
  for _ in $(seq 1 100); do
    kill -0 "$SSHD_PID" 2>/dev/null && ss -ltn 2>/dev/null | grep -Fq "127.0.0.1:$SSH_PORT" && { SSH_OK=1; break; }
    sleep 0.1
  done
  if [ "$SSH_OK" = "1" ]; then
    pass b3 "temporary loopback sshd started (no real remote used)" "127.0.0.1:$SSH_PORT"
  else
    fail b3 "temporary loopback sshd started (no real remote used)" "$(cat "$SSH_TMP/sshd.log" 2>/dev/null || true)"
  fi
else
  skip b3 "temporary loopback sshd started (no real remote used)" "sshd/ssh-keygen/ssh unavailable"
fi
SSH_ID=""
if [ "$SSH_OK" = "1" ]; then
  SSH_ADD="$("$HOST_BIN" machine add --state-dir "$STATE" \
    --name loopback --host 127.0.0.1 --port "$SSH_PORT" --user "$REAL_USER" \
    --identity "$SSH_TMP/client_ed25519" --use-ssh-config false \
    --host-key-policy accept-new --known-hosts-file "$WORK/known_hosts" 2>&1)"
  SSH_ID="$(printf '%s' "$SSH_ADD" | sed -n 's/^id=//p' | head -n 1)"
  if [ -n "$SSH_ID" ]; then
    pass b4 "SSH machine registered (loopback sshd substitute)"
  else
    fail b4 "SSH machine registered (loopback sshd substitute)" "$SSH_ADD"
  fi
  SSH_PROBE="$("$HOST_BIN" machine probe --state-dir "$STATE" --id "$SSH_ID" --timeout-seconds 15 2>&1)"
  contains b5 "SSH machine probes online" "status=online" "$SSH_PROBE"
  if [ -f "$WORK/home/.ssh/known_hosts" ]; then
    fail b6 "acceptance did not modify the user's ~/.ssh" "temp HOME somehow has ~/.ssh/known_hosts"
  else
    pass b6 "acceptance did not modify the user's ~/.ssh"
  fi
else
  skip b4 "SSH machine registered (loopback sshd substitute)" "no sshd"
  skip b5 "SSH machine probes online" "no sshd"
  skip b6 "acceptance did not modify the user's ~/.ssh" "no sshd"
fi

# ---------------------------------------------------------------------------
printf '\n== (c). open a Workspace, create and list a Worktree ==\n'
# ---------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email acceptance@example.invalid
git -C "$REPO" config user.name Acceptance
printf 'hello m7\n' >"$REPO/README.md"
printf 'verify marker\n' >"$REPO/verify.txt"
git -C "$REPO" add README.md verify.txt
git -C "$REPO" commit -qm 'initial'

OPEN="$(rpc workspace.open "$(jq -n --arg m "$LOCAL_ID" --arg root "$REPO" '{target:$m,root:$root}')")"
WS="$(printf '%s' "$OPEN" | jq -r '.workspace.id // empty')"
if [ -n "$WS" ]; then
  pass c1 "workspace.open returns a workspace for this machine"
else
  fail c1 "workspace.open returns a workspace for this machine" "$OPEN"
fi
eq c2 "registered local machine workspace uses the local provider" "local" "$(printf '%s' "$OPEN" | jq -r '.workspace.kind')"
WT_PATH="$WORK/wt-one"
WT="$(rpc worktree.create "$(jq -n --arg id "$WS" --arg p "$WT_PATH" '{workspace_id:$id,branch:"m7-demo",path:$p,base:""}')")"
WT_ID="$(printf '%s' "$WT" | jq -r '.worktree.id // empty')"
if [ -n "$WT_ID" ]; then
  pass c3 "worktree.create returns a worktree"
else
  fail c3 "worktree.create returns a worktree" "$WT"
fi
WTLIST="$(rpc worktree.list "$(jq -n --arg id "$WS" '{workspace_id:$id}')")"
contains c4 "worktree.list includes the created worktree" "$WT_ID" "$WTLIST"
contains c5 "example Workspace from first run is present on disk" "hello-workspace" "$(ls "$STATE/examples")"

# ---------------------------------------------------------------------------
printf '\n== (d). one mock ACP session (stdio adapter) ==\n'
# ---------------------------------------------------------------------------
MOCK_ACP="$ROOT/tests/agent/mock_acp_agent.mjs"
PROBE_PARAMS="$(jq -n --arg cmd "$NODE_BIN" --arg script "$MOCK_ACP" \
  '{agent_id:"m7-mock",mode:"acp",command:$cmd,args:[$script],cwd:"",env:{}}')"
PROBE_OUT="$(rpc agent.probe "$PROBE_PARAMS")"
eq d1 "mock ACP agent readiness probe is ok" "true" "$(printf '%s' "$PROBE_OUT" | jq -r '.readiness.ok // false')"
START_PARAMS="$(jq -n --arg cmd "$NODE_BIN" --arg script "$MOCK_ACP" --arg ws "$WS" \
  '{agent_id:"m7-mock",mode:"acp",command:$cmd,args:[$script],workspace_id:$ws,prompt:"hello monexus",memory_limit:4096,env:{}}')"
START_OUT="$(rpc agent.start "$START_PARAMS")"
SID="$(printf '%s' "$START_OUT" | jq -r '.session.id // empty')"
if [ -n "$SID" ]; then
  pass d2 "agent.start creates an ACP session"
else
  fail d2 "agent.start creates an ACP session" "$START_OUT"
fi
if poll_agent_text "$SID" "MOCK#1 start" 200; then
  pass d3 "streamed ACP transcript reached agent.read"
else
  fail d3 "streamed ACP transcript reached agent.read" "$RPC_OUT"
fi
contains d4 "agent.read exposes the session record" '"state"' "$RPC_OUT"
rpc agent.stop "$(jq -n --arg id "$SID" '{session_id:$id}')" >/dev/null
sleep 0.3
STOPPED="$(rpc agent.read "$(jq -n --arg id "$SID" '{session_id:$id,cursor:0}')")"
eq d5 "agent.stop ends the session" "stopped" "$(printf '%s' "$STOPPED" | jq -r '.state // empty')"

if [ "${M7_REAL_ACP:-0}" = "1" ]; then
  REAL_PROBE="$(HOME="$REAL_HOME" "$HOST_BIN" rpc --state-dir "$STATE" --method agent.probe \
    --params '{"agent_id":"claude","mode":"acp","command":"","args":[],"env":{}}' 2>&1)"
  if printf '%s' "$REAL_PROBE" | grep -Fq '"ok":true'; then
    pass d6 "real ACP adapter probe (opt-in)" "claude-code-acp"
  else
    skip d6 "real ACP adapter probe (opt-in)" "not logged in or adapter unavailable"
  fi
else
  record d6 "real ACP adapter probe (opt-in)" SKIP "M7_REAL_ACP=1 to run"
fi

# ---------------------------------------------------------------------------
printf '\n== (e). two tasks in parallel (local + SSH) behind the evidence gate ==\n'
# ---------------------------------------------------------------------------
PROJECT="$(rpc project.create "$(jq -n --arg ws "$WS" \
  '{name:"m7-demo",verify:["sh -c \"test -f verify.txt\"","echo verify-ok"]}')")"
PJ="$(printf '%s' "$PROJECT" | jq -r '.project.id // empty')"
TASK="$(rpc task.create "$(jq -n --arg pj "$PJ" --arg ws "$WS" \
  '{title:"parallel local+ssh",project_id:$pj,workspace_id:$ws,status:"ready"}')")"
TK="$(printf '%s' "$TASK" | jq -r '.task.id // empty')"
eq e1 "task inherits the project verify[]" "2" "$(printf '%s' "$TASK" | jq -r '.task.verify | length')"
RWS=""
if [ -n "$SSH_ID" ]; then
  R_OPEN="$(rpc workspace.open "$(jq -n --arg m "$SSH_ID" --arg root "$REPO" '{target:$m,root:$root}')")"
  RWS="$(printf '%s' "$R_OPEN" | jq -r '.workspace.id // empty')"
  contains e2 "SSH workspace opened over the same contract" "ssh" "$(printf '%s' "$R_OPEN" | jq -r '.workspace.kind')"
fi
L_RUN="$(rpc run.create "$(jq -n --arg tk "$TK" --arg ws "$WS" --arg m "$LOCAL_ID" \
  '{task_id:$tk,workspace_id:$ws,machine_id:$m,mode:"command",command:"sh -c \"sleep 2; echo local-m7\"",idempotency_key:"m7/local"}')" | jq -r '.run.id // empty')"
R_RUN=""
if [ -n "$RWS" ]; then
  R_RUN="$(rpc run.create "$(jq -n --arg tk "$TK" --arg ws "$RWS" --arg m "$SSH_ID" \
    '{task_id:$tk,workspace_id:$ws,machine_id:$m,mode:"command",command:"sh -c \"sleep 2; echo ssh-m7\"",idempotency_key:"m7/ssh"}')" | jq -r '.run.id // empty')"
fi
sleep 0.7
L_ST="$(run_status "$L_RUN")"
R_ST="$([ -n "$R_RUN" ] && run_status "$R_RUN" || echo missing)"
if { [ "$L_ST" = "running" ] || [ "$L_ST" = "verifying" ]; } && \
   { [ "$R_ST" = "running" ] || [ "$R_ST" = "verifying" ]; }; then
  pass e3 "local and SSH runs execute in parallel"
else
  fail e3 "local and SSH runs execute in parallel" "local=$L_ST ssh=$R_ST"
fi
if wait_run "$L_RUN" succeeded 300; then pass e4 "local run succeeds"; else fail e4 "local run succeeds" "$(rpc run.get "$(jq -n --arg id "$L_RUN" '{run_id:$id}')")"; fi
if [ -n "$R_RUN" ] && wait_run "$R_RUN" succeeded 300; then
  pass e5 "SSH run succeeds"
else
  fail e5 "SSH run succeeds" "$([ -n "$R_RUN" ] && rpc run.get "$(jq -n --arg id "$R_RUN" '{run_id:$id}')" || echo "no ssh run")"
fi
DETAIL="$(rpc run.get "$(jq -n --arg id "$L_RUN" '{run_id:$id}')")"
eq e6 "evidence gate produced two passing rows" "true" "$(printf '%s' "$DETAIL" | jq -r '.evidence | length == 2 and all(.passed == true)')"
eq e7 "a passing gate is required for succeeded" "verified" "$(printf '%s' "$DETAIL" | jq -r '.run.stop_reason')"
eq e8 "the task rolls up both parallel runs" "2/2 runs succeeded" "$(rpc task.get "$(jq -n --arg id "$TK" '{task_id:$id}')" | jq -r '.task.result_summary')"

# ---------------------------------------------------------------------------
printf '\n== (f). failed evidence -> Decision -> Inbox waive / retry ==\n'
# ---------------------------------------------------------------------------
STRICT_PJ="$(rpc project.create '{"name":"strict-m7","verify":["sh -c \"echo lint-error; exit 3\""]}' | jq -r '.project.id')"
STRICT_TASK="$(rpc task.create "$(jq -n --arg pj "$STRICT_PJ" --arg ws "$WS" \
  '{title:"strict",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
BAD_RUN="$(rpc run.create "$(jq -n --arg tk "$STRICT_TASK" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"echo main-ok",idempotency_key:"m7/strict-1"}')" | jq -r '.run.id')"
if wait_run "$BAD_RUN" waiting_approval 200; then
  pass f1 "failed verify parks the run in waiting_approval"
else
  fail f1 "failed verify parks the run in waiting_approval" "$(rpc run.get "$(jq -n --arg id "$BAD_RUN" '{run_id:$id}')")"
fi
PENDING="$(rpc decision.list '{"status":"pending"}')"
DEC="$(printf '%s' "$PENDING" | jq -r --arg run "$BAD_RUN" '.decisions[] | select(.run_id==$run) | .id' | head -n 1)"
if [ -n "$DEC" ]; then pass f2 "evidence failure created a Decision"; else fail f2 "evidence failure created a Decision" "$PENDING"; fi
eq f3 "Decision is in Needs you" "needs_you" "$(printf '%s' "$PENDING" | jq -r --arg id "$DEC" '.decisions[] | select(.id==$id) | .inbox')"
contains f4 "Decision offers waive/retry/fail" "waive,retry,fail" "$(printf '%s' "$PENDING" | jq -r --arg id "$DEC" '.decisions[] | select(.id==$id) | [.options[].option_id] | join(",")')"
WAIVE="$(rpc decision.respond "$(jq -n --arg id "$DEC" '{decision_id:$id,option_id:"waive",text:"accepted in the Inbox"}')")"
contains f5 "answering waive returns the answered Decision" '"status":"answered"' "$WAIVE"
eq f5b "answering waive settles the run succeeded" "succeeded" "$(run_status "$BAD_RUN")"
eq f6 "waiver is stamped on evidence" "true" "$(rpc run.get "$(jq -n --arg id "$BAD_RUN" '{run_id:$id}')" | jq -r '.evidence[0].waived')"

RETRY_TASK="$(rpc task.create "$(jq -n --arg pj "$STRICT_PJ" --arg ws "$WS" \
  '{title:"strict retry",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
RETRY_RUN="$(rpc run.create "$(jq -n --arg tk "$RETRY_TASK" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"echo main-ok",idempotency_key:"m7/strict-2"}')" | jq -r '.run.id')"
wait_run "$RETRY_RUN" waiting_approval 200 >/dev/null 2>&1
RETRY_DEC="$(rpc decision.list '{"status":"pending"}' | jq -r --arg run "$RETRY_RUN" '.decisions[] | select(.run_id==$run) | .id' | head -n 1)"
rpc decision.respond "$(jq -n --arg id "$RETRY_DEC" '{decision_id:$id,option_id:"retry",text:"re-run the gate"}')" >/dev/null
sleep 0.6
NEW_DEC="$(rpc decision.list '{"status":"pending"}' | jq -r --arg run "$RETRY_RUN" '.decisions[] | select(.run_id==$run) | .id' | head -n 1)"
if [ -n "$NEW_DEC" ] && [ "$NEW_DEC" != "$RETRY_DEC" ]; then
  pass f7 "retry re-runs the gate and asks again"
else
  fail f7 "retry re-runs the gate and asks again" "old=$RETRY_DEC new=$NEW_DEC"
fi
rpc decision.respond "$(jq -n --arg id "$NEW_DEC" '{decision_id:$id,option_id:"fail",text:"not acceptable"}')" >/dev/null
sleep 0.3
eq f8 "answering fail settles the run failed" "failed" "$(run_status "$RETRY_RUN")"
eq f9 "answered Decisions leave Needs you" "handled" "$(rpc decision.list '{}' | jq -r --arg id "$DEC" '.decisions[] | select(.id==$id) | .inbox')"

# ---------------------------------------------------------------------------
printf '\n== (g). recovery: desktop reconnect, host restart, unreachable SSH ==\n'
# ---------------------------------------------------------------------------
# A durable run is created before the crash so reconcile has real work to do.
GR_TASK="$(rpc task.create "$(jq -n --arg pj "$PJ" --arg ws "$WS" \
  '{title:"restart reconcile",project_id:$pj,workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
GR_RUN="$(rpc run.create "$(jq -n --arg tk "$GR_TASK" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"sleep 10; echo restart-ok\"",idempotency_key:"m7/restart"}')" | jq -r '.run.id')"
wait_run "$GR_RUN" running 100 && pass g1 "durable run is running before the host crash" || fail g1 "durable run is running before the host crash" "$(run_status "$GR_RUN")"

DESKTOP_TRACE="$WORK/desktop-trace.log"
if [ -x "$DESKTOP_BIN" ] && command -v xvfb-run >/dev/null 2>&1; then
  # stdbuf keeps the trace line-buffered when stdout is a file; without it a
  # live window's println() output sits in the C buffer and the test cannot
  # observe reconnect transitions.
  ( MONEXUS_STATE_DIR="$STATE" MONEXUS_LINK_TRACE=1 \
      xvfb-run -a stdbuf -oL -eL "$DESKTOP_BIN" ) >"$DESKTOP_TRACE" 2>&1 &
  DESKTOP_PID=$!
  if wait_file_text "$DESKTOP_TRACE" "link online" 300; then
    pass g2 "desktop connects (xvfb, link online traced)"
  else
    fail g2 "desktop connects (xvfb, link online traced)" "$(tail -n 5 "$DESKTOP_TRACE" 2>/dev/null)"
  fi
else
  skip g2 "desktop connects (xvfb, link online traced)" "xvfb-run or desktop binary missing"
fi

kill -9 "$HOST_PID" 2>/dev/null || true
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
if [ -n "$DESKTOP_PID" ]; then
  wait_file_text "$DESKTOP_TRACE" "link offline" 200 && pass g3 "desktop shows offline when the host dies" || fail g3 "desktop shows offline when the host dies" "$(tail -n 5 "$DESKTOP_TRACE" 2>/dev/null)"
else
  skip g3 "desktop shows offline when the host dies" "desktop not running"
fi
"$M" start --headless >"$WORK/g-restart.log" 2>&1
"$M" status >/dev/null 2>&1 && pass g4 "host restarts on the same state dir" || fail g4 "host restarts on the same state dir" "$(cat "$WORK/g-restart.log")"
HOST_PID="$(cat "$STATE/host.pid" 2>/dev/null || true)"
if [ -n "$DESKTOP_PID" ]; then
  ONLINE_BEFORE=1
  for _ in $(seq 1 200); do
    ONLINE_NOW="$(count_text 'link online' "$DESKTOP_TRACE")"
    if [ "${ONLINE_NOW:-0}" -gt "$ONLINE_BEFORE" ]; then pass g5 "desktop reconnects after the host restarts"; break; fi
    sleep 0.1
  done
  if [ "${ONLINE_NOW:-0}" -le "$ONLINE_BEFORE" ]; then
    fail g5 "desktop reconnects after the host restarts" "$(tail -n 8 "$DESKTOP_TRACE" 2>/dev/null)"
  fi
else
  skip g5 "desktop reconnects after the host restarts" "desktop not running"
fi
if wait_run "$GR_RUN" succeeded 300; then
  pass g6 "startup reconcile settles the crashed run (no silent running)"
else
  fail g6 "startup reconcile settles the crashed run (no silent running)" "$(rpc run.get "$(jq -n --arg id "$GR_RUN" '{run_id:$id}')")"
fi
GREV="$(rpc events.list '{"since":0,"limit":2000}')"
eq g7 "reconcile wrote run.reconcile.reconnect" "1" \
  "$(printf '%s' "$GREV" | jq -r --arg run "$GR_RUN" '[.events[] | select(.type=="run.recovered" and .subject==$run and .payload.action=="run.reconcile.reconnect")] | length')"
if [ -n "$DESKTOP_PID" ]; then
  kill -TERM -- "-$DESKTOP_PID" 2>/dev/null || true
  sleep 0.3
  DESKTOP_PID=""
fi

# Unreachable SSH: a separate host with a fake ssh that can be told to
# disconnect. The run must become lost/unverifiable with a Decision, never a
# silent success.
FAKE_PID=""
if command -v tmux >/dev/null 2>&1; then
  FAKE_ROOT="$WORK/fake"
  FAKE_BIN="$FAKE_ROOT/bin"
  FAKE_MODE="$FAKE_ROOT/mode"
  FAKE_STATE="$WORK/fake-state"
  mkdir -p "$FAKE_BIN" "$FAKE_STATE"
  printf 'ok\n' >"$FAKE_MODE"
  cat >"$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/bin/sh
set -u
dir="${FAKE_SSH_DIR:?}"
if [ "${1:-}" = "-G" ]; then
  printf 'hostname fakehost\nuser %s\nport 22\nidentityfile none\n' "${USER:-acceptance}"
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
  chmod +x "$FAKE_BIN/ssh"
  FAKE_SSH_DIR="$FAKE_ROOT" PATH="$FAKE_BIN:$PATH" \
    MONEXUS_MAX_PARALLEL=2 MONEXUS_RECOVERY_POLL_MS=100 \
    MONEXUS_RECOVERY_UNVERIFIABLE_MS=1200 \
    "$HOST_BIN" serve --state-dir "$FAKE_STATE" --heartbeat-ms 60000 \
    >"$FAKE_STATE/.log" 2>&1 &
  FAKE_PID=$!
  FAKE_HOST_PID=$FAKE_PID
  for _ in $(seq 1 100); do
    "$HOST_BIN" status --state-dir "$FAKE_STATE" >/dev/null 2>&1 && break
    sleep 0.1
  done
  FAKE_ADD="$(PATH="$FAKE_BIN:$PATH" FAKE_SSH_DIR="$FAKE_ROOT" \
    "$HOST_BIN" machine add --state-dir "$FAKE_STATE" --name fake-ssh \
    --host fakehost --user acceptance --use-ssh-config false 2>&1)"
  FAKE_MACHINE="$(printf '%s' "$FAKE_ADD" | sed -n 's/^id=//p' | head -n 1)"
  if [ -n "$FAKE_MACHINE" ]; then
    pass g8 "fake SSH machine registered for the unreachable scenario"
  else
    fail g8 "fake SSH machine registered for the unreachable scenario" "$FAKE_ADD"
  fi
  FAKE_PROBE="$(PATH="$FAKE_BIN:$PATH" FAKE_SSH_DIR="$FAKE_ROOT" \
    "$HOST_BIN" machine probe --state-dir "$FAKE_STATE" --id "$FAKE_MACHINE" \
    --timeout-seconds 10 2>&1)"
  contains g8b "fake SSH machine probes online" "status=online" "$FAKE_PROBE"
  FAKE_WS_OPEN="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method workspace.open \
    --params "$(jq -n --arg m "$FAKE_MACHINE" --arg root "$REPO" '{target:$m,root:$root}')" 2>&1)"
  FAKE_WS="$(printf '%s' "$FAKE_WS_OPEN" | jq -r '.workspace.id // empty')"
  FAKE_TASK="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method task.create \
    --params "$(jq -n --arg ws "$FAKE_WS" '{title:"ssh unreachable",workspace_id:$ws,status:"ready"}')" | jq -r '.task.id // empty')"
  FAKE_RUN="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method run.create \
    --params "$(jq -n --arg tk "$FAKE_TASK" --arg ws "$FAKE_WS" --arg m "$FAKE_MACHINE" \
      '{task_id:$tk,workspace_id:$ws,machine_id:$m,mode:"command",command:"sh -c \"sleep 8; echo never\"",idempotency_key:"m7/fake-ssh"}')" | jq -r '.run.id // empty')"
  FAKE_STATUS=""
  for _ in $(seq 1 100); do
    FAKE_DETAIL0="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method run.get \
      --params "$(jq -n --arg id "$FAKE_RUN" '{run_id:$id}')")"
    FAKE_STATUS="$(printf '%s' "$FAKE_DETAIL0" | jq -r '.run.status // "missing"')"
    FAKE_DURABLE="$(printf '%s' "$FAKE_DETAIL0" | jq -r '.run.durable // ""')"
    # Only cut the transport once the tmux session really exists; otherwise
    # the fault lands in the start path and the run fails for a different
    # reason than the one under test.
    [ "$FAKE_STATUS" = "running" ] && [ "$FAKE_DURABLE" = "tmux" ] && break
    sleep 0.1
  done
  printf 'disconnect\n' >"$FAKE_MODE"
  FAKE_LOST=0
  for _ in $(seq 1 150); do
    FAKE_STATUS="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method run.get \
      --params "$(jq -n --arg id "$FAKE_RUN" '{run_id:$id}')" | jq -r '.run.status // "missing"')"
    [ "$FAKE_STATUS" = "lost" ] && { FAKE_LOST=1; break; }
    sleep 0.1
  done
  if [ "$FAKE_LOST" = "1" ]; then
    pass g9 "unreachable SSH marks the run lost"
  else
    fail g9 "unreachable SSH marks the run lost" "status=$FAKE_STATUS"
  fi
  FAKE_DETAIL="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method run.get \
    --params "$(jq -n --arg id "$FAKE_RUN" '{run_id:$id}')")"
  eq g10 "stop_reason is unverifiable (not silently succeeded)" "unverifiable" "$(printf '%s' "$FAKE_DETAIL" | jq -r '.run.stop_reason')"
  FAKE_DECS="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method decision.list --params '{"status":"pending"}')"
  FAKE_DEC_COUNT="$(printf '%s' "$FAKE_DECS" | jq -r --arg run "$FAKE_RUN" '[.decisions[] | select(.run_id==$run and .kind=="recovery")] | length')"
  eq g11 "recovery Decision is raised for the owner" "1" "$FAKE_DEC_COUNT"
  FAKE_RUNS="$("$HOST_BIN" rpc --state-dir "$FAKE_STATE" --method run.list \
    --params "$(jq -n --arg tk "$FAKE_TASK" '{task_id:$tk}')" | jq -r '.runs | length')"
  eq g12 "unverifiable run is not auto-retried" "1" "$FAKE_RUNS"
  printf 'ok\n' >"$FAKE_MODE"
  kill "$FAKE_PID" 2>/dev/null || true
  wait "$FAKE_PID" 2>/dev/null || true
  FAKE_PID=""
  FAKE_HOST_PID=""
else
  skip g8 "fake SSH machine registered for the unreachable scenario" "tmux missing"
  skip g9 "unreachable SSH marks the run lost" "tmux missing"
  skip g10 "stop_reason is unverifiable (not silently succeeded)" "tmux missing"
  skip g11 "recovery Decision is raised for the owner" "tmux missing"
  skip g12 "unverifiable run is not auto-retried" "tmux missing"
fi

# ---------------------------------------------------------------------------
printf '\n== (h). audit is queryable and secrets stay out of events/logs ==\n'
# ---------------------------------------------------------------------------
SECRET="supersecretvalue-m7-$RANDOM$RANDOM"
export ACCEPTANCE_SECRET="$SECRET"
SECRET_TASK="$(rpc task.create "$(jq -n --arg ws "$WS" '{title:"secret echo",workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
SECRET_RUN="$(rpc run.create "$(jq -n --arg tk "$SECRET_TASK" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sh -c \"echo API_KEY=$ACCEPTANCE_SECRET\"",idempotency_key:"m7/secret"}')" | jq -r '.run.id')"
wait_run "$SECRET_RUN" succeeded 200 && pass h1 "secret-echo run completes" || fail h1 "secret-echo run completes" "$(run_status "$SECRET_RUN")"
SECRET_DETAIL="$(rpc run.get "$(jq -n --arg id "$SECRET_RUN" '{run_id:$id}')")"
ART_ID="$(printf '%s' "$SECRET_DETAIL" | jq -r '.artifacts[0].id // empty')"
ART_TEXT="$(rpc artifact.read "$(jq -n --arg id "$ART_ID" '{artifact_id:$id}')" | jq -r '.text // empty')"
not_contains h2 "artifact output does not leak the secret" "$SECRET" "$ART_TEXT"
contains h3 "artifact output shows the redaction marker" "[redacted]" "$ART_TEXT"

DENY_TASK="$(rpc task.create "$(jq -n --arg ws "$WS" '{title:"deny",workspace_id:$ws,status:"ready"}')" | jq -r '.task.id')"
DENY="$(rpc run.create "$(jq -n --arg tk "$DENY_TASK" --arg ws "$WS" \
  '{task_id:$tk,workspace_id:$ws,mode:"command",command:"sudo echo nope",idempotency_key:"m7/deny"}')")"
contains h4 "policy deny is audited before a run exists" "denied by policy" "$DENY"
AUDIT="$(rpc audit.list '{"limit":500}')"
if [ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select((.action|length)>0 and (.actor|length)>0 and (.subject|length)>0 and (.outcome|length)>0 and (.ts|length)>0)] | length')" -ge 1 ]; then
  pass h5 "audit.list returns records with the required fields"
else
  fail h5 "audit.list returns records with the required fields" "$AUDIT"
fi
if [ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select(.action=="policy.deny" and .outcome=="denied")] | length')" -ge 1 ]; then
  pass h6 "policy deny has an audit record"
else
  fail h6 "policy deny has an audit record" "$AUDIT"
fi
if [ "$(printf '%s' "$AUDIT" | jq '[.audit[] | select(.action=="decision.respond" and (.decision_id|length)>0)] | length')" -ge 1 ]; then
  pass h7 "Decision answers have an audit record"
else
  fail h7 "Decision answers have an audit record" "$AUDIT"
fi
EVENTS_ALL="$(rpc events.list '{"since":0,"limit":3000}')"
not_contains h8 "event stream does not carry the secret" "$SECRET" "$EVENTS_ALL"
TOKEN="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$STATE/host.json" 2>/dev/null | head -n 1)"
if [ -z "$TOKEN" ]; then
  fail h9 "host token is present for the leak check" "no token in host.json"
else
  LEAKED="$(grep -R --binary-files=without-match -Fl -- "$SECRET" \
    "$STATE/logs" "$STATE/runs" "$STATE/agents" 2>/dev/null || true)"
  if [ -z "$LEAKED" ]; then pass h9 "no secret in logs/artifacts/agent files"; else fail h9 "no secret in logs/artifacts/agent files" "$LEAKED"; fi
  TOKEN_LEAK="$(grep -R --binary-files=without-match -Fl -- "$TOKEN" \
    "$STATE/logs" "$STATE/runs" "$STATE/agents" 2>/dev/null || true)"
  if [ -z "$TOKEN_LEAK" ]; then pass h10 "host bearer token never appears in logs"; else fail h10 "host bearer token never appears in logs" "$TOKEN_LEAK"; fi
fi
not_contains h11 "audit stream does not carry the secret" "$SECRET" "$AUDIT"

# ---------------------------------------------------------------------------
printf '\n== stopping hosts ==\n'
if [ -n "$HOST_PID" ]; then kill "$HOST_PID" 2>/dev/null || true; wait "$HOST_PID" 2>/dev/null || true; fi
if [ -n "$SSHD_PID" ]; then kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; SSHD_PID=""; fi

summary
