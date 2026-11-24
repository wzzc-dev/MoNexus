# MoNexus

MoNexus is a local-first desktop shell for machines, tasks and agent
sessions. This worktree contains the **M5 vertical slice**: the M4 host and
MoUI shell extended with Task/Run scheduling, per-machine `max_parallel`
queueing, idempotent dispatch, a `verify[]` evidence gate backed by
Artifacts and owner Decisions, cursor-based event refresh in the desktop
Tasks board/Run detail/Activity stream, and `search.sessions` over session
and decision text (FTS5 with a LIKE fallback). The host keeps machine,
workspace/worktree/lease, agent-session, decision, artifact, project, task,
run and evidence records plus the append-only event log in SQLite.

Crash recovery for in-flight runs (M6) and packaging (M7) are intentionally
**not** implemented here.

## Layout

```
moon.work                     workspace manifest
packages/contracts/           JSON-RPC, event envelope, discovery, machine/agent/task contracts
packages/machines/            SQLite store (machines, workspaces, agents, decisions, artifacts, tasks, runs, evidence) + replay
packages/providers/           SSH/PTY, local-or-SSH workspace provider, ACP agent provider
packages/host-client/         host.json discovery + WebSocket JSON-RPC client
services/host/                monexus-host executable (serve/status/subscribe/machine/rpc) + agent/task handlers
apps/desktop/app/             MoUI model/update/view, host-link + machine + agent stream workers, tests
apps/desktop/linux_skia/      Linux native entry + Vulkan linker shim
scripts/host_smoke.sh         end-to-end host smoke test (M1 regression)
scripts/machine_smoke.sh      machine registry + SSH probe smoke test (temp sshd/fake ssh)
scripts/workspace_smoke.sh    M3 workspace/worktree/lease/terminal smoke (temp sshd)
scripts/agent_smoke.sh        M4 ACP session/permission/memory smoke (mock adapter)
scripts/task_smoke.sh         M5 Task/Run scheduling, evidence gate, events/search smoke (temp sshd)
tests/agent/                  mock ACP + stdout test doubles (test-only, JS)
docs/m1.md … docs/m5.md       design notes, verification and limitations
spikes/m0/                    frozen M0 spike (see docs/spikes/m0.md)
```

## Prerequisites

- MoonBit toolchain with native target (`~/.moon/bin` on `PATH`).
- **Node.js on `PATH`** — the MoUI skia package runs a node prebuild step.
- Linux: a Vulkan runtime (`libvulkan.so.1`). The desktop package adds a tiny
  repo-local linker script named `libvulkan.so` so linking works without
  `libvulkan-dev`; it is used only through `-L`.
- A display server (Wayland or X11) to open the native window. Headless
  machines can still build, test and render screenshots.
- For **real** agent sessions: a logged-in Claude Code account on the host
  machine, and network access for the first
  `npx -y @zed-industries/claude-code-acp@0.16.2` download. The host spawns
  the adapter via `env -u CLAUDECODE` and reuses the machine's existing
  login; it never reads or logs credentials. Without a login the readiness
  probe fails and a readiness Decision shows up in the desktop Inbox.

```bash
export PATH="$HOME/.moon/bin:$HOME/.nvm/versions/node/v26.13.0/bin:$PATH"
```

The Node path above is the one used during M1 verification; use whatever
`node` your environment provides.

## Build and test

Run everything **from the repository root**. The desktop link flag
`-Lapps/desktop/linux_skia/third_party/vulkan` is relative to this directory.

```bash
moon build --target native
moon test  --target native
```

Expected: build succeeds and all tests pass (contracts, providers,
host-client, machines, host, desktop app).

If the Vulkan shim cannot be used in your environment, set
`MOUI_SKIA_ENABLE_GPU_VULKAN=0` before building; that avoids linking against
Vulkan at the cost of the GPU path.

## Run the host

```bash
# Terminal 1: state dir defaults to $MONEXUS_STATE_DIR or $HOME/.monexus
_build/native/debug/build/monexus/host/host.exe serve

# Terminal 2 (same state dir)
_build/native/debug/build/monexus/host/host.exe status
_build/native/debug/build/monexus/host/host.exe subscribe --max-events 3
```

`serve` writes `host.json` atomically with mode `0600`, binds a random
`127.0.0.1` port, rejects a second instance with the `host.lock` flock, and
opens `<state_dir>/monexus.db`. Machine records and events are persisted
there; after a restart the event sequence continues and `subscribe --since 0`
replays the recent machine events.

### Machine registry

```bash
HOST=_build/native/debug/build/monexus/host/host.exe

# Explicit target; --use-ssh-config false pins to -F /dev/null.
$HOST machine add --name box --host 127.0.0.1 --port 2222 \
  --user me --identity /path/to/key --use-ssh-config false \
  --host-key-policy accept-new --known-hosts-file /tmp/monexus_known_hosts

$HOST machine list
$HOST machine probe --id mch_... --timeout-seconds 10
$HOST machine remove --id mch_...
```

`add` and `probe` record the effective `ssh -G` values (hostname/user/port/
identityfile/...). When `--use-ssh-config` is on, values inherited from
`~/.ssh/config` are reflected in the record; with it off the explicit record
is the only source of truth. Probe failures come back as `Unauthorized`,
`Timeout`, `NotFound`, `Unreachable`, `HostKeyRejected` or `RemoteError` with
a readable reason and the first stderr line.

Smoke tests:

```bash
scripts/host_smoke.sh       # M1 host regression
scripts/machine_smoke.sh    # machine add/list/probe/remove, events, restart
scripts/workspace_smoke.sh  # M3 open/read/write/diff/worktrees/leases/terminals
scripts/agent_smoke.sh      # M4 ACP session → permission → Decision → memory artifact
scripts/task_smoke.sh       # M5 tasks/runs/evidence gate/events/search
M4_REAL_ACP=1 scripts/agent_smoke.sh   # also probes the real claude-code-acp once
```

`agent_smoke.sh` runs entirely against a temp state dir/temp `HOME` with a
JavaScript mock ACP agent under `tests/agent` (never on the product path).
It proves probe readiness (ok + auth failure), AGENTS.md read-only,
audited MEMORY.md writes, memory injection, streaming/send, the permission
round trip through the Inbox, stop + memory diff artifact, resume via
`session/load`, the stdout fallback, host-restart reconcile, and event
replay. The opt-in real-adapter section reports `UNVERIFIED` (skipped)
instead of failing when the machine is not logged in.

`task_smoke.sh` uses a temp state dir, `MONEXUS_MAX_PARALLEL=1` and a
throwaway loopback sshd. It proves the local happy path (inherited verify,
subtask parent, idempotent dispatch, evidence/artifacts/diff/rollup), local
queueing and cancellation, all three verify-decision options (waive/retry/
fail), event cursor stability, `search.sessions`, local + SSH runs on one
task in parallel, host-restart projection reads, and illegal transitions.
See `docs/m5.md` for the schedule/evidence/event design and M5 limitations.

`machine_smoke.sh` starts an ephemeral non-root sshd on a random loopback
port and injects a fake `ssh` for error classification. Every `add` passes an
explicit temporary known-hosts file; the script snapshots the real `~/.ssh`
before and after and asserts it was not modified. It never contacts an
external machine. `workspace_smoke.sh` uses the same sshd/temp-HOME pattern
and additionally proves that two worktrees written in parallel stay isolated
and that a second lease on the same target is refused.

## Run the desktop shell

```bash
_build/native/debug/build/monexus/desktop/linux_skia/linux_skia.exe
```

Start the host first (or let the shell show `offline` and retry). The window
shows eight switchable pages — Home, Machines, Projects, Agents, Inbox,
Tasks, Search, Settings — and a live host status (`connecting` / `online` /
`offline`) with an event counter and a 1.5 s reconnect backoff.

The Machines page is functional: fill host/port/user/identity, choose whether
to use `~/.ssh/config`, cycle the host-key policy, then Add. Cards show
online/offline/degraded, the resolved target and profile summary, the last
error, and Probe/Remove buttons. Machine commands use a separate short-lived
connection (a queue worker beside the event subscription) so notifications
are not dropped while a request is in flight; after a reconnect the page
refreshes the machine list.

The Projects page opens a local or SSH root by machine id, lists a directory,
reads/writes a file atomically, shows git status and a file diff, sends
commands to a local PTY or a remote `ssh -tt`+tmux terminal, and creates
worktrees.

The Agents page starts an ACP session against a local workspace/worktree,
shows the streamed transcript and session state, sends follow-up prompts,
stops the session and resumes it via `session/load` (when the adapter
declares it). The Inbox page lists pending decisions: ACP permissions render
one button per option and a free-text field, and readiness failures appear on
the same channel. Transcripts are polled by cursor every 300 ms on a
short-lived connection so the event subscription is never blocked.

The Tasks page creates a `ready` task (workspace defaults to the open
Project), dispatches command runs to local or an SSH machine id, and shows the
selected task's runs with a Run detail: status, evidence (pass/waived/failed,
exit code, excerpt), artifacts (readable), and the worktree diff. The
Activity section is a cursor-fed tail of the host event stream; task/run/
artifact/decision events refresh the board and the open run live, including a
verify Decision answered from the Inbox. The Search page queries
`search.sessions` and renders hits with kind, ref, snippet and the backend
(`fts` or `like`).

With no display server the native entry panics at window creation; this is a
MoUI Linux backend limitation, not a MoNexus error. Use the headless
verification below instead.

## Headless verification (no display)

App tests drive the real TEA runtime and tap navigation by text:

```bash
moon test --target native -p monexus/desktop/app
```

Offscreen screenshots of the shell (requires the `moui` CLI and the app
package's `pub fn program()`):

```bash
cd apps/desktop
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" \
  moui screenshot --app app --out /tmp/monexus-home.png --width 920 --height 560
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" MONEXUS_SCENE_PAGE=Machines \
  moui screenshot --app app --out /tmp/monexus-machines.png
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" MONEXUS_SCENE_PAGE=Machines \
  MONEXUS_SCENE_MACHINES=demo MONEXUS_SCENE_HOST=online \
  moui screenshot --app app --out /tmp/monexus-machines-demo.png
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" MONEXUS_SCENE_HOST=online \
  moui screenshot --app app --out /tmp/monexus-online.png
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" MONEXUS_SCENE_HOST=offline \
  moui screenshot --app app --out /tmp/monexus-offline.png
```

(`moui screenshot` builds its own native render package and does not need a
display. It also links `-lvulkan` without the package's `cc-link-flags`, so
point `LIBRARY_PATH` at the repo-local shim directory as shown; the Vulkan
runtime `libvulkan.so.1` must still be installed.)

## Protocol (M5)

- Transport: WebSocket JSON-RPC 2.0 at `ws://127.0.0.1:<random>/ws`,
  `Authorization: Bearer <token>` during the HTTP upgrade; wrong or missing
  token returns `401`.
- Requests: `host.status`, `events.subscribe`, `machine.add`, `machine.list`,
  `machine.probe`, `machine.remove`, the `workspace.*`/`worktree.*`/
  `lease.*`/`terminal.*` methods, `agent.probe/start/send/read/stop/list/
  resume/memoryRead/memoryWrite`, `decision.list/respond`, the M5
  `project.create/list`, `task.create/list/get/cancel`,
  `run.create/list/get/cancel`, `artifact.read`, `events.list` and
  `search.sessions`, and `rpc --method ... --params ...` for shell-driven
  calls. Every request must
  carry a non-empty `params.client_request_id`; the host caches the response
  and returns it again for a retry with the same key.
- Notifications: `events.event` with `params.event` set to the ADR 0002 event
  envelope. `host.heartbeat` is emitted every second (configurable with
  `--heartbeat-ms`). Machine events are `machine.registered`,
  `machine.connected`, `machine.probed`, `machine.disconnected` and the
  `machine.removed` tombstone; each carries the full machine snapshot so the
  desktop can upsert without another request. Agent events are
  `agent.readiness.ok/failed`, `agent.session.started/updated/output/
  stopped/exited/resumed`, `agent.artifact.created`, `agent.memory.updated`,
  and the decision events `decision.requested/responded/expired`; they carry
  the full session/decision/artifact record. M5 adds `project.created`,
  `task.created/assigned/status.changed/cancelled`,
  `run.queued/started/progress/verifying/evidence/succeeded/failed/
  cancelled/waiting_approval`, and `artifact.created` (with `run_id`); every
  event carries the full Task/Run/Evidence projection.
- Persistence: machine, workspace, worktree, lease, agent-session, decision,
  artifact, project, task, run and evidence events live in SQLite
  (`<state_dir>/monexus.db`, WAL) with their projections. `meta.last_seq`
  keeps the event sequence monotonic across restarts, startup replays
  machine/workspace/worktree/lease events to reconcile the projections and
  closes agent sessions that were live when the previous host exited, and
  now also rebuilds the task projections from events. The last 256 events
  are cached in memory for `events.subscribe --since` replay; the desktop
  uses `events.list --since <cursor>` for the Activity tail.
- Errors: JSON-RPC codes `-32700`, `-32600`, `-32601`, `-32602`, `-32603`;
  machine/workspace failures use the host error code with `data.kind` =
  `unauthorized|timeout|not_found|unreachable|host_key|remote|invalid|
  conflict|internal`, agent failures add `readiness|unsupported`, and a
  message prefixed by a readable label (`Unauthorized: ...`).

## Known limitations (M1–M5)

- Probing is **manual**: there is no background heartbeat/probe loop yet.
- File listing is one directory level; reads are whole-file and diffs stop at
  128 KiB. Large-file streaming and recursive walking are out of scope.
- Desktop terminal output is polled after each send rather than streamed, and
  no `workspace.changed` watcher exists for external edits.
- The generic `rpc` CLI uses wire field names; typed machine commands remain
  the only first-class CLI subcommands.
- `events.subscribe --since` replays from the 256-event in-memory ring, which
  is seeded from SQLite on startup. Older events are reachable through the
  M5 `events.list --since` RPC (used by the desktop Activity tail), not
  through the subscription itself.
- The response idempotency cache is in memory; a retry with the same
  `client_request_id` after a host restart may execute again. The desktop
  uses fresh ids per command.
- OpenSSH resolves `~` in `ssh -G` via the passwd home, not `$HOME`; pass an
  explicit `known_hosts_file`/identity path when the state must stay
  independent of the user's `~/.ssh`.
- The client allows **one request in flight** per connection; the desktop
  therefore uses a separate command connection for machine RPCs.
- `HostStatus.pid` / `HostInfo.pid` are `0`: MoonBit's async runtime exposes
  no portable `getpid` in the pinned version.
- On SIGINT/SIGTERM the process exits through async cancellation; the stale
  `host.json` is tolerated and overwritten on the next start (the flock is
  released by the OS).
- MoUI Linux entry requires Node at build time and a display at run time; use
  tests/screenshots on headless machines.
- No web/wasm desktop target yet.
- Agents run **local only**: `agent.start` rejects SSH-backed workspaces and
  worktrees, so a remote project cannot host an agent session yet.
- Finished agent transcripts are in-memory (bounded to 64 sessions). Session,
  decision and artifact records persist, but the transcript text does not
  survive a host restart.
- Desktop agent output is polled through `agent.read` every 300 ms; the event
  stream carries state changes, not transcript chunks.
- The stdout fallback has no protocol handshake, no turn completion and no
  readiness beyond an executable check.
- Task/Run scheduling is in place, but there is **no M6 recovery**: runs that
  were `running/verifying` when the host exited are not resumed or marked
  `lost`; startup reconciles projections only.
- Agent-mode Runs are local-only and use an internal Sink, so they do not
  stream into the Agents page. Desktop dispatch is command-mode only.
- `verify[]` commands run serially per run; a waiver applies to every failed
  evidence row of the run (not a selected row) and stores only the Decision
  answer as audit text.
- Search indexes finished session transcripts and decisions; live
  transcripts are not searchable until finalize. This environment's bundled
  SQLite reports `backend: like`, not FTS5.
- The desktop Tasks board refreshes whole lists on relevant events rather
  than applying deltas, and the Activity tail keeps 200 events (renders 30).
- Permission answers are manual through `decision.respond`; there is no
  auto-approve or timeout-based policy.
- The real adapter needs a logged-in account on the host machine. The host
  spawns it with `env -u CLAUDECODE` and never reads or logs credentials;
  when no login exists, readiness fails and the Inbox shows a readiness
  Decision.

## Licenses

MoNexus code in this worktree is Apache-2.0. MoUI (`wzzc-dev/moui`) and
`wzzc-dev/moui_skia_renderer` are Apache-2.0 dependencies fetched at build
time; they are **not vendored**. The MoNexus shell uses their public TEA/View
API; no MoUI example source was copied. M0 spike code and the refactored
providers are MoNexus originals. SQLite is used through
`moonbit-community/sqlite3` (which bundles SQLite 3.49.1, public domain) and
is likewise fetched, not vendored.
