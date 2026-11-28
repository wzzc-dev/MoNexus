# MoNexus usage

This guide covers the V0.1 workflows: starting the app, registering
machines, opening workspaces, running agents and tasks, answering Decisions,
and reading the audit trail. For install/package steps see the
[README](../README.md); for failures see
[troubleshooting](troubleshooting.md).

All CLI examples assume the packaged/installed `monexus` launcher is on
`PATH` and a host is running (`monexus start --headless` or the window). The
shorter form `monexus host ...` is equivalent to running `monexus-host ...`
against the same state directory.

## 1. Start, inspect, stop

```bash
monexus                     # start/reuse host, then open the window
monexus start --headless    # no display: host only
monexus status              # host.status + host.json endpoint
monexus stop                # stop a host started by this launcher
monexus version             # monexus, monexus-host, monexus-desktop
monexus --help
```

- The state directory defaults to `$MONEXUS_STATE_DIR`, else
  `$HOME/.monexus`. Use `--state-dir DIR` or the environment variable to run
  an isolated instance (the acceptance script does this).
- `monexus start` checks for an online host first. If one exists it reuses it;
  otherwise it starts a detached `monexus-host serve`, waits for `host.json`
  and writes `<state>/host.pid`.
- `--headless` prints the state dir, `host.json` mode, endpoint and token
  status (present/missing; the token value is never printed), then exits.
- `--no-keep-alive` stops a host that this invocation started, once the
  window exits. The default is keep-alive: closing the window leaves the host
  running.
- On Linux, without Wayland/X11 the launcher exits 3 with a headless/xvfb
  hint; the native desktop binary does the same. Under CI or a headless Linux
  box, `xvfb-run -a monexus` runs the real window against a virtual X server.
  On macOS the window needs a logged-in GUI session (AppKit/WindowServer);
  over SSH, use `monexus start --headless`.

`monexus status` prints the RPC status plus the discovery file:

```
state dir:  /home/me/.monexus
host.json:  /home/me/.monexus/host.json (mode 600)
endpoint:   ws://127.0.0.1:43771/ws
token:      present (stored only in host.json; never printed)
```

Settings page equivalents: connection (`connecting/online/offline`), host
address, token status, version, data directory, host id, last error.

## 2. Machines

Desktop: **Machines** → fill the fields → **Add machine**; cards show status,
target, profile, last error, with **Probe** and **Remove**.

```bash
# This machine (no SSH; host-side local provider)
monexus host machine add --kind local --name "this machine"

# Explicit SSH target
monexus host machine add --name box --host 10.0.0.5 --port 22 --user me \
  --identity ~/.ssh/id_ed25519 --use-ssh-config false \
  --host-key-policy accept-new --known-hosts-file ~/.monexus/known_hosts

monexus host machine list
monexus host machine probe --id mch_... --timeout-seconds 10
monexus host machine remove --id mch_...
```

Notes:

- `--kind local` is a V0.1 addition. It records `kind=local`, probes local
  capabilities instead of SSH, and lets agents run in a workspace that is
  attached to a registered local machine. The default remains `ssh`.
- `--kind runtime` registers a V0.2 paired node (ADR-0012). Its `--host` is
  the runtime id the node used when pairing, not a hostname; the node dials
  out to the primary and has no inbound port. Setup, revoke, drain and
  switching back to SSH are covered in §10.
- `--host-key-policy` accepts `accept-new` (default), `yes`, `no` or `config`.
  `accept-new` records a first-seen key in the chosen known-hosts file;
  `strict` behavior belongs to `yes`. Use a dedicated known-hosts file for
  automation so `~/.ssh` is untouched.
- With `--use-ssh-config true` (default) OpenSSH config is honored and the
  effective values are shown by `ssh -G`; set it to `false` for unattended,
  fully explicit targets.
- The machine id (`mch_...`) is what `workspace.open`, `run.create` and the
  desktop selectors use.

## 3. Workspaces and worktrees

Desktop: **Projects** → machine + root → **Open project**. The page provides
a one-level file list, atomic read/write, git status/diff, a terminal, and a
worktree form. In the terminal input, plain Ctrl+C (or **Stop**) sends the raw
interrupt byte, while Cmd+C, Ctrl+Shift+C and Ctrl+Insert copy; the same
shortcuts work in the focused Projects terminal and the floating terminal.

```bash
monexus host rpc --method workspace.open \
  --params '{"target":"mch_...","root":"/home/me/project"}'
```

`target` is a machine id; `"local"` or `""` uses the local provider. The
response contains the workspace id (`wsp_...`) and its git root.

```bash
# list / read / write files (paths are workspace-relative)
monexus host rpc --method workspace.list --params '{"workspace_id":"wsp_..."}'
monexus host rpc --method workspace.read \
  --params '{"workspace_id":"wsp_...","path":"README.md"}'
monexus host rpc --method workspace.write \
  --params '{"workspace_id":"wsp_...","path":"NOTES.md","content":"hello\n"}'
monexus host rpc --method workspace.diff \
  --params '{"workspace_id":"wsp_...","path":"README.md"}'

# worktrees (git workspaces only)
monexus host rpc --method worktree.create --params '{
  "workspace_id":"wsp_...","branch":"m7-demo","path":"/tmp/wt-demo","base":""}'
monexus host rpc --method worktree.list --params '{"workspace_id":"wsp_..."}'
monexus host rpc --method worktree.remove --params '{"worktree_id":"wtr_..."}'
```

First-run sample: `~/.monexus/examples/hello-workspace` (README, AGENTS.md,
git repo, no commits until git is available). Open it with the local machine
to try worktrees, terminals and agent sessions immediately.

A worktree is a first-class object: each Run can target its own worktree, so
two concurrent Runs do not share a working directory. Non-git workspaces use
exclusive leases instead.

### Project membership by Bot name

Desktop: **Manage** → **Projects** → select a Project. The **Bot members**
section lists active members; use **Remove** beside a Bot name, or **Add**
beside an available Bot name. The same controls are on the Bot page's Project
section. Lists and pickers show Bot and Project names, not raw `bot_`/`prj_`
ids. Adding or removing a member refreshes the Project page, Bot page and the
New Chat draft so a revoked Bot is not left selected.

```bash
monexus host rpc --method project.membership.list --params '{"project_id":"prj_..."}'
monexus host rpc --method project.membership.add \
  --params '{"project_id":"prj_...","bot_id":"bot_..."}'
monexus host rpc --method project.membership.remove \
  --params '{"project_id":"prj_...","bot_id":"bot_...","reason":"owner request"}'
```

`project.membership.list` with no `project_id` returns every active membership.
Adding an existing active member is idempotent. Removal fails with `conflict`
while that Bot has a non-terminal AgentSession in the Project; stop the session
first. M1 access is always empty, and permissions stay bounded by the Bot
ceiling plus the existing permission snapshot.

## 4. Agent sessions

Desktop: **Agents** → workspace/worktree + adapter → **Start session**; the
transcript streams in, follow-up prompts use **Send**, **Stop** ends it, and
**Resume** uses `session/load` when the adapter supports it. Permission
requests become Decisions in **Inbox**.

Test double (no account, no network):

```bash
monexus host rpc --method agent.probe --params '{
  "agent_id":"mock","mode":"acp","command":"node",
  "args":["tests/agent/mock_acp_agent.mjs"],"env":{}}'
# → readiness.ok=true, adapter="acp"

monexus host rpc --method agent.start --params '{
  "agent_id":"mock","mode":"acp","command":"node",
  "args":["tests/agent/mock_acp_agent.mjs"],
  "workspace_id":"wsp_...","prompt":"hello"}'
# → .session.id = ags_...

monexus host rpc --method agent.read \
  --params '{"session_id":"ags_...","cursor":0}'
monexus host rpc --method agent.send \
  --params '{"session_id":"ags_...","text":"continue"}'
monexus host rpc --method agent.stop --params '{"session_id":"ags_..."}'
```

Real ACP adapter:

- Node must be on `PATH`; the first start downloads
  `@zed-industries/claude-code-acp` via npx.
- The machine must be logged in to Claude Code. The host spawns the adapter
  with `env -u CLAUDECODE` and never reads/logs credentials.
- If readiness fails, the Inbox receives a readiness Decision.
- Verified on 2026-11-25 with `@zed-industries/claude-code-acp 0.16.2`: the
  readiness probe passed, and one real turn streamed the requested output with
  `stop_reason=end_turn`.
- Agent sessions run on a local machine, or on a V0.2 paired runtime machine
  selected with `machine_id` (see §10). For a runtime machine the primary-side
  absolute cwd is mapped into the node's `--runtime-workspace-root`; an
  absolute path outside those roots is rejected, and a cwd equal to a root
  becomes `.`.
- SSH-backed remote agent sessions are still a gated PoC behind
  `MONEXUS_AGENT_SSH=1` (ADR-0011); they are not part of the V0.2 runtime
  path. Legacy runtime sessions keep transcripts in memory (bounded); Chat
  AgentSession transcripts are also written to a bounded audit cache keyed by
  the canonical Chat session id, but `chat.read` never replays that cache as
  visible text after a restart.

### Chat continuation and restart recovery

- The Chat timeline is built from `ChatMessage` and is the only user-visible
  history authority. Assistant messages keep their `agent_session_id`; host
  boundaries are ordinary `role=system`, `actor=host` messages.
- A host restart closes every `starting|active|waiting` Chat AgentSession as
  `ended` with `end_reason=host_restarted`, expires its pending Decisions and
  writes exactly one visible boundary message per interrupted session. Repeating
  startup reconcile does not add a second boundary.
- In an interrupted Chat, use **Continue Agent session** on the same Chat. The
  new AgentSession records `handoff_from_session_id`; this does not create a new
  Chat and does not resurrect the old ACP process.
- The first `chat.send` of a new session injects at most 8 KiB (UTF-8) of the
  most recent user/assistant visible history as a hidden prompt prefix. system
  boundaries, Decisions and the current message are excluded, and the prefix is
  sent only once. It never appears in `ChatMessage.body`, the durable transcript
  or event payloads.
- The durable transcript is execution/audit cache, not UI replay. With the
  runtime gone, `chat.read` still returns empty `text` and keeps the caller's
  cursor; a new AgentSession starts a new runtime transcript at cursor 0.
- Runtime `prompt=""` and `memory_limit=0` are unchanged; Bot memory injection
  remains M1b scope.

Remote agent PoC (rounds 1–2, not full remote-agent support):

- An SSH workspace/worktree still gets the local-only error unless the host
  process is started with `MONEXUS_AGENT_SSH=1`. With the gate on, the agent
  process is launched through `ssh -T` (no PTY) using the machine's stored
  identity, dedicated known-hosts file and host-key policy.
- The remote cwd is the workspace/worktree path. The remote command is a
  fixed `sh -c` script with positional parameters, so paths and arguments are
  never interpolated into shell text. The remote machine uses its own
  login/runtime; the host does not copy model credentials or keys.
- stderr is captured separately in `<state>/logs/agent-<session>.stderr.log`
  (redacted, mode 0600) and in the session record's `stderr_tail`. Both keep
  only the most recent 2 KB, and multi-line private-key blocks are collapsed
  to a `[redacted]` marker, so neither can hold key body lines. stderr never
  reaches the ACP stdout transcript.
- Failure semantics follow [ADR-0011](adr/0011-agent-over-ssh.md). A completed
  turn is settled by the ACP `stopReason` first; the later clean EOF is the
  existing `exited` state. If the stream ends while a prompt is still active,
  the host reads the local `ssh` client's exit status with a bounded wait
  (`try_wait`, about 2 s, then "unknown"):
  - `ssh` exit 255, an unobservable status, or a killed local `ssh` client →
    final state `lost`, stop reason `lost`, event `agent.session.lost`,
    `last_error` "remote agent connection lost";
  - any other observed exit (the remote agent exiting mid-turn) → final state
    `interrupted`, stop reason `interrupted`, event
    `agent.session.interrupted`, `last_error` "remote agent exited mid-turn".
  Neither case sets `idle`/`end_turn`, both are terminal, and both expire any
  pending permission Decision through the normal finalize path. There is no
  auto-reconnect, auto-restart or cross-connection transcript resume.
- What the owner should do: `lost` means the transport died before the turn's
  outcome was known. Check the network/sshd, and clean up a possibly orphaned
  remote agent process by hand (the ADR does not promise automatic reaping).
  `interrupted` means the remote agent itself exited mid-turn; check the
  remote CLI/runtime logs or readiness. In both cases start a new turn or
  session after the cause is fixed; do not treat the truncated output as a
  completed result.
- Local launches are unchanged in this round: their EOF still settles as
  `exited`.
- Verified by `scripts/agent_ssh_smoke.sh` with a mock ACP agent over a
  temporary loopback sshd: killing the local `ssh` client yields
  `lost`/`lost`/`agent.session.lost`, killing the remote mock yields
  `interrupted`/`interrupted`/`agent.session.interrupted`, and a clean turn
  followed by EOF still yields `exited`.
- Round-2 real-host evidence (Debian 13 x86_64, Aliyun; remote DSH 0.2.2-rc.5,
  Node 24.22.3, `@deepseek-ai/dsh/lib/bin.js --profile acp`, model `llm-local`
  / `DeepSeek-V4.1-Flash-1017-Local-02`; host started with
  `MONEXUS_AGENT_SSH=1` and an isolated state dir): remote workspace
  read/write, a real model turn (`end_turn`), a permission request entering a
  Decision and allowed once, and `agent.stop` ending `stopped`/`cancelled`
  with the remote process gone. The pre-fix run exposed this bug: both failure
  cases settled as `exited`. Re-run after the fix, a real DSH turn with an
  in-flight `sleep 120` tool killed by dropping the local `ssh` client settled
  as `lost`/`lost` with `last_error` "remote agent connection lost", event
  `agent.session.lost`, no false `exited`, and the remote `sleep 120`/DSH was
  gone afterwards. SIGKILLing remote DSH directly makes the local `ssh` client
  exit 255, so ADR-0011 records that as `lost` (ambiguous), not
  `interrupted`. The real non-255 path was exercised on a real DSH ACP stream
  with a test-only wrapper on the remote host that runs the real DSH ACP
  engine, forwards ACP stdin through a FIFO (so the handshake works), watches
  for the in-flight `sleep 120` tool, SIGKILLs DSH and exits 3 while the
  prompt is still active; through MoNexus, session
  `agt_01M897GMSX5WWPDSYF000000FE` recorded `interrupted`/`interrupted` with
  `last_error` "remote agent exited mid-turn", exactly one
  `agent.session.interrupted` event, and no false `exited`. That is a
  synthetic non-255 remote exit on a real DSH stream (test harness), not a
  real DSH crash; the wrapper is test-only and not committed. This DSH result
  makes no Ubuntu or macOS claim.
- Still missing for real remote agents: `agent.probe` is local-only,
  `agent.resume` does not reconstruct an SSH launch, and `env` from
  `agent.start` is not forwarded over SSH.

### New Chat with an isolated worktree

Desktop: **New Chat** → choose the Bot, Project, Workspace and Agent by name
→ choose the Worktree → **Create Chat**. The Worktree selector starts at
**Workspace root**; existing `ready` worktrees appear by branch. Choosing
**New isolated worktree · monexus/<short>** makes the host create a sibling
worktree at `<workspace.root>-monexus-<short>`, where `short` is the last
eight characters of the new `cht_` id, then starts the Agent session with that
worktree id. If the Bot has exactly one active Agent it is preselected;
otherwise choose one explicitly. The Chat still belongs to the selected
workspace, but its session cwd is the worktree path.

The Chat details rail shows Project, Workspace, Worktree (or **Workspace
root**), Git status and diff, a terminal entry, and the latest execution
result. The Git panes call `workspace.gitStatus`/`workspace.gitDiff` with the
session's `worktree_id`, so the diff contains only that worktree's changes and
does not mix in uncommitted changes from the main checkout. M1 does not allow
switching the Agent inside one Chat; start a new Chat instead. Ending the Chat
session is required before `worktree.remove` will accept that worktree.
Environment/container-backed workspaces do not support worktree Chat review
in M1; their Git panes reject a `worktree_id` with an explicit unsupported
error.

## 5. Projects, tasks, Runs and evidence

A Project declares `verify[]`; a Task inherits it; a Run executes a command
on a machine in a workspace/worktree. The Run enters `verifying` after the
command and becomes `succeeded` only when every evidence row passes (or the
owner waives it).

```bash
monexus host rpc --method project.create --params '{
  "name":"demo",
  "verify":["sh -c \"test -f verify.txt\"","echo verify-ok"]}'
# → prj_...

monexus host rpc --method task.create --params '{
  "title":"demo task","project_id":"prj_...","workspace_id":"wsp_..."}'
# → tsk_...

monexus host rpc --method run.create --params '{
  "task_id":"tsk_...","workspace_id":"wsp_...","machine_id":"mch_...",
  "mode":"command","command":"sh -c \"sleep 2; echo done\"",
  "idempotency_key":"demo/1"}'
# → run_...

monexus host rpc --method run.get --params '{"run_id":"run_..."}'
monexus host rpc --method task.get --params '{"task_id":"tsk_..."}'
```

- Dispatch the same task to a local workspace and an SSH workspace to run it
  in parallel; per-machine `max_parallel` (`MONEXUS_MAX_PARALLEL`, default 4)
  queues the excess.
- `idempotency_key` is stable: a duplicate `run.create` returns the existing
  queued/running Run rather than launching a second one.
- Evidence rows (pass/fail, exit code, output excerpt), artifacts (including
  the run output log) and the worktree diff are attached to the Run.
- A failed verify raises a verify Decision with `waive`, `retry`, `fail`
  (see below). `task.get` rolls up multiple Runs, e.g. `2/2 runs succeeded`.

Risk policy runs before a Run exists. `ls`, `cat`, `git status` and similar
read-only commands are allowed; `rm -rf build`, `pip install`, `git reset
--hard` and similar are high risk and wait for approval; `sudo ...`, `mkfs`,
`shutdown`, `systemctl` and similar root/system commands are denied and
audited. High-risk Runs are created in `waiting_approval`; approving the
Decision returns them to the queue.

## 6. Decisions and the Inbox

Desktop **Inbox** has three sections: **Needs you** (pending), **waiting**
(answered, work still running) and **handled** (Run settled). Buttons map to
the Decision options; free-text is stored as the answer text.

```bash
monexus host rpc --method decision.list --params '{"status":"pending"}'
# or bucket: {"bucket":"needs_you"} / waiting / handled

monexus host rpc --method decision.respond --params '{
  "decision_id":"dec_...","option_id":"waive","text":"accepted in review"}'
```

Decision kinds and answers:

| kind | raised by | options |
| --- | --- | --- |
| `verify` | failed evidence gate | `waive`, `retry`, `fail` |
| `permission` | ACP permission request | adapter-provided options |
| `recovery` | lost/unverifiable/timeout/exhausted retry | `retry`, `fail`, `waive` |
| `readiness` | agent probe failure | acknowledge/deny-style options |
| `skill` | write-mode skill invocation (A4) | `approve`, `deny` |
| `environment_approval` | environment create/start plan (A2) | `approve`, `deny` |

A duplicate answer is rejected as a conflict (`decision is already
answered`). The answer, actor, option and target are audited.

## 7. Events, search and audit

```bash
monexus host rpc --method events.list --params '{"since":0,"limit":100}'
monexus host rpc --method search.sessions \
  --params '{"query":"verify failed","limit":20}'
monexus host rpc --method audit.list --params '{"limit":100}'
```

- Events are append-only and carry full projections; `seq` is monotonic
  across restarts. `events.subscribe --since <seq>` (CLI) streams new events.
- `search.sessions` returns matching session transcripts and Decision text.
  Depending on the bundled SQLite the backend is `fts` or `like`.
- `audit.list` records the gate (`policy.verdict`, `policy.deny`,
  `decision.respond`, `recovery.*`, `run.stop`, ...), actor, subject, outcome,
  policy/risk, run/decision/task ids and redacted detail.
- Secret-looking values are redacted (`[redacted]`) before logs, artifacts,
  events and audit detail. Bearer tokens are stored only in `host.json`
  (0600) and never printed by the launcher.

## 8. Recovery behavior you can rely on

- Closing the desktop does not stop the host or its Runs; reopening
  reconnects with a 1.5 s backoff.
- A host crash/restart reconciles every active Run:
  - tmux session alive → reattached and monitored;
  - exit marker 0 → evidence gate; non-zero → failed with an observed code;
  - session gone/dead without an exit marker → `lost` (unknown code);
  - transport unobservable → `unverifiable`.
- `lost` retries once automatically (a new Run with `retried_from`, attempt
  2); `unverifiable` is never auto-retried and immediately asks the owner.
- A short SSH drop is tolerated; a persistent one becomes
  `lost`/`unverifiable` with a recovery Decision and teardown of the durable
  session.
- `MONEXUS_RECOVERY_POLL_MS` and `MONEXUS_RECOVERY_UNVERIFIABLE_MS` tune the
  poll and silence windows (used by acceptance/tests; defaults 120 ms and
  15 s).
- Chat recovery is separate from Run recovery: interrupted Chat AgentSessions
  become `ended/host_restarted`, pending Decisions expire, and one system
  boundary is kept in the Chat timeline. Durable transcripts remain available
  for audit but are never replayed into `chat.read`.

## 9. Schedule and webhook triggers

Trigger dispatch is opt-in and remains **off by default** while A3 completes
acceptance. Start the host with `--trigger-enabled true` (or
`MONEXUS_TRIGGER_ENABLED=1`); when off, every `trigger.*` RPC returns
`unsupported` and `POST /hooks/<trigger_id>` returns the same uniform 401 as
an unknown key; the rest of the host behaves as before. Event, schedule and
webhook triggers are wired in the host and covered by
`scripts/trigger_smoke.sh`; the owner enables the flag explicitly after A3.2
sign-off.

A trigger creates a Task, never an execution. With `target.start_run=false`
(default) the Task is `planned`; with `target.start_run=true` the Task is
created `ready` and the host queues one `mode=agent` Run through the existing
`run.create` path after the Task commit. `start_run=true` requires
`target.agent_id` and `target.workspace_id`, and the Run carries the
idempotency key `trigger:<trigger_id>:<fire_key>`; retrying the same fire
returns the same Run. A trigger has no command, argv, environment, policy or
approval field, never executes the goal itself, and never creates, grants or
answers a Decision: a tool permission still goes to the owner Inbox as
`decision.requested`, and a denied or expired permission leaves the Run
not-successful. Disabling a trigger stops new Tasks but does not cancel an
existing Task or Run.

### Trigger target and Runs

`target` accepts `title_template`, `goal_template`, `agent_id`,
`workspace_id`, `project_id`, `verify`, and `start_run`. Template variables
come from the declared event fields or webhook `payload_fields`; they are
bounded and redacted, are treated as untrusted text, and cannot set a command,
environment, agent, workspace, project, policy, approval or `start_run`.
`verify` is allowed only as a subset of the referenced project's `verify`
list. The trigger-created Run is scheduled and governed exactly like an
owner-created Run: per-machine concurrency, policy, evidence gate, recovery
and cancellation all apply.

### Event and manual triggers

Create an event trigger with `"type":"event"`. `source` accepts exactly:

| field | meaning |
| --- | --- |
| `event_type` | exact type (`run.failed`) or one trailing `*` prefix (`run.*`, `machine.*`); no other wildcard, regex or boolean expression |
| `subject_prefix` | optional string prefix for the event subject |
| `correlation_id` | optional exact correlation filter |
| `ignore_self` | default `true`; skip events produced by the trigger's own Tasks/Runs |
| `payload_fields` | declared scalar fields from the event payload (names ≤64 characters) exposed as `{{name}}` variables |

Templates in event triggers can also use `{{event_type}}`, `{{event_subject}}`,
`{{event_id}}`, `{{event_seq}}`, `{{event_ts}}` and `{{correlation_id}}`.
High-volume and meta events — `host.heartbeat`, `audit.recorded`,
`trigger.*`, `run.progress`, `run.heartbeat`, `agent.session.output` and
`agent.session.updated` — never match. The dispatcher reads the persisted
event log with cursor `meta.trigger.event_cursor`, so a restart resumes where
it stopped; replaying the same event hits `(trigger_id, fire_key)` and only
increments `dedupe_hits`. Trigger-created Tasks carry provenance
(`trigger_id`, `fire_key`, `root_trigger_id`, `depth`); a chain deeper than 8 is
rejected with `trigger.rejected reason=cascade_depth`, and `ignore_self`
prevents a trigger from feeding itself.

`trigger.fire` (`{"trigger_id":..., "note":...}`) is the owner's manual test
path. It uses `source=manual` and `fire_key=manual:<request_id>`, goes through
the same validation, rate limits, Task creation and optional Run start, and
returns `{task_id, run_id, duplicate}`. It is not an execute or approval
shortcut.

### Schedule triggers

Create one with `trigger.create` and `"type":"schedule"`. `source` accepts
exactly these shapes:

| `schedule_kind` | fields |
| --- | --- |
| `every` | `interval_minutes` 1..1440, optional `timezone`, `jitter_s` 0..300, `missed` |
| `daily` | `at` `HH:MM`, optional `timezone`, `jitter_s` 0..300, `missed` |
| `weekly` | `weekday` 1..7 (ISO, Monday=1), `at` `HH:MM`, optional `timezone`, `jitter_s` 0..300, `missed` |

Cron syntax and unknown/extra fields are rejected. `missed` is `skip` (default)
or `coalesce_once`.

`timezone` accepts `UTC` (also the empty default), a fixed offset `±HH:MM`
within `-12:00..+14:00`, an IANA name such as `Europe/Berlin`, or `local`.
`local` is resolved once at creation to a concrete IANA zone and frozen; it is
never stored as `local`. IANA zones are read from `$MONEXUS_TZDATA_DIR`, else
`/usr/share/zoneinfo`; an invalid, unreadable or unresolvable zone rejects
creation with `unsupported` instead of silently falling back to UTC.

The UTC anchor is the creation time truncated to the minute. `every` fires at
`anchor + k*interval` and ignores DST entirely. `daily`/`weekly` use local
wall-clock time: a nonexistent local time in a DST gap resolves to the first
valid instant after the jump, and a repeated local time uses the earlier
occurrence. `jitter_s` adds a deterministic 0..`jitter_s` delay derived from
`(trigger_id, scheduled slot)`, so it is stable across restarts.

One scheduler loop ticks every second and claims at most 100 due triggers per
tick. A claim is a compare-and-swap on `(id, next_fire_at)` plus a unique fire
key `slot:<scheduled_for_ms>`; concurrent ticks cannot create a second Task for
the same slot. Missed windows are applied once at startup: `skip` advances to
the next future slot and records `trigger.rejected` with
`reason=missed_window` and `missed_count`; `coalesce_once` creates at most one
Task for the latest missed slot (`coalesced=true`). Slots older than the
90-day ledger are always skipped. If the wall clock is more than five minutes
behind the persisted tick, the tick is rejected with `reason=clock_skew` and
the projection is clamped forward.

### Webhook triggers

`POST /hooks/<trigger_id>` on the existing loopback HTTP server is the only
webhook route. It is split before the `/ws` bearer check: `/ws` still requires
the owner bearer token, `/hooks/*` never accepts it, and every other path is
404. Only `POST` with `Content-Type: application/json` is accepted.

Required headers:

- `X-Monexus-Key-Id: whk_...`
- `X-Monexus-Timestamp`: Unix milliseconds (an RFC3339 UTC value is also
  accepted)
- `X-Monexus-Nonce`: 16..64 characters, unique per request
- `X-Monexus-Delivery-Id`: optional, 1..64 characters, preferred dedupe key
- `X-Monexus-Signature: v1=<lowercase hex HMAC-SHA256>`

The signed bytes are exactly:
`monexus-webhook-v1\n<key_id>\n<trigger_id>\n<timestamp>\n<nonce>\n<raw_body>`,
and the HMAC key is the raw 32-byte secret from the key file. A missing or
malformed header, an unknown/disabled/revoked/expired key, a bad signature, a
stale timestamp or a replay all return the same
`401 {"accepted":false,"error":"unauthorized"}`; the distinguishing reason is
only written to the `trigger.rejected` audit event. Timestamps must be within
±300 s by default (±900 s cap).

A repeated `X-Monexus-Delivery-Id` (or, without one, a repeated nonce) returns
`202` with the original `task_id` and `"duplicate":true`. Reusing a nonce with a
different body is a 401 with a `nonce_reuse` audit reason. Nonces are persisted
for the freshness window plus 120 s.

Only fields declared in `source.payload_fields` (max 8, dot paths of at most
two segments, scalar values, each truncated to 512 characters) become
`{{name}}` template variables. Objects and arrays are rejected, recursion is
never performed, and no payload field can set the command, argv, environment,
agent, workspace, project, verification, machine, policy, approval or
`start_run`. The raw body is never persisted; audit records contain only its
length and SHA-256.

Limits (ADR-0014 §4.5): request body 64 KiB default (256 KiB cap), read
timeout 5 s default (10 s cap), 8 concurrent requests per trigger, and
per-trigger / per-key / global token buckets. Over-limit requests get `413` or
`429` with `Retry-After`; rate-limit audit events coalesce to at most one per
trigger per minute and carry `suppressed_count`.

### Key management and TLS

`trigger.source.add` (`{"trigger_id":..., "name":...}`) creates a `whk_<ULID>`
key and returns `{"key_id":..., "secret":...}` exactly once. The secret is 32
bytes of CSPRNG output stored as lowercase hex at
`<state-dir>/secrets/webhook/<key_id>.key`, with directory mode `0700` and file
mode `0600`; only the relative path is stored in the database, and the secret
never appears in events, logs or audit detail. A trigger may have at most 8
active keys. `trigger.source.revoke` (`{"key_id":...}`) is immediate and
idempotent for new requests and never touches Tasks that already exist.
Rotate by adding a new key, deploying it, then revoking the old one.

The host serves loopback HTTP only and does not terminate TLS. Put a TLS
reverse proxy in front (or keep the host unreachable from other machines),
forward the original method, path and raw body bytes unchanged, preserve
`Content-Length`, disable caching and body rewriting, and do not rely on
forwarding headers: the host ignores `X-Forwarded-*` and never trusts a claimed
client address. Protect or do not expose `/ws` through the same proxy.

### Lifecycle, expiry and incident response

`trigger.list` (`state` filter `active`/`disabled`/`expired`, optional `type`)
enumerates triggers; `trigger.get` returns the record, its recent fire ledger
rows (`fire_key`, `source`, `task_id`, `run_id`, `coalesced`, `depth`) and
webhook key metadata without any secret. `trigger.update` requires
`expected_version` and rejects a stale version with `conflict`. There is no
delete in A3: disable or expire, then audit the retained events and fire
ledger.

`trigger.disable` is idempotent and stops new Tasks immediately; the fire
transaction re-reads `enabled`/`expires_at`, so there is no check-then-fire
window. It does **not** cancel an existing Task or Run, nor does it answer a
pending Decision. `expires_at` is RFC3339 UTC; after it passes the trigger is
`expired`, `trigger.expired` is emitted once, and new fires are rejected.
Restoring an expired trigger needs an update setting both `enabled=true` and a
future `expires_at`.

For an incident:

1. **Unplug the whole surface first.** Stop the host and restart it without
   `--trigger-enabled` (or with the environment variable unset); every
   `trigger.*` call then returns `unsupported` and `/hooks/*` returns 401.
   Existing Tasks/Runs/Decisions keep running normally.
2. **Disable every trigger.** Page `trigger.list` and call `trigger.disable`
   for each id. Use `trigger.source.revoke` for every `webhook_keys[].key_id`
   seen in `trigger.get`, then remove the corresponding
   `<state-dir>/secrets/webhook/<key_id>.key` files. Revocation is immediate
   for new requests and never touches existing Tasks.
3. **Audit what fired.** `trigger.get` gives per-trigger `recent_fires` with
   `fire_key`, `source`, `task_id` and `run_id`; `events.list` returns the
   `trigger.fired` / `trigger.rejected` events (subjects `trigger/<id>`) —
   inspect `reason` (`rate_limited`, `cascade_depth`, `missed_window`,
   `history_gap`, `clock_skew`, webhook authentication reasons) and
   `coalesced`/`depth`. For a specific Run, `audit.list {"run_id":...}` shows
   the `trigger.run.start` record (source, fire_key, task and run ids) plus
   the normal policy/Decision audit trail.
4. **Stop the work explicitly if needed.** Disable does not cancel work;
   use `run.cancel` / `task.cancel`. Any Decision raised by a trigger-created
   Run stays in the owner Inbox until the owner answers it — a trigger cannot
   answer or grant it.
5. **Secrets stay out of the report.** Events, audit detail and logs never
   contain the HMAC secret; never copy the 0600 key file into an incident
   bundle, and rotate by adding a new key before revoking the old one.

## 10. Paired remote runtime

V0.2 adds a second kind of execution plane: a **runtime node** dials out to
the primary host over pinned TLS and executes `machine.exec`, `machine.fs`,
`machine.pty`, `machine.git` and ACP agent sessions. There is no inbound port
on the node and no plaintext fallback. The trust model and failure semantics
are in [ADR-0012](adr/0012-paired-remote-runtime.md); the acceptance matrix
below is `scripts/runtime_e2e.sh`.

### 10.1 Install and check

The primary needs a TLS leaf certificate and key, a CA bundle the node will
trust, and the leaf's SHA-256 pin. The pin is computed over the DER form:

```bash
openssl x509 -in leaf.pem -outform DER | openssl dgst -sha256 -hex
# use the hex value after "= " as --pin
```

Start the primary with the runtime listener (both `--runtime-cert` and
`--runtime-key` are required; there is no plaintext mode):

```bash
monexus-host serve --state-dir /var/lib/monexus \
  --runtime-listen 0.0.0.0:7443 \
  --runtime-cert /etc/monexus/leaf.pem --runtime-key /etc/monexus/leaf.key \
  --runtime-state-dir /var/lib/monexus/rt \
  --runtime-policy /etc/monexus/policy.json \
  --runtime-workspace-root /srv/monexus-workspace \
  --runtime-wait-ms 2000 --runtime-approval-ttl-ms 120000
```

`--runtime-workspace-root` may be repeated; it defines the primary-side
directories that map into the node's workspace. Agent starts with a
primary-side absolute `cwd` outside those roots are rejected.

There is no separate `doctor` subcommand. Check a node and the pairing with:

```bash
monexus-host runtime status --runtime-id node-a \
  --state-base /var/lib/monexus-runtime
# runtime=node-a state_dir=... workspace=... paired=yes token=...
monexus-host machine probe --state-dir /var/lib/monexus --id mch_...
monexus-host rpc --state-dir /var/lib/monexus --method runtime.audit --params '{}'
```

`runtime status` reports `paired=yes` only when a token exists; it prints the
token path, never the token. `machine probe` reports `status=online` and the
node profile, including `policy=snapshot` and the workspace roots.

### 10.2 Pair, serve and attach

```bash
# 1. Primary: mint a one-time 128-bit code (shown once, never audited).
monexus-host rpc --state-dir /var/lib/monexus \
  --method runtime.pairing.create --params '{}'
# -> {"code":"...", ...}

# 2. Node: exchange the code and store a 0600 token under
#    <state-base>/<runtime-id>/.
monexus-host runtime pair --runtime-id node-a \
  --primary primary.example.com:7443 \
  --ca /etc/monexus/ca.pem --pin <leaf-sha256> \
  --code <one-time-code> --state-base /var/lib/monexus-runtime

# 3. Node: dial out and serve. This process has no listening socket.
monexus-host runtime serve --runtime-id node-a \
  --primary primary.example.com:7443 \
  --ca /etc/monexus/ca.pem --pin <leaf-sha256> \
  --state-base /var/lib/monexus-runtime --heartbeat-ms 300 --backoff-ms 300

# 4. Primary: register the node as a machine (host is the runtime id).
monexus-host machine add --state-dir /var/lib/monexus \
  --kind runtime --host node-a --name node-a
```

Wrong, expired, replayed or already-used codes are rejected with the same
shape of error, audited as `runtime.pairing_rejected`, and enroll nothing. A
pin mismatch is refused before a credential is sent. Re-pairing the same
runtime id rotates the credential and revokes the previous one; using the old
token afterwards is audited as `runtime.auth_rejected`.

### 10.3 Policy and approvals

The node runs the A1.3b policy gate itself. The primary publishes its snapshot
on attach; the node acknowledges it (`runtime.status.installed_policies`).
A read-only command allowed by the snapshot runs without a Decision. A
high-risk or not-explicitly-allowed command creates a `permission` Decision on
the primary:

- the Decision is bound to the machine, run and a `sha256:<64 hex>` command
  digest, and shows the command to the owner;
- `approve` is one-time and only for that digest; `deny` never executes;
- if the owner does not answer before `--runtime-approval-ttl-ms`, the
  Decision expires and the operation fails — there is no offline allow;
- if the primary is unreachable, the operation waits and then reports
  `unreachable`/`unverifiable`; it does not run on a cached approval.

A path-qualified `argv[0]` (for example `/tmp/ws/ls`) is never treated as the
read-only builtin `ls`; it goes through the same approval path. This was a
classifier bug fixed with a regression test during A1.5 (see
`services/policy/risk_test.mbt`).

### 10.4 Exec, files, PTY, git and agents

```bash
monexus-host rpc --method machine.exec --params '{
  "machine_id":"mch_...","argv":["printf","hello"],"run_id":"run-1",
  "client_request_id":"crid-1"}'
monexus-host rpc --method machine.exec.status --params '{
  "machine_id":"mch_...","run_id":"run-1"}'
monexus-host rpc --method machine.fs --params '{
  "machine_id":"mch_...","op":"read","path":"README.md"}'
monexus-host rpc --method machine.pty --params '{
  "machine_id":"mch_...","op":"open","argv":["sh"],"rows":24,"cols":80}'
monexus-host rpc --method machine.git --params '{
  "machine_id":"mch_...","op":"status"}'
```

`machine.exec` returns `stdout`/`stderr` separately, the exit code, `status`,
`stop_reason`, `timed_out`, `run_id` and `started_at`. A timeout finalizes as
`cancelled` with `stop_reason=timeout` and is never a success. Filesystem
paths are node-relative; writes are atomically recorded and persisted.
`machine.git` is read-only (status/diff/log/show/branches). `machine.pty`
streams bytes through the node and keeps a status snapshot; it does **not**
surface the shell exit code (use exec when the code matters).

For an agent on a runtime machine, pass `machine_id` in `agent.start` (and a
`cwd` under a `--runtime-workspace-root`); the host registers the runtime ACP
launcher when the node attaches, so the process start and its approval use the
same Decision path:

```bash
monexus-host rpc --method agent.start --params '{
  "machine_id":"mch_...","agent_id":"claude","mode":"acp",
  "cwd":"/srv/monexus-workspace","prompt":"hello"}'
```

### 10.5 Idempotency and restarts

Every mutating call carries `client_request_id`; the primary caches responses
for a bounded window and the node keeps a durable idempotency record. To
retry, send the **same** id and parameters. A replay returns the original
`run_id`/`started_at` and does not start a second process. Note that
`monexus-host rpc` generates a fresh id each time and therefore cannot replay;
use a client that pins `client_request_id` (the harness uses
`tests/runtime/rpc_client.mjs`).

- **Node restart:** Runs that were still executing are finalized as `lost`
  with `success=false`; they never become success. Completed Runs and fs
  idempotency records are recovered from the node's durable event log.
- **Primary restart:** the node reconnects with backoff and catches up from
  its outbox cursor; completed Runs remain queryable. In a local drill,
  killing the primary while a node was connected left the listener port in
  `TIME-WAIT` and an immediate rebind on the same port failed; stop the node
  first (or restart on a new port) and let it reconnect.
- **No reattach:** live PTY sessions and in-flight child processes are not
  resumed after a node restart. Start a new session after the node is back.

### 10.6 Revoke, drain and switching back to SSH

```bash
monexus-host rpc --state-dir /var/lib/monexus --method runtime.revoke \
  --params '{"runtime_id":"node-a","reason":"rotate"}'
monexus-host rpc --state-dir /var/lib/monexus --method runtime.drain \
  --params '{}'
```

Revoking removes the credential immediately; a serving node exits within a
heartbeat and logs `revoked`, and `machine probe` no longer reports it online.
Re-pair with a new one-time code to re-enroll. Draining answers
`{"draining":true}` and lets nodes exit cleanly (`drained`).

To go back to SSH, revoke/drain the runtime node, remove its machine record
(`machine remove --id mch_...`), and add an SSH machine as in §2. Runtime and
SSH machine records and providers are separate: registering a local or SSH
machine does not change a runtime node's attachment, and the existing SSH
smoke/acceptance suites remain green.

### 10.7 Clearing node state and logs

Stop the node first, then remove its per-runtime directory:

```bash
rm -rf /var/lib/monexus-runtime/node-a
```

That directory holds the token, identity, outbox, idempotency store, PTY
snapshots and the node workspace (all owner-only). On the primary, the
transport state lives under `--runtime-state-dir` (0600 JSON); revoke the
runtime before deleting it so no credential is orphaned. Node logs are
operator-managed (stdout/stderr of `runtime serve`); the primary audit and
`<state>/logs` contain no pairing code, bearer token or command text. Never
copy the token file or a pairing code into a report.

### 10.8 Known limits and verification

- **No reattach** after a node restart; unfinished Runs are `lost` (above).
- **PTY exit codes are not surfaced**; use exec for exit status.
- **Primary crash rebind:** stop the node before an immediate same-port
  restart if the listener is still in `TIME-WAIT`.
- **Packaging:** verified for Linux x86_64 and macOS aarch64; Ubuntu was not
  separately verified in this environment, and RISC-V is out of scope. The
  A1.5 runtime-node evidence was produced on Linux x86_64; do not cite it as
  Ubuntu or as macOS runtime-node validation.
- **Real ACP model turn:** the harness runs a mock ACP agent by default. With
  `M4_REAL_ACP=1` (and a logged-in adapter under the node's HOME) it also
  attempts one real model turn. Without that dependency the row is recorded as
  `SKIP`/unverified, never as a pass.
- **Isolation:** `scripts/runtime_e2e.sh` runs the primary and node as
  separate processes with throwaway HOMEs, state dirs and workspace in one
  kernel network namespace; CI is unprivileged, so it does not claim namespace
  isolation. It asserts the node has no listening socket when `ss` is
  available. The same commands apply on two real hosts.
- **Acceptance evidence:** `scripts/runtime_e2e.sh` covers the ADR-0012
  verification items: pairing/transport security (A), exec/streams/timeout/
  path escape, fs, PTY, git (B), reconnect, lost Runs and primary/node restart
  (C), real ACP opt-in (E), revoke/drain (D) and log redaction (F); the SSH
  regression stays in `scripts/agent_smoke.sh`,
  `scripts/agent_ssh_smoke.sh` and `scripts/acceptance.sh`. Run the harness
  with:

  ```bash
  export PATH="$HOME/.moon/bin:$PATH"
  scripts/runtime_e2e.sh
  M4_REAL_ACP=1 scripts/runtime_e2e.sh   # also attempt a real model turn
  ```

  The A1.5 validation run on 2026-11-27 (Linux x86_64, Node 26) reported
  `129 passed, 1 skipped, 0 failed` and exited 0; the skipped row was the real
  ACP model turn (`M4_REAL_ACP` not set). CI runs the same command as the
  `Runtime e2e` step in `.github/workflows/ci.yml`.
## 11. Managed account credentials (A5)

Managed model accounts are opt-in. With `credential.enabled=false` (default)
the host keeps the V0.1 path exactly: no proxy environment, every
`credential.*` RPC answers `credential_disabled`, no credential events are
written, and readiness does not consult managed accounts.

```bash
monexus-host serve --credential-enabled true --credential-storage auto \
  --credential-lease-ttl-ms 900000 --credential-cooldown-ms 600000
# or MONEXUS_CREDENTIAL_ENABLED=1
```

`--credential-storage auto` uses the Keychain when the host detects macOS and
the file backend elsewhere. The file backend is a `0700` directory with `0600`
files under `<state-dir>/credentials/`; wrong permissions are refused, never
repaired silently. `--credential-storage file` forces that backend; asking for
`keychain` on a non-macOS host fails closed (`unsupported`) instead of falling
back. The Keychain backend feeds the secret through stdin, never argv, but it
has not been exercised end-to-end in the recorded environments and is
reported as unverified.

### Local Agent (the host machine)

1. Put the secret in a `0600` JSON params file so it never enters argv or shell
   history, then enroll:

   ```bash
   install -m 0600 /dev/null /tmp/mx-enroll.json
   $EDITOR /tmp/mx-enroll.json   # {"kind":"api_key","secret":"..."}
   monexus-host rpc --method credential.enroll --params-file /tmp/mx-enroll.json
   rm -f /tmp/mx-enroll.json
   # → {"credential":{"id":"crd_...","version":1,...}}; the secret is not echoed
   ```

2. Bind the credential to one Agent and profile. An empty `machine_id` means
   the primary's own machine:

   ```bash
   monexus-host rpc --method credential.binding.create --params '{
     "credential_id":"crd_...","agent_id":"claude","profile":"default"}'
   ```

3. Start the Agent with `"credential_profile":"default"` (optional when only
   one active binding exists). The Agent environment receives only
   `MONEXUS_CREDENTIAL_PROXY_URL=http://127.0.0.1:<port>` and
   `MONEXUS_CREDENTIAL_PROXY_TOKEN=mxp_...`; the real key stays in the store
   and the loopback proxy swaps the token for the upstream credential. The
   host spawns Agents with a fixed base allowlist (`PATH`, `HOME`, `LANG`,
   `LC_ALL`, `TMPDIR`, `USER`, `SHELL`, `TERM`) instead of inheriting its whole
   environment, so host secrets cannot leak into `/proc/<pid>/environ`.

4. Rotate by enrolling the new secret into the same credential (version+1;
   old version is rejected and live proxies stop):

   ```bash
   install -m 0600 /dev/null /tmp/mx-rotate.json
   $EDITOR /tmp/mx-rotate.json   # {"credential_id":"crd_...","secret":"..."}
   monexus-host rpc --method credential.rotate --params-file /tmp/mx-rotate.json
   rm -f /tmp/mx-rotate.json
   ```

5. Revoke with `credential.revoke {"credential_id":"crd_..."}` (or
   `binding_id`). Revocation marks the binding, closes its proxies and tokens,
   deletes the stored secret, and makes new starts fail readiness.

6. Inspect with `credential.status` and `credential.doctor`; both report
   storage, permissions/readiness, version and fingerprint but never the
   secret. `credential.binding.list` lists metadata only.

### Remote Agent (paired runtime node)

The primary never holds, receives or forwards the remote secret. The node
registers the secret on itself, offline, with its own login:

```bash
# On the node
install -m 0600 /dev/null /tmp/node-key
$EDITOR /tmp/node-key
monexus-host runtime credential-enroll --runtime-id rt_... \
  --profile default --secret-file /tmp/node-key
rm -f /tmp/node-key
# → profile, version, fingerprint, storage, state_dir
monexus-host runtime credential-status --runtime-id rt_...
monexus-host runtime credential-revoke --runtime-id rt_... --profile default
```

`runtime credential-enroll` is a local node command, not a node RPC: the node
service registers only `runtime.credential.status`, `.lease` and `.revoke`, all
of which carry binding metadata and fixed reasons, never a secret.

On the primary, create a metadata-only mirror binding with the node's printed
`credential_id`, `version` and `fingerprint`:

```bash
monexus-host rpc --method credential.binding.create --params '{
  "credential_id":"crd_...","machine_id":"mch_...","agent_id":"claude",
  "profile":"default","node_enrolled":true,"version":1,
  "fingerprint":"<sha256 from the node>","storage":"file","kind":"api_key"}'
```

`credential.enroll` (and a rotate carrying a secret) is refused for a remote
machine — enroll on the node instead. SSH machines are refused with
`credential_proxy_unsupported`; there is no second best-effort delivery path.

At `agent.start` the primary sends only the binding tuple. The node verifies
its local profile, version and fingerprint, starts a node-local loopback proxy
with a short-lived `mxs_` token, and fails closed when the primary lease is
expired. Node leases are renewed from the primary over the paired channel; with
the primary unreachable beyond `--credential-lease-ttl-ms` (default 15
minutes) the node stops authorizing new calls and records
`credential.lease.expired`. `credential.revoke` sends a metadata-only revoke
signal: the node deletes its local secret immediately when reachable, otherwise
at lease expiry, and syncs revocation before accepting new sessions after a
reconnect. Workspace, primary events and primary state never see the node
secret.

Remote rotation is node-local: re-run `runtime credential-enroll` with the new
secret, then mirror the new metadata with
`credential.rotate {"credential_id":"crd_...","version":N,"fingerprint":"..."}`
(no `secret`; the primary rejects one for a node-owned credential).

### Limits and rollback

- One credential has exactly one live binding. A second binding returns
  `credential_reused`; unbound Agent/machine pairs get no proxy coordinates.
- The `mxp_`/`mxs_` session token is a capability, not the real key. Agent
  output and persisted surfaces redact it and the real secret patterns
  (`mxp_`, `mxs_`, `Bearer`, `sk-`, `KEY=value`, private-key blocks); token
  copies die with the session or revocation.
- To roll back, revoke every binding first (releases proxies and tokens), then
  restart with `--credential-enabled false`. Revoked metadata stays for audit
  and cannot be revived; a rollback never degrades to plaintext injection.
- Readiness failures are deduplicated with a cooldown
  (`--credential-cooldown-ms`, default 10 minutes) and become one readable
  Decision per `(agent, machine, binding, reason)`; they never auto-retry in a
  storm.

## 12. Skill packs (A4)

Skill packs bundle instructions, resources and declared commands behind a
signature and an owner allowlist. The host stores them immutably (content
addressed), injects a frozen snapshot into an Agent session and exposes exactly
one gateway tool, `skill.invoke`, whose only argument is an `entry_id`. The
feature is off by default.

### Opting in

```bash
monexus-host serve --skill-enabled true    # or MONEXUS_SKILL_ENABLED=1
```

While the feature is off, every `skill.*` method answers `unsupported` with
`skill packs are disabled (skill.enabled=false)`, and a `skills` array passed
to `agent.start` is ignored.

### Bundle, manifest and signature

A bundle is a plain directory (not a symlink) containing `skill.json` plus the
declared files. `skill.json` must be a regular, non-executable file; every
physical file must be declared and every declared file must exist. Import reads
only a local directory and does not delete it afterwards.

```text
demo-skill/
  skill.json
  SKILL.md
  notes/README.md
```

```json
{
  "schema_version": 1,
  "name": "demo-skill",
  "version": "1.0.0",
  "description": "Report the repository status and summarise the conventions.",
  "permissions": ["workspace.read", "git.read", "exec.readonly"],
  "entry": {"path": "SKILL.md", "max_bytes": 4096},
  "resources": [
    {"path": "notes/README.md", "description": "House conventions"}
  ],
  "commands": [
    {"id": "status", "argv": ["git", "status", "--porcelain"],
     "mode": "read_only", "timeout_ms": 5000, "max_output_bytes": 8192}
  ],
  "source": {
    "kind": "local_directory",
    "path": "/home/me/demo-skill",
    "author": "owner",
    "created_at": "2026-11-27T00:00:00Z"
  },
  "signature": {"key_id": "owner-demo", "alg": "ed25519", "sig": "..."}
}
```

The signature is over a domain-separated content hash, and the host recomputes
it on import; the `skill.json` formatting above does not matter.

- Canonical body: exactly the declared fields above except `signature` (and the
  derived hash), object keys sorted, compact JSON, UTF-8.
- `content_hash` = `"sha256:"` + SHA-256 of
  `"monexus.skill.v1\n"` + canonical body + `"\n"` + one entry per physical
  file except `skill.json`, sorted by path: `path + "\n"` + SHA-256 of its
  bytes + `"\n"`.
- Signed payload: the ASCII string `"monexus.skill.sig.v1\n"` followed by the
  `content_hash`, signed with `ssh-keygen -Y sign -n monexus-skill-v1`.
  `signature.sig` is the base64 SSHSIG body without armor or whitespace; the
  public key is a bare `ssh-ed25519 <base64>` value.
- `source.kind` is `local_directory` only. Entry text is at most 32 KiB,
  resources at most 256 KiB each (64 resources), the bundle at most 4 MiB, and
  at most 32 commands; each command has a timeout of at most 600000 ms and an
  output cap of at most 1048576 bytes.

There is no bundled signer command yet. A complete fixture that canonicalises,
hashes and signs a bundle is in `services/host/skill_wbtest.mbt`; the canonical
rules live in `packages/skills/canonical.mbt`. The essential signing step is:

```bash
printf 'monexus.skill.sig.v1\n%s' "$CONTENT_HASH" > payload
ssh-keygen -q -Y sign -f owner_key -n monexus-skill-v1 payload
# strip the BEGIN/END SSH SIGNATURE lines and newlines -> signature.sig
```

### Registering keys, importing, allowlisting

```bash
monexus host rpc --method skill.key.register --params '{
  "key_id":"owner-demo",
  "public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."}'
# → {"key_id":"owner-demo"}

monexus host rpc --method skill.import --params '{
  "path":"/home/me/demo-skill"}'
# → {"skill":{"name":"demo-skill","version":"1.0.0",
#            "content_hash":"sha256:...","key_id":"owner-demo",
#            "file_count":3,"total_bytes":...,"status":"pending"}}
```

`skill.import` accepts an optional `source` but only `local_directory` is
supported; the source directory is not deleted after import. `file_count` and
`total_bytes` include every physical file, including `skill.json`, while the
content hash excludes it. A re-import of an already allowed, identical tuple
stays `allowed`; any other import starts `pending`. Refusals produce a
`skill.refused` event with a redacted source path and a stable reason code.

Import alone does not make a bundle usable. The owner allows an exact tuple:

```bash
monexus host rpc --method skill.allow --params '{
  "name":"demo-skill","version":"1.0.0","content_hash":"sha256:...",
  "mode":"loaded","reason":"owner"}'
# → {"name":"demo-skill","version":"1.0.0",
#    "content_hash":"sha256:...","state":"allowed"}

monexus host rpc --method skill.allowlist.revoke --params '{
  "name":"demo-skill","version":"1.0.0","content_hash":"sha256:...",
  "reason":"superseded"}'
# → state="revoked"
```

`skill.allow` requires the tuple to be imported and its key registered and
unrevoked; `mode` defaults to `loaded`. Revoking an allowlist entry marks the
row `revoked` but does not remove Agent/Task bindings; a session started after
the revocation re-checks the allowlist and refuses to start. Keys are managed
with `skill.key.register` and `skill.key.revoke {"key_id":"..."}`; there is no
trust-on-first-use, and `skill.doctor` re-verifies stored bundles against the
current key set.

### Binding to an Agent, Task or session

```bash
monexus host rpc --method skill.enable --params '{
  "scope":"agent","scope_ref":"agt_...","name":"demo-skill",
  "version":"1.0.0","content_hash":"sha256:...","mode":"loaded"}'
# → {"binding":{"scope":"agent","scope_ref":"agt_...",
#               "name":"demo-skill","version":"1.0.0",
#               "content_hash":"sha256:...","mode":"loaded"}}
```

Scopes are `agent`, `task` and `session`. An `agent` scope reference must be a
valid agent id; `task`/`session` references are non-empty ids of at most 128
characters. The tuple must already be allowed. `loaded` injects the entry text
and materialises the entry and resources into the session; `available` adds a
one-line card only and cannot be invoked.

Bindings can also be requested for one `agent.start` call through a top-level
`skills` array (at most 64 entries, each an exact
`name`/`version`/`content_hash`/`mode` tuple; a malformed array fails the whole
request). Session bindings outrank Task bindings, which outrank Agent bindings.
For the same name, a differing version or hash is refused as `skill_conflict`;
any loaded declaration wins over available. A session holds at most 8 loaded
and 32 available skills.

### Session injection and the gateway

At `agent.start` the host re-verifies the allowlist row, manifest tuple,
permission ceiling, duplicate entry ids, stored hash and signature, and skill
dependencies. Any failure blocks the start; no partial session is created.
Local loaded skills are copied to
`<agent home>/sessions/<sid>/skills/<name>-<version>` (directories 0700, files
0444) and injected before the prompt under the exact header
`--- SKILLS (untrusted, enabled for this session) ---`. The default budget is
8192 bytes (hard cap 32768); overflow is marked with
`[skill entry truncated]`. The snapshot is frozen for the life of the session.

A local session with loaded skills also receives a host-owned stdio MCP server
named `monexus-skills` (`monexus-host skill-mcp --state-dir ... --session ...`)
and a host-generated `MONEXUS_SKILL_TOKEN` in its environment. Do not set that
variable yourself; it is a per-session capability and is never printed or
audited. The gateway advertises exactly one tool, `skill.invoke`, whose input
schema contains only the required string `entry_id`. The token is not exposed
through RPC or logs, so the two calls below are mainly for tests and
embedders:

```bash
monexus host rpc --method skill.tools --params '{"token":"<session token>"}'
monexus host rpc --method skill.invoke --params '{
  "token":"<session token>","entry_id":"<entry id>"}'
# → {"invocation":{"name":"demo-skill","version":"1.0.0",
#    "content_hash":"sha256:...","entry_id":"...","exit_code":0,
#    "output":"...","truncated":false,"decision_id":""}}
```

A non-zero `exit_code` is a normal result. Through MCP, `tools/call` returns
the output as text with `(exit_code=N)` appended and sets `isError` when the
exit code is non-zero.

### Permissions, Decisions and execution limits

Declared permissions are intersected with the Agent's ceiling. The default
ceiling is `workspace.read`, `git.read`, `exec.readonly`; the available
permissions are `workspace.read`, `workspace.write`, `git.read`, `git.write`,
`exec.readonly` and `exec.workspace`. A per-Agent ceiling is set with:

```bash
monexus host rpc --method skill.permissions.set --params '{
  "agent_id":"agt_...",
  "permissions":["workspace.read","git.read"]}'
```

A `write`-mode command always raises a Decision of kind `skill` with
`approve`/`deny` options; the call waits up to 5 minutes, then the Decision
expires and the call fails as `decision_denied`. Policy-denied commands fail
as `policy_denied`; critical commands are rejected before any Decision is
raised. A command runs as the exact argv with a fixed `PATH`, `LANG=C`,
`LC_ALL=C`, `HOME` set to the session skills directory and the session cwd.
The first token may not be a shell/interpreter from the denylist, arguments may
not start with `/` or `~`, and no argument may contain a `..` segment. Output
is redacted and truncated to the command's `max_output_bytes`; the gateway
allows 120 calls per 60 seconds per token.

### Upgrade, disable, uninstall and doctor

```bash
monexus host rpc --method skill.upgrade --params '{
  "scope":"agent","scope_ref":"agt_...",
  "name":"demo-skill","version":"1.1.0","content_hash":"sha256:...",
  "mode":"loaded"}'

monexus host rpc --method skill.disable --params '{
  "scope":"agent","scope_ref":"agt_...","name":"demo-skill"}'

monexus host rpc --method skill.uninstall --params '{
  "name":"demo-skill","version":"1.0.0","content_hash":"sha256:..."}'
```

`skill.upgrade` only rebinds an already imported and allowed tuple; it never
downloads content, and returns the previous `old_version` alongside the new
binding. `skill.disable` removes a binding (it also succeeds when the binding
is already gone) but cannot recall text already injected; the gateway refuses
new calls, as the response's `active_sessions_note` says. `skill.uninstall`
revokes the allowlist row, removes bindings and drops live capabilities. When
a live session still holds the tuple the stored row becomes `pending_delete`
and is collected when that session finalises or on `skill.doctor`; the
response reports `pending_delete` and `affected_sessions`. `skill.list`
optionally filters by `scope`/`scope_ref` and returns `skills`, `allowlist` and
`bindings`; `skill.get` returns one stored bundle plus its manifest and allow
state; `skill.doctor` returns `{ok,checks,problems}`.

Events and audits to watch: `skill.loaded` and `skill.context_truncated` at
session start, `skill.imported`/`skill.refused` around import,
`skill.allowlisted`, `skill.enabled`, `skill.upgraded`, `skill.uninstalled`,
`skill.invoked` and `skill.invoke_denied` at call time; the corresponding
audit entries include `skill.session.load` and `skill.invoke`.

### Known limits

- Import and upgrade are local-only: the host never downloads a bundle, and an
  upgrade binds bytes already stored on the host.
- Remote (SSH/runtime) sessions receive the injected, declarative skill text
  only. This release does not wire `skill.invoke` or the MCP server to remote
  sessions, so a remote Agent has no invocable skill capability even when the
  injected header lists entries.
- `skill.json` is metadata: it is excluded from the content hash and is not
  materialised into the session; only the entry and declared resources are
  copied.
- Disable and uninstall cannot recall injected text. Revoking the allowlist is
  not a binding cleanup; use `skill.disable`/`skill.uninstall` for that.
- `skill.permissions.get` always reports `default:true` in this release, even
  when a custom ceiling is set; read the `permissions` array instead.

## 13. Environment recipes (A2)

An environment recipe describes a Docker container: a digest-pinned image,
mounts, resource limits, an environment-variable allowlist and three lifecycle
hooks. Recipes are owner-signed and owner-approved; creating an environment
always goes through a Decision. Environments can then be used directly
(`environment.exec`) or attached to a Run.

### Owner trust store

Recipe signatures are checked against an owner trust store only; there is no
trust-on-first-use, and a recipe cannot add a key. The store is read once at
host startup from `MONEXUS_RECIPE_TRUST` or, by default,
`<state-dir>/recipe_trust.json`; edit it and restart the host to apply changes.
It must be a regular file (not a symlink) with mode `0600` or `0400`, and
strict JSON with only the `keys` field:

```json
{
  "keys": [
    {
      "key_id": "owner-demo",
      "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...",
      "added_at": "2026-11-27T00:00:00Z"
    }
  ]
}
```

`key_id` is at most 64 characters of alphanumerics, `.`, `_`, `-` or `@`;
`public_key` is a bare `ssh-ed25519` key without a comment; timestamps use
`YYYY-MM-DDTHH:MM:SSZ`. An optional `revoked_at` retires a key. A missing or
invalid store means no recipe can be imported, and the host still starts.

### Recipe document and signature

```json
{
  "schema_version": 1,
  "name": "demo",
  "version": "1.0.0",
  "image": {
    "ref": "nginx:alpine",
    "digest": "sha256:<64 lowercase hex>"
  },
  "workdir": "/workspace",
  "mounts": [
    {"source": "workspace", "target": "/workspace", "mode": "rw"}
  ],
  "limits": {"cpu_millis": 1000, "memory_mb": 2048, "pids": 512},
  "network": "none",
  "lifecycle": {
    "prepare": {"argv": ["/bin/true"], "timeout_s": 10},
    "start": {"argv": ["/bin/true"], "timeout_s": 10},
    "stop": {"argv": ["/bin/true"], "timeout_s": 10}
  },
  "source": {
    "kind": "local_file",
    "path": "/home/me/demo.recipe.json",
    "author": "owner",
    "created_at": "2026-11-27T00:00:00Z"
  },
  "signature": {"key_id": "owner-demo", "alg": "ed25519", "sig": "..."}
}
```

- `image.digest` is mandatory and must be `sha256:` plus 64 lowercase hex
  characters; a tag is display-only, and Docker pull/create always use the
  digest. Unknown fields such as `privileged` or `ports`, and values such as
  host networking, are rejected rather than ignored.
- `mounts` holds exactly one `workspace` source and at most one `scratch`
  source, with unique container targets; extra host paths must live under
  those roots. `mode` defaults to `ro` but is written into canonical bytes, so
  signers should spell it out.
- All three lifecycle hooks are mandatory. Each has exactly one of `argv` or
  `script`, plus `timeout_s` between 1 and 3600. `limits` defaults are 1000 CPU
  millis, 2048 MB and 512 pids; `network` defaults to `none`.
- If any environment values will be supplied, the recipe must declare an
  `env_allowlist`; values are never taken from inline secret-named parameters.

The signature is over the content hash of canonical bytes: the declared fields
with keys sorted, compact JSON, and `signature` excluded. The signed payload is
the ASCII `content_hash` (`sha256:` + SHA-256 of the canonical bytes) with no
trailing newline, using namespace `monexus-recipe-v1`; `signature.sig` is the
base64 SSHSIG body with no armor or whitespace. Verification shells out to
`ssh-keygen -Y verify` (OpenSSH 8.0 or newer); a missing or unusable verifier
fails closed. `scripts/agent_ssh_smoke.sh` contains a complete, working signer;
the canonical and schema rules are in `packages/recipes/`.

### Import, inspect, revoke

```bash
(umask 077; jq -n --arg text "$(cat demo.recipe.json)" \
  '{recipe:$text,source:"inline"}' > /tmp/recipe-params.json)
monexus host rpc --method recipe.import --params-file /tmp/recipe-params.json
# → {"recipe":{"id":"rcp_...","name":"demo","version":"1.0.0",
#    "content_hash":"sha256:...","key_id":"owner-demo",
#    "state":"trusted",...}}

monexus host rpc --method recipe.list
monexus host rpc --method recipe.show --params '{"recipe":"demo@1.0.0"}'
monexus host rpc --method recipe.revoke --params '{"recipe":"demo@1.0.0"}'
```

`recipe.import` takes the signed document as the `recipe` string; `source` is
free-form metadata for the audit trail. Re-importing an identical hash is
idempotent; the same `name@version` with different content is a `conflict`, and
a revoked recipe cannot be re-imported. Every create and start re-verifies the
stored recipe against the current trust store. A refused import produces a
`recipe.refused` event with a reason code.

### Create: plan, approval, retry

`environment.create` takes `workspace_id` and a `recipe` reference of the form
`name@version`, plus optional `worktree_id`, `machine_id`, `environment_id`,
`env` (`[{"name":...,"value":...}]`), `mounts`, `ephemeral`, `ttl_s`,
`approval_id` and `client_request_id`.

The plan pins the exact environment id, mounts, env names, limits, network and
user. Approval is required for a high-risk plan (bridge network, a writable
extra mount, or a prepare hook) and in practice for every valid recipe, because
the prepare hook is mandatory. The first call therefore returns an error whose
`data` is:

```json
{"kind":"approval_required","decision_id":"dec_...",
 "expires_at":"...","plan_digest":"sha256:...","environment_id":"env_..."}
```

Approve it through the normal Inbox flow, then retry with the proposed
`environment_id` and the returned `approval_id`:

```bash
monexus host rpc --method decision.list --params '{"status":"pending"}'
monexus host rpc --method decision.respond --params '{
  "decision_id":"dec_...","option_id":"approve","text":"approved"}'

monexus host rpc --method environment.create --params '{
  "workspace_id":"wsp_...","recipe":"demo@1.0.0",
  "environment_id":"env_...","approval_id":"dec_...",
  "client_request_id":"env-create-1"}'
# → {"environment":{"state":"running", ...}}
```

The approval lives 15 minutes and is burned only after the conflict check and
lease acquisition; it is single-use. At most one lease exists per target, so a
concurrent create is refused as `conflict`. `client_request_id` (and a repeat
`environment_id`) make retries idempotent. The host writes a durable
`environment.creating` event before touching Docker. A same-name container is
adopted only on an exact plan match; otherwise create returns `conflict` and
leaves it untouched.

### Using an environment

```bash
monexus host rpc --method environment.exec --params '{
  "environment_id":"env_...","exec_id":"exec-1",
  "argv":["sh","-c","printf ok"],"timeout_s":60}'
# → {"exec_id":"exec-1","exit_code":0,"stdout":"ok",
#    "stderr":"","timed_out":false,"cancelled":false,"truncated":false}
```

`environment.exec` is argv-only (no shell unless you pass one), requires a
unique `exec_id` of at most 128 characters, runs only while the environment is
`running`, and defaults to a 600-second timeout (cap 3600). Results are cached
per `(environment, exec_id)` while the host runs. `stop`/`destroy` cancel
in-flight execs; a daemon or transport failure is returned as
`{"__exec_error":{...}}` rather than a normal result. `stdout` and `stderr` are
each redacted and capped at 65536 bytes, with `truncated` set if either was cut.

A Run can attach an environment with `run.create`'s optional `environment_id`.
An explicit environment must belong to the exact workspace/worktree and be
running; otherwise the active running environment for that target is used. Run
and verify commands are executed as `sh -c <command>` inside the container at
the recipe workdir, while workspace file/git IO stays on the provider and
binds the same root. Agent-mode Runs with an environment are rejected in A2.1
(`agent runs with an environment are not supported in A2.1 (A2.2)`). An
`ephemeral` environment is destroyed when the Run reaches a terminal state, and
only that Run's environment is touched. `terminal.open`,
`workspace.gitStatus` and `workspace.gitDiff` redirect into a running
environment for the workspace root (no specific `worktree_id`).
`terminal.resize` takes `session_id`, `rows` and `cols` (validated `1..10000`);
local PTY, SSH project terminals (including SSH container terminals), container
and runtime environments apply it. SSH runs `ssh -tt` behind a local PTY, so
resizing that PTY sends SIGWINCH to `ssh`, which forwards an SSH
`window-change` request to the remote PTY.

### Start, stop, destroy, list, doctor

```bash
monexus host rpc --method environment.stop --params '{"environment_id":"env_..."}'
monexus host rpc --method environment.start --params '{
  "environment_id":"env_...","approval_id":"dec_..."}'
monexus host rpc --method environment.destroy --params '{"environment_id":"env_..."}'
monexus host rpc --method environment.list --params '{"workspace_id":"wsp_..."}'
monexus host rpc --method environment.doctor --params '{"environment_id":"env_..."}'
```

- `environment.start` works only from `stopped`. It requires approval when the
  recipe has a start hook or uses the bridge network; since the start hook is
  mandatory, restarting in practice always asks once. A failed start hook stops
  the container and leaves the record with the error.
- `environment.stop` calls `docker stop` only. It keeps the container and the
  environment/scratch directories, moves the record to `stopped`, treats a
  missing container as success and is safe to repeat. It does **not** run the
  recipe's `lifecycle.stop` hook in A2.1.
- `environment.destroy` removes the container, environment directory and
  scratch, releases the lease and records a tombstone. It is idempotent,
  including for an unknown id. If cleanup cannot be confirmed it returns
  `cleanup_failed` with artifact detail, keeps the record as
  `orphan_suspected`, and writes
  `<state-dir>/artifacts/environment-<id>-cleanup.log`.
- `environment.get` returns `{environment:{...}}`; only destroyed records are
  tombstones. `environment.list` accepts an optional `workspace_id`.
  `environment.doctor` is read-only and reports daemon, container, label,
  running, mount and optional recipe checks; its guidance is to inspect only
  the `monexus-env-<id>` container and never run `docker system prune` or
  delete unowned containers.

When `MONEXUS_ENVIRONMENT_ENABLED=false` (or `0`/`off`/`no`), `create`, `start`
and `exec` return `unsupported`; `stop`, `destroy`, `doctor`, `list`, `get` and
all recipe methods remain available so cleanup still works.

### Cleanup guarantees and reconciliation

Every managed container is named `monexus-env-<environment_id>` and carries
`monexus.managed=true`, `monexus.primary_id`, `monexus.environment_id`,
`monexus.workspace_id` and `monexus.recipe_hash` labels. The host reconciles at
startup and every 60 seconds, read-only: it adopts a matching container only on
an exact recorded-plan match (including a re-verified recipe), removes a
container that matches a timed-out create intent, and marks any label or plan
mismatch as drift without touching it. It never creates containers and never
deletes unowned ones. If a runtime node's link is unavailable, destroy returns
`unreachable` before cleanup and leaves the record; there is no silent reroute
to local Docker. The honest invariant is therefore: a durable intent, labelled
containers, periodic reconcile, `environment.doctor`, and an explicit
`orphan_suspected` state when cleanup cannot be confirmed — not a promise that
no orphan can ever exist.

### Paths and runtime nodes

- Environment directories live at
  `<runner home>/.monexus/environments/<id>` (mode 0700); a temporary env-file
  is removed after container start and before the prepare hook. The workspace
  scratch directory is `<workspace root>-monexus-scratch-<id>` locally or over
  SSH, and `<node home>/.monexus/environments/<id>/scratch` on a runtime node.
- The runner is chosen from the machine: local, SSH, or a paired runtime node.
  A runtime machine must have a live paired transport session, otherwise the
  call fails as `unreachable`; a node without a usable home fails as
  `unsupported`. There is no local fallback.
- Runtime nodes use the generic runtime exec/fs/pty primitives, with paths
  confined to the `workspace` or `environments` root; they expose no
  environment-specific RPC. Their environment root is
  `<node home>/.monexus/environments` (mode 0700), and the host drives the same
  create/start/stop/destroy/exec sequence over those primitives.

### Known limits

- `lifecycle.stop` is declared, signed and mandatory, but `environment.stop`
  and `environment.destroy` do not execute it in A2.1; only Docker stop/remove
  happen. Do not rely on the stop hook for cleanup work.
- `ttl_s` is recorded on the environment but is not enforced anywhere, and
  there is no automatic TTL stop.
- Approval TTL is fixed at 15 minutes and is not caller-configurable.
- Docker-backed end-to-end tests are opportunistic: they visibly skip in CI
  when no Docker daemon is reachable or when `nginx:alpine` with a repository
  digest is not available locally. A skip is not a pass; `environment.doctor`
  is the supported way to check a live environment.
- The recipe schema rejects privileged mode, published ports and host
  networking outright; an approval cannot enable them.

## 14. Environment variables

| variable | purpose |
| --- | --- |
| `MONEXUS_STATE_DIR` | state directory (default `$HOME/.monexus`) |
| `MONEXUS_RUNTIME_DIR` | default node state base for `runtime pair/serve/status` (default `$HOME/.monexus/runtime`); overridden by `--state-base` |
| `MONEXUS_THEME=light\|dark` | desktop startup appearance used when no Settings choice has been saved (illegal or missing → dark) |
| `MONEXUS_LANG=en\|zh` | desktop startup language used when no Settings choice has been saved (illegal or missing → English; `zh-CN`/`zh-Hans` are also accepted) |
| `MONEXUS_CONFIG_DIR` | desktop preference directory (default `$XDG_CONFIG_HOME/monexus`, else `$HOME/.config/monexus`); the theme choice is `theme.json` and the language choice is `language.json` |
| `MONEXUS_HOST_BIN`, `MONEXUS_DESKTOP_BIN` | override component binaries in the launcher |
| `MONEXUS_MAX_PARALLEL` | per-machine Run limit (default 4) |
| `MONEXUS_AGENT_SSH=1` | opt in to the round-1 remote-agent PoC: SSH-backed `agent.start` launches the adapter over `ssh -T` instead of returning the local-only error |
| `MONEXUS_SKILL_ENABLED=1` | default for `--skill-enabled` (skill packs stay off unless enabled) |
| `MONEXUS_ENVIRONMENT_ENABLED=false` | disable environment `create`/`start`/`exec` (`0`, `off`, `no` also disable); `stop`/`destroy`/`doctor`/`list`/`get` and recipe methods stay available for cleanup |
| `MONEXUS_RECIPE_TRUST` | owner trust-store file for recipe signing keys (default `<state-dir>/recipe_trust.json`); read only at host startup |
| `MONEXUS_TRIGGER_ENABLED=1` | default for `--trigger-enabled` (triggers stay off unless enabled) |
| `MONEXUS_TZDATA_DIR` | tzdata directory for IANA schedule timezones (default `/usr/share/zoneinfo`) |
| `MONEXUS_WEBHOOK_BODY_LIMIT` | webhook body limit in bytes (default 65536, cap 262144) |
| `MONEXUS_WEBHOOK_FRESHNESS_S` | webhook timestamp freshness window in seconds (default 300, cap 900) |
| `MONEXUS_WEBHOOK_READ_TIMEOUT_MS` | webhook request read timeout (default 5000, cap 10000) |
| `MONEXUS_WEBHOOK_RATE_TRIGGER_PER_MIN` | per-trigger webhook rate (default 60, cap 600) |
| `MONEXUS_WEBHOOK_RATE_KEY_PER_MIN` | per-key webhook rate (default 120, cap 1200) |
| `MONEXUS_WEBHOOK_RATE_GLOBAL_PER_MIN` | global webhook rate (default 300, cap 3000) |
| `MONEXUS_RECOVERY_POLL_MS` | durable Run poll interval |
| `MONEXUS_RECOVERY_UNVERIFIABLE_MS` | transport-error window before `unverifiable` |
| `MONEXUS_LINK_TRACE=1` | desktop stdout trace of link connecting/online/offline |
| `MONEXUS_SCENE_PAGE`, `MONEXUS_SCENE_HOST`, `MONEXUS_SCENE_MACHINES` | deterministic `moui screenshot` scenes (tests) |
| `TMUX_TMPDIR` | isolate the tmux server used by tests |
| `ACCEPTANCE_SKIP_PACKAGE=1` | acceptance uses repo binaries instead of a tarball |
| `M7_REAL_ACP=1` | acceptance also probes a real ACP adapter |
| `M4_REAL_ACP=1` | runtime e2e harness also attempts a real ACP model turn (otherwise recorded as unverified) |
| `RUNTIME_E2E_KEEP=1` | keep the runtime e2e harness work directory, state dirs and logs |

### Theme preference

The Settings page's Light/Dark control applies immediately and saves the
explicit choice locally for the desktop. Startup uses, in order:

1. the saved choice (`theme.json` in the config directory above);
2. a legal `MONEXUS_THEME=light|dark`;
3. dark, the product default.

The file is one small JSON object (`{"schema_version":1,"theme":"light"}`),
written atomically with mode 0600 and holding no secrets; it is not part of
the workspace or the host event log. Editing or deleting it is safe: a missing
file is silent, while an unreadable, corrupt or unknown-valued file is ignored,
falls through to the environment/default and is reported on the Settings page.
`MONEXUS_THEME` therefore only decides the mode until a choice has been saved;
remove `theme.json` to make the variable authoritative again.

### Language preference

The Settings page's English/中文 control switches the desktop UI immediately
and saves the explicit choice locally. Startup uses, in order:

1. the saved choice (`language.json` in the config directory above);
2. a legal `MONEXUS_LANG=en|zh` (`zh-CN`, `zh-Hans`, `en-US` etc. are accepted);
3. English, the product default.

The file is one small JSON object (`{"schema_version":1,"language":"zh"}`),
written atomically with mode 0600 and holding no secrets. It lives beside
`theme.json`, not in the workspace or host event log, and has the same failure
handling: a missing file is silent; an unreadable, corrupt or unknown-valued
file is ignored, falls through and is reported on the Settings page. Remove
`language.json` to make `MONEXUS_LANG` authoritative again.

The static desktop shell (navigation, pages, buttons, placeholders and form
validation) is translated. Host/agent technical output, ids, commands and
error strings returned by the host remain in the language they were produced
in, so diagnostics stay searchable and unchanged. macOS renders Chinese with
the system PingFang/Hiragino fonts; a Linux desktop needs a CJK font such as
Noto Sans CJK SC (`fonts-noto-cjk`) for the Chinese labels to display.
