# MoNexus V0.1

MoNexus is a local-first desktop workbench for machines, workspaces, tasks and
agent sessions. One `monexus` command starts (or reuses) a `monexus-host`
single-instance process and opens the MoUI desktop window on Linux or macOS.
The host keeps the authoritative state — machines, workspaces/worktrees,
agent sessions, decisions, projects/tasks/runs/evidence, artifacts and the
append-only event log — in SQLite under `~/.monexus`, and serves it over
authenticated WebSocket JSON-RPC on loopback.

V0.1 is the M1–M7 vertical slice. Its recovery rule is **silence is not
exit**: a Run settles only from an observed exit code or a verified result.
Anything the host cannot observe becomes `unverifiable` and asks the owner
through the Inbox — it is never silently retried or marked successful.
Secrets are redacted before logs, artifacts, events and audit records.

- Start here: [Quick start](#quick-start), [Acceptance](#acceptance).
- Day-to-day use: [`docs/usage.md`](docs/usage.md).
- Failures: [`docs/troubleshooting.md`](docs/troubleshooting.md).
- M7 verification and the architecture §14 mapping: [`docs/m7.md`](docs/m7.md).
- Design: [`docs/architecture.md`](docs/architecture.md), [`docs/adr/`](docs/adr/).
- Desktop visual system: [`docs/design-ui.md`](docs/design-ui.md).

## Install

Two supported ways to get a runnable V0.1: install the packaged tarball, or
build from this worktree.

### Packaged tarball (no MoonBit toolchain needed)

Release artifacts are built per OS/architecture:
`dist/monexus-0.1.0-linux-x86_64.tar.gz` and
`dist/monexus-0.1.0-macos-aarch64.tar.gz` (Apple Silicon), each with a
`.sha256` file. On Linux:

```bash
sha256sum -c monexus-0.1.0-linux-x86_64.tar.gz.sha256
tar -xzf monexus-0.1.0-linux-x86_64.tar.gz
./monexus-0.1.0-linux-x86_64/bin/monexus version
```

On macOS (Apple Silicon):

```bash
shasum -a 256 -c monexus-0.1.0-macos-aarch64.tar.gz.sha256
tar -xzf monexus-0.1.0-macos-aarch64.tar.gz
./monexus-0.1.0-macos-aarch64/bin/monexus version
```

Install layout (the directory name follows `<os>-<arch>`):

```
monexus-0.1.0-<os>-<arch>/
  bin/monexus             launcher (single entry point)
  bin/monexus-host        host executable
  bin/monexus-desktop     native desktop executable
  share/monexus/VERSION
  share/monexus/README.md
  share/monexus/docs/     usage, troubleshooting, architecture, m7, ADRs
  share/monexus/examples/workspace/{README.md,AGENTS.md}
```

Move the directory anywhere (for example `~/opt/monexus-0.1.0`) and add its
`bin/` to `PATH`:

```bash
mv monexus-0.1.0-macos-aarch64 ~/opt/monexus-0.1.0
export PATH="$HOME/opt/monexus-0.1.0/bin:$PATH"
monexus version
```

Keep `bin/` and `share/` together: the launcher resolves its resources
relative to its own path. Add the real `bin/` directory to `PATH` instead of
symlinking a single file elsewhere.

Runtime dependencies are deliberately small. On Linux: glibc, a Vulkan
runtime (`libvulkan.so.1`) and, for a window, Wayland or X11. On macOS the
desktop uses the native AppKit backend; the window needs a logged-in GUI
session (SSH-only sessions should use `--headless`), and no Vulkan, X11 or
Xvfb is involved. `tmux` is optional but required for
durable/crash-recoverable command Runs; `ssh` is only needed for SSH
machines. Node.js is **not** needed to run the packaged binaries.

### From source

Prerequisites:

- MoonBit toolchain with the native target (`~/.moon/bin` on `PATH`).
- **Node.js on `PATH`** — the MoUI skia package runs a node prebuild step.
- Linux: a Vulkan runtime (`libvulkan.so.1`). The desktop package links
  through a repo-local `libvulkan.so` shim, so `libvulkan-dev` is not needed.
  The window also needs Wayland or X11.
- macOS: Xcode command-line tools (for the native build) and a GUI login
  session for the window. SSH-only use `monexus start --headless`.
- Headless verification works without a display on either OS.

```bash
export PATH="$HOME/.moon/bin:$HOME/.nvm/versions/node/v26.13.0/bin:$PATH"
moon build --target native --release
moon test  --target native
scripts/package.sh            # tarball + checksum in dist/
```

`scripts/package.sh` verifies that the repo `VERSION` file and
`packages/contracts/version.mbt` agree (`0.1.0`), builds
`--target native --release`, and stages the fixed products:

```
_build/native/release/build/monexus/host/host.exe
_build/native/release/build/monexus/desktop/linux_skia/linux_skia.exe   # Linux
_build/native/release/build/monexus/desktop/macos_skia/macos_skia.exe   # macOS
```

It then writes `dist/monexus-<version>-<os>-<arch>.tar.gz` and
`...tar.gz.sha256`. `--skip-build` reuses existing release binaries;
`--out DIR` changes the output root.

From the worktree the launcher picks the release binaries first, then the
debug build, so this also works after a plain `moon build --target native`:

```bash
scripts/monexus.sh version   # or scripts/start.sh
```

## Quick start

```bash
monexus
```

This is `monexus start`: it checks for a live host, reuses it or starts
`monexus-host serve` detached, waits for `host.json`, prints the loopback
endpoint (never the token), then opens the desktop window. The host stays
alive after the window closes (`keepAlive`), so reopening the window is fast
and background Runs keep going. Single-instance protection comes from
`host.status` plus the host's `host.lock` flock.

On Linux without Wayland/X11 the launcher exits with code 3 and a clear
message instead of failing inside the window backend. On macOS, run from a
logged-in GUI session; an SSH-only session should use `--headless`. Use:

```bash
monexus start --headless       # start/reuse the host, print endpoint, no window
monexus status                 # host online/offline, ws_url, token presence
monexus stop                   # stop a host started by this launcher
monexus --help
monexus version
```

Useful variants:

```bash
monexus start --state-dir /tmp/monexus-demo   # isolated state
monexus start --no-keep-alive                 # stop the host when the window exits
MONEXUS_STATE_DIR=/tmp/monexus-demo monexus   # same, via environment
scripts/start.sh                              # equivalent to scripts/monexus.sh start
```

The desktop Settings page shows the connection state, host `ws_url`, token
status (present/missing, never the token), product version, data directory,
host id, launcher hint and last error. It also has Light/Dark appearance and
English/中文 language controls; both choices are saved locally and applied on
the next launch (`MONEXUS_THEME` / `MONEXUS_LANG` cover the first run).

### First run

The host creates `~/.monexus` (mode 0700) before serving:

```
~/.monexus/
  host.json         {ws_url, token, host_id, pid, ...}, mode 0600, atomic rename
  host.lock         single-instance flock
  monexus.db        SQLite + WAL: projections, events, audit
  agents/           per-agent homes
  artifacts/        run/agent artifacts
  logs/             host.log (launcher) and SSH run markers
  examples/hello-workspace/   sample Workspace with README.md, AGENTS.md and a git repo
```

Existing files are never overwritten. The sample workspace is initialized
with `git init` when `git` is available, so Projects/worktrees can be tried
immediately. Restarting the host on the same state dir continues the event
sequence and reconciles projections from the append-only log.

## Register machines

The desktop **Machines** page can add/probe/remove machines. The CLI uses the
same RPC surface through `monexus host` (the host must be running):

```bash
# This machine: a host-side local provider, no SSH.
monexus host machine add --kind local --name "this machine"

# An SSH machine. Use explicit values for predictable unattended behavior.
monexus host machine add --name box --host 10.0.0.5 --port 22 --user me \
  --identity ~/.ssh/id_ed25519 --use-ssh-config false \
  --host-key-policy accept-new --known-hosts-file ~/.monexus/known_hosts

monexus host machine list
monexus host machine probe --id mch_... --timeout-seconds 10
monexus host machine remove --id mch_...
```

`--kind local` is an additive V0.1 contract extension: the record stores
`kind=local`, uses the local workspace provider, and gets a local capability
profile (OS, arch, shell, display, parallel limit) without running `ssh`.
The default kind remains `ssh`, so existing SSH records are unchanged.
`--use-ssh-config true` inherits `~/.ssh/config` and records the effective
`ssh -G` values; explicit flags are the source of truth when it is false.
Probe failures are classified as `Unauthorized`, `Timeout`, `NotFound`,
`Unreachable`, `HostKeyRejected` or `RemoteError` with a readable reason.

## Open a Workspace

In the desktop: **Projects** → pick a machine (the local record or an SSH
one), enter a root path, **Open project**. The page lists the directory,
reads/writes files atomically via temp-file + rename, shows git status/diff,
opens a terminal, and creates worktrees.

From the CLI:

```bash
monexus host rpc --method workspace.open \
  --params '{"target":"mch_...","root":"/home/me/project"}'

monexus host rpc --method worktree.create \
  --params '{"workspace_id":"wsp_...","branch":"m7-demo","path":"/tmp/wt-demo","base":""}'

monexus host rpc --method worktree.list --params '{"workspace_id":"wsp_..."}'
```

`target` accepts a machine id; `"local"` or an empty target uses the local
provider. The first-run sample is
`~/.monexus/examples/hello-workspace`; open it with the local machine.

## Start an Agent session

Desktop: **Agents** → choose the workspace (or worktree), keep the default
ACP adapter or provide a command, then **Start session**. The streamed
transcript, state, follow-up prompts and stop/resume controls are on the same
page. ACP permission requests are converted into Decisions and appear in the
Inbox; nothing is auto-approved.

CLI example with the test double (no account or network needed):

```bash
monexus host rpc --method agent.probe --params '{
  "agent_id":"mock","mode":"acp","command":"node",
  "args":["tests/agent/mock_acp_agent.mjs"],"env":{}}'

monexus host rpc --method agent.start --params '{
  "agent_id":"mock","mode":"acp","command":"node",
  "args":["tests/agent/mock_acp_agent.mjs"],
  "workspace_id":"wsp_...","prompt":"hello"}'

monexus host rpc --method agent.read --params '{"session_id":"ags_...","cursor":0}'
monexus host rpc --method agent.stop --params '{"session_id":"ags_..."}'
```

A real ACP session needs Node, network access for the first
`npx -y @zed-industries/claude-code-acp@0.16.2` download, and a logged-in
Claude Code account on the host machine. The host spawns the adapter with
`env -u CLAUDECODE` and reuses the machine's login; it never reads or logs
credentials. Without a login the readiness probe fails and the Inbox shows a
readiness Decision. The real adapter was verified on 2026-11-25
(`@zed-industries/claude-code-acp 0.16.2`): the readiness probe passed and one
real turn streamed the requested output with `stop_reason=end_turn`. Agent
sessions are local-workspace only by default in V0.1; a gated round-1 PoC
(`MONEXUS_AGENT_SSH=1`) can launch an SSH workspace's adapter over `ssh -T` —
see `docs/usage.md` §4. For that PoC, a turn that loses its transport ends as
`lost` (stop reason `lost`, event `agent.session.lost`) and a remote agent
that exits mid-turn ends as `interrupted` (stop reason `interrupted`, event
`agent.session.interrupted`); neither is a success, and a clean turn followed
by EOF is still `exited`.

## Tasks, evidence and approvals

Desktop: **Tasks** → choose the open Project, create a task with a title and
one `verify` command per line, then dispatch a command Run to a machine.
Evidence must pass before a Run becomes `succeeded`; a failed verify parks
the Run in `waiting_approval` and creates a Decision.

CLI sketch:

```bash
monexus host rpc --method project.create --params '{
  "name":"demo","verify":["sh -c \"test -f verify.txt\"","echo verify-ok"]}'

monexus host rpc --method task.create --params '{
  "title":"parallel local+ssh","project_id":"prj_...","workspace_id":"wsp_..."}'

monexus host rpc --method run.create --params '{
  "task_id":"tsk_...","workspace_id":"wsp_...","machine_id":"mch_...",
  "mode":"command","command":"sh -c \"sleep 2; echo done\"",
  "idempotency_key":"demo/1"}'

monexus host rpc --method decision.list --params '{"status":"pending"}'
monexus host rpc --method decision.respond \
  --params '{"decision_id":"dec_...","option_id":"waive","text":"accepted"}'
```

Two Runs of one task may target different machines/workspaces and execute in
parallel up to each machine's `max_parallel` (`MONEXUS_MAX_PARALLEL`, default
4). A finished task rolls up as, for example, `2/2 runs succeeded`. Verify
failure offers three Inbox answers:

- `waive` — stamp the failed evidence as waived, then succeed;
- `retry` — re-run the verify gate and ask again if it fails;
- `fail` — settle the Run as failed.

Command risk policy also runs before a Run exists. Read-only commands are
allowed; destructive/high-risk commands such as `rm -rf build` become an
approval Decision; root/system commands such as `sudo ...`, `mkfs`,
`shutdown` or `systemctl` are denied and audited.

## Failure recovery

The three V0.1 recovery scenarios settle through the same policy:

1. **Desktop exits / reconnects.** The host keeps running (`keepAlive`).
   Reopening the window reconnects to the same `host.json`, replays state and
   resumes the Inbox. Link transitions are visible on Settings; set
   `MONEXUS_LINK_TRACE=1` to trace `link connecting/online/offline` on stdout.
2. **Host restarts.** On startup the host reconciles projections and every
   active Run. A durable tmux session is polled: an observed exit 0 continues
   to the evidence gate (`run.reconcile.reconnect`), a non-zero exit fails,
   a dead/missing pane becomes `lost`, and an unobservable transport becomes
   `unverifiable` — never a silent success. `lost` retries once automatically;
   `unverifiable` never auto-retries and immediately raises a recovery
   Decision.
3. **SSH disconnect / unreachable machine.** A short drop is tolerated.
   Persistent transport failure marks the Run `lost`/`unverifiable` with an
   explanation, tears down the durable session and raises a recovery Decision
   (Retry / Fail / Waive) for the owner.

Run **Inbox** is the single attention queue: **Needs you**, **waiting**
(answered but work continues) and **handled**. Recovery Decisions show the
Run status and stop reason. `monexus host rpc --method audit.list --params
'{"limit":100}'` exposes policy verdicts, Decision answers and recovery
actions; secrets and bearer tokens are absent from events, logs, artifacts
and audit detail.

## Acceptance

`scripts/acceptance.sh` runs V0.1 end to end under a throwaway `HOME`:

```bash
scripts/acceptance.sh
# or reuse repository binaries without packaging:
ACCEPTANCE_SKIP_PACKAGE=1 scripts/acceptance.sh
# also probe a real, logged-in ACP adapter once:
M7_REAL_ACP=1 scripts/acceptance.sh
```

It builds packages the tarball, verifies its SHA-256, unpacks it, and drives
the **installed** `bin/monexus` / `monexus-host` / `monexus-desktop` against
`<temp>/.monexus`. External dependencies are substituted, not contacted:

- SSH machines use a throwaway **loopback sshd** (random 127.0.0.1 port,
  temporary host/client keys, temporary known-hosts file; the real `~/.ssh`
  is asserted untouched);
- the unreachable-SSH scenario uses a fake `ssh` on `PATH` with an injectable
  disconnect mode;
- the desktop reconnect scenario runs the real window under `xvfb-run` when
  no physical display exists.

Those substitutes are the script's, not the whole V0.1 record. On 2026-11-25
a real **Debian 13 x86_64** machine was verified separately: `machine
add`/probe online with a Linux x86_64 profile, remote workspace
read/write/git/terminal, and parallel local + remote Runs `2/2 runs
succeeded` with all evidence verified. **Ubuntu has not been separately
verified; do not read the Debian result as Ubuntu.** RISC-V is out of V0.1
scope.

macOS support was verified separately on 2026-11-27 on **macOS aarch64**
(Apple Silicon): `moon build --target native` (debug and release; both the
Linux and macOS desktop entries), `moon test --target native` 524/524,
`scripts/package.sh` (13 MB tarball + SHA-256), `scripts/host_smoke.sh`, and
the installed launcher's `start --headless` / `status` / `stop` lifecycle. The
installed `monexus-desktop` was also launched from a GUI login session: the
process stayed alive and traced `link online` to the headless host (the
window's interactive controls were not driven automatically).
`scripts/acceptance.sh` still relies on a loopback sshd and `xvfb-run`, so its
in-script run remains Linux-only; macOS packaging is covered by
`scripts/package.sh` and the macOS CI job.

The script prints one `PASS`/`FAIL`/`SKIP` row per requirement (packaging plus
items a–h) and a `SUMMARY checks=... failed=... result=...` line; it exits
non-zero on any failure. The verified run and the per-item architecture §14
mapping are in [`docs/m7.md`](docs/m7.md). The M1–M6 regression smokes remain
available:

```bash
scripts/host_smoke.sh       # M1 host
scripts/machine_smoke.sh    # M2 machines, temp sshd
scripts/workspace_smoke.sh  # M3 workspace/worktree/lease/terminal, temp sshd
scripts/agent_smoke.sh      # M4 ACP session/permission/memory, mock adapter
scripts/agent_ssh_smoke.sh  # PoC: mock ACP over ssh -T, temp sshd + temp keys
scripts/task_smoke.sh       # M5 tasks/runs/evidence/search, temp sshd
scripts/recovery_smoke.sh   # M6 recovery matrix, fake ssh faults
```

## CI

`.github/workflows/ci.yml` (workflow **CI**) runs on pull requests, pushes to
`main` and manual dispatch. On `ubuntu-latest`, **`build-test-acceptance`**
(timeout 60 minutes) runs `moon build --target native`, `moon test --target
native`, the loopback-sshd smokes (`machine`, `workspace`, `task`,
`agent_ssh`), the headless `agent_smoke.sh`, and `scripts/acceptance.sh` —
all under throwaway `HOME`/state dirs, with no real remote or credential. On
`macos-14` (Apple Silicon), **`build-test-macos`** runs the native build, the
full native test suite, `scripts/package.sh`, `scripts/host_smoke.sh` and the
installed launcher's headless start/status/stop check. Require both checks
for merges to `main`.

## Layout

```
moon.work                     workspace manifest
VERSION                       product version (0.1.0)
packages/contracts/           JSON-RPC, discovery, machine/agent/task/version contracts
packages/machines/            SQLite store + projections/replay
packages/providers/           SSH/PTY, local-or-SSH workspace, ACP agent, policy
packages/host-client/         host.json discovery + WebSocket JSON-RPC client
services/host/                monexus-host executable + handlers + recovery
apps/desktop/app/             MoUI model/update/view, host-link/workers, tests
apps/desktop/linux_skia/      Linux native entry + Vulkan linker shim
apps/desktop/macos_skia/      macOS native entry (AppKit backend)
scripts/monexus.sh, start.sh  single-command launcher
scripts/package.sh            release build, install layout, tar.gz + SHA-256
scripts/acceptance.sh         fresh-HOME PASS/FAIL acceptance
tests/agent/                  mock ACP/stdout test doubles (test-only, JS)
docs/m1.md … docs/m7.md       milestone notes, verification and limitations
docs/usage.md, troubleshooting.md
docs/adr/                     architecture decisions
spikes/m0/                    frozen M0 spike
```

## Protocol and data

- Transport: WebSocket JSON-RPC 2.0 at `ws://127.0.0.1:<random>/ws`;
  `Authorization: Bearer <token>` during upgrade (missing/wrong token → 401).
- Requests include `host.status`, `events.subscribe/list`, `machine.*`,
  `workspace.*`, `worktree.*`, `lease.*`, `terminal.*`, `agent.*`,
  `decision.*`, `project.*`, `task.*`, `run.*`, `artifact.read`,
  `search.sessions`, `audit.list`, and the generic `rpc --method ...`.
  Every request carries a non-empty `params.client_request_id`; the host
  caches responses for retries with the same key.
- Notifications: `events.event` (full projection in the ADR-0002 envelope),
  plus a `host.heartbeat` every second (`--heartbeat-ms`). Machine, workspace,
  agent, decision, task/run/evidence, artifact and audit events each carry
  enough state for the desktop to upsert without another request.
- Persistence: SQLite WAL at `<state_dir>/monexus.db`, with monotonic
  `meta.last_seq`; startup replays machine/workspace/task projections and
  reconciles agent sessions and active Runs. The in-memory event ring feeds
  `events.subscribe --since`; older history is available through
  `events.list --since`.
- Errors: JSON-RPC `-32700/-32600/-32601/-32602/-32603`; provider kinds
  `unauthorized|timeout|not_found|unreachable|host_key|remote|invalid|
  conflict|internal` (plus `readiness|unsupported` for agents), with a
  readable message prefix.

## Known limitations (V0.1)

- Packaging is verified for Linux x86_64 and macOS aarch64. The launcher is a
  POSIX shell script; there is no Windows build, installer, auto-update or
  code signing. macOS x86_64 is buildable by the same scripts but was not
  separately exercised.
- Remote machine verification covers a real **Debian 13 x86_64** machine
  (machine add/probe online, remote workspace read/write/git/terminal,
  parallel local + remote Runs `2/2` with evidence verified). Ubuntu has not
  been separately verified — Debian is not Ubuntu — and RISC-V is out of V0.1
  scope.
- The Linux window needs Wayland/X11; headless Linux machines use `--headless`,
  tests, or `xvfb-run` (there is no built-in virtual display). The macOS
  window needs a logged-in GUI session; use `--headless` over SSH.
- Building from source needs MoonBit + Node; the packaged binaries do not
  need Node at runtime.
- A real ACP session needs Node, a first-run npx download and a logged-in
  account. The real adapter (`claude-code-acp 0.16.2`) was verified locally
  on 2026-11-25 (readiness plus one turn, `stop_reason=end_turn`). Agent
  sessions and their in-memory transcripts are local-only and do not survive
  a host restart (session/decision/artifact records do); remote agent
  sessions are not supported in V0.1, and the Agent-over-SSH design is
  PoC-only ([ADR-0011](docs/adr/0011-agent-over-ssh.md)).
- Durable command Runs need `tmux` on the target. Without it the host uses a
  synchronous fallback and such a Run is `unverifiable` after a host restart.
- Probing is manual (Machines page/CLI); there is no background probe loop.
  Heartbeats are host events, not per-machine liveness checks.
- File listing is one directory level; reads are whole-file and diffs stop at
  128 KiB. No recursive walk or file watcher.
- The response idempotency cache is in memory; a retry with the same
  `client_request_id` after a host restart may execute again. The desktop uses
  fresh ids per command.
- One request in flight per connection; the desktop uses a separate command
  connection for machine RPCs.
- `HostStatus.pid` / `HostInfo.pid` are `0` because the pinned MoonBit runtime
  exposes no portable `getpid`.
- On SIGINT/SIGTERM a stale `host.json` is tolerated and overwritten on the
  next start; the OS releases the flock.
- Verify commands run serially per Run; a waiver applies to every failed
  evidence row of that Run. Search may report the `like` backend instead of
  FTS5 depending on the bundled SQLite.
- `events.subscribe --since` replays only from the 256-event in-memory ring
  (seeded from SQLite at startup); use `events.list --since` for older
  history.
- OpenSSH resolves `~` in `ssh -G` using the passwd home, not `$HOME`; pass
  explicit identity/known-hosts paths when state must be isolated.
- Owner-declared command text is stored verbatim (it is the program and the
  retry source), so credentials must come from the machine account. Agent env
  names that look secret are redacted.
- A recovered Run without a persisted `worktree_id` verifies in the workspace
  root; a worktree created but not attached before a crash is an accepted
  edge case.
- tmux session names use the last 12 characters of the Run id; two live hosts
  sharing one tmux server can collide.
- No web/wasm desktop target yet.

## Licenses

MoNexus code is Apache-2.0. MoUI (`wzzc-dev/moui`) and
`wzzc-dev/moui_skia_renderer` are Apache-2.0 dependencies fetched at build
time; they are **not** vendored. SQLite is used through
`moonbit-community/sqlite3` (bundling SQLite 3.49.1, public domain) and is
likewise fetched, not vendored.
