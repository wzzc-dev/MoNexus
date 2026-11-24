# MoNexus

MoNexus is a local-first desktop shell for machines, tasks and agent
sessions. This worktree contains the **M1 minimal vertical slice**: a real
local host (WebSocket JSON-RPC 2.0) plus a MoUI 0.9.1 desktop shell that
launches, reads `host.json`, connects to the host and switches between five
pages.

M2–M5 business features (machine inventory, task execution, sessions,
ACP-backed search) are intentionally **not** implemented here.

## Layout

```
moon.work                     workspace manifest
packages/contracts/           JSON-RPC, event envelope, discovery contracts
packages/providers/           SSH + PTY providers moved out of the M0 spike
packages/host-client/         host.json discovery + WebSocket JSON-RPC client
services/host/                monexus-host executable (serve/status/subscribe)
apps/desktop/app/             MoUI model/update/view, host-link worker, tests
apps/desktop/linux_skia/      Linux native entry + Vulkan linker shim
scripts/host_smoke.sh         end-to-end host smoke test
docs/m1.md                    M1 design notes, verification and limitations
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
host-client, host, desktop app).

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
`127.0.0.1` port, and rejects a second instance with the `host.lock` flock.
The bearer token in `host.json` is the only credential; the endpoint is
loopback-only.

Smoke test (builds, starts a host, checks status/subscribe/lock/401):

```bash
scripts/host_smoke.sh
```

## Run the desktop shell

```bash
_build/native/debug/build/monexus/desktop/linux_skia/linux_skia.exe
```

Start the host first (or let the shell show `offline` and retry). The window
shows five switchable pages — Home, Machines, Tasks, Search, Settings — and a
live host status (`connecting` / `online` / `offline`) with an event counter
and a 1.5 s reconnect backoff.

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
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" MONEXUS_SCENE_HOST=online \
  moui screenshot --app app --out /tmp/monexus-online.png
LIBRARY_PATH="$PWD/linux_skia/third_party/vulkan" MONEXUS_SCENE_HOST=offline \
  moui screenshot --app app --out /tmp/monexus-offline.png
```

(`moui screenshot` builds its own native render package and does not need a
display. It also links `-lvulkan` without the package's `cc-link-flags`, so
point `LIBRARY_PATH` at the repo-local shim directory as shown; the Vulkan
runtime `libvulkan.so.1` must still be installed.)

## Protocol (M1)

- Transport: WebSocket JSON-RPC 2.0 at `ws://127.0.0.1:<random>/ws`,
  `Authorization: Bearer <token>` during the HTTP upgrade; wrong or missing
  token returns `401`.
- Requests: `host.status`, `events.subscribe`. Every request must carry a
  non-empty `params.client_request_id`; the host caches the response and
  returns it again for a retry with the same key.
- Notifications: `events.event` with `params.event` set to the ADR 0002 event
  envelope. `host.heartbeat` is emitted every second (configurable with
  `--heartbeat-ms`) and kept in a 256-event in-memory ring for replay via
  `since`.
- Errors: JSON-RPC codes `-32700`, `-32600`, `-32601`, `-32602`, `-32603`.

## Known M1 limitations

- The host event log is an **in-memory ring**; restarting the host loses
  history and sequence numbers restart at 1.
- The client allows **one request in flight** per connection.
- `HostStatus.pid` / `HostInfo.pid` are `0`: MoonBit's async runtime exposes
  no portable `getpid` in the pinned version.
- On SIGINT/SIGTERM the process exits through async cancellation; the stale
  `host.json` is tolerated and overwritten on the next start (the flock is
  released by the OS).
- MoUI Linux entry requires Node at build time and a display at run time; use
  tests/screenshots on headless machines.
- No web/wasm desktop target in M1.

## Licenses

MoNexus code in this worktree is Apache-2.0. MoUI (`wzzc-dev/moui`) and
`wzzc-dev/moui_skia_renderer` are Apache-2.0 dependencies fetched at build
time; they are **not vendored**. The MoNexus shell uses their public TEA/View
API; no MoUI example source was copied. M0 spike code and the refactored
providers are MoNexus originals.
