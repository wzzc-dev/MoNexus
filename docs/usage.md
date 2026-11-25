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
- Without Wayland/X11 the launcher exits 3 with a headless/xvfb hint. The
  native desktop binary does the same. Under CI or a headless box:
  `xvfb-run -a monexus` runs the real window against a virtual X server.

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
worktree form.

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
- Agent sessions are local-workspace only by default in V0.1; remote agent
  sessions are not supported yet (Agent over SSH is a gated PoC, see
  [ADR-0011](adr/0011-agent-over-ssh.md)). Transcripts are kept in memory
  (bounded); sessions/decisions/artifacts persist but transcript text does not
  survive a host restart.

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
  real DSH crash; the wrapper is test-only and not committed. No Ubuntu/macOS
  claim is made.
- Still missing for real remote agents: `agent.probe` is local-only,
  `agent.resume` does not reconstruct an SSH launch, and `env` from
  `agent.start` is not forwarded over SSH.

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

## 9. Environment variables

| variable | purpose |
| --- | --- |
| `MONEXUS_STATE_DIR` | state directory (default `$HOME/.monexus`) |
| `MONEXUS_THEME=light\|dark` | desktop startup appearance used when no Settings choice has been saved (illegal or missing → dark) |
| `MONEXUS_CONFIG_DIR` | desktop preference directory (default `$XDG_CONFIG_HOME/monexus`, else `$HOME/.config/monexus`); the theme choice is `theme.json` |
| `MONEXUS_HOST_BIN`, `MONEXUS_DESKTOP_BIN` | override component binaries in the launcher |
| `MONEXUS_MAX_PARALLEL` | per-machine Run limit (default 4) |
| `MONEXUS_AGENT_SSH=1` | opt in to the round-1 remote-agent PoC: SSH-backed `agent.start` launches the adapter over `ssh -T` instead of returning the local-only error |
| `MONEXUS_RECOVERY_POLL_MS` | durable Run poll interval |
| `MONEXUS_RECOVERY_UNVERIFIABLE_MS` | transport-error window before `unverifiable` |
| `MONEXUS_LINK_TRACE=1` | desktop stdout trace of link connecting/online/offline |
| `MONEXUS_SCENE_PAGE`, `MONEXUS_SCENE_HOST`, `MONEXUS_SCENE_MACHINES` | deterministic `moui screenshot` scenes (tests) |
| `TMUX_TMPDIR` | isolate the tmux server used by tests |
| `ACCEPTANCE_SKIP_PACKAGE=1` | acceptance uses repo binaries instead of a tarball |
| `M7_REAL_ACP=1` | acceptance also probes a real ACP adapter |

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
