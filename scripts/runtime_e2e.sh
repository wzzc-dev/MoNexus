#!/usr/bin/env bash
# MoNexus A1 paired-remote-runtime acceptance (A1.5).
#
# Exercises the production path end to end: a primary `monexus-host serve`
# with a pinned-TLS runtime listener, a separate node `monexus-host runtime
# serve` that only dials out, the real `@policy.evaluate` gate and the
# Decision/approval handshake. No test-only bypass is used.
#
# Isolation: the primary and the node each get a throwaway HOME, state
# directory, workspace and process. They share one Linux namespace because
# the harness must also run unprivileged in CI; kernel namespaces and a second
# host are not claimed. The node exposes no listening socket (checked when
# `ss` is available) and is never given an inbound address.
#
# What is covered:
#   A. pairing/security vectors (wrong, expired, replayed, rotated, plaintext,
#      pin/certificate change) with audit and no plaintext secret in logs;
#   B. exec streams/exit/timeout/run_id, argv[0] read-only bypass, fs and
#      workspace/symlink-escape refusal, PTY, git, an ACP session over
#      runtime.process, and a local machine coexisting with the runtime
#      machine;
#   C. node loss mid-run (interrupted/lost, never success), restart recovery,
#      reconnect/catch-up without duplicate execution, primary restart;
#   D. revoke and drain; a revoked machine cannot be probed;
#   E. real ACP model turn only when explicitly opted in and actually present.
#
# Requirements: bash, jq, python3, openssl, git, node. `ss` is used for the
# no-inbound-port check and that row is SKIPped when it is unavailable.
#
# Usage:
#   scripts/runtime_e2e.sh
#   M4_REAL_ACP=1 scripts/runtime_e2e.sh   # also attempt a real model turn
#   RUNTIME_E2E_KEEP=1 scripts/runtime_e2e.sh
#
# Exit code is non-zero when any row FAILs. A failing run keeps its work
# directory and prints it; a passing run removes it.
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME:?HOME is required to run the build toolchain}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-runtime-e2e.XXXXXX")"
export HOME="$WORK/home"
WS="$WORK/ws"
mkdir -p "$HOME" "$WORK/primary-home" "$WORK/node-home" "$WS" "$WORK/pki"

HOST_BIN="$(find "$ROOT/_build/native" -type f -path '*/build/monexus/host/host.exe' 2>/dev/null | head -n 1)"
if [ -z "$HOST_BIN" ]; then
  if command -v moon >/dev/null 2>&1; then
    packages="$(bash "$ROOT/scripts/native_packages.sh")" || exit 1
    ( cd "$ROOT" && moon build --target native $packages >/dev/null ) || exit 1
  fi
  HOST_BIN="$(find "$ROOT/_build/native" -type f -path '*/build/monexus/host/host.exe' 2>/dev/null | head -n 1)"
fi
if [ -z "$HOST_BIN" ] || [ ! -x "$HOST_BIN" ]; then
  printf 'FAIL  P0  monexus-host binary is not built\n' >&2
  exit 1
fi

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  for candidate in "$REAL_HOME"/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ]; then NODE_BIN="$candidate"; break; fi
  done
fi
if [ -n "$NODE_BIN" ]; then
  export PATH="$(dirname "$NODE_BIN"):$PATH"
fi

RESULTS="$WORK/results.txt"
: >"$RESULTS"
PIDS=()
LAST_PID=""
NODE_PID=""
PRIMARY_PID=""
FAILS=0
CODES=()
RPC_TAG="$$-$RANDOM"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$RESULTS"; }
pass() { record "$1" "$2" PASS "${3:-}"; printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() {
  FAILS=$((FAILS + 1))
  record "$1" "$2" FAIL "${3:-}"
  printf 'FAIL  %-3s %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then printf '      %s\n' "$3" >&2; fi
}
skip() { record "$1" "$2" SKIP "${3:-}"; printf 'SKIP  %-3s %s (%s)\n' "$1" "$2" "${3:-}"; }
eq() { # id item expected actual
  if [ "$3" = "$4" ]; then pass "$1" "$2"; else fail "$1" "$2" "expected: $3 got: $4"; fi
}
contains() { # id item needle haystack
  if printf '%s' "$4" | grep -Fq -- "$3"; then pass "$1" "$2"; else fail "$1" "$2" "missing: $3"; fi
}
not_contains() { # id item needle haystack
  if printf '%s' "$4" | grep -Fq -- "$3"; then fail "$1" "$2" "unexpected: $3"; else pass "$1" "$2"; fi
}

stop_pid() {
  local pid="$1" i=0
  [ -z "$pid" ] && return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Wait for a background child to exit and record its status in WAIT_RC.
# Returns 0 when it exited on its own, 1 when the timeout killed it.
WAIT_RC=0
wait_exit() { # pid timeout_tenths
  local pid="$1" timeout="${2:-100}" i=0
  while [ "$i" -lt "$timeout" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      WAIT_RC=$?
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  WAIT_RC=124
  return 1
}

# Read a file mode portably: GNU stat on Linux, BSD stat on macOS.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo '?'
}

cleanup() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    stop_pid "$pid"
  done
  if [ "$FAILS" -gt 0 ] || [ "${RUNTIME_E2E_KEEP:-0}" = "1" ]; then
    printf '\nwork directory kept: %s\n' "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

rpc_at() { # state_dir method params
  "$HOST_BIN" rpc --state-dir "$1" --method "$2" --params "$3" 2>&1
}
rpc_main() { rpc_at "$MAIN_STATE" "$1" "$2"; }

# JSON-RPC calls with a pinned id, which is also the idempotency key. The CLI
# derives client_request_id from a fresh request id, so it cannot replay a
# settled request; these helpers can. `rpc_json` prints the result object (or
# the raw transport/error text) and returns the client's exit status. The host
# answers a cache hit with the *original* response frame (including its id), so
# every unpinned call needs an id that cannot repeat; ids are random, not
# counters, because callers capture results in command-substitution subshells.
rpc_json() { # state_dir id method params
  local out rc
  out="$("$NODE_BIN" "$ROOT/tests/runtime/rpc_client.mjs" call "$1" "$2" "$3" "$4" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | jq -c '.result'
    return 0
  fi
  printf '%s' "$out"
  return "$rc"
}
rpc_q() { # state_dir method params — unique id and client_request_id
  local id params
  # Callers capture the result in command substitution, so a shell counter
  # would not survive; draw 64 random bits instead.
  id="e2e-$RPC_TAG-$(od -An -N8 -tu8 /dev/urandom | tr -d ' \n')"
  params="$(printf '%s' "$3" | jq -c --arg c "$id" \
    '. + (if has("client_request_id") then {} else {client_request_id:$c} end)')"
  rpc_json "$1" "$id" "$2" "$params"
}
fill_cache() { # state_dir count
  "$NODE_BIN" "$ROOT/tests/runtime/rpc_client.mjs" fill "$1" "$2" "fill-$RPC_TAG-$RANDOM" >/dev/null 2>&1
}
jqr() { jq -r "$1" 2>/dev/null; }

wait_host_json() { # state_dir pid timeout_tenths
  local sd="$1" pid="$2" timeout="${3:-150}" i=0
  while [ "$i" -lt "$timeout" ]; do
    [ -f "$sd/host.json" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_primary() { # name state_dir addr cert key policy ttl_ms wait_ms
  local name="$1" sd="$2" addr="$3" cert="$4" key="$5" policy="$6" ttl="$7" wait="$8"
  mkdir -p "$sd"
  rm -f "$sd/host.json"
  local args=(
    serve --state-dir "$sd" --heartbeat-ms 200
    --runtime-listen "$addr" --runtime-cert "$cert" --runtime-key "$key"
    --runtime-state-dir "$sd/rt" --runtime-wait-ms "$wait"
    --runtime-approval-ttl-ms "$ttl"
  )
  if [ -n "$policy" ]; then
    args+=(--runtime-policy "$policy" --runtime-workspace-root "$WS")
  fi
  HOME="$WORK/primary-home" "$HOST_BIN" "${args[@]}" >"$WORK/$name.log" 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
  if ! wait_host_json "$sd" "$LAST_PID" 150; then
    printf 'primary %s did not come up:\n' "$name" >&2
    tail -n 20 "$WORK/$name.log" >&2
    return 1
  fi
  return 0
}

free_port() {
  python3 -I -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null ||
    echo $((20000 + RANDOM % 20000))
}

main_addr() { printf '127.0.0.1:%s' "$1"; }

pin_of() { openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.*= //'; }

make_leaf() { # name ca_pem ca_key out_dir
  local name="$1" ca="$2" cakey="$3" dir="$4"
  openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$dir/$name.key" \
    -out "$dir/$name.csr" -subj "/CN=localhost" 2>/dev/null
  cat >"$dir/$name.ext" <<EXT
subjectAltName=IP:127.0.0.1,DNS:localhost
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
  openssl x509 -req -sha256 -days 2 -in "$dir/$name.csr" -CA "$ca" \
    -CAkey "$cakey" -CAcreateserial -out "$dir/$name.pem" \
    -extfile "$dir/$name.ext" 2>/dev/null
}

make_policy() { # path ttl_ms version
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib, json, sys, time
path, ttl_text, version = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time() * 1000)
ttl = int(ttl_text)
rules = {
    "allow_read_only": True,
    "allowed_argv_prefixes": ["sleep"],
    # `exec` is deliberately absent: low-risk read-only commands are allowed
    # by `allow_read_only`, while an unknown command (including a
    # path-qualified argv[0]) must surface as an owner Decision.
    "allowed_operations": ["control", "fs.read", "fs.write", "git.read", "pty"],
    "denied_operations": [],
    "denied_patterns": [],
    "env_allowlist": ["HOME", "PATH", "LANG"],
    "high_risk_operations": [],
    "high_risk_patterns": [],
}

def arr(values):
    # MoonBit's Array[String].sort() orders by length first, then text.
    return "[" + ",".join(json.dumps(x) for x in sorted(set(values), key=lambda s: (len(s), s))) + "]"

rules_canonical = (
    '{"allow_read_only":' + ("true" if rules["allow_read_only"] else "false") + ","
    '"allowed_argv_prefixes":' + arr(rules["allowed_argv_prefixes"]) + ","
    '"allowed_operations":' + arr(rules["allowed_operations"]) + ","
    '"denied_operations":' + arr(rules["denied_operations"]) + ","
    '"denied_patterns":' + arr(rules["denied_patterns"]) + ","
    '"env_allowlist":' + arr(rules["env_allowlist"]) + ","
    '"high_risk_operations":' + arr(rules["high_risk_operations"]) + ","
    '"high_risk_patterns":' + arr(rules["high_risk_patterns"]) + "}"
)
issued = now if ttl > 0 else now - 3_600_000
expires = now + ttl
body = (
    "monexus.policy.snapshot.v1\n{" +
    '"expires_at_ms":' + str(expires) + "," +
    '"format":"monexus.policy.snapshot",' +
    '"format_version":1,' +
    '"issued_at_ms":' + str(issued) + "," +
    '"rules":' + rules_canonical + "," +
    '"version":' + json.dumps(version) + "}"
)
digest = hashlib.sha256(body.encode()).hexdigest()
doc = {
    "expires_at_ms": expires,
    "format": "monexus.policy.snapshot",
    "format_version": 1,
    "hash": digest,
    "issued_at_ms": issued,
    "rules": rules,
    "version": version,
}
with open(path, "w") as handle:
    handle.write(json.dumps(doc, separators=(",", ":")))
print(digest)
PY
}

node_pair() { # home state_base runtime_id addr ca pin code
  HOME="$1" "$HOST_BIN" runtime pair --runtime-id "$3" --primary "$4" \
    --ca "$5" --pin "$6" --code "$7" --state-base "$2" 2>&1
}

node_serve() { # home state_base runtime_id addr ca pin log [extra flags...]
  local home="$1" base="$2" rid="$3" addr="$4" ca="$5" pin="$6" log="$7"
  shift 7
  HOME="$home" "$HOST_BIN" runtime serve --runtime-id "$rid" --primary "$addr" \
    --ca "$ca" --pin "$pin" --state-base "$base" --heartbeat-ms 300 \
    --backoff-ms 300 "$@" >"$log" 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
}

new_code() { # state_dir
  local out code
  out="$(rpc_at "$1" runtime.pairing.create '{}')" || { printf '%s' "$out"; return 1; }
  code="$(printf '%s' "$out" | jq -r '.code // empty')"
  if [ -z "$code" ]; then printf '%s' "$out"; return 1; fi
  CODES+=("$code")
  printf '%s' "$code"
}

machine_add() { # state_dir kind host name
  "$HOST_BIN" machine add --state-dir "$1" --kind "$2" --host "$3" --name "$4" 2>&1
}

machine_id_from() { printf '%s\n' "$1" | sed -n 's/^id=//p' | head -n 1; }

wait_attached() { # state_dir machine_id timeout_tenths
  local sd="$1" mid="$2" timeout="${3:-200}" i=0 out
  while [ "$i" -lt "$timeout" ]; do
    out="$(rpc_at "$sd" runtime.status '{}')"
    if printf '%s' "$out" | jq -e --arg m "$mid" \
      '.attached[]? | select(.machine_id == $m and .connected == true)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_policy_acked() { # state_dir timeout_tenths
  local sd="$1" timeout="${2:-200}" i=0 out count
  while [ "$i" -lt "$timeout" ]; do
    out="$(rpc_at "$sd" runtime.status '{}')"
    count="$(printf '%s' "$out" | jq -r '.installed_policies // 0' 2>/dev/null)"
    if [ -n "$count" ] && [ "$count" -ge 1 ] 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_probe_online() { # state_dir machine_id timeout_tenths
  local sd="$1" mid="$2" timeout="${3:-200}" i=0 out=""
  while [ "$i" -lt "$timeout" ]; do
    out="$(rpc_q "$sd" machine.probe "$(jq -n --arg m "$mid" '{machine_id:$m}')")"
    if printf '%s' "$out" | jq -e '.machine.status == "online"' >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$out"
  return 1
}

pending_decision() { # state_dir run_id [action]
  local sd="$1" run="$2" action="${3:-}" out
  out="$(rpc_q "$sd" decision.list '{}')" || return 1
  printf '%s' "$out" | jq -r --arg r "$run" --arg a "$action" '
    (.decisions // .) | .[]?
    | select(.status == "pending" and ($r == "" or .run_id == $r) and ($a == "" or .action == $a))
    | .id' 2>/dev/null | head -n 1
}

wait_decision() { # state_dir run_id action timeout_tenths
  local sd="$1" run="$2" action="$3" timeout="${4:-100}" i=0 dec=""
  while [ "$i" -lt "$timeout" ]; do
    dec="$(pending_decision "$sd" "$run" "$action")"
    if [ -n "$dec" ]; then printf '%s' "$dec"; return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

decision_json() { # state_dir decision_id
  rpc_q "$1" decision.list '{}' | jq -r --arg id "$2" \
    '(.decisions // .) | .[]? | select(.id == $id)' 2>/dev/null
}

respond_decision() { # state_dir decision_id option
  rpc_q "$1" decision.respond \
    "$(jq -n --arg id "$2" --arg opt "$3" '{decision_id:$id,option_id:$opt}')"
}

# ---------------------------------------------------------------------------
# Preflight and PKI
# ---------------------------------------------------------------------------
printf '\n== preflight ==\n'
printf 'host=%s\nwork=%s\nnode=%s\n' "$HOST_BIN" "$WORK" "${NODE_BIN:-missing}"

if [ -n "$NODE_BIN" ]; then
  pass P0 "node is available for pinned-id replays and the ACP rows" "$NODE_BIN"
else
  fail P0 "node is available for pinned-id replays and the ACP rows" "node missing"
fi

for tool in jq python3 openssl git; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass P1 "tool available: $tool"
  else
    fail P1 "tool available: $tool" "missing"
  fi
done
if [ "$FAILS" -gt 0 ]; then
  printf '\nSUMMARY: missing required tools\n' >&2
  exit 1
fi

PKI="$WORK/pki"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -keyout "$PKI/ca.key" -out "$PKI/ca.pem" \
  -subj '/CN=MoNexus Harness CA' \
  -addext 'basicConstraints=critical,CA:TRUE' 2>/dev/null
make_leaf leaf1 "$PKI/ca.pem" "$PKI/ca.key" "$PKI"
make_leaf leaf2 "$PKI/ca.pem" "$PKI/ca.key" "$PKI"
chmod 600 "$PKI/ca.pem" "$PKI/ca.key" "$PKI/leaf1.pem" "$PKI/leaf1.key" "$PKI/leaf2.pem" "$PKI/leaf2.key"
PIN1="$(pin_of "$PKI/leaf1.pem")"
PIN2="$(pin_of "$PKI/leaf2.pem")"
if [ -n "$PIN1" ] && [ -n "$PIN2" ] && [ "$PIN1" != "$PIN2" ]; then
  pass P2 "two distinct leaf certificates generated" "pin1=${PIN1:0:16}... pin2=${PIN2:0:16}..."
else
  fail P2 "two distinct leaf certificates generated" "pins are empty or equal"
  exit 1
fi

# ---------------------------------------------------------------------------
# A. Pairing and transport security vectors
# ---------------------------------------------------------------------------
printf '\n== (a). pairing and transport security vectors ==\n'

# A1: a wrong code is rejected uniformly and audited; nothing is enrolled.
A1_STATE="$WORK/a1-state"
A1_ADDR="$(main_addr "$(free_port)")"
if start_primary a1 "$A1_STATE" "$A1_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "" 8000 12000; then
  A1_PID="$LAST_PID"
  A1_CODE="$(new_code "$A1_STATE")" || A1_CODE=""
  if [ -z "$A1_CODE" ]; then
    fail A1 "wrong pairing code is rejected" "could not issue a code"
  else
    A1_TRY="$(node_pair "$WORK/node-home" "$WORK/a1-node" rt-wrong "$A1_ADDR" "$PKI/ca.pem" "$PIN1" "00000000000000000000000000000000")"
    A1_RC=$?
    if [ "$A1_RC" -ne 0 ] && [ ! -f "$WORK/a1-node/rt-wrong/token" ]; then
      pass A1 "wrong pairing code is rejected ($A1_RC)"
    else
      fail A1 "wrong pairing code is rejected" "rc=$A1_RC token=$([ -f "$WORK/a1-node/rt-wrong/token" ] && echo yes || echo no) out=$A1_TRY"
    fi
    A1_AUDIT="$(rpc_at "$A1_STATE" runtime.audit '{}' | jq -r '.audit_text // ""')"
    contains A2 "wrong-code audit names the rejection" "runtime.pairing_rejected" "$A1_AUDIT"
    contains A3 "wrong-code audit reason=unknown_code" "reason=unknown_code" "$A1_AUDIT"
    A1_STATUS="$(rpc_at "$A1_STATE" runtime.status '{}')"
    eq A4 "wrong code enrolls no credential" "0" "$(printf '%s' "$A1_STATUS" | jq -r '.credentials')"
    not_contains A5 "pairing code never appears in the primary audit" "$A1_CODE" "$A1_AUDIT"
    not_contains A6 "pairing code never appears in the primary log" "$A1_CODE" "$(cat "$WORK/a1.log" 2>/dev/null)"
    not_contains A7 "pairing output never echoes the code" "$A1_CODE" "$A1_TRY"
  fi

  # A8: plaintext bytes on the TLS port are not answered and enroll nothing.
  A8_OUT="$(python3 -I - "$A1_ADDR" <<'PY'
import json, socket, struct, sys
host, port = sys.argv[1].rsplit(":", 1)
payload = json.dumps({"jsonrpc": "2.0", "id": "plain", "method": "runtime.pair",
                      "params": {"code": "00" * 16, "runtime_id": "rt-plain"}}).encode()
frame = struct.pack(">I", len(payload)) + payload
s = socket.socket()
s.settimeout(2.0)
try:
    s.connect((host, int(port)))
    s.sendall(frame)
    s.settimeout(1.0)
    data = s.recv(4096)
    print("BYTES=%d" % len(data))
except (ConnectionResetError, BrokenPipeError, socket.timeout, OSError) as exc:
    print("CLOSED=%s" % type(exc).__name__)
finally:
    s.close()
PY
)"
  if printf '%s' "$A8_OUT" | grep -Eq '^(BYTES=0|CLOSED=)'; then
    pass A8 "plaintext attempt is refused, not answered"
  else
    fail A8 "plaintext attempt is refused, not answered" "$A8_OUT"
  fi
  A8_STATUS="$(rpc_at "$A1_STATE" runtime.status '{}')"
  eq A9 "plaintext attempt enrolls nothing" "0" "$(printf '%s' "$A8_STATUS" | jq -r '.credentials')"

  # A10/A11: a different certificate's pin is refused before any enrollment.
  A10_TRY="$(node_pair "$WORK/node-home" "$WORK/a1-node" rt-pin-wrong "$A1_ADDR" "$PKI/ca.pem" "$PIN2" "11111111111111111111111111111111")"
  A10_RC=$?
  A10_STATUS="$(rpc_at "$A1_STATE" runtime.status '{}')"
  if [ "$A10_RC" -ne 0 ] && [ "$(printf '%s' "$A10_STATUS" | jq -r '.credentials')" = "0" ]; then
    pass A10 "a changed certificate fingerprint (pin mismatch) is refused"
  else
    fail A10 "a changed certificate fingerprint (pin mismatch) is refused" "rc=$A10_RC out=$A10_TRY"
  fi
  contains A11 "pin mismatch is reported to the operator" "pin" "$(printf '%s' "$A10_TRY" | tr 'A-Z' 'a-z')"
  stop_pid "$A1_PID"
fi

# A12: an expired pairing code is rejected; the entry is pruned and the
# uniform wire answer is the same as an unknown code. The harness moves the
# persisted expiry backwards so it does not wait ten minutes.
A12_STATE="$WORK/a12-state"
A12_ADDR="$(main_addr "$(free_port)")"
if start_primary a12 "$A12_STATE" "$A12_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "" 8000 12000; then
  A12_PID="$LAST_PID"
  A12_CODE="$(new_code "$A12_STATE")" || A12_CODE=""
  if [ -z "$A12_CODE" ]; then
    fail A12 "expired pairing code is rejected" "could not issue a code"
  else
    stop_pid "$A12_PID"
    python3 -I - "$A12_STATE/rt/transport-state.json" <<'PY'
import json, sys, time
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
past = int(time.time() * 1000) - 5_000
for record in doc.get("pairings", []):
    record["expires_at_ms"] = past
with open(path, "w") as handle:
    json.dump(doc, handle, separators=(",", ":"))
PY
    chmod 600 "$A12_STATE/rt/transport-state.json"
    if start_primary a12b "$A12_STATE" "$A12_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "" 8000 12000; then
      A12_PID="$LAST_PID"
      A12_TRY="$(node_pair "$WORK/node-home" "$WORK/a12-node" rt-expired "$A12_ADDR" "$PKI/ca.pem" "$PIN1" "$A12_CODE")"
      A12_RC=$?
      if [ "$A12_RC" -ne 0 ] && [ ! -f "$WORK/a12-node/rt-expired/token" ]; then
        pass A12 "expired pairing code is rejected (uniform answer)"
      else
        fail A12 "expired pairing code is rejected (uniform answer)" "rc=$A12_RC out=$A12_TRY"
      fi
      A12_AUDIT="$(rpc_at "$A12_STATE" runtime.audit '{}' | jq -r '.audit_text // ""')"
      contains A13 "expired-code attempt is audited" "runtime.pairing_rejected" "$A12_AUDIT"
      eq A14 "expired code enrolls no credential" "0" \
        "$(rpc_at "$A12_STATE" runtime.status '{}' | jq -r '.credentials')"
      stop_pid "$A12_PID"
    fi
  fi
fi

# A15: replay of a consumed code is rejected and audited as used_code.
A15_STATE="$WORK/a15-state"
A15_ADDR="$(main_addr "$(free_port)")"
if start_primary a15 "$A15_STATE" "$A15_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "" 8000 12000; then
  A15_PID="$LAST_PID"
  A15_CODE="$(new_code "$A15_STATE")" || A15_CODE=""
  A15_FIRST="$(node_pair "$WORK/node-home" "$WORK/a15-node" rt-replay "$A15_ADDR" "$PKI/ca.pem" "$PIN1" "$A15_CODE")"
  A15_FIRST_RC=$?
  A15_REPLAY="$(node_pair "$WORK/node-home" "$WORK/a15-node" rt-replay "$A15_ADDR" "$PKI/ca.pem" "$PIN1" "$A15_CODE")"
  A15_REPLAY_RC=$?
  if [ "$A15_FIRST_RC" -eq 0 ] && [ "$A15_REPLAY_RC" -ne 0 ]; then
    pass A15 "replayed pairing code is rejected"
  else
    fail A15 "replayed pairing code is rejected" "first=$A15_FIRST_RC replay=$A15_REPLAY_RC replay_out=$A15_REPLAY"
  fi
  A15_AUDIT="$(rpc_at "$A15_STATE" runtime.audit '{}' | jq -r '.audit_text // ""')"
  contains A16 "replay audit reason=used_code" "reason=used_code" "$A15_AUDIT"
  eq A17 "replay keeps exactly one enrollment" "1" \
    "$(rpc_at "$A15_STATE" runtime.status '{}' | jq -r '.credentials')"
  stop_pid "$A15_PID"
fi

# A18: pairing the same runtime id again rotates the credential: the old
# bearer token is unauthorized and the new one works. Old and new never
# coexist.
A18_STATE="$WORK/a18-state"
A18_ADDR="$(main_addr "$(free_port)")"
if start_primary a18 "$A18_STATE" "$A18_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "" 8000 12000; then
  A18_PID="$LAST_PID"
  A18_C1="$(new_code "$A18_STATE")" || A18_C1=""
  A18_FIRST="$(node_pair "$WORK/node-home" "$WORK/a18-node" rt-dup "$A18_ADDR" "$PKI/ca.pem" "$PIN1" "$A18_C1")"
  A18_FIRST_RC=$?
  cp "$WORK/a18-node/rt-dup/token" "$WORK/a18-old-token" 2>/dev/null
  A18_C2="$(new_code "$A18_STATE")" || A18_C2=""
  A18_SECOND="$(node_pair "$WORK/node-home" "$WORK/a18-node" rt-dup "$A18_ADDR" "$PKI/ca.pem" "$PIN1" "$A18_C2")"
  A18_SECOND_RC=$?
  if [ "$A18_FIRST_RC" -eq 0 ] && [ "$A18_SECOND_RC" -eq 0 ] \
    && [ -f "$WORK/a18-old-token" ] && [ -f "$WORK/a18-node/rt-dup/token" ] \
    && ! cmp -s "$WORK/a18-old-token" "$WORK/a18-node/rt-dup/token"; then
    pass A18 "re-pairing rotates the credential (new token differs)"
  else
    fail A18 "re-pairing rotates the credential (new token differs)" "first=$A18_FIRST_RC second=$A18_SECOND_RC"
  fi
  A18_AUDIT="$(rpc_at "$A18_STATE" runtime.audit '{}' | jq -r '.audit_text // ""')"
  contains A19 "rotation is audited" "runtime.credential_revoked" "$A18_AUDIT"
  # The audit detail is over-redacted from `credential_id=` onward, so the
  # durable revocation record is what carries the reason.
  A20_REASON="$(jq -r '[.revoked[]? | select(.runtime_id == "rt-dup")] | last | .reason // ""' \
    "$A18_STATE/rt/transport-state.json" 2>/dev/null)"
  eq A20 "rotation records reason=re-pair" "re-pair" "$A20_REASON"
  # Old token, same runtime id, separate node state: must be unauthorized.
  mkdir -p "$WORK/a18-old-node/rt-dup"
  chmod 700 "$WORK/a18-old-node" "$WORK/a18-old-node/rt-dup"
  cp "$WORK/a18-old-token" "$WORK/a18-old-node/rt-dup/token" 2>/dev/null
  chmod 600 "$WORK/a18-old-node/rt-dup/token" 2>/dev/null
  A18_OLD="$(HOME="$WORK/node-home" timeout 15 "$HOST_BIN" runtime serve \
    --runtime-id rt-dup --primary "$A18_ADDR" --ca "$PKI/ca.pem" --pin "$PIN1" \
    --state-base "$WORK/a18-old-node" --max-attempts 2 --backoff-ms 100 2>&1)"
  A18_OLD_RC=$?
  if [ "$A18_OLD_RC" -ne 0 ] && printf '%s' "$A18_OLD" | grep -Eiq 'unauthorized|revoked'; then
    pass A21 "the rotated-away token is unauthorized"
  else
    fail A21 "the rotated-away token is unauthorized" "rc=$A18_OLD_RC out=$A18_OLD"
  fi
  A18_AUDIT="$(rpc_at "$A18_STATE" runtime.audit '{}' | jq -r '.audit_text // ""')"
  contains A22 "unauthorized token use is audited" "runtime.auth_rejected" "$A18_AUDIT"
  # The replacement token still connects.
  node_serve "$WORK/node-home" "$WORK/a18-node" rt-dup "$A18_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/a18-node.log" --max-attempts 1
  A18_NEW_PID="$LAST_PID"
  A18_OK=0
  for _i in $(seq 1 100); do
    if rpc_at "$A18_STATE" runtime.status '{}' | jq -e '.channels >= 1' >/dev/null 2>&1; then A18_OK=1; break; fi
    sleep 0.1
  done
  if [ "$A18_OK" = "1" ]; then pass A23 "the replacement token is accepted"; else fail A23 "the replacement token is accepted" "$(cat "$WORK/a18-node.log")"; fi
  stop_pid "$A18_NEW_PID"
  stop_pid "$A18_PID"
fi

# A24: rotating the server certificate makes the old pinned node refuse to
# connect, while the new pin connects with the same credential.
A24_STATE="$WORK/a24-state"
A24_ADDR="$(main_addr "$(free_port)")"
if start_primary a24 "$A24_STATE" "$A24_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "" 8000 12000; then
  A24_PID="$LAST_PID"
  A24_CODE="$(new_code "$A24_STATE")" || A24_CODE=""
  A24_TRY="$(node_pair "$WORK/node-home" "$WORK/a24-node" rt-cert "$A24_ADDR" "$PKI/ca.pem" "$PIN1" "$A24_CODE")"
  A24_RC=$?
  stop_pid "$A24_PID"
  if start_primary a24b "$A24_STATE" "$A24_ADDR" "$PKI/leaf2.pem" "$PKI/leaf2.key" "" 8000 12000; then
    A24_PID="$LAST_PID"
    node_serve "$WORK/node-home" "$WORK/a24-node" rt-cert "$A24_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/a24-old.log" --max-attempts 2
    A24_OLD_PID="$LAST_PID"
    wait_exit "$A24_OLD_PID" 200
    A24_OLD_RC=$WAIT_RC
    A24_OLD_OUT="$(cat "$WORK/a24-old.log" 2>/dev/null)"
    if [ "$A24_RC" -eq 0 ] && [ "$A24_OLD_RC" -ne 0 ]; then
      pass A24 "a rotated certificate is refused by the old pin"
    else
      fail A24 "a rotated certificate is refused by the old pin" "pair=$A24_RC serve=$A24_OLD_RC out=$A24_OLD_OUT"
    fi
    node_serve "$WORK/node-home" "$WORK/a24-node" rt-cert "$A24_ADDR" "$PKI/ca.pem" "$PIN2" "$WORK/a24-new.log" --max-attempts 1
    A24_NEW_PID="$LAST_PID"
    A24_OK=0
    for _i in $(seq 1 100); do
      if rpc_at "$A24_STATE" runtime.status '{}' | jq -e '.channels >= 1' >/dev/null 2>&1; then A24_OK=1; break; fi
      sleep 0.1
    done
    if [ "$A24_OK" = "1" ]; then pass A25 "the new pin connects with the same credential"; else fail A25 "the new pin connects with the same credential" "$(cat "$WORK/a24-new.log")"; fi
    stop_pid "$A24_NEW_PID"
    stop_pid "$A24_PID"
  fi
fi

# A26: the listener refuses to start without TLS material (no plaintext mode).
mkdir -p "$WORK/a26-state"
A26_PORT="$(free_port)"
A26_OUT="$(HOME="$WORK/primary-home" timeout 10 "$HOST_BIN" serve \
  --state-dir "$WORK/a26-state" --runtime-listen "127.0.0.1:$A26_PORT" 2>&1)"
A26_RC=$?
if [ "$A26_RC" -ne 0 ] && printf '%s' "$A26_OUT" | grep -Fq -- '--runtime-cert and --runtime-key' \
  && [ ! -f "$WORK/a26-state/host.json" ]; then
  pass A26 "a runtime listener without TLS material is refused"
else
  fail A26 "a runtime listener without TLS material is refused" "rc=$A26_RC out=$A26_OUT"
fi

# ---------------------------------------------------------------------------
# B. Two-machine runtime: pairing, exec, fs, PTY, git, ACP, local coexistence
# ---------------------------------------------------------------------------
printf '\n== (b). paired runtime: exec, fs, pty, git, agent ==\n'

MAIN_STATE="$WORK/main-state"
MAIN_ADDR="$(main_addr "$(free_port)")"
MAIN_POLICY="$WORK/policy-main.json"
MAIN_POLICY_HASH="$(make_policy "$MAIN_POLICY" 3600000 pol-main-1)"
NODE_BASE="$WORK/node"
mkdir -p "$NODE_BASE"
chmod 700 "$NODE_BASE"
MAIN_READY=0
if start_primary main "$MAIN_STATE" "$MAIN_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "$MAIN_POLICY" 8000 12000; then
  MAIN_READY=1
  MAIN_PID="$LAST_PID"
fi

MAIN_RID="rt-main"
MAIN_CODE="$(new_code "$MAIN_STATE")" || MAIN_CODE=""
MAIN_PAIR_OUT="$(node_pair "$WORK/node-home" "$NODE_BASE" "$MAIN_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$MAIN_CODE")"
MAIN_PAIR_RC=$?
if [ "$MAIN_PAIR_RC" -eq 0 ] && [ -f "$NODE_BASE/$MAIN_RID/token" ]; then
  pass B1 "pair with a one-time code stores a node token"
else
  fail B1 "pair with a one-time code stores a node token" "rc=$MAIN_PAIR_RC out=$MAIN_PAIR_OUT"
fi
if [ -f "$NODE_BASE/$MAIN_RID/token" ]; then
  TOKEN_MODE="$(file_mode "$NODE_BASE/$MAIN_RID/token")"
  eq B2 "node token file is 0600" "600" "$TOKEN_MODE"
  NODE_TOKEN="$(cat "$NODE_BASE/$MAIN_RID/token" 2>/dev/null)"
else
  NODE_TOKEN=""
  fail B2 "node token file is 0600" "token file missing after pair"
fi

# Prepare the node workspace as a git repo before the node serves.
NODE_WORK="$NODE_BASE/$MAIN_RID/work"
mkdir -p "$NODE_WORK"
(
  cd "$NODE_WORK" || exit 1
  git init -q
  git config user.email "harness@example.invalid"
  git config user.name "MoNexus Harness"
  printf 'v1\n' >tracked.txt
  git add tracked.txt
  git commit -q -m "harness baseline"
  printf 'v2\n' >tracked.txt
)

node_serve "$WORK/node-home" "$NODE_BASE" "$MAIN_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/main-node.log"
NODE_PID="$LAST_PID"

MAIN_ADD="$(machine_add "$MAIN_STATE" runtime "$MAIN_RID" node-a)"
MAIN_MID="$(machine_id_from "$MAIN_ADD")"
if [ -n "$MAIN_MID" ]; then pass B3 "machine add accepts kind=runtime"; else fail B3 "machine add accepts kind=runtime" "$MAIN_ADD"; fi

if wait_attached "$MAIN_STATE" "$MAIN_MID" 200; then
  pass B4 "the outbound node attaches to the primary"
else
  fail B4 "the outbound node attaches to the primary" "$(tail -n 20 "$WORK/main-node.log")"
fi
if wait_policy_acked "$MAIN_STATE" 200; then
  pass B4a "the node acknowledges the installed policy snapshot"
else
  fail B4a "the node acknowledges the installed policy snapshot" "$(rpc_main runtime.status '{}')"
fi

if MAIN_PROBE_OUT="$(wait_probe_online "$MAIN_STATE" "$MAIN_MID" 200)"; then
  PROBE_JSON="$MAIN_PROBE_OUT"
  eq B5 "probe reports kind=runtime" "runtime" "$(printf '%s' "$PROBE_JSON" | jq -r '.machine.kind')"
  contains B6 "probe reports the runtime profile" "runtime $MAIN_RID" \
    "$(printf '%s' "$PROBE_JSON" | jq -r '.profile.notes')"
  contains B7 "probe reports an installed policy snapshot" "policy=snapshot" \
    "$(printf '%s' "$PROBE_JSON" | jq -r '.profile.notes')"
else
  fail B5 "probe reports kind=runtime" "machine probe never came online: $MAIN_PROBE_OUT"
  fail B6 "probe reports the runtime profile" "machine probe never came online: $MAIN_PROBE_OUT"
  fail B7 "probe reports an installed policy snapshot" "machine probe never came online: $MAIN_PROBE_OUT"
fi

# B8: the node has no listening socket of its own.
if command -v ss >/dev/null 2>&1; then
  B8_LISTEN="$(ss -ltnp 2>/dev/null | grep -F "pid=$NODE_PID" || true)"
  if [ -z "$B8_LISTEN" ]; then
    pass B8 "the node exposes no inbound listening port"
  else
    fail B8 "the node exposes no inbound listening port" "$B8_LISTEN"
  fi
else
  skip B8 "the node exposes no inbound listening port" "ss unavailable"
fi

# B9-B11: low-risk exec: exit code, streams, explicit and stable run_id.
# The id is pinned so B15/C7 can replay the exact same request (the CLI would
# derive a fresh idempotency key and turn the replay into a second execution).
EXEC_LOW_PARAMS="$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,argv:["printf","hello-runtime"],run_id:"run-low",client_request_id:"crid-low"}')"
EXEC_LOW="$(rpc_json "$MAIN_STATE" req-exec-low machine.exec "$EXEC_LOW_PARAMS")"
eq B9 "low-risk exec succeeds with exit 0" "0" "$(printf '%s' "$EXEC_LOW" | jq -r '.exit_code')"
eq B10 "low-risk exec captures stdout" "hello-runtime" "$(printf '%s' "$EXEC_LOW" | jq -r '.stdout')"
eq B11 "low-risk exec keeps the requested run_id" "run-low" "$(printf '%s' "$EXEC_LOW" | jq -r '.run_id')"
# The policy gate allows a read-only command without a Decision; the Run keeps
# the exec-level risk label, which is medium rather than the policy's low.
eq B12 "an allowed read-only exec reports its execution risk" "medium" "$(printf '%s' "$EXEC_LOW" | jq -r '.risk')"
EXEC_STATUS="$(rpc_q "$MAIN_STATE" machine.exec.status "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,run_id:"run-low"}')")"
eq B13 "exec status is keyed by the same run_id" "run-low" "$(printf '%s' "$EXEC_STATUS" | jq -r '.run_id')"
eq B14 "exec status reports success" "succeeded" "$(printf '%s' "$EXEC_STATUS" | jq -r '.status')"

# B15: replaying the same request id returns the existing result, no
# duplicate execution. Clear the primary's response cache first so the replay
# exercises the node's durable idempotency record, not the host cache.
fill_cache "$MAIN_STATE" 520
EXEC_REPLAY="$(rpc_json "$MAIN_STATE" req-exec-low machine.exec "$EXEC_LOW_PARAMS")"
if [ "$(printf '%s' "$EXEC_REPLAY" | jq -r '.started_at')" = "$(printf '%s' "$EXEC_LOW" | jq -r '.started_at')" ] \
  && [ "$(printf '%s' "$EXEC_REPLAY" | jq -r '.run_id')" = "run-low" ] \
  && [ "$(printf '%s' "$EXEC_REPLAY" | jq -r '.status')" = "succeeded" ]; then
  pass B15 "replaying a settled exec is idempotent (no second process)"
else
  fail B15 "replaying a settled exec is idempotent (no second process)" "$EXEC_REPLAY"
fi

# B57-B59: an explicit timeout cancels the command and reports it, never
# success. `sleep` is explicitly allowed by the fixture so this row does not
# need an approval.
TIMEOUT_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["sleep","5"],run_id:"run-timeout",client_request_id:"crid-timeout",timeout_ms:800}')"
TIMEOUT_OUT="$(rpc_main machine.exec "$TIMEOUT_PARAMS")"
eq B57 "an exec timeout is reported as cancelled" "cancelled" "$(printf '%s' "$TIMEOUT_OUT" | jq -r '.status')"
eq B58 "an exec timeout names the timeout stop reason" "timeout" "$(printf '%s' "$TIMEOUT_OUT" | jq -r '.stop_reason')"
if [ "$(printf '%s' "$TIMEOUT_OUT" | jq -r '.timed_out')" = "true" ] \
  && [ "$(printf '%s' "$TIMEOUT_OUT" | jq -r '.success')" = "false" ]; then
  pass B59 "a timed-out exec is never a success"
else
  fail B59 "a timed-out exec is never a success" "$TIMEOUT_OUT"
fi

# B16-B19: a workspace-written program named like a read-only builtin must not
# ride the read-only path; it needs an owner Decision and denial means no run.
cat >"$NODE_WORK/ls" <<'SH'
#!/bin/sh
printf bypass >bypass.txt
SH
chmod 700 "$NODE_WORK/ls"
BYPASS_PARAMS="$(jq -n --arg m "$MAIN_MID" --arg p "$NODE_WORK/ls" \
  '{machine_id:$m,argv:[$p],run_id:"run-bypass",client_request_id:"crid-bypass"}')"
rpc_main machine.exec "$BYPASS_PARAMS" >"$WORK/bypass.json" 2>&1 &
BYPASS_PID=$!
PIDS+=("$BYPASS_PID")
BYPASS_DEC="$(wait_decision "$MAIN_STATE" run-bypass "" 100)" || BYPASS_DEC=""
if [ -n "$BYPASS_DEC" ]; then
  pass B16 "a path-qualified argv[0] is not on the read-only allow path"
else
  fail B16 "a path-qualified argv[0] is not on the read-only allow path" "$(cat "$WORK/bypass.json" 2>/dev/null)"
fi
if [ -n "$BYPASS_DEC" ]; then
  BYPASS_DETAIL="$(decision_json "$MAIN_STATE" "$BYPASS_DEC" | jq -r '.detail // ""')"
  contains B17 "the bypass Decision shows the exact command" "$NODE_WORK/ls" "$BYPASS_DETAIL"
  respond_decision "$MAIN_STATE" "$BYPASS_DEC" deny >/dev/null 2>&1 || true
fi
wait_exit "$BYPASS_PID" 200
BYPASS_RC=$WAIT_RC
if [ -n "$BYPASS_DEC" ] && [ "$BYPASS_RC" -ne 0 ] && [ ! -f "$NODE_WORK/bypass.txt" ]; then
  pass B18 "denying the bypass Decision executes nothing"
else
  fail B18 "denying the bypass Decision executes nothing" "dec=$BYPASS_DEC rc=$BYPASS_RC file=$([ -f "$NODE_WORK/bypass.txt" ] && echo yes || echo no) out=$(cat "$WORK/bypass.json" 2>/dev/null)"
fi
if [ -n "$BYPASS_DEC" ] && ! grep -Fq '"status":"succeeded"' "$WORK/bypass.json" 2>/dev/null; then
  pass B19 "denial does not report success"
else
  fail B19 "denial does not report success" "$(cat "$WORK/bypass.json" 2>/dev/null)"
fi

# B20-B25: a high-risk command asks the owner; the Decision is bound to the
# machine, run and command digest, and approval executes the exact command.
HIGH_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["sh","-c","printf approved-run >approved.txt; printf approved-run"],run_id:"run-hi",client_request_id:"crid-hi"}')"
rpc_main machine.exec "$HIGH_PARAMS" >"$WORK/hi.json" 2>&1 &
HI_PID=$!
PIDS+=("$HI_PID")
HI_DEC="$(wait_decision "$MAIN_STATE" run-hi "" 150)" || HI_DEC=""
if [ -n "$HI_DEC" ]; then
  pass B20 "a high-risk command pauses for an owner Decision"
  HI_ROW="$(decision_json "$MAIN_STATE" "$HI_DEC")"
  eq B21 "the Decision is bound to the runtime machine" "$MAIN_MID" "$(printf '%s' "$HI_ROW" | jq -r '.machine_id')"
  eq B22 "the Decision is bound to the run" "run-hi" "$(printf '%s' "$HI_ROW" | jq -r '.run_id')"
  HI_DIGEST_HEX="$(printf '%s' "$HI_ROW" | jq -r '.plan_digest' | sed -n 's/^sha256://p')"
  if printf '%s' "$HI_DIGEST_HEX" | grep -Eq '^[0-9a-f]{64}$'; then
    pass B23 "the Decision carries a sha256-prefixed 64-hex command digest"
  else
    fail B23 "the Decision carries a sha256-prefixed 64-hex command digest" "$(printf '%s' "$HI_ROW" | jq -r '.plan_digest')"
  fi
  contains B24 "the Decision shows the command to the owner" "approved.txt" "$(printf '%s' "$HI_ROW" | jq -r '.detail')"
  HI_ANSWER="$(respond_decision "$MAIN_STATE" "$HI_DEC" approve)"
  if printf '%s' "$HI_ANSWER" | jq -e '.decision.status == "answered"' >/dev/null 2>&1; then
    pass B25 "answering a runtime Decision succeeds (no false ACP delivery error)"
  else
    fail B25 "answering a runtime Decision succeeds (no false ACP delivery error)" "$HI_ANSWER"
  fi
  HI_SECOND="$(respond_decision "$MAIN_STATE" "$HI_DEC" approve)"
  if [ $? -ne 0 ]; then pass B26 "a runtime Decision can be answered only once"; else fail B26 "a runtime Decision can be answered only once" "$HI_SECOND"; fi
else
  fail B20 "a high-risk command pauses for an owner Decision" "no Decision appeared"
fi
wait_exit "$HI_PID" 200
HI_RC=$WAIT_RC
if [ -n "$HI_DEC" ] && [ "$HI_RC" -eq 0 ] && [ "$(jq -r '.status' "$WORK/hi.json" 2>/dev/null)" = "succeeded" ] \
  && [ "$(jq -r '.stdout' "$WORK/hi.json" 2>/dev/null)" = "approved-run" ]; then
  pass B27 "approval executes the bound command exactly once"
else
  fail B27 "approval executes the bound command exactly once" "dec=$HI_DEC $(cat "$WORK/hi.json" 2>/dev/null)"
fi
if [ -f "$NODE_WORK/approved.txt" ] && [ "$(cat "$NODE_WORK/approved.txt")" = "approved-run" ]; then
  pass B28 "the approved command's side effect is present"
else
  fail B28 "the approved command's side effect is present" "missing or wrong content"
fi

# B60-B63: a non-zero exit and stderr are reported as such (never success).
EXIT_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["sh","-c","printf out; printf err >&2; exit 7"],run_id:"run-exit",client_request_id:"crid-exit"}')"
rpc_main machine.exec "$EXIT_PARAMS" >"$WORK/exit.json" 2>&1 &
EXIT_PID=$!
PIDS+=("$EXIT_PID")
EXIT_DEC="$(wait_decision "$MAIN_STATE" run-exit "" 150)" || EXIT_DEC=""
if [ -n "$EXIT_DEC" ]; then
  respond_decision "$MAIN_STATE" "$EXIT_DEC" approve >/dev/null 2>&1 || true
fi
wait_exit "$EXIT_PID" 200
EXIT_RC=$WAIT_RC
EXIT_OUT="$(cat "$WORK/exit.json" 2>/dev/null)"
eq B60 "a non-zero exit code is preserved" "7" "$(printf '%s' "$EXIT_OUT" | jq -r '.exit_code')"
eq B61 "stdout is captured separately" "out" "$(printf '%s' "$EXIT_OUT" | jq -r '.stdout')"
eq B62 "stderr is captured separately" "err" "$(printf '%s' "$EXIT_OUT" | jq -r '.stderr')"
if [ "$EXIT_RC" -eq 0 ] && [ "$(printf '%s' "$EXIT_OUT" | jq -r '.status')" = "failed" ] \
  && [ "$(printf '%s' "$EXIT_OUT" | jq -r '.success')" = "false" ]; then
  pass B63 "a failed exit is never reported as success"
else
  fail B63 "a failed exit is never reported as success" "rc=$EXIT_RC out=$EXIT_OUT"
fi

# B29-B31: denial never executes; the Decision records the denial.
DENY_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["sh","-c","printf denied >denied.txt"],run_id:"run-deny",client_request_id:"crid-deny"}')"
rpc_main machine.exec "$DENY_PARAMS" >"$WORK/deny.json" 2>&1 &
DENY_PID=$!
PIDS+=("$DENY_PID")
DENY_DEC="$(wait_decision "$MAIN_STATE" run-deny "" 150)" || DENY_DEC=""
if [ -n "$DENY_DEC" ]; then
  pass B29 "a second high-risk command asks again"
  respond_decision "$MAIN_STATE" "$DENY_DEC" deny >/dev/null 2>&1 || true
fi
wait_exit "$DENY_PID" 200
DENY_RC=$WAIT_RC
if [ -n "$DENY_DEC" ] && [ "$DENY_RC" -ne 0 ] && [ ! -f "$NODE_WORK/denied.txt" ]; then
  pass B30 "a denied command never executes"
else
  fail B30 "a denied command never executes" "dec=$DENY_DEC rc=$DENY_RC file=$([ -f "$NODE_WORK/denied.txt" ] && echo yes || echo no)"
fi
if [ -n "$DENY_DEC" ]; then
  DENY_ROW="$(decision_json "$MAIN_STATE" "$DENY_DEC")"
  if [ "$(printf '%s' "$DENY_ROW" | jq -r '.status')" = "answered" ] \
    && [ "$(printf '%s' "$DENY_ROW" | jq -r '.option_id')" = "deny" ]; then
    pass B31 "the denial is recorded on the Decision"
  else
    fail B31 "the denial is recorded on the Decision" "$DENY_ROW"
  fi
else
  fail B31 "the denial is recorded on the Decision" "no Decision appeared"
fi

# B32-B33: an unanswered Decision expires; the operation never runs offline.
EXPIRE_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["sh","-c","printf expired >expired.txt"],run_id:"run-expire",client_request_id:"crid-expire"}')"
rpc_main machine.exec "$EXPIRE_PARAMS" >"$WORK/expire.json" 2>&1 &
EXPIRE_PID=$!
PIDS+=("$EXPIRE_PID")
EXPIRE_DEC="$(wait_decision "$MAIN_STATE" run-expire "" 150)" || EXPIRE_DEC=""
if [ -n "$EXPIRE_DEC" ]; then
  pass B32 "an unanswered high-risk command waits for the owner"
else
  fail B32 "an unanswered high-risk command waits for the owner" "no Decision appeared"
fi
wait_exit "$EXPIRE_PID" 300
EXPIRE_RC=$WAIT_RC
if [ -n "$EXPIRE_DEC" ] && [ "$EXPIRE_RC" -ne 0 ] && [ ! -f "$NODE_WORK/expired.txt" ]; then
  pass B33 "an expired approval never executes (no offline allow)"
else
  fail B33 "an expired approval never executes (no offline allow)" "dec=$EXPIRE_DEC rc=$EXPIRE_RC file=$([ -f "$NODE_WORK/expired.txt" ] && echo yes || echo no) out=$(cat "$WORK/expire.json" 2>/dev/null)"
fi
if [ -n "$EXPIRE_DEC" ]; then
  eq B34 "the unanswered Decision is marked expired" "expired" "$(decision_json "$MAIN_STATE" "$EXPIRE_DEC" | jq -r '.status')"
else
  fail B34 "the unanswered Decision is marked expired" "no Decision appeared"
fi

# B35-B39: fs roundtrip and durable idempotency (a replayed write keeps the
# first content instead of overwriting it).
FS_WRITE_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"write",path:"dup.txt",content:"first",client_request_id:"crid-dup-write"}')"
FS_WRITE="$(rpc_json "$MAIN_STATE" req-fs-write machine.fs "$FS_WRITE_PARAMS")"
eq B35 "fs write succeeds on the node" "dup.txt" "$(printf '%s' "$FS_WRITE" | jq -r '.path')"
FS_READ="$(rpc_q "$MAIN_STATE" machine.fs "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"read",path:"dup.txt"}')")"
eq B36 "fs read returns the written bytes" "first" "$(printf '%s' "$FS_READ" | jq -r '.data')"
FS_STAT="$(rpc_q "$MAIN_STATE" machine.fs "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"stat",path:"dup.txt"}')")"
eq B37 "fs stat reports a regular file" "file" "$(printf '%s' "$FS_STAT" | jq -r '.kind')"
FS_LIST="$(rpc_q "$MAIN_STATE" machine.fs "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"list",path:"."}')")"
contains B38 "fs list sees the written file" "dup.txt" "$FS_LIST"
# Clear the primary cache so this replay is answered by the node's durable
# idempotency record; the changed content must not be written.
fill_cache "$MAIN_STATE" 520
FS_REPLAY="$(rpc_json "$MAIN_STATE" req-fs-write machine.fs "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"write",path:"dup.txt",content:"second",client_request_id:"crid-dup-write"}')")"
FS_AFTER="$(rpc_q "$MAIN_STATE" machine.fs "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"read",path:"dup.txt"}')")"
if [ "$(printf '%s' "$FS_AFTER" | jq -r '.data')" = "first" ] \
  && [ "$(printf '%s' "$FS_REPLAY" | jq -r '.written')" = "true" ]; then
  pass B39 "a replayed fs write is served from cache, not re-executed"
else
  fail B39 "a replayed fs write is served from cache, not re-executed" "$FS_AFTER"
fi

# B64-B66: a path or cwd that escapes the node workspace root is refused
# before any read, write or process start. The parent of the work root holds a
# sentinel that the escape must never reveal or overwrite.
ESCAPE_SENTINEL="$NODE_BASE/$MAIN_RID/escape-sentinel.txt"
printf 'do-not-read\n' >"$ESCAPE_SENTINEL"
ESCAPE_READ="$(rpc_json "$MAIN_STATE" req-fs-escape-read machine.fs "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"read",path:"../escape-sentinel.txt",client_request_id:"crid-fs-escape-read"}')")"
if printf '%s' "$ESCAPE_READ" | jq -e '.error' >/dev/null 2>&1 \
  && ! printf '%s' "$ESCAPE_READ" | grep -Fq 'do-not-read'; then
  pass B64 "fs read of a path outside the workspace root is refused"
else
  fail B64 "fs read of a path outside the workspace root is refused" "$ESCAPE_READ"
fi
ESCAPE_WRITE="$(rpc_json "$MAIN_STATE" req-fs-escape-write machine.fs "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"write",path:"../escape.txt",content:"escaped",client_request_id:"crid-fs-escape-write"}')")"
if printf '%s' "$ESCAPE_WRITE" | jq -e '.error' >/dev/null 2>&1 \
  && [ ! -f "$NODE_BASE/$MAIN_RID/escape.txt" ]; then
  pass B65 "fs write outside the workspace root is refused and creates nothing"
else
  fail B65 "fs write outside the workspace root is refused and creates nothing" "$ESCAPE_WRITE"
fi
ESCAPE_EXEC="$(rpc_json "$MAIN_STATE" req-exec-escape machine.exec "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["printf","escaped"],cwd:"..",run_id:"run-escape",client_request_id:"crid-exec-escape"}')")"
if printf '%s' "$ESCAPE_EXEC" | jq -e '.error' >/dev/null 2>&1; then
  pass B66 "exec with a cwd outside the workspace root is refused"
else
  fail B66 "exec with a cwd outside the workspace root is refused" "$ESCAPE_EXEC"
fi

# B67-B68: a symlink inside the workspace that resolves outside the root must
# not be followed for reads or writes. RootedDir resolves the existing parent
# and refuses a target outside the root; a write may replace the link entry
# itself but must never modify the outside target.
ln -s ../escape-sentinel.txt "$NODE_WORK/escape-link.txt"
SYMLINK_READ="$(rpc_json "$MAIN_STATE" req-fs-symlink-read machine.fs "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"read",path:"escape-link.txt",client_request_id:"crid-fs-symlink-read"}')")"
if printf '%s' "$SYMLINK_READ" | jq -e '.error' >/dev/null 2>&1 \
  && ! printf '%s' "$SYMLINK_READ" | grep -Fq 'do-not-read'; then
  pass B67 "fs read through a symlink outside the workspace root is refused"
else
  fail B67 "fs read through a symlink outside the workspace root is refused" "$SYMLINK_READ"
fi
SYMLINK_TARGET="$NODE_BASE/$MAIN_RID/escape-write-target.txt"
printf 'outside-original\n' >"$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$NODE_WORK/escape-write-link.txt"
SYMLINK_WRITE="$(rpc_json "$MAIN_STATE" req-fs-symlink-write machine.fs "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"write",path:"escape-write-link.txt",content:"via-link",client_request_id:"crid-fs-symlink-write"}')")"
if [ "$(cat "$SYMLINK_TARGET" 2>/dev/null)" = "outside-original" ]; then
  pass B68 "fs write through a symlink cannot modify a file outside the workspace root"
else
  fail B68 "fs write through a symlink cannot modify a file outside the workspace root" "$SYMLINK_WRITE"
fi

# B40-B44: PTY open -> input -> resize -> status -> close, with a side effect
# written from inside the session and an exit code.
PTY_OPEN="$(rpc_main machine.pty "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"open",argv:["sh"],cwd:"",rows:24,cols:80,client_request_id:"crid-pty-open"}')")"
PTY_ID="$(printf '%s' "$PTY_OPEN" | jq -r '.session.session_id // empty')"
if [ -n "$PTY_ID" ]; then pass B40 "PTY open creates a session on the node"; else fail B40 "PTY open creates a session on the node" "$PTY_OPEN"; fi
if [ -n "$PTY_ID" ]; then
  PTY_INPUT="$(rpc_main machine.pty "$(jq -n --arg m "$MAIN_MID" --arg s "$PTY_ID" \
    '{machine_id:$m,op:"input",session_id:$s,data:"printf pty-ok >pty.txt\nexit 7\n",client_request_id:"crid-pty-input"}')")"
  PTY_RESIZE="$(rpc_main machine.pty "$(jq -n --arg m "$MAIN_MID" --arg s "$PTY_ID" \
    '{machine_id:$m,op:"resize",session_id:$s,rows:40,cols:100,client_request_id:"crid-pty-resize"}')")"
  PTY_OK=0
  for _i in $(seq 1 100); do
    PTY_READ="$(rpc_main machine.fs "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"read",path:"pty.txt"}')")"
    if [ "$(printf '%s' "$PTY_READ" | jq -r '.data // ""')" = "pty-ok" ]; then PTY_OK=1; break; fi
    sleep 0.1
  done
  if [ "$PTY_OK" = "1" ]; then pass B41 "PTY input runs inside the session"; else fail B41 "PTY input runs inside the session" "$PTY_INPUT $PTY_RESIZE"; fi
  PTY_STATUS="$(rpc_main machine.pty "$(jq -n --arg m "$MAIN_MID" --arg s "$PTY_ID" \
    '{machine_id:$m,op:"status",session_id:$s}')")"
  if [ "$(printf '%s' "$PTY_STATUS" | jq -r '.session.output_seq')" -gt 0 ] 2>/dev/null; then
    pass B42 "PTY status reports streamed output"
  else
    fail B42 "PTY status reports streamed output" "$PTY_STATUS"
  fi
  PTY_CLOSE="$(rpc_q "$MAIN_STATE" machine.pty "$(jq -n --arg m "$MAIN_MID" --arg s "$PTY_ID" \
    '{machine_id:$m,op:"close",session_id:$s}')")"
  # The PTY provider finalizes the session but does not surface the shell exit
  # code (a known limit, documented in docs/usage.md); it must never claim
  # success for the non-zero exit.
  if [ "$(printf '%s' "$PTY_CLOSE" | jq -r '.session.running')" = "false" ] \
    && [ "$(printf '%s' "$PTY_CLOSE" | jq -r '.session.success')" = "false" ]; then
    pass B43 "PTY close finalizes the shell session and never reports success"
  else
    fail B43 "PTY close finalizes the shell session and never reports success" "$PTY_CLOSE"
  fi
  PTY_CLOSED="$(rpc_q "$MAIN_STATE" machine.pty "$(jq -n --arg m "$MAIN_MID" --arg s "$PTY_ID" \
    '{machine_id:$m,op:"status",session_id:$s}')")"
  if [ "$(printf '%s' "$PTY_CLOSED" | jq -r '.session.status')" = "failed" ] \
    && [ "$(printf '%s' "$PTY_CLOSED" | jq -r '.session.running')" = "false" ]; then
    pass B44 "PTY session remains inspectable as failed after close"
  else
    fail B44 "PTY session remains inspectable as failed after close" "$PTY_CLOSED"
  fi
else
  fail B41 "PTY input runs inside the session" "no session id"
  fail B42 "PTY status reports streamed output" "no session id"
  fail B43 "PTY close finalizes the shell session and never reports success" "no session id"
  fail B44 "PTY session remains inspectable as failed after close" "no session id"
fi

# B45-B49: git reads over the runtime transport.
GIT_STATUS="$(rpc_main machine.git "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"status"}')")"
contains B45 "git status sees the node repository" "tracked.txt" "$GIT_STATUS"
GIT_DIFF="$(rpc_main machine.git "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"diff"}')")"
contains B46 "git diff reads uncommitted changes" "v2" "$GIT_DIFF"
GIT_LOG="$(rpc_main machine.git "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"log",max_count:5}')")"
contains B47 "git log reads the node history" "harness baseline" "$GIT_LOG"
GIT_SHOW="$(rpc_main machine.git "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"show",rev:"HEAD"}')")"
contains B48 "git show reads a commit" "tracked.txt" "$GIT_SHOW"
GIT_BRANCHES="$(rpc_main machine.git "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"branches"}')")"
contains B49 "git branches lists the node branch" "current" "$GIT_BRANCHES"

# B50-B55: one ACP session on the runtime machine. The process start needs an
# approval (unknown, non-read-only argv), which is the production launcher
# registered by the attach loop. The mock adapter answers the prompt. The
# adapter is a node-local file, so it lives inside the node workspace (the
# primary's `$WS` path is only the mapped root): policy validation denies any
# argv path argument outside the node workspace root, while argv[0] (the node
# toolchain binary) is exempt as a machine executable.
if [ -n "$NODE_BIN" ]; then
  mkdir -p "$NODE_WORK/tools"
  cp "$ROOT/tests/agent/mock_acp_agent.mjs" "$NODE_WORK/tools/mock_acp_agent.mjs"
  AGENT_PARAMS="$(jq -n --arg m "$MAIN_MID" --arg cmd "$NODE_BIN" --arg ws "$WS" \
    '{machine_id:$m,agent_id:"rt-mock",mode:"acp",command:$cmd,args:["tools/mock_acp_agent.mjs"],cwd:$ws,prompt:"hello runtime",memory_limit:4096,env:{},client_request_id:"crid-agent"}')"
  rpc_json "$MAIN_STATE" req-agent agent.start "$AGENT_PARAMS" >"$WORK/agent.json" 2>&1 &
  AGENT_PID=$!
  PIDS+=("$AGENT_PID")
  AGENT_DEC="$(wait_decision "$MAIN_STATE" "" "runtime.process.start" 200)" || AGENT_DEC=""
  if [ -n "$AGENT_DEC" ]; then
    pass B50 "agent.start on kind=runtime asks for approval through the registered launcher"
    respond_decision "$MAIN_STATE" "$AGENT_DEC" approve >/dev/null 2>&1 || true
  else
    fail B50 "agent.start on kind=runtime asks for approval through the registered launcher" "$(cat "$WORK/agent.json" 2>/dev/null)"
  fi
  wait "$AGENT_PID" 2>/dev/null || true
  AGENT_OUT="$(cat "$WORK/agent.json" 2>/dev/null)"
  AGENT_SID="$(printf '%s' "$AGENT_OUT" | jq -r '.session.id // empty' 2>/dev/null)"
  if [ -n "$AGENT_SID" ]; then pass B51 "agent.start creates a session on the runtime machine"; else fail B51 "agent.start creates a session on the runtime machine" "$AGENT_OUT"; fi
  if [ -n "$AGENT_SID" ]; then
    eq B52 "the runtime agent runs in the mapped node workspace" "." "$(printf '%s' "$AGENT_OUT" | jq -r '.session.cwd')"
    AGENT_TEXT=0
    for _i in $(seq 1 200); do
      AGENT_READ="$(rpc_q "$MAIN_STATE" agent.read "$(jq -n --arg id "$AGENT_SID" '{session_id:$id,cursor:0}')")"
      if printf '%s' "$AGENT_READ" | grep -Fq 'MOCK#1 start'; then AGENT_TEXT=1; break; fi
      sleep 0.1
    done
    if [ "$AGENT_TEXT" = "1" ]; then pass B53 "the ACP transcript streams over runtime.process"; else fail B53 "the ACP transcript streams over runtime.process" "$AGENT_READ"; fi
    rpc_q "$MAIN_STATE" agent.stop "$(jq -n --arg id "$AGENT_SID" '{session_id:$id}')" >/dev/null 2>&1 || true
    AGENT_STATE=0
    for _i in $(seq 1 100); do
      AGENT_READ="$(rpc_q "$MAIN_STATE" agent.read "$(jq -n --arg id "$AGENT_SID" '{session_id:$id,cursor:0}')")"
      if [ "$(printf '%s' "$AGENT_READ" | jq -r '.state // empty')" = "stopped" ]; then AGENT_STATE=1; break; fi
      sleep 0.1
    done
    if [ "$AGENT_STATE" = "1" ]; then pass B54 "agent.stop ends the runtime ACP session"; else fail B54 "agent.stop ends the runtime ACP session" "$AGENT_READ"; fi
  else
    fail B52 "the runtime agent runs in the mapped node workspace" "no session id"
    fail B53 "the ACP transcript streams over runtime.process" "no session id"
    fail B54 "agent.stop ends the runtime ACP session" "no session id"
  fi
else
  skip B50 "agent.start on kind=runtime asks for approval through the registered launcher" "node missing"
  skip B51 "agent.start creates a session on the runtime machine" "node missing"
  skip B52 "the runtime agent runs in the mapped node workspace" "node missing"
  skip B53 "the ACP transcript streams over runtime.process" "node missing"
  skip B54 "agent.stop ends the runtime ACP session" "node missing"
fi

# B55-B56: a local machine coexists with the runtime machine without
# contaminating it.
LOCAL_ADD="$(machine_add "$MAIN_STATE" local localhost local-m)"
LOCAL_MID="$(machine_id_from "$LOCAL_ADD")"
if [ -n "$LOCAL_MID" ]; then
  LOCAL_PROBE="$("$HOST_BIN" machine probe --state-dir "$MAIN_STATE" --id "$LOCAL_MID" 2>&1 || true)"
  contains B55 "the local machine probes independently" "status=online" "$LOCAL_PROBE"
else
  fail B55 "the local machine probes independently" "$LOCAL_ADD"
fi
if rpc_q "$MAIN_STATE" machine.probe "$(jq -n --arg id "$MAIN_MID" '{machine_id:$id}')" | jq -e '.machine.status == "online"' >/dev/null 2>&1; then
  pass B56 "registering a local machine leaves the runtime machine online"
else
  fail B56 "registering a local machine leaves the runtime machine online" "runtime probe failed"
fi

# ---------------------------------------------------------------------------
# C. Weak network: node loss mid-run, restart recovery, reconnect
# ---------------------------------------------------------------------------
printf '\n== (c). weak network and restart ==\n'

DROP_PARAMS="$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,argv:["sh","-c","sleep 6"],run_id:"run-drop",client_request_id:"crid-drop",timeout_ms:20000}')"
rpc_main machine.exec "$DROP_PARAMS" >"$WORK/drop.json" 2>&1 &
DROP_PID=$!
PIDS+=("$DROP_PID")
DROP_DEC="$(wait_decision "$MAIN_STATE" run-drop "" 150)" || DROP_DEC=""
if [ -n "$DROP_DEC" ]; then
  respond_decision "$MAIN_STATE" "$DROP_DEC" approve >/dev/null 2>&1 || true
  sleep 0.5
  kill -KILL "$NODE_PID" 2>/dev/null || true
  wait "$NODE_PID" 2>/dev/null || true
  wait_exit "$DROP_PID" 300
  DROP_RC=$WAIT_RC
  DROP_OUT="$(cat "$WORK/drop.json" 2>/dev/null)"
  if [ "$DROP_RC" -ne 0 ] && ! printf '%s' "$DROP_OUT" | grep -Fq '"status":"succeeded"'; then
    pass C1 "killing the node mid-run never reports success"
  else
    fail C1 "killing the node mid-run never reports success" "rc=$DROP_RC out=$DROP_OUT"
  fi
else
  fail C1 "killing the node mid-run never reports success" "no Decision appeared"
fi

# Restart the node. The unfinished run must come back lost, never succeeded.
node_serve "$WORK/node-home" "$NODE_BASE" "$MAIN_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/main-node2.log"
NODE_PID="$LAST_PID"
if wait_attached "$MAIN_STATE" "$MAIN_MID" 200; then
  pass C2 "the node reconnects and reattaches after restart"
else
  fail C2 "the node reconnects and reattaches after restart" "$(tail -n 20 "$WORK/main-node2.log")"
fi
if wait_probe_online "$MAIN_STATE" "$MAIN_MID" 200 >/dev/null; then
  pass C3 "the restarted node probes online"
else
  fail C3 "the restarted node probes online" "probe failed"
fi
DROP_STATUS="$(rpc_main machine.exec.status "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,run_id:"run-drop"}')")"
eq C4 "a node restart finalizes the unfinished run as lost" "lost" "$(printf '%s' "$DROP_STATUS" | jq -r '.status')"
eq C5 "a lost run is never a success" "false" "$(printf '%s' "$DROP_STATUS" | jq -r '.success')"

# Durable idempotency survives the node restart: the fs write replay must not
# overwrite the first content with the second. Clear the host cache first so
# the answer comes from the node's durable record.
fill_cache "$MAIN_STATE" 520
FS_REPLAY2="$(rpc_json "$MAIN_STATE" req-fs-write machine.fs "$(jq -n --arg m "$MAIN_MID" \
  '{machine_id:$m,op:"write",path:"dup.txt",content:"third",client_request_id:"crid-dup-write"}')")"
FS_AFTER2="$(rpc_q "$MAIN_STATE" machine.fs "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,op:"read",path:"dup.txt"}')")"
if [ "$(printf '%s' "$FS_AFTER2" | jq -r '.data')" = "first" ]; then
  pass C6 "a replay after restart is served from the durable cache (no duplicate write)"
else
  fail C6 "a replay after restart is served from the durable cache (no duplicate write)" "$FS_AFTER2"
fi
EXEC_REPLAY2="$(rpc_json "$MAIN_STATE" req-exec-low machine.exec "$EXEC_LOW_PARAMS")"
if [ "$(printf '%s' "$EXEC_REPLAY2" | jq -r '.started_at')" = "$(printf '%s' "$EXEC_LOW" | jq -r '.started_at')" ] \
  && [ "$(printf '%s' "$EXEC_REPLAY2" | jq -r '.run_id')" = "run-low" ] \
  && [ "$(printf '%s' "$EXEC_REPLAY2" | jq -r '.status')" = "succeeded" ]; then
  pass C7 "a settled exec replay after restart keeps its original run"
else
  fail C7 "a settled exec replay after restart keeps its original run" "$EXEC_REPLAY2"
fi

# Catch-up: the cursor advances after reconnect and the audit records the
# reattach.
C8_BEFORE="$(rpc_main runtime.status '{}' | jq -r --arg m "$MAIN_MID" '.attached[]? | select(.machine_id==$m) | .ack_cursor' | head -n1)"
sleep 1
C8_AFTER="$(rpc_main runtime.status '{}' | jq -r --arg m "$MAIN_MID" '.attached[]? | select(.machine_id==$m) | .ack_cursor' | head -n1)"
if [ -n "$C8_BEFORE" ] && [ -n "$C8_AFTER" ] && [ "$C8_AFTER" -ge "$C8_BEFORE" ]; then
  pass C8 "the outbox cursor catches up after reconnect"
else
  fail C8 "the outbox cursor catches up after reconnect" "before=$C8_BEFORE after=$C8_AFTER"
fi
C9_AUDIT="$(rpc_main runtime.audit '{}' | jq -r '.audit_text // ""')"
contains C9 "reattach is audited" "runtime.attached" "$C9_AUDIT"

# Primary restart: the node reconnects to the same state and keeps its Runs.
# Stop the node before the primary: killing the primary while the TLS channel
# is live leaves the listener port in TIME-WAIT and an immediate rebind fails
# (verified locally). A graceful node stop releases the channel first.
stop_pid "$NODE_PID"
NODE_PID=""
stop_pid "$MAIN_PID"
MAIN_PID=""
sleep 0.5
if start_primary main2 "$MAIN_STATE" "$MAIN_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "$MAIN_POLICY" 8000 12000; then
  MAIN_PID="$LAST_PID"
  node_serve "$WORK/node-home" "$NODE_BASE" "$MAIN_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/main-node3.log"
  NODE_PID="$LAST_PID"
  if wait_attached "$MAIN_STATE" "$MAIN_MID" 300; then
    pass C10 "the node reconnects after a primary restart"
  else
    fail C10 "the node reconnects after a primary restart" "$(tail -n 20 "$WORK/main-node3.log")"
  fi
  if wait_policy_acked "$MAIN_STATE" 300; then
    pass C10a "the node re-acknowledges the policy after the primary restart"
  else
    fail C10a "the node re-acknowledges the policy after the primary restart" "$(rpc_q "$MAIN_STATE" runtime.status '{}')"
  fi
  C11_STATUS="$(rpc_q "$MAIN_STATE" machine.exec.status "$(jq -n --arg m "$MAIN_MID" '{machine_id:$m,run_id:"run-low"}')")"
  eq C11 "a completed run survives the primary restart" "succeeded" "$(printf '%s' "$C11_STATUS" | jq -r '.status')"
  C12_REPLAY="$(rpc_json "$MAIN_STATE" req-exec-low machine.exec "$EXEC_LOW_PARAMS")"
  if [ "$(printf '%s' "$C12_REPLAY" | jq -r '.started_at')" = "$(printf '%s' "$EXEC_LOW" | jq -r '.started_at')" ] \
    && [ "$(printf '%s' "$C12_REPLAY" | jq -r '.run_id')" = "run-low" ]; then
    pass C12 "a replay after a primary restart is still idempotent"
  else
    fail C12 "a replay after a primary restart is still idempotent" "$C12_REPLAY"
  fi
else
  fail C10 "the node reconnects after a primary restart" "primary failed to restart"
  fail C10a "the node re-acknowledges the policy after the primary restart" "primary failed to restart"
  fail C11 "a completed run survives the primary restart" "primary failed to restart"
  fail C12 "a replay after a primary restart is still idempotent" "primary failed to restart"
fi

# Policy staleness: a separate node receives an already-expired snapshot.
# Read-only commands stay local; high-risk work is unverifiable and never
# runs offline.
STALE_STATE="$WORK/stale-state"
STALE_ADDR="$(main_addr "$(free_port)")"
STALE_POLICY="$WORK/policy-stale.json"
make_policy "$STALE_POLICY" -5000 pol-stale-1 >/dev/null
STALE_RID="rt-stale"
STALE_OK=0
if start_primary stale "$STALE_STATE" "$STALE_ADDR" "$PKI/leaf1.pem" "$PKI/leaf1.key" "$STALE_POLICY" 8000 12000; then
  STALE_PID="$LAST_PID"
  STALE_CODE="$(new_code "$STALE_STATE")" || STALE_CODE=""
  node_pair "$WORK/node-home" "$WORK/stale-node" "$STALE_RID" "$STALE_ADDR" "$PKI/ca.pem" "$PIN1" "$STALE_CODE" >/dev/null 2>&1
  node_serve "$WORK/node-home" "$WORK/stale-node" "$STALE_RID" "$STALE_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/stale-node.log"
  STALE_NODE_PID="$LAST_PID"
  STALE_ADD="$(machine_add "$STALE_STATE" runtime "$STALE_RID" node-stale)"
  STALE_MID="$(machine_id_from "$STALE_ADD")"
  if wait_attached "$STALE_STATE" "$STALE_MID" 200; then
    STALE_OK=1
  else
    fail C13a "a stale-policy node attaches" "$(tail -n 20 "$WORK/stale-node.log")"
  fi
  if [ "$STALE_OK" = "1" ] && ! wait_policy_acked "$STALE_STATE" 200; then
    STALE_OK=0
    fail C13b "a stale-policy node acknowledges the snapshot" "$(rpc_at "$STALE_STATE" runtime.status '{}')"
  elif [ "$STALE_OK" = "1" ]; then
    pass C13b "a stale-policy node acknowledges the snapshot"
  fi
  if [ "$STALE_OK" = "1" ]; then
    STALE_LOW="$(rpc_at "$STALE_STATE" machine.exec "$(jq -n --arg m "$STALE_MID" \
      '{machine_id:$m,argv:["printf","stale-low"],run_id:"run-stale-low",client_request_id:"crid-stale-low"}')")"
    eq C13 "read-only work is still allowed under a stale snapshot" "stale-low" "$(printf '%s' "$STALE_LOW" | jq -r '.stdout')"
    STALE_HIGH="$(rpc_at "$STALE_STATE" machine.exec "$(jq -n --arg m "$STALE_MID" \
      '{machine_id:$m,argv:["sh","-c","printf stale >stale.txt"],run_id:"run-stale-hi",client_request_id:"crid-stale-hi"}')")"
    STALE_HIGH_RC=$?
    if [ "$STALE_HIGH_RC" -ne 0 ] && [ ! -f "$WORK/stale-node/$STALE_RID/work/stale.txt" ]; then
      pass C14 "high-risk work under a stale snapshot is unverifiable, never offline"
    else
      fail C14 "high-risk work under a stale snapshot is unverifiable, never offline" "rc=$STALE_HIGH_RC out=$STALE_HIGH"
    fi
    contains C15 "the stale refusal names the unverified policy" "cannot be verified under the installed policy" "$STALE_HIGH"
  fi
  stop_pid "$STALE_NODE_PID"
  stop_pid "$STALE_PID"
fi

# ---------------------------------------------------------------------------
# E. Real ACP model turn (explicit opt-in only)
# ---------------------------------------------------------------------------
printf '\n== (e). real ACP model turn ==\n'
REAL_ACP_AVAILABLE=0
E1_REASON="unverified: M4_REAL_ACP was not set, so no real model turn was attempted"
if [ "${M4_REAL_ACP:-0}" = "1" ]; then
  E1_REASON="unverified: claude-code-acp@0.16.2 is not runnable through npx under the node HOME"
  if command -v npx >/dev/null 2>&1 \
    && HOME="$REAL_HOME" timeout 20 npx -y @zed-industries/claude-code-acp@0.16.2 --version >/dev/null 2>&1; then
    REAL_ACP_AVAILABLE=1
  fi
fi
if [ "$REAL_ACP_AVAILABLE" = "1" ]; then
  REAL_RID="rt-real"
  REAL_BASE="$WORK/real-node"
  REAL_CODE="$(new_code "$MAIN_STATE")" || REAL_CODE=""
  REAL_PAIR="$(node_pair "$REAL_HOME" "$REAL_BASE" "$REAL_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$REAL_CODE")"
  REAL_PAIR_RC=$?
  if [ "$REAL_PAIR_RC" -eq 0 ]; then
    node_serve "$REAL_HOME" "$REAL_BASE" "$REAL_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/real-node.log"
    REAL_NODE_PID="$LAST_PID"
    REAL_ADD="$(machine_add "$MAIN_STATE" runtime "$REAL_RID" node-real)"
    REAL_MID="$(machine_id_from "$REAL_ADD")"
    if wait_attached "$MAIN_STATE" "$REAL_MID" 200; then
      REAL_PARAMS="$(jq -n --arg m "$REAL_MID" \
        '{machine_id:$m,agent_id:"claude",mode:"acp",command:"",args:[],cwd:".",prompt:"Reply with the single word: pong",memory_limit:4096,env:{},client_request_id:"crid-real-agent"}')"
      rpc_json "$MAIN_STATE" req-real-agent agent.start "$REAL_PARAMS" >"$WORK/real-agent.json" 2>&1 &
      REAL_AGENT_PID=$!
      PIDS+=("$REAL_AGENT_PID")
      REAL_DEC="$(wait_decision "$MAIN_STATE" "" "runtime.process.start" 600)" || REAL_DEC=""
      if [ -n "$REAL_DEC" ]; then
        respond_decision "$MAIN_STATE" "$REAL_DEC" approve >/dev/null 2>&1 || true
      fi
      wait "$REAL_AGENT_PID" 2>/dev/null || true
      REAL_OUT="$(cat "$WORK/real-agent.json" 2>/dev/null)"
      REAL_SID="$(printf '%s' "$REAL_OUT" | jq -r '.session.id // empty' 2>/dev/null)"
      if [ -n "$REAL_SID" ]; then
        REAL_TEXT=0
        for _i in $(seq 1 600); do
          REAL_READ="$(rpc_q "$MAIN_STATE" agent.read "$(jq -n --arg id "$REAL_SID" '{session_id:$id,cursor:0}')")"
          if printf '%s' "$REAL_READ" | jq -e '(.text // "") | length > 0' >/dev/null 2>&1; then REAL_TEXT=1; break; fi
          sleep 0.2
        done
        if [ "$REAL_TEXT" = "1" ]; then
          # Evidence: keep the streamed reply and the turn's stop reason. The
          # turn can still be open when the first text arrives, so wait
          # briefly for a terminal state. The assertion above already passed
          # on a non-empty stream and is unchanged.
          REAL_STOP=""
          for _i in $(seq 1 100); do
            REAL_STOP="$(printf '%s' "$REAL_READ" | jq -r '.stop_reason // empty' 2>/dev/null)"
            [ -n "$REAL_STOP" ] && break
            sleep 0.2
            REAL_READ="$(rpc_q "$MAIN_STATE" agent.read "$(jq -n --arg id "$REAL_SID" '{session_id:$id,cursor:0}')")"
          done
          REAL_REPLY="$(printf '%s' "$REAL_READ" | jq -r '.text // ""' 2>/dev/null)"
          # The reply is model output, so it must not be able to carry the
          # caller's token into the log or the results file. Shell
          # substitution keeps the value out of any process argv.
          REAL_READ_SAFE="$REAL_READ"
          if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            REAL_REPLY="${REAL_REPLY//"$ANTHROPIC_AUTH_TOKEN"/[redacted]}"
            REAL_STOP="${REAL_STOP//"$ANTHROPIC_AUTH_TOKEN"/[redacted]}"
            REAL_READ_SAFE="${REAL_READ_SAFE//"$ANTHROPIC_AUTH_TOKEN"/[redacted]}"
          fi
          REAL_REPLY="$(printf '%s' "$REAL_REPLY" | tr '\n\t' '  ')"
          printf '%s\n' "$REAL_READ_SAFE" >"$WORK/real-read.json"
          printf '      E1 reply: %s (stop_reason=%s)\n' "$REAL_REPLY" "${REAL_STOP:-unknown}" >&2
          pass E1 "a real ACP model turn ran through the runtime launcher" "stop_reason=${REAL_STOP:-unknown} reply=${REAL_REPLY}"
        else
          fail E1 "a real ACP model turn ran through the runtime launcher" "$REAL_READ"
        fi
        rpc_q "$MAIN_STATE" agent.stop "$(jq -n --arg id "$REAL_SID" '{session_id:$id}')" >/dev/null 2>&1 || true
      else
        fail E1 "a real ACP model turn ran through the runtime launcher" "$REAL_OUT"
      fi
    else
      fail E1 "a real ACP model turn ran through the runtime launcher" "real node did not attach"
    fi
    stop_pid "$REAL_NODE_PID"
    # Section D's "revoke leaves no credential" counts every runtime
    # credential on the primary, so the real node's credential must be dropped
    # here. Otherwise this opt-in machine would keep the count at one.
    rpc_main runtime.revoke "$(jq -n --arg r "$REAL_RID" '{runtime_id:$r,reason:"harness"}')" >/dev/null 2>&1 || true
  else
    fail E1 "a real ACP model turn ran through the runtime launcher" "pair failed: $REAL_PAIR"
  fi
else
  skip E1 "a real ACP model turn ran through the runtime launcher" "$E1_REASON"
fi

# ---------------------------------------------------------------------------
# D. Revoke and drain
# ---------------------------------------------------------------------------
printf '\n== (d). revoke and drain ==\n'

REVOKE="$(rpc_main runtime.revoke "$(jq -n --arg r "$MAIN_RID" '{runtime_id:$r,reason:"harness"}')")"
if printf '%s' "$REVOKE" | jq -e '.revoked == 1' >/dev/null 2>&1; then
  pass D1 "revoke drops the runtime credential"
else
  fail D1 "revoke drops the runtime credential" "$REVOKE"
fi
D2_OK=0
for _i in $(seq 1 100); do
  if ! kill -0 "$NODE_PID" 2>/dev/null; then D2_OK=1; break; fi
  sleep 0.1
done
if [ "$D2_OK" = "1" ] && grep -Fiq 'revoked' "$WORK/main-node3.log"; then
  pass D2 "the revoked node stops serving"
else
  fail D2 "the revoked node stops serving" "$(tail -n 20 "$WORK/main-node3.log")"
fi
eq D3 "revoke leaves no credential" "0" "$(rpc_main runtime.status '{}' | jq -r '.credentials')"
D4_PROBE="$("$HOST_BIN" machine probe --state-dir "$MAIN_STATE" --id "$MAIN_MID" 2>&1 || true)"
if printf '%s' "$D4_PROBE" | grep -Fq 'status=online'; then
  fail D4 "a revoked machine cannot be probed as online" "$D4_PROBE"
else
  pass D4 "a revoked machine cannot be probed as online"
fi

# Re-pair and drain. Draining ends the serving node cleanly with exit 0.
DRAIN_CODE="$(new_code "$MAIN_STATE")" || DRAIN_CODE=""
DRAIN_PAIR="$(node_pair "$WORK/node-home" "$NODE_BASE" "$MAIN_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$DRAIN_CODE")"
DRAIN_PAIR_RC=$?
if [ "$DRAIN_PAIR_RC" -eq 0 ]; then
  pass D5 "a revoked runtime can be paired again with a new code"
else
  fail D5 "a revoked runtime can be paired again with a new code" "$DRAIN_PAIR"
fi
node_serve "$WORK/node-home" "$NODE_BASE" "$MAIN_RID" "$MAIN_ADDR" "$PKI/ca.pem" "$PIN1" "$WORK/main-node3.log"
NODE_PID="$LAST_PID"
if wait_attached "$MAIN_STATE" "$MAIN_MID" 200; then
  pass D6 "the re-paired node attaches again"
else
  fail D6 "the re-paired node attaches again" "$(tail -n 20 "$WORK/main-node3.log")"
fi
DRAIN="$(rpc_main runtime.drain '{}')"
if printf '%s' "$DRAIN" | jq -e '.draining == true' >/dev/null 2>&1; then
  pass D7 "drain is accepted by the primary"
else
  fail D7 "drain is accepted by the primary" "$DRAIN"
fi
D8_OK=0
for _i in $(seq 1 100); do
  if ! kill -0 "$NODE_PID" 2>/dev/null; then D8_OK=1; break; fi
  sleep 0.1
done
if [ "$D8_OK" = "1" ] && grep -Fq 'drained' "$WORK/main-node3.log"; then
  pass D8 "the drained node exits cleanly"
else
  fail D8 "the drained node exits cleanly" "$(tail -n 20 "$WORK/main-node3.log")"
fi

# ---------------------------------------------------------------------------
# F. Secret redaction across audits and logs
# ---------------------------------------------------------------------------
printf '\n== (f). secret redaction ==\n'
MAIN_AUDIT="$(rpc_main runtime.audit '{}' | jq -r '.audit_text // ""')"
ALL_AUDIT_TEXT="$MAIN_AUDIT"
ALL_LOGS=""
for log in "$WORK"/*.log; do
  [ -f "$log" ] && ALL_LOGS="$ALL_LOGS$(cat "$log")"$'\n'
done
SECRET_FAIL=0
for code in ${CODES[@]+"${CODES[@]}"}; do
  if printf '%s' "$ALL_AUDIT_TEXT$ALL_LOGS" | grep -Fq -- "$code"; then
    SECRET_FAIL=1
    fail F1 "no pairing code appears in any audit or log" "a code leaked"
    break
  fi
done
[ "$SECRET_FAIL" = "0" ] && pass F1 "no pairing code appears in any audit or log"
if [ -n "$NODE_TOKEN" ]; then
  if printf '%s' "$ALL_AUDIT_TEXT$ALL_LOGS" | grep -Fq -- "$NODE_TOKEN"; then
    fail F2 "the node bearer token never appears in audit or logs" "token leaked"
  else
    pass F2 "the node bearer token never appears in audit or logs"
  fi
else
  skip F2 "the node bearer token never appears in audit or logs" "no token available"
fi
if printf '%s' "$MAIN_AUDIT" | grep -Fq -- 'approved-run' \
  || printf '%s' "$MAIN_AUDIT" | grep -Fq -- 'pty-ok'; then
  fail F3 "command text and file content stay out of audit" "argv/content leaked"
else
  pass F3 "command text and file content stay out of audit"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
PASS_COUNT="$(awk -F'\t' '$3=="PASS"' "$RESULTS" | wc -l | tr -d ' ')"
SKIP_COUNT="$(awk -F'\t' '$3=="SKIP"' "$RESULTS" | wc -l | tr -d ' ')"
FAIL_COUNT="$(awk -F'\t' '$3=="FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
printf 'SUMMARY: %s passed, %s skipped, %s failed\n' "$PASS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '\nfailed rows:\n'
  awk -F'\t' '$3=="FAIL" { printf "  %s  %s  %s\n", $1, $2, $4 }' "$RESULTS"
  exit 1
fi
exit 0
