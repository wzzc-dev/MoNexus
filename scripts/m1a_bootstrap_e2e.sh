#!/usr/bin/env bash
# MoNexus M1a-4 bootstrap E2E.
#
# Exercises the local M1a closed loop without a real model, logged-in gh or
# the owner's SSH configuration:
#   Project -> local git workspace -> isolated worktree -> Project membership
#   -> Chat + AgentSession(worktree_id) -> mock ACP reads AGENTS.md/docs,
#   edits a file, runs a check -> visible transcript + worktree-scoped Git
#   review -> commit/push to a throwaway bare remote -> host restart
#   -> ended(host_restarted) + one system boundary + same-Chat handoff.
# A second independent workspace repeats the path with a MoUI-like layout.
#
# Requirements: Linux, bash, jq, git, node, sh. The host binary is reused from
# _build/native or built with moon when missing. All state, HOME, repositories
# and remotes live under a throwaway work directory. No network or SSH is used.
#
# Usage:
#   bash scripts/m1a_bootstrap_e2e.sh
#   MONEXUS_M1A_E2E_KEEP=1 bash scripts/m1a_bootstrap_e2e.sh
#
# Every check prints PASS or FAIL. The final line is
# `SUMMARY passed=N failed=N`. A failing run keeps and prints its work
# directory; a passing run removes it.
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME:?HOME is required to run the build toolchain}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/monexus-m1a-e2e.XXXXXX")"
mkdir -p "$WORK/home"
export HOME="$WORK/home"

STATE="$WORK/state"
HOST_LOG="$STATE/.host.log"
RPC_CLIENT="$ROOT/tests/runtime/rpc_client.mjs"
MOCK_ACP="$ROOT/tests/agent/mock_acp_agent.mjs"
HOST_PID=""
RPC_SEQ_FILE="$WORK/rpc-seq"
printf '0\n' >"$RPC_SEQ_FILE"
PASS=0
FAIL=0

pass() { # id item [note]
  PASS=$((PASS + 1))
  printf 'PASS  %-4s %s%s\n' "$1" "$2" "${3:+ [$3]}"
}

fail() { # id item [note]
  FAIL=$((FAIL + 1))
  printf 'FAIL  %-4s %s%s\n' "$1" "$2" "${3:+ [$3]}"
  if [ -n "${3:-}" ]; then printf '        %s\n' "$3" >&2; fi
}

summary() {
  printf '\nSUMMARY passed=%s failed=%s\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

stop_host() {
  local pid="$HOST_PID" i=0
  HOST_PID=""
  if [ -z "$pid" ]; then
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 120 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_host
  if [ "$FAIL" -gt 0 ] || [ "${MONEXUS_M1A_E2E_KEEP:-0}" = "1" ]; then
    printf '\nwork directory kept: %s\n' "$WORK" >&2
    printf 'host log: %s\n' "$HOST_LOG" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

die() { # id item [note]
  fail "$1" "$2" "${3:-}"
  summary || true
  exit 1
}

start_host() {
  mkdir -p "$STATE"
  "$HOST_BIN" serve --state-dir "$STATE" --heartbeat-ms 60000 \
    >>"$HOST_LOG" 2>&1 &
  HOST_PID=$!
  local i=0
  while [ "$i" -lt 200 ]; do
    if "$HOST_BIN" status --state-dir "$STATE" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

rpc() { # method params-json-without-client_request_id
  local method="$1" params="$2" id with_id out rc seq
  seq="$(cat "$RPC_SEQ_FILE" 2>/dev/null || printf '0')"
  seq=$((seq + 1))
  printf '%s\n' "$seq" >"$RPC_SEQ_FILE"
  id="m1a-$$-$seq"
  with_id="$(printf '%s' "$params" | jq -c --arg id "$id" \
    '. + {client_request_id: $id}' 2>/dev/null)" || {
    printf 'invalid params JSON for %s: %s\n' "$method" "$params"
    return 2
  }
  out="$(node "$RPC_CLIENT" call "$STATE" "$id" "$method" "$with_id" 2>&1)"
  rc=$?
  printf '%s' "$out"
  return "$rc"
}

jq_true() { # json [jq args...] filter
  local json="$1"
  shift
  printf '%s' "$json" | jq -e "$@" >/dev/null 2>&1
}

jq_raw() { # json [jq args...] filter
  local json="$1"
  shift
  printf '%s' "$json" | jq -r "$@" 2>/dev/null
}

check_eq() { # id item expected actual
  if [ "$3" = "$4" ]; then
    pass "$1" "$2" "$4"
  else
    fail "$1" "$2" "expected '$3', got '$4'"
  fi
}

check_contains() { # id item needle haystack
  if printf '%s' "$4" | grep -Fq -- "$3"; then
    pass "$1" "$2"
  else
    fail "$1" "$2" "missing '$3'"
  fi
}

check_not_contains() { # id item needle haystack
  if printf '%s' "$4" | grep -Fq -- "$3"; then
    fail "$1" "$2" "unexpected '$3'"
  else
    pass "$1" "$2"
  fi
}

seed_repo() { # repo target-relative-path
  local repo="$1" target="$2" target_dir
  target_dir="$(dirname "$target")"
  mkdir -p "$repo"
  git -C "$repo" -c init.defaultBranch=main init -q
  git -C "$repo" config user.email "m1a-e2e@example.invalid"
  git -C "$repo" config user.name "M1a E2E"
  mkdir -p "$repo/docs" "$repo/$target_dir"
  cat >"$repo/AGENTS.md" <<'EOF'
# AGENTS.md

Keep this fixture small. The mock agent must read this file before editing.
EOF
  cat >"$repo/docs/overview.md" <<'EOF'
# Fixture overview

This document proves the mock agent can read project docs from the runtime cwd.
EOF
  printf 'baseline content\n' >"$repo/$target"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "seed fixture"
}

poll_chat_read() { # chat_id cursor needle tries
  local chat="$1" cursor="$2" needle="$3" tries="${4:-200}" i=0 resp text
  CHAT_READ_RESP=""
  while [ "$i" -lt "$tries" ]; do
    resp="$(rpc chat.read \
      "$(jq -c -n --arg chat "$chat" --argjson cursor "$cursor" \
        '{chat_id: $chat, cursor: $cursor}')")" || resp=""
    if [ -n "$resp" ]; then
      CHAT_READ_RESP="$resp"
      text="$(jq_raw "$resp" '.result.text // ""')"
      if printf '%s' "$text" | grep -Fq -- "$needle"; then
        return 0
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

poll_chat_messages() { # chat_id needle tries
  local chat="$1" needle="$2" tries="${3:-200}" i=0 resp
  CHAT_MESSAGES_RESP=""
  while [ "$i" -lt "$tries" ]; do
    resp="$(rpc chat.messages \
      "$(jq -c -n --arg chat "$chat" \
        '{chat_id: $chat, after: "", limit: 100}')")" || resp=""
    if [ -n "$resp" ]; then
      CHAT_MESSAGES_RESP="$resp"
      if jq_true "$resp" --arg needle "$needle" \
        'any(.result.messages[]; ((.body // "") | contains($needle)))'; then
        return 0
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

printf '== environment ==\n'
if [ ! -x "$ROOT/scripts/native_packages.sh" ]; then
  die E00 "repository layout" "missing scripts/native_packages.sh"
fi
if [ "$(uname -s)" != "Linux" ]; then
  printf 'NOTE  macOS is not the CI target; this script is Linux-first.\n'
fi

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  for candidate in "$REAL_HOME"/.nvm/versions/node/*/bin/node \
    /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ]; then
      NODE_BIN="$candidate"
      break
    fi
  done
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  die E01 "node is available" "install node or put it on PATH"
fi
export PATH="$(dirname "$NODE_BIN"):$PATH"
pass E01 "node is available" "$NODE_BIN"

if ! command -v jq >/dev/null 2>&1; then
  die E02 "jq is available" "jq is required for RPC assertions"
fi
if ! command -v git >/dev/null 2>&1; then
  die E03 "git is available" "git is required for the worktree fixture"
fi
pass E02 "jq and git are available"

HOST_BIN="$(find "$ROOT/_build/native" -type f \
  -path '*/build/monexus/host/host.exe' 2>/dev/null | head -n 1)"
if [ -z "$HOST_BIN" ]; then
  if ! command -v moon >/dev/null 2>&1; then
    die E04 "monexus-host binary" "build native packages with moon first"
  fi
  packages="$(bash "$ROOT/scripts/native_packages.sh")" || \
    die E04 "monexus-host binary" "native_packages.sh failed"
  (cd "$ROOT" && HOME="$REAL_HOME" moon build --target native $packages) || \
    die E04 "monexus-host binary" "moon build failed"
  HOST_BIN="$(find "$ROOT/_build/native" -type f \
    -path '*/build/monexus/host/host.exe' 2>/dev/null | head -n 1)"
fi
if [ -z "$HOST_BIN" ] || [ ! -x "$HOST_BIN" ]; then
  die E04 "monexus-host binary is built" "$HOST_BIN"
fi
pass E04 "monexus-host binary is built" "$HOST_BIN"
check_eq E05 "HOME points at the throwaway directory" "$WORK/home" "$HOME"

if ! start_host; then
  if [ -f "$HOST_LOG" ]; then sed -n '1,120p' "$HOST_LOG" >&2; fi
  die E06 "host starts on the throwaway state dir" "$STATE"
fi
pass E06 "host starts on the throwaway state dir"
pass E07 "host state dir is isolated" "$STATE"

# ---------------------------------------------------------------------------
printf '\n== A. MoNexus-style bootstrap closed loop ==\n'
# ---------------------------------------------------------------------------
REPO_A="$WORK/nexus-repo"
WT_A="$WORK/nexus-wt"
REMOTE_A="$WORK/nexus-remote.git"
PROMPT_A="Read AGENTS.md and docs, update notes.txt, and run the check."
PROMPT_A2="Continue the same repository after the restart."
BOT_A="bot_00000000000000000000000001"
AGENT_A="agw_00000000000000000000000001"
CHAT_A="cht_00000000000000000000000001"
BOT_NAME_A="Nexus Builder"
AGENT_NAME_A="Nexus Mock Agent"
BRANCH_A="m1a/nexus-bootstrap"

if seed_repo "$REPO_A" "notes.txt" && git init --bare -q "$REMOTE_A"; then
  pass A00 "temp git workspace and bare remote" "$REPO_A"
else
  die A00 "temp git workspace and bare remote" "$REPO_A"
fi

BOT_JSON_A="$(jq -c -n --arg id "$BOT_A" --arg name "$BOT_NAME_A" \
  '{id: $id, org_id: "org_local", name: $name, create_policy: "auto",
    software_allowlist: ["mock-agent"], state: "active"}')"
PROJECT_RESP="$(rpc project.create \
  "$(jq -c -n --arg name "M1a Nexus bootstrap" \
    '{name: $name, repo_url: "", default_branch: "main", verify: []}')")" || \
  die A01 "project.create" "$PROJECT_RESP"
PROJECT_A="$(jq_raw "$PROJECT_RESP" '.result.project.id // ""')"
if [ -n "$PROJECT_A" ]; then
  pass A01 "project.create returns a Project id" "$PROJECT_A"
else
  die A01 "project.create returns a Project id" "$PROJECT_RESP"
fi

BOT_RESP="$(rpc bot.create \
  "$(jq -c -n --argjson bot "$BOT_JSON_A" \
    '{bot: $bot, actor: "owner", source: "m1a-e2e"}')")" || \
  die A02 "bot.create" "$BOT_RESP"
if jq_true "$BOT_RESP" --arg id "$BOT_A" --arg name "$BOT_NAME_A" \
  '.result.bot.id == $id and .result.bot.name == $name and
   .result.bot.state == "active"'; then
  pass A02 "bot.create returns the named active Bot" "$BOT_NAME_A"
else
  die A02 "bot.create returns the named active Bot" "$BOT_RESP"
fi

BINDING_A="$(jq -c -n --arg command "$NODE_BIN" --arg script "$MOCK_ACP" \
  --arg file "notes.txt" \
  '{software_id: "mock-agent", adapter_id: "mock-acp", launch_kind: "acp",
    command: $command,
    args: [$script, "--cwd", "--m1a-demo", "--m1a-file", $file],
    model_profile: "test", tools: [], skills: [], version: "0.1.0-e2e",
    hash: "sha256:m1a-e2e-mock"}')"
AGENT_JSON_A="$(jq -c -n --arg id "$AGENT_A" --arg bot "$BOT_A" \
  --arg name "$AGENT_NAME_A" --argjson binding "$BINDING_A" \
  '{id: $id, org_id: "org_local", bot_id: $bot, name: $name,
    specialty: "", tags: [], runtime_binding: $binding,
    permission_scope: [], state: "active", created_at: "", updated_at: "",
    retired_at: ""}')"
AGENT_RESP="$(rpc bot.agent.create \
  "$(jq -c -n --arg bot "$BOT_A" --argjson agent "$AGENT_JSON_A" \
    '{bot_id: $bot, agent: $agent, actor: "owner", source: "m1a-e2e"}')")" || \
  die A03 "bot.agent.create" "$AGENT_RESP"
if jq_true "$AGENT_RESP" --arg id "$AGENT_A" \
  '.result.agent.id == $id and .result.agent.state == "active"'; then
  pass A03 "bot.agent.create creates an active mock Agent" "$AGENT_A"
else
  die A03 "bot.agent.create creates an active mock Agent" "$AGENT_RESP"
fi

WS_RESP="$(rpc workspace.open \
  "$(jq -c -n --arg root "$REPO_A" \
    '{target: "local", root: $root}')")" || \
  die A04 "workspace.open" "$WS_RESP"
WS_A="$(jq_raw "$WS_RESP" '.result.workspace.id // ""')"
if [ -n "$WS_A" ] && jq_true "$WS_RESP" --arg root "$REPO_A" \
  '.result.workspace.root == $root and .result.workspace.is_git == true'; then
  pass A04 "workspace.open registers the temp git workspace" "$WS_A"
else
  die A04 "workspace.open registers the temp git workspace" "$WS_RESP"
fi

WT_RESP="$(rpc worktree.create \
  "$(jq -c -n --arg ws "$WS_A" --arg branch "$BRANCH_A" --arg path "$WT_A" \
    '{workspace_id: $ws, branch: $branch, path: $path, base: ""}')")" || \
  die A05 "worktree.create" "$WT_RESP"
WT_A_ID="$(jq_raw "$WT_RESP" '.result.worktree.id // ""')"
WT_A_PATH="$(jq_raw "$WT_RESP" '.result.worktree.path // ""')"
WT_A_BRANCH="$(jq_raw "$WT_RESP" '.result.worktree.branch // ""')"
if [ -n "$WT_A_ID" ] && jq_true "$WT_RESP" --arg path "$WT_A" \
  '.result.worktree.path == $path and .result.worktree.state == "ready"'; then
  pass A05 "worktree.create makes an isolated ready worktree" "$WT_A_PATH"
else
  die A05 "worktree.create makes an isolated ready worktree" "$WT_RESP"
fi
if [ -f "$WT_A_PATH/AGENTS.md" ] && [ -f "$WT_A_PATH/notes.txt" ]; then
  pass A06 "worktree has the seeded repository files"
else
  fail A06 "worktree has the seeded repository files" "$WT_A_PATH"
fi

MEM_RESP="$(rpc project.membership.add \
  "$(jq -c -n --arg project "$PROJECT_A" --arg bot "$BOT_A" \
    '{project_id: $project, bot_id: $bot, actor: "owner"}')")" || \
  die A07 "project.membership.add" "$MEM_RESP"
if jq_true "$MEM_RESP" --arg project "$PROJECT_A" --arg bot "$BOT_A" \
  '.result.membership.project_id == $project and
   .result.membership.bot_id == $bot and
   .result.membership.state == "active" and
   .result.membership.access == []'; then
  pass A07 "Bot joins the Project membership with access=[]"
else
  fail A07 "Bot joins the Project membership with access=[]" "$MEM_RESP"
fi

MEM_LIST_RESP="$(rpc project.membership.list \
  "$(jq -c -n --arg project "$PROJECT_A" '{project_id: $project}')")" || \
  die A08 "project.membership.list" "$MEM_LIST_RESP"
if jq_true "$MEM_LIST_RESP" --arg project "$PROJECT_A" --arg bot "$BOT_A" \
  '[.result.memberships[] | select(.project_id == $project and
    .bot_id == $bot and .state == "active" and .access == [])] | length == 1'; then
  pass A08 "project.membership.list returns the Bot by Project"
else
  fail A08 "project.membership.list returns the Bot by Project" "$MEM_LIST_RESP"
fi

MEM_ALL_RESP="$(rpc project.membership.list '{}')" || \
  die A09 "project.membership.list all" "$MEM_ALL_RESP"
if jq_true "$MEM_ALL_RESP" --arg bot "$BOT_A" \
  '[.result.memberships[] | select(.bot_id == $bot)] | length == 1'; then
  pass A09 "project.membership.list without project filters all active members"
else
  fail A09 "project.membership.list without project filters all active members" "$MEM_ALL_RESP"
fi

BOT_GET_RESP="$(rpc bot.get \
  "$(jq -c -n --arg bot "$BOT_A" '{bot_id: $bot}')")" || \
  die A10 "bot.get" "$BOT_GET_RESP"
if jq_true "$BOT_GET_RESP" --arg name "$BOT_NAME_A" \
  '.result.bot.name == $name'; then
  pass A10 "membership bot_id resolves to the Bot name" "$BOT_NAME_A"
else
  fail A10 "membership bot_id resolves to the Bot name" "$BOT_GET_RESP"
fi

CHAT_JSON_A="$(jq -c -n --arg id "$CHAT_A" --arg project "$PROJECT_A" \
  '{id: $id, org_id: "org_local", title: "M1a Nexus bootstrap",
    project_id: $project, summary_ref: "", state: "active",
    created_at: "", updated_at: "", archived_at: ""}')"
CHAT_RESP="$(rpc chat.create \
  "$(jq -c -n --argjson chat "$CHAT_JSON_A" --arg bot "$BOT_A" \
    '{chat: $chat, bot_id: $bot, participant_bot_ids: [$bot]}')")" || \
  die A11 "chat.create" "$CHAT_RESP"
if jq_true "$CHAT_RESP" --arg id "$CHAT_A" --arg project "$PROJECT_A" \
  '.result.chat.id == $id and .result.chat.project_id == $project'; then
  pass A11 "chat.create makes a Project Chat"
else
  die A11 "chat.create makes a Project Chat" "$CHAT_RESP"
fi

SESSION_RESP="$(rpc chat.agent_session.start \
  "$(jq -c -n --arg chat "$CHAT_A" --arg agent "$AGENT_A" --arg ws "$WS_A" \
    --arg root "$WT_A" --arg worktree "$WT_A_ID" \
    '{chat_id: $chat, agent_id: $agent, workspace_id: $ws,
      workspace_root: $root, worktree_id: $worktree}')")" || \
  die A12 "chat.agent_session.start" "$SESSION_RESP"
OLD_SID="$(jq_raw "$SESSION_RESP" '.result.session.id // ""')"
if [ -n "$OLD_SID" ] && jq_true "$SESSION_RESP" --arg root "$WT_A" \
  --arg worktree "$WT_A_ID" \
  '.result.session.state == "active" and
   .result.session.workspace_root == $root and
   .result.session.worktree_id == $worktree'; then
  pass A12 "AgentSession starts in the selected worktree" "$OLD_SID"
else
  die A12 "AgentSession starts in the selected worktree" "$SESSION_RESP"
fi

FIRST_SEND_A="$(rpc chat.send \
  "$(jq -c -n --arg chat "$CHAT_A" --arg text "$PROMPT_A" \
    '{chat_id: $chat, text: $text, actor: "owner"}')")" || \
  die A12B "first chat.send" "$FIRST_SEND_A"
if jq_true "$FIRST_SEND_A" --arg chat "$CHAT_A" --arg text "$PROMPT_A" \
  '.result.message.chat_id == $chat and .result.message.body == $text and
   .result.session.state == "active"'; then
  pass A12B "first chat.send creates the visible user message"
else
  die A12B "first chat.send creates the visible user message" "$FIRST_SEND_A"
fi

if poll_chat_read "$CHAT_A" 0 "M1A-VALIDATE: ok" 300; then
  pass A13 "mock ACP reads AGENTS.md, docs, edits and validates"
else
  fail A13 "mock ACP reads AGENTS.md, docs, edits and validates"
fi
READ_A="$(rpc chat.read \
  "$(jq -c -n --arg chat "$CHAT_A" '{chat_id: $chat, cursor: 0}')")" || \
  READ_A=""
TEXT_A="$(jq_raw "$READ_A" '.result.text // ""')"
CURSOR_A="$(jq_raw "$READ_A" '.result.cursor // 0')"
if jq_true "$READ_A" --arg cwd "$WT_A_PATH" \
  '(.result.text | contains("CWD=" + $cwd)) and
   (.result.text | contains("M1A-CWD=" + $cwd)) and
   (.result.text | contains("M1A-AGENTS-READ")) and
   (.result.text | contains("M1A-DOCS-READ=docs/overview.md")) and
   (.result.text | contains("M1A-EDIT=notes.txt")) and
   (.result.text | contains("M1A-VALIDATE: ok"))'; then
  pass A14 "runtime cwd equals worktree.path and the file/check markers are visible" "$WT_A_PATH"
else
  fail A14 "runtime cwd equals worktree.path and the file/check markers are visible" "$TEXT_A"
fi
if [ "$CURSOR_A" -gt 0 ] 2>/dev/null; then
  pass A15 "chat.read cursor advances after the first turn" "$CURSOR_A"
else
  fail A15 "chat.read cursor advances after the first turn" "$CURSOR_A"
fi

if poll_chat_messages "$CHAT_A" "M1A-VALIDATE: ok" 300; then
  pass A16 "visible Chat transcript stores the assistant result"
else
  fail A16 "visible Chat transcript stores the assistant result"
fi
MESSAGES_A="$(rpc chat.messages \
  "$(jq -c -n --arg chat "$CHAT_A" \
    '{chat_id: $chat, after: "", limit: 100}')")" || MESSAGES_A=""
if jq_true "$MESSAGES_A" --arg prompt "$PROMPT_A" --arg sid "$OLD_SID" \
  '([.result.messages[] | select(.role == "user" and .body == $prompt)] |
     length) == 1 and
   ([.result.messages[] | select(.role == "assistant" and
      .agent_session_id == $sid and (.body | contains("M1A-VALIDATE: ok")))] |
    length) == 1'; then
  pass A17 "chat.messages contains the user prompt and one assistant turn"
else
  fail A17 "chat.messages contains the user prompt and one assistant turn" "$MESSAGES_A"
fi
OLD_ASSIST_BODY="$(jq_raw "$MESSAGES_A" --arg sid "$OLD_SID" \
  '[.result.messages[] | select(.role == "assistant" and
     .agent_session_id == $sid)] | last | .body // ""')"

WT_STATUS="$(rpc workspace.gitStatus \
  "$(jq -c -n --arg ws "$WS_A" --arg worktree "$WT_A_ID" \
    '{workspace_id: $ws, worktree_id: $worktree}')")" || WT_STATUS=""
if jq_true "$WT_STATUS" --arg path "notes.txt" \
  '[.result.git_status.changes[] | select(.path == $path)] | length == 1'; then
  pass A18 "worktree gitStatus shows only the worktree change" "notes.txt"
else
  fail A18 "worktree gitStatus shows only the worktree change" "$WT_STATUS"
fi

MAIN_STATUS="$(rpc workspace.gitStatus \
  "$(jq -c -n --arg ws "$WS_A" '{workspace_id: $ws}')")" || MAIN_STATUS=""
if jq_true "$MAIN_STATUS" \
  '.result.git_status.is_git == true and
   (.result.git_status.changes | length) == 0'; then
  pass A19 "main workspace gitStatus stays clean"
else
  fail A19 "main workspace gitStatus stays clean" "$MAIN_STATUS"
fi

WT_DIFF="$(rpc workspace.gitDiff \
  "$(jq -c -n --arg ws "$WS_A" --arg worktree "$WT_A_ID" \
    '{workspace_id: $ws, worktree_id: $worktree, path: "notes.txt",
      cached: false, range: ""}')")" || WT_DIFF=""
if jq_true "$WT_DIFF" '.result.git_diff.text | contains("M1A-DEMO-EDIT")'; then
  pass A20 "worktree gitDiff contains the mock edit"
else
  fail A20 "worktree gitDiff contains the mock edit" "$WT_DIFF"
fi

MAIN_DIFF="$(rpc workspace.gitDiff \
  "$(jq -c -n --arg ws "$WS_A" \
    '{workspace_id: $ws, path: "notes.txt", cached: false, range: ""}')")" || \
  MAIN_DIFF=""
if jq_true "$MAIN_DIFF" \
  '(.result.git_diff.text | contains("M1A-DEMO-EDIT")) | not'; then
  pass A21 "main workspace gitDiff does not contain the worktree edit"
else
  fail A21 "main workspace gitDiff does not contain the worktree edit" "$MAIN_DIFF"
fi

if grep -Fq "M1A-DEMO-EDIT" "$WT_A_PATH/notes.txt" &&
  ! grep -Fq "M1A-DEMO-EDIT" "$REPO_A/notes.txt"; then
  pass A22 "filesystem edit exists only under the worktree"
else
  fail A22 "filesystem edit exists only under the worktree"
fi

BASE_HEAD_A="$(git -C "$REPO_A" rev-parse HEAD 2>/dev/null || true)"
if git -C "$WT_A_PATH" add -A &&
  git -C "$WT_A_PATH" -c user.email="m1a-e2e@example.invalid" \
    -c user.name="M1a E2E" commit -qm "M1a mock edit" 2>/dev/null; then
  pass A23 "worktree commit succeeds"
else
  fail A23 "worktree commit succeeds"
fi
WT_HEAD_A="$(git -C "$WT_A_PATH" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$WT_HEAD_A" ] &&
  git -C "$WT_A_PATH" push -q "$REMOTE_A" \
    "HEAD:refs/heads/$WT_A_BRANCH" 2>/dev/null; then
  pass A24 "worktree pushes to the throwaway bare remote" "$WT_A_BRANCH"
else
  fail A24 "worktree pushes to the throwaway bare remote" "$WT_A_BRANCH"
fi
REMOTE_HEAD_A="$(git ls-remote "$REMOTE_A" \
  "refs/heads/$WT_A_BRANCH" 2>/dev/null | awk '{print $1}')"
if [ -n "$WT_HEAD_A" ] && [ "$REMOTE_HEAD_A" = "$WT_HEAD_A" ]; then
  pass A25 "bare remote branch head equals the worktree HEAD" "$WT_HEAD_A"
else
  fail A25 "bare remote branch head equals the worktree HEAD" \
    "worktree=$WT_HEAD_A remote=$REMOTE_HEAD_A"
fi
MAIN_HEAD_A="$(git -C "$REPO_A" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$BASE_HEAD_A" ] && [ "$BASE_HEAD_A" = "$MAIN_HEAD_A" ]; then
  pass A26 "main workspace HEAD is unchanged by the worktree commit"
else
  fail A26 "main workspace HEAD is unchanged by the worktree commit" \
    "before=$BASE_HEAD_A after=$MAIN_HEAD_A"
fi

CHAT_GET_A="$(rpc chat.get \
  "$(jq -c -n --arg chat "$CHAT_A" '{chat_id: $chat}')")" || CHAT_GET_A=""
if jq_true "$CHAT_GET_A" --arg sid "$OLD_SID" \
  '.result.active_agent_session.id == $sid'; then
  pass A27 "chat.get shows the active AgentSession before restart" "$OLD_SID"
else
  fail A27 "chat.get shows the active AgentSession before restart" "$CHAT_GET_A"
fi
if [ "$CURSOR_A" -gt 0 ] 2>/dev/null; then
  pass A28 "pre-restart cursor captured" "$CURSOR_A"
else
  fail A28 "pre-restart cursor captured" "$CURSOR_A"
fi

OLD_PID="$HOST_PID"
stop_host
if ! kill -0 "$OLD_PID" 2>/dev/null; then
  pass A29 "host stops cleanly before restart" "pid=$OLD_PID"
else
  fail A29 "host stops cleanly before restart" "pid=$OLD_PID"
fi
if start_host; then
  pass A30 "host restarts on the same state dir" "$STATE"
else
  if [ -f "$HOST_LOG" ]; then sed -n '1,160p' "$HOST_LOG" >&2; fi
  die A30 "host restarts on the same state dir" "$STATE"
fi

CHAT_GET_RESTART="$(rpc chat.get \
  "$(jq -c -n --arg chat "$CHAT_A" '{chat_id: $chat}')")" || \
  CHAT_GET_RESTART=""
if jq_true "$CHAT_GET_RESTART" '.result.active_agent_session == null'; then
  pass A31 "chat.get has no active AgentSession after restart"
else
  fail A31 "chat.get has no active AgentSession after restart" "$CHAT_GET_RESTART"
fi

EVENTS_RESTART="$(rpc events.list \
  "$(jq -c -n '{since: 0, limit: 500}')")" || EVENTS_RESTART=""
if jq_true "$EVENTS_RESTART" --arg sid "$OLD_SID" \
  '[.result.events[] | select(.type == "chat.agent_session.ended" and
    .payload.agent_session_id == $sid)] | length == 1'; then
  pass A32 "restart appends chat.agent_session.ended for the old session" "$OLD_SID"
else
  fail A32 "restart appends chat.agent_session.ended for the old session" "$EVENTS_RESTART"
fi
if jq_true "$EVENTS_RESTART" --arg sid "$OLD_SID" \
  '[.result.events[] | select(.type == "chat.agent_session.ended" and
    .payload.agent_session_id == $sid)] | last | .payload.end_reason ==
    "host_restarted" and .payload.record.state == "ended"'; then
  pass A33 "old AgentSession ends with end_reason=host_restarted"
else
  fail A33 "old AgentSession ends with end_reason=host_restarted" "$EVENTS_RESTART"
fi

RESTART_READ="$(rpc chat.read \
  "$(jq -c -n --arg chat "$CHAT_A" --argjson cursor "$CURSOR_A" \
    '{chat_id: $chat, cursor: $cursor}')")" || RESTART_READ=""
if jq_true "$RESTART_READ" --argjson cursor "$CURSOR_A" \
  '.result.cursor == $cursor and .result.text == "" and
   .result.state == "ended"'; then
  pass A34 "chat.read preserves the old cursor after restart" "$CURSOR_A"
else
  fail A34 "chat.read preserves the old cursor after restart" "$RESTART_READ"
fi

RESTART_MESSAGES="$(rpc chat.messages \
  "$(jq -c -n --arg chat "$CHAT_A" \
    '{chat_id: $chat, after: "", limit: 100}')")" || RESTART_MESSAGES=""
if jq_true "$RESTART_MESSAGES" --arg body "$PROMPT_A" \
  '[.result.messages[] | select(.role == "user" and .body == $body)] |
   length == 1'; then
  pass A35 "restart keeps the old user message"
else
  fail A35 "restart keeps the old user message" "$RESTART_MESSAGES"
fi
if [ -n "$OLD_ASSIST_BODY" ] && jq_true "$RESTART_MESSAGES" \
  --arg body "$OLD_ASSIST_BODY" \
  '[.result.messages[] | select(.role == "assistant" and .body == $body)] |
   length == 1'; then
  pass A36 "restart keeps the old assistant message"
else
  fail A36 "restart keeps the old assistant message" "$RESTART_MESSAGES"
fi
if jq_true "$RESTART_MESSAGES" \
  '[.result.messages[] | select(.role == "system" and
    (.body | contains("运行时已中断")))] | length == 1'; then
  pass A37 "restart writes exactly one visible system boundary"
else
  fail A37 "restart writes exactly one visible system boundary" "$RESTART_MESSAGES"
fi

NEW_SESSION_RESP="$(rpc chat.agent_session.start \
  "$(jq -c -n --arg chat "$CHAT_A" --arg agent "$AGENT_A" --arg ws "$WS_A" \
    --arg root "$WT_A" --arg worktree "$WT_A_ID" \
    '{chat_id: $chat, agent_id: $agent, workspace_id: $ws,
      workspace_root: $root, worktree_id: $worktree}')")" || \
  die A38 "same-Chat chat.agent_session.start" "$NEW_SESSION_RESP"
NEW_SID="$(jq_raw "$NEW_SESSION_RESP" '.result.session.id // ""')"
if [ -n "$NEW_SID" ] && jq_true "$NEW_SESSION_RESP" \
  --arg handoff "$OLD_SID" --arg root "$WT_A" --arg worktree "$WT_A_ID" \
  '.result.session.state == "active" and
   .result.session.handoff_from_session_id == $handoff and
   .result.session.workspace_root == $root and
   .result.session.worktree_id == $worktree'; then
  pass A38 "new AgentSession handoff points at the old session" "$OLD_SID -> $NEW_SID"
else
  die A38 "new AgentSession handoff points at the old session" "$NEW_SESSION_RESP"
fi

NEW_SEND_RESP="$(rpc chat.send \
  "$(jq -c -n --arg chat "$CHAT_A" --arg text "$PROMPT_A2" \
    '{chat_id: $chat, text: $text, actor: "owner"}')")" || \
  die A39 "first chat.send on the continued Chat" "$NEW_SEND_RESP"
if jq_true "$NEW_SEND_RESP" --arg sid "$NEW_SID" \
  '.result.session.id == $sid'; then
  pass A39 "first chat.send on the continued Chat succeeds" "$NEW_SID"
else
  fail A39 "first chat.send on the continued Chat succeeds" "$NEW_SEND_RESP"
fi

if poll_chat_read "$CHAT_A" 0 "M1A-HANDOFF-SEEN" 300; then
  pass A40 "continued Chat first send injects the recovery context"
else
  fail A40 "continued Chat first send injects the recovery context"
fi
NEW_READ="$(rpc chat.read \
  "$(jq -c -n --arg chat "$CHAT_A" '{chat_id: $chat, cursor: 0}')")" || \
  NEW_READ=""
NEW_TEXT="$(jq_raw "$NEW_READ" '.result.text // ""')"
HANDOFF_BYTES="$(
  printf '%s' "$NEW_TEXT" | grep -o 'M1A-HANDOFF-BYTES=[0-9][0-9]*' |
    tail -n 1 | cut -d= -f2
)"
if [ -n "$HANDOFF_BYTES" ] && [ "$HANDOFF_BYTES" -gt 0 ] &&
  [ "$HANDOFF_BYTES" -le 8192 ]; then
  pass A41 "injected visible history stays within 8 KiB" "$HANDOFF_BYTES bytes"
else
  fail A41 "injected visible history stays within 8 KiB" "$HANDOFF_BYTES"
fi

if poll_chat_messages "$CHAT_A" "M1A-HANDOFF-SEEN" 300; then
  pass A42 "continued Chat visible transcript records the recovery marker"
else
  fail A42 "continued Chat visible transcript records the recovery marker"
fi
MESSAGES_NEW="$(rpc chat.messages \
  "$(jq -c -n --arg chat "$CHAT_A" \
    '{chat_id: $chat, after: "", limit: 100}')")" || MESSAGES_NEW=""
if jq_true "$MESSAGES_NEW" --arg old "$PROMPT_A" --arg new "$PROMPT_A2" \
  '([.result.messages[] | select(.role == "user" and .body == $old)] |
     length) == 1 and
   ([.result.messages[] | select(.role == "user" and .body == $new)] |
    length) == 1'; then
  pass A43 "history is not lost and the new user message is appended once"
else
  fail A43 "history is not lost and the new user message is appended once" "$MESSAGES_NEW"
fi
if jq_true "$MESSAGES_NEW" \
  '[.result.messages[] | select(.role == "system" and
    (.body | contains("运行时已中断")))] | length == 1'; then
  pass A44 "continued Chat still has exactly one restart boundary"
else
  fail A44 "continued Chat still has exactly one restart boundary" "$MESSAGES_NEW"
fi
if jq_true "$MESSAGES_NEW" --arg sid "$NEW_SID" \
  '[.result.messages[] | select(.role == "assistant" and
    .agent_session_id == $sid)] | length == 1'; then
  pass A45 "continued Chat has one assistant message for the new session"
else
  fail A45 "continued Chat has one assistant message for the new session" "$MESSAGES_NEW"
fi

READ_0="$(rpc chat.read \
  "$(jq -c -n --arg chat "$CHAT_A" '{chat_id: $chat, cursor: 0}')")" || \
  READ_0=""
CURSOR_NEW_0="$(jq_raw "$READ_0" '.result.cursor // 0')"
READ_1="$(rpc chat.read \
  "$(jq -c -n --arg chat "$CHAT_A" --argjson cursor "$CURSOR_NEW_0" \
    '{chat_id: $chat, cursor: $cursor}')")" || READ_1=""
CURSOR_NEW_1="$(jq_raw "$READ_1" '.result.cursor // 0')"
if [ "$CURSOR_NEW_0" -gt 0 ] 2>/dev/null &&
  [ "$CURSOR_NEW_1" -ge "$CURSOR_NEW_0" ] 2>/dev/null; then
  pass A46 "new runtime cursor does not regress" \
    "$CURSOR_NEW_0 -> $CURSOR_NEW_1"
else
  fail A46 "new runtime cursor does not regress" \
    "$CURSOR_NEW_0 -> $CURSOR_NEW_1"
fi

REMOVE_ACTIVE="$(rpc worktree.remove \
  "$(jq -c -n --arg worktree "$WT_A_ID" \
    '{worktree_id: $worktree, force: false}')")" || true
if jq_true "$REMOVE_ACTIVE" \
  '.error.message | contains("non-terminal Chat AgentSession")'; then
  pass A47 "worktree.remove is refused while the continued session is active"
else
  fail A47 "worktree.remove is refused while the continued session is active" \
    "$REMOVE_ACTIVE"
fi

END_RESP="$(rpc chat.agent_session.end \
  "$(jq -c -n --arg session "$NEW_SID" \
    '{session_id: $session, end_reason: "cancelled"}')")" || END_RESP=""
if jq_true "$END_RESP" --arg sid "$NEW_SID" \
  '.result.session.id == $sid and .result.session.state == "ended"'; then
  pass A48 "chat.agent_session.end closes the continued session" "$NEW_SID"
else
  fail A48 "chat.agent_session.end closes the continued session" "$END_RESP"
fi
REMOVE_DONE="$(rpc worktree.remove \
  "$(jq -c -n --arg worktree "$WT_A_ID" \
    '{worktree_id: $worktree, force: false}')")" || REMOVE_DONE=""
if jq_true "$REMOVE_DONE" '.result.ok == true'; then
  pass A49 "worktree.remove succeeds after the session ends"
else
  fail A49 "worktree.remove succeeds after the session ends" "$REMOVE_DONE"
fi

# ---------------------------------------------------------------------------
printf '\n== B. MoUI-like independent workspace ==\n'
# ---------------------------------------------------------------------------
REPO_B="$WORK/moui-like-repo"
WT_B="$WORK/moui-like-wt"
PROMPT_B="Read this project's AGENTS.md and docs, update src/app.txt, then validate."
BOT_B="bot_00000000000000000000000002"
AGENT_B="agw_00000000000000000000000002"
CHAT_B="cht_00000000000000000000000002"
BOT_NAME_B="MoUI-like Builder"
AGENT_NAME_B="MoUI Mock Agent"
BRANCH_B="m1a/moui-like-bootstrap"

if [ "$REPO_B" != "$REPO_A" ] && [[ "$REPO_B" != "$ROOT"/* ]] &&
  seed_repo "$REPO_B" "src/app.txt"; then
  pass B00 "second temp workspace is independent of the repo and first workspace" \
    "$REPO_B"
else
  die B00 "second temp workspace is independent of the repo and first workspace" \
    "$REPO_B"
fi

PROJECT_B_RESP="$(rpc project.create \
  "$(jq -c -n --arg name "MoUI-like bootstrap" \
    '{name: $name, repo_url: "", default_branch: "main", verify: []}')")" || \
  die B01 "second project.create" "$PROJECT_B_RESP"
PROJECT_B="$(jq_raw "$PROJECT_B_RESP" '.result.project.id // ""')"
if [ -n "$PROJECT_B" ]; then
  pass B01 "second Project is created" "$PROJECT_B"
else
  die B01 "second Project is created" "$PROJECT_B_RESP"
fi

BOT_JSON_B="$(jq -c -n --arg id "$BOT_B" --arg name "$BOT_NAME_B" \
  '{id: $id, org_id: "org_local", name: $name, create_policy: "auto",
    software_allowlist: ["mock-agent"], state: "active"}')"
BOT_B_RESP="$(rpc bot.create \
  "$(jq -c -n --argjson bot "$BOT_JSON_B" \
    '{bot: $bot, actor: "owner", source: "m1a-e2e"}')")" || \
  die B02 "second bot.create" "$BOT_B_RESP"
if jq_true "$BOT_B_RESP" --arg id "$BOT_B" --arg name "$BOT_NAME_B" \
  '.result.bot.id == $id and .result.bot.name == $name'; then
  pass B02 "second Bot is created" "$BOT_NAME_B"
else
  die B02 "second Bot is created" "$BOT_B_RESP"
fi

BINDING_B="$(jq -c -n --arg command "$NODE_BIN" --arg script "$MOCK_ACP" \
  --arg file "src/app.txt" \
  '{software_id: "mock-agent", adapter_id: "mock-acp", launch_kind: "acp",
    command: $command,
    args: [$script, "--cwd", "--m1a-demo", "--m1a-file", $file],
    model_profile: "test", tools: [], skills: [], version: "0.1.0-e2e",
    hash: "sha256:m1a-e2e-mock-moui"}')"
AGENT_JSON_B="$(jq -c -n --arg id "$AGENT_B" --arg bot "$BOT_B" \
  --arg name "$AGENT_NAME_B" --argjson binding "$BINDING_B" \
  '{id: $id, org_id: "org_local", bot_id: $bot, name: $name,
    specialty: "", tags: [], runtime_binding: $binding,
    permission_scope: [], state: "active", created_at: "", updated_at: "",
    retired_at: ""}')"
AGENT_B_RESP="$(rpc bot.agent.create \
  "$(jq -c -n --arg bot "$BOT_B" --argjson agent "$AGENT_JSON_B" \
    '{bot_id: $bot, agent: $agent, actor: "owner", source: "m1a-e2e"}')")" || \
  die B03 "second bot.agent.create" "$AGENT_B_RESP"
if jq_true "$AGENT_B_RESP" --arg id "$AGENT_B" \
  '.result.agent.id == $id and .result.agent.state == "active"'; then
  pass B03 "second Agent is created" "$AGENT_B"
else
  die B03 "second Agent is created" "$AGENT_B_RESP"
fi

WS_B_RESP="$(rpc workspace.open \
  "$(jq -c -n --arg root "$REPO_B" \
    '{target: "local", root: $root}')")" || \
  die B04 "second workspace.open" "$WS_B_RESP"
WS_B="$(jq_raw "$WS_B_RESP" '.result.workspace.id // ""')"
if [ -n "$WS_B" ] && jq_true "$WS_B_RESP" --arg root "$REPO_B" \
  '.result.workspace.root == $root and .result.workspace.is_git == true'; then
  pass B04 "second workspace.open registers the MoUI-like repository" "$WS_B"
else
  die B04 "second workspace.open registers the MoUI-like repository" "$WS_B_RESP"
fi

WT_B_RESP="$(rpc worktree.create \
  "$(jq -c -n --arg ws "$WS_B" --arg branch "$BRANCH_B" --arg path "$WT_B" \
    '{workspace_id: $ws, branch: $branch, path: $path, base: ""}')")" || \
  die B05 "second worktree.create" "$WT_B_RESP"
WT_B_ID="$(jq_raw "$WT_B_RESP" '.result.worktree.id // ""')"
WT_B_PATH="$(jq_raw "$WT_B_RESP" '.result.worktree.path // ""')"
if [ -n "$WT_B_ID" ] && jq_true "$WT_B_RESP" --arg path "$WT_B" \
  '.result.worktree.path == $path and .result.worktree.state == "ready"'; then
  pass B05 "second isolated worktree is ready" "$WT_B_PATH"
else
  die B05 "second isolated worktree is ready" "$WT_B_RESP"
fi

MEM_B_RESP="$(rpc project.membership.add \
  "$(jq -c -n --arg project "$PROJECT_B" --arg bot "$BOT_B" \
    '{project_id: $project, bot_id: $bot, actor: "owner"}')")" || \
  die B06 "second project.membership.add" "$MEM_B_RESP"
MEM_B_LIST_RESP="$(rpc project.membership.list \
  "$(jq -c -n --arg project "$PROJECT_B" '{project_id: $project}')")" || \
  MEM_B_LIST_RESP=""
if jq_true "$MEM_B_RESP" --arg project "$PROJECT_B" --arg bot "$BOT_B" \
  '.result.membership.project_id == $project and
   .result.membership.bot_id == $bot and
   .result.membership.access == []' &&
  jq_true "$MEM_B_LIST_RESP" --arg project "$PROJECT_B" --arg bot "$BOT_B" \
  '[.result.memberships[] | select(.project_id == $project and
    .bot_id == $bot and .access == [])] | length == 1'; then
  pass B06 "second Bot joins membership and lists with access=[]"
else
  fail B06 "second Bot joins membership and lists with access=[]" "$MEM_B_LIST_RESP"
fi
BOT_B_GET="$(rpc bot.get \
  "$(jq -c -n --arg bot "$BOT_B" '{bot_id: $bot}')")" || BOT_B_GET=""
if jq_true "$BOT_B_GET" --arg name "$BOT_NAME_B" '.result.bot.name == $name'; then
  pass B07 "second membership bot_id resolves to the Bot name" "$BOT_NAME_B"
else
  fail B07 "second membership bot_id resolves to the Bot name" "$BOT_B_GET"
fi

CHAT_JSON_B="$(jq -c -n --arg id "$CHAT_B" --arg project "$PROJECT_B" \
  '{id: $id, org_id: "org_local", title: "MoUI-like bootstrap",
    project_id: $project, summary_ref: "", state: "active",
    created_at: "", updated_at: "", archived_at: ""}')"
CHAT_B_RESP="$(rpc chat.create \
  "$(jq -c -n --argjson chat "$CHAT_JSON_B" --arg bot "$BOT_B" \
    '{chat: $chat, bot_id: $bot, participant_bot_ids: [$bot]}')")" || \
  die B08 "second chat.create" "$CHAT_B_RESP"
if jq_true "$CHAT_B_RESP" --arg id "$CHAT_B" --arg project "$PROJECT_B" \
  '.result.chat.id == $id and .result.chat.project_id == $project'; then
  pass B08 "second Chat is created"
else
  die B08 "second Chat is created" "$CHAT_B_RESP"
fi

SESSION_B_RESP="$(rpc chat.agent_session.start \
  "$(jq -c -n --arg chat "$CHAT_B" --arg agent "$AGENT_B" --arg ws "$WS_B" \
    --arg root "$WT_B" --arg worktree "$WT_B_ID" \
    '{chat_id: $chat, agent_id: $agent, workspace_id: $ws,
      workspace_root: $root, worktree_id: $worktree}')")" || \
  die B09 "second chat.agent_session.start" "$SESSION_B_RESP"
SESSION_B_ID="$(jq_raw "$SESSION_B_RESP" '.result.session.id // ""')"
if [ -n "$SESSION_B_ID" ] && jq_true "$SESSION_B_RESP" --arg root "$WT_B" \
  --arg worktree "$WT_B_ID" \
  '.result.session.state == "active" and
   .result.session.workspace_root == $root and
   .result.session.worktree_id == $worktree'; then
  pass B09 "second AgentSession runs in the MoUI-like worktree" "$SESSION_B_ID"
else
  die B09 "second AgentSession runs in the MoUI-like worktree" "$SESSION_B_RESP"
fi

FIRST_SEND_B="$(rpc chat.send \
  "$(jq -c -n --arg chat "$CHAT_B" --arg text "$PROMPT_B" \
    '{chat_id: $chat, text: $text, actor: "owner"}')")" || \
  die B09B "second chat.send" "$FIRST_SEND_B"
if jq_true "$FIRST_SEND_B" --arg chat "$CHAT_B" --arg text "$PROMPT_B" \
  '.result.message.chat_id == $chat and .result.message.body == $text and
   .result.session.state == "active"'; then
  pass B09B "second chat.send creates the visible user message"
else
  die B09B "second chat.send creates the visible user message" "$FIRST_SEND_B"
fi

if poll_chat_read "$CHAT_B" 0 "M1A-VALIDATE: ok" 300; then
  pass B10 "second mock ACP reads docs, edits and validates"
else
  fail B10 "second mock ACP reads docs, edits and validates"
fi
READ_B="$(rpc chat.read \
  "$(jq -c -n --arg chat "$CHAT_B" '{chat_id: $chat, cursor: 0}')")" || \
  READ_B=""
TEXT_B="$(jq_raw "$READ_B" '.result.text // ""')"
if jq_true "$READ_B" --arg cwd "$WT_B_PATH" \
  '(.result.text | contains("CWD=" + $cwd)) and
   (.result.text | contains("M1A-CWD=" + $cwd)) and
   (.result.text | contains("M1A-AGENTS-READ")) and
   (.result.text | contains("M1A-DOCS-READ=docs/overview.md")) and
   (.result.text | contains("M1A-EDIT=src/app.txt")) and
   (.result.text | contains("M1A-VALIDATE: ok"))'; then
  pass B11 "second runtime cwd equals its worktree path" "$WT_B_PATH"
else
  fail B11 "second runtime cwd equals its worktree path" "$TEXT_B"
fi

if poll_chat_messages "$CHAT_B" "M1A-VALIDATE: ok" 300; then
  pass B12 "second visible transcript stores the assistant result"
else
  fail B12 "second visible transcript stores the assistant result"
fi
MESSAGES_B="$(rpc chat.messages \
  "$(jq -c -n --arg chat "$CHAT_B" \
    '{chat_id: $chat, after: "", limit: 100}')")" || MESSAGES_B=""
if jq_true "$MESSAGES_B" --arg prompt "$PROMPT_B" --arg sid "$SESSION_B_ID" \
  '([.result.messages[] | select(.role == "user" and .body == $prompt)] |
     length) == 1 and
   ([.result.messages[] | select(.role == "assistant" and
      .agent_session_id == $sid and (.body | contains("M1A-VALIDATE: ok")))] |
    length) == 1'; then
  pass B13 "second chat.messages contains the user and assistant turns"
else
  fail B13 "second chat.messages contains the user and assistant turns" "$MESSAGES_B"
fi

WT_B_STATUS="$(rpc workspace.gitStatus \
  "$(jq -c -n --arg ws "$WS_B" --arg worktree "$WT_B_ID" \
    '{workspace_id: $ws, worktree_id: $worktree}')")" || WT_B_STATUS=""
if jq_true "$WT_B_STATUS" --arg path "src/app.txt" \
  '[.result.git_status.changes[] | select(.path == $path)] | length == 1'; then
  pass B14 "second worktree gitStatus shows the src/app.txt change"
else
  fail B14 "second worktree gitStatus shows the src/app.txt change" "$WT_B_STATUS"
fi
MAIN_B_STATUS="$(rpc workspace.gitStatus \
  "$(jq -c -n --arg ws "$WS_B" '{workspace_id: $ws}')")" || MAIN_B_STATUS=""
if jq_true "$MAIN_B_STATUS" '.result.git_status.changes | length == 0'; then
  pass B15 "second main workspace gitStatus stays clean"
else
  fail B15 "second main workspace gitStatus stays clean" "$MAIN_B_STATUS"
fi
WT_B_DIFF="$(rpc workspace.gitDiff \
  "$(jq -c -n --arg ws "$WS_B" --arg worktree "$WT_B_ID" \
    '{workspace_id: $ws, worktree_id: $worktree, path: "src/app.txt",
      cached: false, range: ""}')")" || WT_B_DIFF=""
if jq_true "$WT_B_DIFF" '.result.git_diff.text | contains("M1A-DEMO-EDIT")'; then
  pass B16 "second worktree gitDiff contains the mock edit"
else
  fail B16 "second worktree gitDiff contains the mock edit" "$WT_B_DIFF"
fi
MAIN_B_DIFF="$(rpc workspace.gitDiff \
  "$(jq -c -n --arg ws "$WS_B" \
    '{workspace_id: $ws, path: "src/app.txt", cached: false, range: ""}')")" || \
  MAIN_B_DIFF=""
if jq_true "$MAIN_B_DIFF" \
  '(.result.git_diff.text | contains("M1A-DEMO-EDIT")) | not'; then
  pass B17 "second main workspace gitDiff does not contain the worktree edit"
else
  fail B17 "second main workspace gitDiff does not contain the worktree edit" \
    "$MAIN_B_DIFF"
fi
if grep -Fq "M1A-DEMO-EDIT" "$WT_B_PATH/src/app.txt" &&
  ! grep -Fq "M1A-DEMO-EDIT" "$REPO_B/src/app.txt"; then
  pass B18 "second filesystem edit exists only under its worktree"
else
  fail B18 "second filesystem edit exists only under its worktree"
fi

MEM_ALL_B="$(rpc project.membership.list '{}')" || MEM_ALL_B=""
if jq_true "$MEM_ALL_B" --arg a "$BOT_A" --arg b "$BOT_B" \
  '[.result.memberships[] | select(.bot_id == $a or .bot_id == $b)] |
   length == 2'; then
  pass B19 "both Project memberships are active and independently listed"
else
  fail B19 "both Project memberships are active and independently listed" "$MEM_ALL_B"
fi

printf '\n== result ==\n'
summary
exit $?
