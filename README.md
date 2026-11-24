# MoNexus

MoNexus is a local-first desktop shell for machines, tasks and agent
sessions. This worktree contains the **M3 vertical slice**: the M2 host and
MoUI 0.9.1 shell extended with workspaces, worktrees, file editing, git
status/diff and terminals over one local-or-SSH provider contract. The host
keeps workspace/worktree/lease records and events in SQLite, enforces one
active lease per worktree (or non-git workspace), and the desktop Projects
page opens local or remote roots through the same RPC surface.

M4–M5 business features (task execution, agent sessions, ACP-backed search)
are intentionally **not** implemented here.

## Layout

```
moon.work                     workspace manifest
packages/contracts/           JSON-RPC, event envelope, discovery, machine contracts
packages/machines/            SQLite machine store + pure event replay
packages/providers/           SSH/PTY plus the local-or-SSH workspace provider
packages/host-client/         host.json discovery + WebSocket JSON-RPC client
services/host/                monexus-host executable (serve/status/subscribe/machine/rpc)
apps/desktop/app/             MoUI model/update/view, host-link + machine workers, tests
apps/desktop/linux_skia/      Linux native entry + Vulkan linker shim
scripts/host_smoke.sh         end-to-end host smoke test (M1 regression)
scripts/machine_smoke.sh      machine registry + SSH probe smoke test (temp sshd/fake ssh)
scripts/workspace_smoke.sh    M3 workspace/worktree/lease/terminal smoke (temp sshd)
docs/m1.md, docs/m2.md, docs/m3.md  design notes, verification and limitations
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
```

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
shows six switchable pages — Home, Machines, Projects, Tasks, Search,
Settings — and a
live host status (`connecting` / `online` / `offline`) with an event counter
and a 1.5 s reconnect backoff.

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

## Protocol (M3)

- Transport: WebSocket JSON-RPC 2.0 at `ws://127.0.0.1:<random>/ws`,
  `Authorization: Bearer <token>` during the HTTP upgrade; wrong or missing
  token returns `401`.
- Requests: `host.status`, `events.subscribe`, `machine.add`, `machine.list`,
  `machine.probe`, `machine.remove`, the `workspace.*`/`worktree.*`/
  `lease.*`/`terminal.*` methods, and `rpc --method ... --params ...` for
  shell-driven calls. Every request must carry a non-empty
  `params.client_request_id`; the host caches the response and returns it
  again for a retry with the same key.
- Notifications: `events.event` with `params.event` set to the ADR 0002 event
  envelope. `host.heartbeat` is emitted every second (configurable with
  `--heartbeat-ms`). Machine events are `machine.registered`,
  `machine.connected`, `machine.probed`, `machine.disconnected` and the
  `machine.removed` tombstone; each carries the full machine snapshot so the
  desktop can upsert without another request.
- Persistence: machine, workspace, worktree and lease events live in SQLite
  (`<state_dir>/monexus.db`, WAL) with their projections. `meta.last_seq`
  keeps the event sequence monotonic across restarts, and startup replays
  `machine.*`, `workspace.*`, `worktree.*` and `lease.*` events to reconcile
  the projections. The last 256 events are cached in memory for
  `events.subscribe --since` replay.
- Errors: JSON-RPC codes `-32700`, `-32600`, `-32601`, `-32602`, `-32603`;
  machine/workspace failures use the host error code with `data.kind` =
  `unauthorized|timeout|not_found|unreachable|host_key|remote|invalid|
  conflict|internal`
  and a message prefixed by a readable label (`Unauthorized: ...`).

## Known M3 limitations

- Probing is **manual**: there is no background heartbeat/probe loop yet.
- File listing is one directory level; reads are whole-file and diffs stop at
  128 KiB. Large-file streaming and recursive walking are out of scope.
- Desktop terminal output is polled after each send rather than streamed, and
  no `workspace.changed` watcher exists for external edits.
- The generic `rpc` CLI uses wire field names; typed machine commands remain
  the only first-class CLI subcommands.
- `events.subscribe --since` replays from the 256-event in-memory ring, which
  is seeded from SQLite on startup. Older events remain in the `events` table
  but there is no full-cursor RPC yet.
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

## Licenses

MoNexus code in this worktree is Apache-2.0. MoUI (`wzzc-dev/moui`) and
`wzzc-dev/moui_skia_renderer` are Apache-2.0 dependencies fetched at build
time; they are **not vendored**. The MoNexus shell uses their public TEA/View
API; no MoUI example source was copied. M0 spike code and the refactored
providers are MoNexus originals. SQLite is used through
`moonbit-community/sqlite3` (which bundles SQLite 3.49.1, public domain) and
is likewise fetched, not vendored.
