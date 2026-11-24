#!/usr/bin/env bash
# MoNexus M0 spike — reproducible local check.
#
# TEST HARNESS ONLY. It is not part of the product path. The host, PTY, SSH
# and ACP client are MoonBit; this script uses bash, sshd and (optionally)
# Python for a free port and Node for the mock ACP agent.
#
# Usage:
#   bash spikes/m0/tests/run_all.sh
#   M0_REAL_ACP=1 bash spikes/m0/tests/run_all.sh   # also drive a real ACP agent
set -u -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
HOST="$REPO_ROOT/_build/native/debug/build/services/host/host.exe"
MOCK_AGENT="$TESTS_DIR/mock_acp_agent.mjs"
REAL_AGENT="$REPO_ROOT/spikes/m0/.testdeps/node_modules/.bin/claude-code-acp"

export PATH="$HOME/.moon/bin:$PATH"
# Node is only needed for the mock/real ACP agents; keep it out of the
# product-critical path. Use it when present, otherwise skip the mock test.
if [ -d "$HOME/.nvm/versions/node/v26.13.0/bin" ]; then
  export PATH="$HOME/.nvm/versions/node/v26.13.0/bin:$PATH"
fi

PASSED=0
FAILED=0
SKIPPED=0
SSHD_PID=""
SSH_TMP=""
ACP_WS=""

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s\n' "$1"; }

contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then
    pass "$1"
  else
    fail "$1 (missing: $2)"
    printf '--- output ---\n%s\n--------------\n' "$3" >&2
  fi
}

not_contains() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then
    fail "$1 (unexpected: $2)"
    printf '--- output ---\n%s\n--------------\n' "$3" >&2
  else
    pass "$1"
  fi
}

no_line() { # label exact-line haystack
  if printf '%s\n' "$3" | grep -Fxq -- "$2"; then
    fail "$1 (unexpected line: $2)"
    printf '--- output ---\n%s\n--------------\n' "$3" >&2
  else
    pass "$1"
  fi
}

cleanup() {
  if [ -n "$SSHD_PID" ]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  [ -n "$SSH_TMP" ] && rm -rf "$SSH_TMP"
  [ -n "$ACP_WS" ] && rm -rf "$ACP_WS"
}
trap cleanup EXIT

summary() {
  printf '\nSUMMARY  passed=%d failed=%d skipped=%d\n' \
    "$PASSED" "$FAILED" "$SKIPPED"
  [ "$FAILED" -eq 0 ]
}

if ! command -v moon >/dev/null 2>&1; then
  printf 'moon not found. Add MoonBit to PATH: export PATH="$HOME/.moon/bin:$PATH"\n' >&2
  exit 2
fi

printf '== environment ==\n'
moon version
printf 'repo=%s\n\n' "$REPO_ROOT"

printf '== 1. native host build ==\n'
if (cd "$REPO_ROOT" && moon build --target native); then
  pass 'moon build --target native (first run)'
else
  fail 'moon build --target native (first run)'
  summary
  exit 1
fi
if (cd "$REPO_ROOT" && moon build --target native); then
  pass 'moon build --target native (repeat run)'
else
  fail 'moon build --target native (repeat run)'
fi
if [ -x "$HOST" ]; then
  pass "host binary exists: ${HOST#"$REPO_ROOT"/}"
else
  fail 'host binary exists'
  summary
  exit 1
fi

if (cd "$REPO_ROOT" && moon test --target native >/tmp/m0-moon-test.log 2>&1); then
  pass 'moon test --target native (3 quoting tests)'
else
  fail 'moon test --target native'
  cat /tmp/m0-moon-test.log >&2
fi

out=$("$HOST" version 2>&1); code=$?
if [ "$code" -eq 0 ]; then pass 'host version exit 0'; else fail 'host version exit 0'; fi
contains 'host version string' 'monexus-host 0.0.1-m0' "$out"

printf '\n== 2. local PTY ==\n'
out=$("$HOST" pty-check --shell sh --cmd "printf 'M0_PTY_OK\n'; exit 7" 2>&1); code=$?
if [ "$code" -eq 0 ]; then pass 'pty-check exit 0'; else fail 'pty-check exit 0'; fi
contains 'PTY reports shell' 'M0_PTY_SHELL=sh' "$out"
contains 'PTY reports a pid' 'M0_PTY_PID=' "$out"
contains 'PTY reports exit status 7' 'M0_PTY_EXIT=7' "$out"
contains 'PTY output contains M0_PTY_OK' 'M0_PTY_OK' "$out"

printf '\n== 3. SSH over loopback (ephemeral sshd) ==\n'
if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  fail 'sshd available'
elif ! command -v ssh >/dev/null 2>&1; then
  fail 'ssh client available'
else
  SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
  SSH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/m0-ssh.XXXXXX")"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_TMP/host_ed25519"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_TMP/client_ed25519"
  cp "$SSH_TMP/client_ed25519.pub" "$SSH_TMP/authorized_keys"
  chmod 600 "$SSH_TMP/authorized_keys"
  # Python is test-only here: bind port 0 to let the kernel pick a free port.
  if command -v python3 >/dev/null 2>&1; then
    SSH_PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  else
    SSH_PORT=$((20000 + RANDOM % 20000))
  fi
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
AllowUsers $(id -un)
LogLevel ERROR
EOF
  "$SSHD_BIN" -D -f "$SSH_TMP/sshd_config" -E "$SSH_TMP/sshd.log" &
  SSHD_PID=$!
  ready=0
  for _ in $(seq 1 100); do
    if kill -0 "$SSHD_PID" 2>/dev/null &&
       ss -ltn 2>/dev/null | grep -Fq "127.0.0.1:$SSH_PORT"; then
      ready=1
      break
    fi
    sleep 0.1
  done
  if [ "$ready" -eq 1 ]; then
    pass "ephemeral sshd listening on 127.0.0.1:$SSH_PORT"
  else
    fail 'ephemeral sshd listening'
    printf '%s\n' '--- sshd log ---' >&2
    cat "$SSH_TMP/sshd.log" >&2 || true
  fi

  if [ "$ready" -eq 1 ]; then
    SSH_FLAGS=(
      --ssh-host 127.0.0.1
      --ssh-port "$SSH_PORT"
      --identity "$SSH_TMP/client_ed25519"
      --known-hosts "$SSH_TMP/known_hosts"
      --strict accept-new
      --timeout 10
    )

    out=$("$HOST" ssh-probe "${SSH_FLAGS[@]}" 2>&1); code=$?
    if [ "$code" -eq 0 ]; then pass 'ssh-probe exit 0'; else fail 'ssh-probe exit 0'; fi
    contains 'ssh-probe marker' 'M0_SSH_PROBE_OK' "$out"
    contains 'ssh-probe os=Linux' 'os=Linux' "$out"
    contains 'ssh-probe arch=x86_64' 'arch=x86_64' "$out"
    contains 'ssh-probe found git' 'tool.git=' "$out"
    not_contains 'ssh-probe git is not missing' 'tool.git=<missing>' "$out"
    contains 'ssh-probe kernel line' 'kernel=' "$out"

    out=$("$HOST" ssh-run "${SSH_FLAGS[@]}" --cwd /tmp -- \
      sh -c 'printf "REMOTE_OK=%s\n" "$(hostname)"; exit 3' 2>&1); code=$?
    if [ "$code" -eq 3 ]; then pass 'ssh-run propagates remote exit 3'; else fail 'ssh-run propagates remote exit 3'; fi
    contains 'ssh-run remote stdout' 'REMOTE_OK=' "$out"
    contains 'ssh-run framed exit' 'M0_SSH_RUN_EXIT=3' "$out"

    out=$("$HOST" ssh-run "${SSH_FLAGS[@]}" --cwd /tmp -- \
      printf '%s\n' 'a b; echo INJECTED' '$(echo SUBST)' "it's" '--not-a-flag' 2>&1); code=$?
    if [ "$code" -eq 0 ]; then pass 'ssh-run injection probe exit 0'; else fail 'ssh-run injection probe exit 0'; fi
    contains 'argv with spaces stays one argument' 'a b; echo INJECTED' "$out"
    contains 'argv command substitution stays literal' '$(echo SUBST)' "$out"
    contains 'argv single quote stays literal' "it's" "$out"
    contains 'argv flag-like value stays literal' '--not-a-flag' "$out"
    no_line 'no INJECTED execution' 'INJECTED' "$out"
    no_line 'no command substitution execution' 'SUBST' "$out"
  fi
fi

printf '\n== 4. ACP over stdio ==\n'
if ! command -v node >/dev/null 2>&1; then
  skip 'mock ACP agent (node not on PATH; test-only dependency)'
else
  ACP_WS="$(mktemp -d "${TMPDIR:-/tmp}/m0-acp-ws.XXXXXX")"
  out=$("$HOST" acp --command "$(command -v node)" --arg "$MOCK_AGENT" \
    --workspace "$ACP_WS" --cwd "$ACP_WS" --prompt 'say hi' --timeout 30 2>&1); code=$?
  if [ "$code" -eq 0 ]; then pass 'mock ACP prompt exit 0'; else fail 'mock ACP prompt exit 0'; fi
  contains 'mock ACP session id' 'M0_ACP_SESSION_ID=mock-session-1' "$out"
  contains 'mock ACP agent name' 'M0_ACP_AGENT=mock-acp-agent' "$out"
  contains 'mock ACP streamed 5 chunks' 'M0_ACP_CHUNKS=5' "$out"
  contains 'mock ACP streamed 5 updates' 'M0_ACP_UPDATES=5' "$out"
  contains 'mock ACP text' 'M0_ACP_TEXT=MOCK: hello from ACP #1' "$out"
  contains 'mock ACP end_turn' 'M0_ACP_DONE stop_reason=end_turn' "$out"

  out=$("$HOST" acp --command "$(command -v node)" --arg "$MOCK_AGENT" \
    --workspace "$ACP_WS" --cwd "$ACP_WS" --prompt 'need permission' --timeout 30 2>&1); code=$?
  if [ "$code" -eq 0 ]; then pass 'mock ACP permission prompt exit 0'; else fail 'mock ACP permission prompt exit 0'; fi
  contains 'mock ACP saw 1 permission request' 'M0_ACP_PERMISSION_REQUESTS=1' "$out"
  contains 'mock ACP permission path still ends' 'M0_ACP_DONE stop_reason=end_turn' "$out"

  if [ "${M0_REAL_ACP:-0}" = "1" ]; then
    if [ -x "$REAL_AGENT" ]; then
      # claude-code-acp refuses to start inside another Claude Code session;
      # unset CLAUDECODE for this child process. Authentication comes from the
      # caller's environment, same as Claude Code itself. This test uses the
      # network and the caller's model credentials — opt-in only.
      out=$(timeout 200 env -u CLAUDECODE "$HOST" acp --command "$REAL_AGENT" \
        --workspace "$ACP_WS" --cwd "$ACP_WS" \
        --prompt 'Reply with exactly M0_ACP_REAL_OK and nothing else.' \
        --timeout 170 2>&1); code=$?
      if [ "$code" -eq 0 ]; then pass 'real ACP agent (claude-code-acp) exit 0'; else fail 'real ACP agent (claude-code-acp) exit 0'; fi
      contains 'real ACP agent end_turn' 'M0_ACP_DONE stop_reason=end_turn' "$out"
      contains 'real ACP agent streamed chunks' 'M0_ACP_CHUNKS=' "$out"
      contains 'real ACP agent name' 'M0_ACP_AGENT=@zed-industries/claude-code-acp' "$out"
    else
      skip 'real ACP agent (spikes/m0/.testdeps not installed)'
    fi
  else
    skip 'real ACP agent (set M0_REAL_ACP=1 to run; needs model credentials)'
  fi
fi

summary
