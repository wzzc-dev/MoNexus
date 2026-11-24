#!/usr/bin/env bash
# MoNexus M3 — workspace / worktree / lease / terminal smoke test.
#
# TEST HARNESS ONLY. The SSH section starts an ephemeral, non-root sshd on a
# random loopback port with a temp HOME and an explicit temp known_hosts file.
# It never writes to the real user's ~/.ssh and snapshots that directory
# before/after to prove it. If sshd is unavailable the SSH section is skipped.
#
# Usage:
#   bash scripts/workspace_smoke.sh
#   HOST_BIN=/path/to/host.exe bash scripts/workspace_smoke.sh
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BIN="${HOST_BIN:-$ROOT/_build/native/debug/build/monexus/host/host.exe}"
REAL_USER="$(id -un)"
REAL_SSH_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)/.ssh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m3-smoke.XXXXXX")"
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

ssh_snapshot() {
  if [ -d "$REAL_SSH_DIR" ]; then
    find "$REAL_SSH_DIR" -maxdepth 1 -type f -printf '%f %s %T@\n' 2>/dev/null | sort
  fi
}
SSH_BEFORE="$(ssh_snapshot)"

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

rpc() { # method params-json [state_dir]
  local state="${3:-$STATE}"
  "$HOST_BIN" rpc --state-dir "$state" --method "$1" --params "$2" 2>&1
}
rpc_code() { # method params-json; sets RPC_OUT
  RPC_OUT="$(rpc "$1" "$2")"
  return $?
}

mkdir -p "$STATE"
printf '== environment ==\n'
"$HOST_BIN" version
printf 'work=%s\n\n' "$WORK"

# ---------------------------------------------------------------------------
printf '== 1. local: open/list/read/write/stat/move/remove/git ==\n'
# ---------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email smoke@example.invalid
git -C "$REPO" config user.name Smoke
printf 'hello m3\n' >"$REPO/README.md"
printf 'second\n' >"$REPO/notes.txt"
git -C "$REPO" add README.md notes.txt
git -C "$REPO" commit -qm 'initial'

if start_host "$STATE"; then pass 'host started on a temp state dir'; else fail 'host started'; fi

OPEN="$(rpc workspace.open "$(jq -n --arg root "$REPO" '{machine_id:"",root:$root}')")"
WS="$(printf '%s' "$OPEN" | jq -r '.workspace.id // empty' 2>/dev/null)"
[ -n "$WS" ] && pass "workspace.open returned $WS" || fail 'workspace.open returned an id' "$OPEN"
eq 'workspace root is the realpath' "$REPO" "$(printf '%s' "$OPEN" | jq -r '.workspace.root')"
eq 'local workspace is git' 'true' "$(printf '%s' "$OPEN" | jq -r '.workspace.is_git')"

LIST="$(rpc workspace.listFiles "$(jq -n --arg id "$WS" '{workspace_id:$id,path:""}')")"
contains 'listFiles includes README.md' 'README.md' "$LIST"
contains 'listFiles includes notes.txt' 'notes.txt' "$LIST"

READ="$(rpc workspace.read "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"README.md"}')")"
eq 'read returns file text' 'hello m3' "$(printf '%s' "$READ" | jq -r '.text')"

WRITE="$(rpc workspace.write "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"README.md",content:"hello m3 updated\n"}')")"
contains 'write acknowledges it' '"ok":true' "$WRITE"
eq 'write is atomic and visible on disk' 'hello m3 updated' "$(cat "$REPO/README.md")"
not_contains 'write left no temp file behind' 'monexus-tmp' "$(ls -a "$REPO")"
eq 'read back after write' 'hello m3 updated' "$(rpc workspace.read "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"README.md"}')" | jq -r '.text')"

STAT="$(rpc workspace.stat "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"README.md"}')")"
eq 'stat kind is file' 'file' "$(printf '%s' "$STAT" | jq -r '.stat.kind')"
eq 'stat size is positive' 'true' "$(printf '%s' "$STAT" | jq -r '.stat.size > 0')"

MOVE="$(rpc workspace.move "$(jq -n --arg id "$WS" '{workspace_id:$id,from:"notes.txt",to:"docs/notes.md"}')")"
contains 'move rejects a missing parent directory' 'NotFound' "$MOVE"
mkdir -p "$REPO/docs"
MOVE="$(rpc workspace.move "$(jq -n --arg id "$WS" '{workspace_id:$id,from:"notes.txt",to:"docs/notes.md"}')")"
contains 'move acknowledges it' '"ok":true' "$MOVE"
[ -f "$REPO/docs/notes.md" ] && pass 'move created the destination' || fail 'move created the destination'
printf 'scratch\n' >"$REPO/scratch.txt"
RPC_OUT="$(rpc workspace.remove "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"scratch.txt"}')")"
contains 'remove acknowledges it' '"ok":true' "$RPC_OUT"
[ ! -e "$REPO/scratch.txt" ] && pass 'remove deleted the file' || fail 'remove deleted the file'
RPC_OUT="$(rpc workspace.read "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"../../../etc/passwd"}')")"
contains 'relative paths cannot escape the root' 'Internal' "$RPC_OUT"

STATUS="$(rpc workspace.gitStatus "$(jq -n --arg id "$WS" '{workspace_id:$id}')")"
contains 'git status reports the branch' '"branch":"master"' "$STATUS"
contains 'git status reports the modified file' 'README.md' "$STATUS"
contains 'git status reports the moved directory' 'docs/' "$STATUS"

DIFF="$(rpc workspace.gitDiff "$(jq -n --arg id "$WS" '{workspace_id:$id,path:"README.md",cached:false,range:""}')")"
contains 'git diff shows the change' 'hello m3 updated' "$DIFF"
contains 'git diff marks truncation false' '"truncated":false' "$DIFF"

# ---------------------------------------------------------------------------
printf '\n== 2. local: two parallel worktrees do not interfere ==\n'
# ---------------------------------------------------------------------------
WT_A_DIR="$WORK/wt-a"
WT_B_DIR="$WORK/wt-b"
WT_A="$(rpc worktree.create "$(jq -n --arg id "$WS" --arg p "$WT_A_DIR" '{workspace_id:$id,branch:"m3-a",path:$p,base:""}')")"
WT_A_ID="$(printf '%s' "$WT_A" | jq -r '.worktree.id // empty')"
WT_B="$(rpc worktree.create "$(jq -n --arg id "$WS" --arg p "$WT_B_DIR" '{workspace_id:$id,branch:"m3-b",path:$p,base:""}')")"
WT_B_ID="$(printf '%s' "$WT_B" | jq -r '.worktree.id // empty')"
[ -n "$WT_A_ID" ] && pass "worktree.create returned $WT_A_ID" || fail 'first worktree created' "$WT_A"
[ -n "$WT_B_ID" ] && pass "worktree.create returned $WT_B_ID" || fail 'second worktree created' "$WT_B"
[ -e "$WT_A_DIR/.git" ] && [ -e "$WT_B_DIR/.git" ] && pass 'both worktree directories are git checkouts' || fail 'both worktree directories'
eq 'worktree branch matches' 'm3-a' "$(git -C "$WT_A_DIR" symbolic-ref --short HEAD)"
eq 'second worktree branch matches' 'm3-b' "$(git -C "$WT_B_DIR" symbolic-ref --short HEAD)"

OPEN_A="$(rpc workspace.open "$(jq -n --arg root "$WT_A_DIR" '{machine_id:"",root:$root}')")"
OPEN_B="$(rpc workspace.open "$(jq -n --arg root "$WT_B_DIR" '{machine_id:"",root:$root}')")"
WSA="$(printf '%s' "$OPEN_A" | jq -r '.workspace.id')"
WSB="$(printf '%s' "$OPEN_B" | jq -r '.workspace.id')"
WRITE_A="$(jq -n --arg id "$WSA" '{workspace_id:$id,path:"a.txt",content:"from-a\n"}')"
WRITE_B="$(jq -n --arg id "$WSB" '{workspace_id:$id,path:"b.txt",content:"from-b\n"}')"
( rpc workspace.write "$WRITE_A" >"$WORK/wa.out" 2>&1 ) &
PA=$!
( rpc workspace.write "$WRITE_B" >"$WORK/wb.out" 2>&1 ) &
PB=$!
wait "$PA" "$PB"
eq 'parallel worktree A write succeeded' 'from-a' "$(cat "$WT_A_DIR/a.txt" 2>/dev/null)"
eq 'parallel worktree B write succeeded' 'from-b' "$(cat "$WT_B_DIR/b.txt" 2>/dev/null)"
[ ! -e "$WT_A_DIR/b.txt" ] && pass 'worktree A did not receive B file' || fail 'worktree A leaked B file'
[ ! -e "$WT_B_DIR/a.txt" ] && pass 'worktree B did not receive A file' || fail 'worktree B leaked A file'
eq 'parent checkout was untouched' 'hello m3 updated' "$(cat "$REPO/README.md")"
A_LIST="$(rpc workspace.listFiles "$(jq -n --arg id "$WSA" '{workspace_id:$id,path:""}')")"
B_LIST="$(rpc workspace.listFiles "$(jq -n --arg id "$WSB" '{workspace_id:$id,path:""}')")"
contains 'worktree A lists its own file' 'a.txt' "$A_LIST"
not_contains 'worktree A does not list B file' 'b.txt' "$A_LIST"
contains 'worktree B lists its own file' 'b.txt' "$B_LIST"
not_contains 'worktree B does not list A file' 'a.txt' "$B_LIST"

# ---------------------------------------------------------------------------
printf '\n== 3. leases: one active run per worktree / non-git workspace ==\n'
# ---------------------------------------------------------------------------
LEASE="$(rpc lease.acquire "$(jq -n --arg id "$WT_A_ID" '{target_kind:"worktree",target_id:$id,holder:"run-1"}')")"
LEASE_ID="$(printf '%s' "$LEASE" | jq -r '.lease.id // empty')"
[ -n "$LEASE_ID" ] && pass "first worktree lease acquired $LEASE_ID" || fail 'first worktree lease acquired' "$LEASE"
RPC_OUT="$(rpc lease.acquire "$(jq -n --arg id "$WT_A_ID" '{target_kind:"worktree",target_id:$id,holder:"run-2"}')")"
RPC_CODE=$?
[ "$RPC_CODE" -ne 0 ] && pass 'second run on the same worktree is refused' || fail 'second run on the same worktree is refused' "$RPC_OUT"
contains 'lease conflict is readable' 'Conflict' "$RPC_OUT"
LEASES="$(rpc lease.list '{}')"
contains 'lease.list shows the active lease' "$LEASE_ID" "$LEASES"
RPC_OUT="$(rpc lease.release "$(jq -n --arg id "$LEASE_ID" '{lease_id:$id}')")"
contains 'lease release acknowledged' '"ok":true' "$RPC_OUT"
LEASE2="$(rpc lease.acquire "$(jq -n --arg id "$WT_A_ID" '{target_kind:"worktree",target_id:$id,holder:"run-2"}')")"
LEASE2_ID="$(printf '%s' "$LEASE2" | jq -r '.lease.id // empty')"
[ -n "$LEASE2_ID" ] && pass 'lease can be re-acquired after release' || fail 'lease re-acquired' "$LEASE2"

PLAIN="$WORK/plain"
mkdir -p "$PLAIN"
printf 'plain\n' >"$PLAIN/file.txt"
OPEN_PLAIN="$(rpc workspace.open "$(jq -n --arg root "$PLAIN" '{machine_id:"",root:$root}')")"
WSP="$(printf '%s' "$OPEN_PLAIN" | jq -r '.workspace.id')"
eq 'non-git workspace reports is_git false' 'false' "$(printf '%s' "$OPEN_PLAIN" | jq -r '.workspace.is_git')"
LEASE3="$(rpc lease.acquire "$(jq -n --arg id "$WSP" '{target_kind:"workspace",target_id:$id,holder:"run-3"}')")"
LEASE3_ID="$(printf '%s' "$LEASE3" | jq -r '.lease.id // empty')"
[ -n "$LEASE3_ID" ] && pass 'non-git workspace exclusive lease acquired' || fail 'non-git lease acquired' "$LEASE3"
RPC_OUT="$(rpc lease.acquire "$(jq -n --arg id "$WSP" '{target_kind:"workspace",target_id:$id,holder:"run-4"}')")"
RPC_CODE=$?
[ "$RPC_CODE" -ne 0 ] && pass 'second run on a non-git workspace is refused' || fail 'second non-git run refused' "$RPC_OUT"
rpc lease.release "$(jq -n --arg id "$LEASE3_ID" '{lease_id:$id}')" >/dev/null
rpc lease.release "$(jq -n --arg id "$LEASE2_ID" '{lease_id:$id}')" >/dev/null

# ---------------------------------------------------------------------------
printf '\n== 4. terminal: local PTY and transcript cursor ==\n'
# ---------------------------------------------------------------------------
TOPEN="$(rpc terminal.open "$(jq -n --arg id "$WS" '{workspace_id:$id,command:"printf m3-local-ok\\n",rows:24,cols:80}')")"
TERM="$(printf '%s' "$TOPEN" | jq -r '.session_id // empty')"
[ -n "$TERM" ] && pass "terminal.open returned $TERM" || fail 'terminal.open returned a session' "$TOPEN"
sleep 1
TREAD="$(rpc terminal.read "$(jq -n --arg id "$TERM" '{session_id:$id,cursor:0}')")"
contains 'local PTY produced command output' 'm3-local-ok' "$TREAD"
CURSOR="$(printf '%s' "$TREAD" | jq -r '.cursor')"
TREAD2="$(rpc terminal.read "$(jq -n --arg id "$TERM" '{session_id:$id,cursor:0}')")"
contains 'terminal.read honours the cursor' 'm3-local-ok' "$TREAD2"
TREAD_EMPTY="$(rpc terminal.read "$(jq -n --arg id "$TERM" --argjson c "$CURSOR" '{session_id:$id,cursor:$c}')")"
eq 'reading at the cursor is incremental' '' "$(printf '%s' "$TREAD_EMPTY" | jq -r '.text')"

# Interactive PTY: write goes to the shell, output comes back.
TOPEN2="$(rpc terminal.open "$(jq -n --arg id "$WS" '{workspace_id:$id,command:"",rows:24,cols:80}')")"
TERM2="$(printf '%s' "$TOPEN2" | jq -r '.session_id')"
rpc terminal.write "$(jq -n --arg id "$TERM2" '{session_id:$id,data:"printf m3-write-ok\\n"}')" >/dev/null
sleep 0.7
TREAD3="$(rpc terminal.read "$(jq -n --arg id "$TERM2" '{session_id:$id,cursor:0}')")"
contains 'terminal.write reaches the shell' 'm3-write-ok' "$TREAD3"
rpc terminal.close "$(jq -n --arg id "$TERM2" '{session_id:$id}')" >/dev/null
RPC_OUT="$(rpc terminal.read "$(jq -n --arg id "$TERM2" '{session_id:$id,cursor:0}')")"
contains 'closed terminal is gone' 'NotFound' "$RPC_OUT"

# ---------------------------------------------------------------------------
printf '\n== 5. bookkeeping survives a host restart ==\n'
# ---------------------------------------------------------------------------
stop_host
if start_host "$STATE"; then pass 'host restarted on the same state dir'; else fail 'host restarted'; fi
WLIST="$(rpc workspace.list '{}')"
contains 'parent workspace survives restart' "$WS" "$WLIST"
contains 'parallel worktree workspaces survive restart' "$WSA" "$WLIST"
contains 'non-git workspace survives restart' "$WSP" "$WLIST"
WTLIST="$(rpc worktree.list "$(jq -n --arg id "$WS" '{workspace_id:$id}')")"
contains 'worktree A survives restart' "$WT_A_ID" "$WTLIST"
contains 'worktree B survives restart' "$WT_B_ID" "$WTLIST"
LEASES="$(rpc lease.list '{}')"
not_contains 'released leases did not come back' "$LEASE_ID" "$LEASES"
EVENTS="$("$HOST_BIN" subscribe --state-dir "$STATE" --since 0 --max-events 400 --timeout-ms 4000 2>&1)"
contains 'event replay includes workspace.opened' 'type=workspace.opened' "$EVENTS"
contains 'event replay includes worktree.created' 'type=worktree.created' "$EVENTS"
contains 'event replay includes worktree.ready' 'type=worktree.ready' "$EVENTS"
contains 'event replay includes lease.acquired' 'type=lease.acquired' "$EVENTS"
contains 'event replay includes lease.released' 'type=lease.released' "$EVENTS"
contains 'event replay includes workspace.changed' 'type=workspace.changed' "$EVENTS"

# close guard: parent cannot close while worktrees are live
RPC_OUT="$(rpc workspace.close "$(jq -n --arg id "$WS" '{workspace_id:$id}')")"
RPC_CODE=$?
[ "$RPC_CODE" -ne 0 ] && pass 'closing a workspace with live worktrees is refused' || fail 'close with live worktrees refused' "$RPC_OUT"
contains 'close conflict is readable' 'Conflict' "$RPC_OUT"
# worktree remove archives and deletes the checkout
RPC_OUT="$(rpc worktree.remove "$(jq -n --arg id "$WT_A_ID" '{worktree_id:$id,force:true}')")"
contains 'worktree.remove A acknowledged' '"ok":true' "$RPC_OUT"
[ ! -e "$WT_A_DIR" ] && pass 'worktree A directory removed' || fail 'worktree A directory removed'
rpc worktree.remove "$(jq -n --arg id "$WT_B_ID" '{worktree_id:$id,force:true}')" >/dev/null
WTLIST="$(rpc worktree.list "$(jq -n --arg id "$WS" '{workspace_id:$id}')")"
eq 'worktree.list is empty after removal' '[]' "$(printf '%s' "$WTLIST" | jq -c '.worktrees')"
RPC_OUT="$(rpc workspace.close "$(jq -n --arg id "$WS" '{workspace_id:$id}')")"
contains 'parent workspace closes after worktrees are archived' '"ok":true' "$RPC_OUT"
WLIST="$(rpc workspace.list '{}')"
not_contains 'closed parent workspace is tombstoned' "$WS" "$WLIST"
contains 'worktree workspaces remain open' "$WSA" "$WLIST"

# ---------------------------------------------------------------------------
printf '\n== 6. loopback SSH: same contract over ssh ==\n'
# ---------------------------------------------------------------------------
SSHD_BIN="$(command -v sshd || true)"
[ -z "$SSHD_BIN" ] && [ -x /usr/sbin/sshd ] && SSHD_BIN=/usr/sbin/sshd
if [ -z "$SSHD_BIN" ] || ! command -v ssh >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
  skip 'ephemeral sshd/ssh/tmux unavailable; SSH contract section skipped'
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

    ROPEN="$(rpc workspace.open "$(jq -n --arg m "$MACHINE_ID" --arg root "$REPO" '{target:$m,root:$root}')")"
    RWS="$(printf '%s' "$ROPEN" | jq -r '.workspace.id // empty')"
    [ -n "$RWS" ] && pass "SSH workspace.open returned $RWS" || fail 'SSH workspace.open returned an id' "$ROPEN"
    eq 'SSH workspace kind is ssh' 'ssh' "$(printf '%s' "$ROPEN" | jq -r '.workspace.kind')"
    eq 'SSH workspace sees the git root' 'true' "$(printf '%s' "$ROPEN" | jq -r '.workspace.is_git')"
    RLIST="$(rpc workspace.listFiles "$(jq -n --arg id "$RWS" '{workspace_id:$id,path:""}')")"
    contains 'SSH listFiles includes README.md' 'README.md' "$RLIST"
    contains 'SSH listFiles includes the moved notes file directory' 'docs' "$RLIST"
    RREAD="$(rpc workspace.read "$(jq -n --arg id "$RWS" '{workspace_id:$id,path:"README.md"}')")"
    eq 'SSH read returns file text' 'hello m3 updated' "$(printf '%s' "$RREAD" | jq -r '.text')"
    RWRITE="$(rpc workspace.write "$(jq -n --arg id "$RWS" '{workspace_id:$id,path:"remote.txt",content:"from-ssh\n"}')")"
    contains 'SSH write acknowledged' '"ok":true' "$RWRITE"
    eq 'SSH write is visible on disk' 'from-ssh' "$(cat "$REPO/remote.txt" 2>/dev/null)"
    not_contains 'SSH write left no temp file behind' 'monexus-tmp' "$(ls -a "$REPO")"
    RSTAT="$(rpc workspace.stat "$(jq -n --arg id "$RWS" '{workspace_id:$id,path:"remote.txt"}')")"
    eq 'SSH stat kind is file' 'file' "$(printf '%s' "$RSTAT" | jq -r '.stat.kind')"
    RSTATUS="$(rpc workspace.gitStatus "$(jq -n --arg id "$RWS" '{workspace_id:$id}')")"
    contains 'SSH git status sees the remote.txt change' 'remote.txt' "$RSTATUS"
    RDIFF="$(rpc workspace.gitDiff "$(jq -n --arg id "$RWS" '{workspace_id:$id,path:"README.md",cached:false,range:""}')")"
    contains 'SSH git diff returns the modified README' 'hello m3 updated' "$RDIFF"

    RTOPEN="$(rpc terminal.open "$(jq -n --arg id "$RWS" '{workspace_id:$id,command:"printf m3-ssh-ok\\n",rows:24,cols:80}')")"
    RTERM="$(printf '%s' "$RTOPEN" | jq -r '.session_id // empty')"
    [ -n "$RTERM" ] && pass "SSH terminal.open returned $RTERM" || fail 'SSH terminal.open returned a session' "$RTOPEN"
    sleep 2
    RTREAD="$(rpc terminal.read "$(jq -n --arg id "$RTERM" '{session_id:$id,cursor:0}')")"
    contains 'SSH terminal (ssh -tt) produced command output' 'm3-ssh-ok' "$RTREAD"
    rpc terminal.close "$(jq -n --arg id "$RTERM" '{session_id:$id}')" >/dev/null
    # Interactive remote terminal: empty command -> ssh -tt + tmux session.
    RTOPEN2="$(rpc terminal.open "$(jq -n --arg id "$RWS" '{workspace_id:$id,command:"",rows:24,cols:80}')")"
    RTERM2="$(printf '%s' "$RTOPEN2" | jq -r '.session_id // empty')"
    [ -n "$RTERM2" ] && pass 'SSH interactive terminal opened a tmux-backed session' || fail 'SSH interactive terminal' "$RTOPEN2"
    sleep 2
    rpc terminal.write "$(jq -n --arg id "$RTERM2" '{session_id:$id,data:"printf m3-ssh-tmux-ok\n"}')" >/dev/null
    sleep 2
    RTREAD2="$(rpc terminal.read "$(jq -n --arg id "$RTERM2" '{session_id:$id,cursor:0}')")"
    contains 'SSH tmux session accepts terminal.write' 'm3-ssh-tmux-ok' "$RTREAD2"
    rpc terminal.write "$(jq -n --arg id "$RTERM2" '{session_id:$id,data:"exit\n"}')" >/dev/null
    sleep 0.5
    rpc terminal.close "$(jq -n --arg id "$RTERM2" '{session_id:$id}')" >/dev/null

    RWT_DIR="$WORK/remote-wt"
    RWT="$(rpc worktree.create "$(jq -n --arg id "$RWS" --arg p "$RWT_DIR" '{workspace_id:$id,branch:"m3-remote",path:$p,base:""}')")"
    RWT_ID="$(printf '%s' "$RWT" | jq -r '.worktree.id // empty')"
    [ -n "$RWT_ID" ] && pass 'SSH worktree.create works over the same contract' || fail 'SSH worktree.create' "$RWT"
    [ -e "$RWT_DIR/.git" ] && pass 'remote worktree checkout exists' || fail 'remote worktree checkout exists'
    rpc worktree.remove "$(jq -n --arg id "$RWT_ID" '{worktree_id:$id,force:true}')" >/dev/null
    RWT_LIST="$(rpc worktree.list "$(jq -n --arg id "$RWS" '{workspace_id:$id}')")"
    eq 'remote worktree archived' '[]' "$(printf '%s' "$RWT_LIST" | jq -c '.worktrees')"
  fi
  kill "$SSHD_PID" 2>/dev/null || true
  wait "$SSHD_PID" 2>/dev/null || true
  SSHD_PID=""
fi

# ---------------------------------------------------------------------------
printf '\n== 7. user ~/.ssh guard ==\n'
# ---------------------------------------------------------------------------
SSH_AFTER="$(ssh_snapshot)"
if [ "$SSH_BEFORE" = "$SSH_AFTER" ]; then pass 'user ~/.ssh was not modified'; else fail 'user ~/.ssh was modified' "$SSH_AFTER"; fi

stop_host
summary
