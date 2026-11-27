# Troubleshooting

Start with the three facts every diagnosis needs:

```bash
monexus status
cat ~/.monexus/host.json              # endpoint + token (do not paste the token)
tail -n 50 ~/.monexus/logs/host.log
```

Use `--state-dir DIR`/`MONEXUS_STATE_DIR` consistently in every command; a
host and a client on different state dirs cannot see each other.

## Build and packaging

**`node` is required / skia prebuild fails.** The MoUI skia package runs a
Node prebuild step. Put Node on `PATH` for the build (runtime binaries do not
need Node):

```bash
export PATH="$HOME/.nvm/versions/node/v26.13.0/bin:$HOME/.moon/bin:$PATH"
node --version
moon build --target native --release $(bash scripts/native_packages.sh)
```

Build through `scripts/native_packages.sh`; a root-wide build also compiles
the other platform's desktop entry and fails on Linux/macOS respectively.

If the skia prebuild download stalls, retry on a working network; the
prebuild cache lives under `.mooncakes/wzzc-dev/moui_skia/.skia-cache`. A
cache copied from a completed build can be reused when versions match.

**Vulkan link errors (Linux).** The Linux desktop needs a Vulkan runtime
(`libvulkan.so.1`). The repo supplies a linker shim; no `libvulkan-dev` is
needed. Without a GPU runtime set `MOUI_SKIA_ENABLE_GPU_VULKAN=0` and rebuild.
`moui screenshot` also needs `LIBRARY_PATH=<repo>/apps/desktop/linux_skia/third_party/vulkan`.
The macOS entry uses the AppKit backend and does not link Vulkan.

**`scripts/package.sh` reports VERSION disagreement.** `VERSION` and
`PRODUCT_VERSION` in `packages/contracts/version.mbt` must match exactly. Fix
both, then re-run. `--skip-build` does not skip this check.

**Release products not found at fixed paths.** Run the full build first:

```bash
moon build --target native --release $(bash scripts/native_packages.sh)
ls _build/native/release/build/monexus/host/host.exe
ls _build/native/release/build/monexus/desktop/linux_skia/linux_skia.exe  # Linux
ls _build/native/release/build/monexus/desktop/macos_skia/macos_skia.exe  # macOS
```

**Checksum verification fails.** Re-copy the tarball and `.sha256` together;
do not rename one without the other. Verify from the directory that contains
the tarball:

```bash
cd dist && sha256sum -c monexus-0.1.0-linux-x86_64.tar.gz.sha256
# macOS (no sha256sum in the base system):
cd dist && shasum -a 256 -c monexus-0.1.0-macos-aarch64.tar.gz.sha256
```

**`monexus: monexus-host binary not found`.** You ran a launcher from a
partial copy or without `bin/` and `share/` together. Re-extract the tarball
and add its real `bin/` directory to `PATH`; do not symlink only
`bin/monexus` elsewhere.

## Window and display

**Linux: `no display server found (DISPLAY and WAYLAND_DISPLAY are unset)`,
exit 3.** This is intentional. Either run headless
(`monexus start --headless`) or provide a display:

```bash
xvfb-run -a monexus                 # virtual X server
xvfb-run -a monexus-desktop         # binaries accept --version/--help too
```

Wayland/X11 must be reachable from the process; `sudo` without `-E` or a
stripped environment often loses `DISPLAY`/`WAYLAND_DISPLAY`.

**macOS: the window does not open from an SSH session.** AppKit needs a
logged-in GUI session; a pure terminal/SSH login has no WindowServer access.
Run `monexus` from the desktop session (Terminal, or `launchctl asuser` for a
logged-in user), or use `monexus start --headless` and the CLI. macOS builds
do not use Xvfb, Wayland or Vulkan.

**The window opens but shows `offline`.** The host is down or on another
state dir. `monexus status` should show an endpoint. Set
`MONEXUS_LINK_TRACE=1` to see `link connecting/online/offline` lines. A stale
`host.json` from a dead host is harmless; the launcher overwrites it on the
next start.

**Linux: desktop exits immediately under Xvfb.** Run it without redirecting
stderr to see the renderer error. Missing Vulkan runtime or a broken Xvfb
screen size are the usual causes; `xvfb-run -a -s "-screen 0 1280x800x24" ...`
is a safe default. This section does not apply to macOS.

## Host lifecycle

**`another monexus-host instance is already running in ...`.** The flock is
held by a live host on that state dir. Reuse it (`monexus start` detects it)
or stop it with the owning terminal/`monexus stop`. Do not delete
`host.lock` while the host is alive.

**`monexus stop` says the host was not started by this launcher.** The host
is online but has no trusted pid file (for example it was started manually).
Stop it in the terminal that owns it (Ctrl-C). `monexus stop` deliberately
does not kill unknown processes.

**Host starts but `host.json` is absent or unreadable.** The host writes it
atomically with mode 0600 only after the DB, projections and socket are
ready. Check `host.log`; a bind/DB/lock error prevents publication. Ensure
the state dir and `host.json` are owned by the current user.

**401 / `Unauthorized` from a client.** The bearer token in `host.json` must
match the running host. Do not copy a token between state dirs; restart the
client after the host rewrites the file.

**`HostStatus.pid`/`HostInfo.pid` is 0.** Expected in V0.1: the pinned
MoonBit runtime has no portable `getpid`. Use `host.pid` written by the
launcher for its own children.

## Machines and SSH

**`Unauthorized` on probe.** Wrong user/key, key permissions, or the remote
`authorized_keys` is missing. Test directly with the same identity and port:

```bash
ssh -i /path/key -p 2222 -o BatchMode=yes user@host true
```

**`HostKeyRejected` / `accept-new` did not help.** `accept-new` records the
first key in the configured known-hosts file. If the host key changed, remove
the stale entry deliberately. Automation should pass an explicit
`--known-hosts-file`; OpenSSH may resolve `~` via the passwd home, not
`$HOME`.

**`Timeout` / `Unreachable`.** Check routing, port, firewall and
`ConnectTimeout`. The machine record shows the last classified error; probe
again after fixing connectivity. A temporarily unreachable machine does not
make Runs succeed: unobservable Runs are settled as lost/unverifiable.

**`~/.ssh/config` unexpectedly changes the target.** Pass
`--use-ssh-config false` for explicit, reproducible targets. With it on, the
effective `ssh -G` values are part of the record.

**Loopback sshd tests fail.** `sshd` must be executable (often
`/usr/sbin/sshd`), with a writable host key, a free 127.0.0.1 port, and
`StrictModes no` for the temporary key layout used by the smoke tests.
`ss -ltn` should show the chosen port. Acceptance uses only a temporary
loopback sshd and never contacts an external machine.

## Workspaces and worktrees

**`workspace.open` fails for a root.** Check the path exists, is readable by
the host account, and for SSH is on the remote machine. Git features (status,
diff, worktree) require a git repository; non-git roots still support files,
terminals and exclusive leases.

**`worktree.create` says branch and path are required / path exists.** Supply
both and a new or empty path. Worktrees are recorded by the host; removing
one is `worktree.remove --worktree_id ...`. Concurrent Runs must use
different worktrees (or a lease) to stay isolated.

**File reads/diffs are truncated.** V0.1 lists one directory level, reads
whole files, and caps diffs at 128 KiB. Use a terminal for larger files.

## Tasks, evidence and approvals

**A Run stays `waiting_approval`.** A verify failure or a high-risk command
is waiting for an answer. Open **Inbox → Needs you** or:

```bash
monexus host rpc --method decision.list --params '{"status":"pending"}'
monexus host rpc --method decision.respond \
  --params '{"decision_id":"dec_...","option_id":"waive","text":"..."}'
```

`waive` succeeds with waived evidence, `retry` re-runs the gate and asks
again if it still fails, `fail` settles failed. A denied `sudo`/`systemctl`
command never becomes a Run; the denial is audited.

**`run.create` returns an existing Run or a conflict.** `idempotency_key`
deduplicates dispatch. Use a fresh key for a genuinely new attempt. Duplicate
Decision answers are rejected as `already answered`.

**A task is queued but not running.** Per-machine `max_parallel` is reached
or the machine is offline/unknown. Probe the machine and wait for the current
Runs to settle; `run.list --task_id` shows queue order/status.

**Verify evidence passes locally but fails on SSH.** The verify commands run
in the Run's workspace/worktree on the target machine. Check tool availability
and the root path; evidence output is in the Run/artifacts.

## Recovery

**A Run is `lost` or `unverifiable`.** This is not silent success; it is the
honest answer when the host cannot observe an exit. `lost` retries once
automatically. `unverifiable` (transport unavailable, host restart during
verification, no durable handle) is **never** auto-retried and raises a
recovery Decision. Answer Retry only if duplicating side effects is
acceptable; otherwise inspect logs/artifacts and fail or waive deliberately.

**`tmux` is missing.** Durable command Runs fall back to a synchronous path
(`durable=direct`); such a Run is unverifiable after a host restart. Install
`tmux` on local and SSH targets for crash recovery. Tests isolate the server
with `TMUX_TMPDIR` and set `remain-on-exit on`.

**The desktop does not reconnect after a host restart.** Confirm the host is
back (`monexus status`), then watch `MONEXUS_LINK_TRACE=1` output. The link
retries every 1.5 s. Only one request is in flight per connection; a hung
command connection cannot block the event subscription, but a dead host
process requires a restart.

**SSH dropped and the Run kept running.** A short drop is tolerated by
design. Persistent errors cross `MONEXUS_RECOVERY_UNVERIFIABLE_MS` and settle
the Run; lower that value only in tests, not production.

## Agents

**Readiness fails / Inbox shows a readiness Decision.** For a real adapter:
Node on `PATH`, network for the first npx download, and a logged-in account
on the host machine. The host runs the adapter with `env -u CLAUDECODE` and
never reads/logs credentials. Without a login, use the mock agent for
verification:

```bash
monexus host rpc --method agent.probe --params '{
  "agent_id":"mock","mode":"acp","command":"node",
  "args":["tests/agent/mock_acp_agent.mjs"],"env":{}}'
```

**Agent session disappears after a host restart.** Expected: ACP processes
do not survive the host; live sessions are closed and pending Decisions
expire during reconcile. Session/decision/artifact records persist, transcript
text is in memory only.

**A workspace-backed agent is rejected.** V0.1 agents run only on local
workspaces. Use a local machine record (`--kind local`) or an empty/`local`
target. The round-1 remote-agent PoC is gated: start the host with
`MONEXUS_AGENT_SSH=1` to let `agent.start` launch an SSH workspace's adapter
over `ssh -T` (see `docs/usage.md` §4). This is a PoC — `agent.probe`,
`agent.resume` and `agent.start` env forwarding are still local-only.

## Triggers

**Every `trigger.*` call returns `unsupported`.** The feature flag is off.
Start the host with `--trigger-enabled true` (or
`MONEXUS_TRIGGER_ENABLED=1`) and retry. While off, `/hooks/*` returns the
uniform 401 and existing Task/Run/Decision behavior is unchanged.

**`trigger.create` rejects a timezone as `unsupported`.** IANA zones need
readable TZif data: set `MONEXUS_TZDATA_DIR` or install system tzdata
(`/usr/share/zoneinfo`). Invalid names, unreadable files and parse failures
are rejected rather than falling back to UTC. `UTC` and fixed `±HH:MM`
offsets never need tzdata. IANA-zone behavior is covered by the native suite
on Linux and macOS; verify tzdata availability on other platforms before
relying on named zones.

**A schedule trigger is not firing.** `trigger.get` shows `state`,
`next_fire_at` and the recent fire ledger. Check the trigger is `active` (not
disabled/expired), the host clock is sane, and the slot is actually due for
the configured zone. A restart applies the missed policy once: `skip` creates
no catch-up Task, `coalesce_once` creates at most one (`coalesced=true`).
`trigger.fire` is the manual path for a one-off test.

**A webhook gets 401.** This is deliberately uniform for unknown/disabled
key, revoked key, bad signature, stale timestamp, replay and nonce reuse; the
detailed `reason` is only in the `trigger.rejected` event. Check that the key
belongs to this trigger, the timestamp is fresh (default ±300 s), the nonce is
16–64 characters, and the signature is HMAC-SHA256 over the exact bytes
`monexus-webhook-v1\n<key_id>\n<trigger_id>\n<timestamp>\n<nonce>\n<raw_body>`
using the hex-encoded 32-byte secret from the key file. A proxy must not
rewrite the body or path.

**A webhook gets 429 or 413.** 429 means the per-trigger, per-key or global
token bucket is exhausted; honor `Retry-After`. The rejection audit coalesces
to at most one event per trigger per minute with `suppressed_count`. 413 means
the body exceeded the configured limit. Both happen before any Task exists.

**A retry creates no second Task.** Reusing the same
`X-Monexus-Delivery-Id` (or the same nonce with the same body) returns 202
with `duplicate=true` and the original `task_id`. A different body with a
reused nonce is 401 `nonce_reuse`.

**A trigger Task stays `planned`.** That is `target.start_run=false`. Set
`start_run=true` together with `agent_id` and `workspace_id`; the Task is then
created `ready` and the host queues one agent Run after the Task commit. If a
crash lands between the two commits, restarting with triggers enabled starts
the pending Run with the same idempotency key.

**A trigger-created Run stays `waiting_approval`.** That is the existing
Decision flow, not a trigger failure. Answer it from the owner Inbox. The
trigger cannot answer or grant it. Denying the permission, or letting the
Decision expire, makes the Run not-successful; the ACP adapter may still end
its turn normally, so use the Run status and Decision record as the outcome,
not just the adapter transcript.

**Disabling a trigger did not stop an existing Run.** By design: disable
stops new Tasks and does not cancel work or pending Decisions. Use
`run.cancel`/`task.cancel` for that. Duplicate disable is idempotent; an
expired trigger needs `enabled=true` and a future `expires_at` to become
active again.

**`scripts/trigger_smoke.sh` fails immediately.** It needs the built host
binary plus `jq`, `curl`, `openssl`, `python3` and `node` on `PATH`; export
the moon/node paths used by the other smoke scripts. It uses temporary
HOME/state/workspace directories and loopback-only hosts, and intentionally
waits through a real missed schedule window (~2 minutes), so it is slower than
the other smokes. A failure prints the assertion, RPC output and host log.

## Acceptance and tests

**Acceptance fails at P0 packaging.** Read the kept `package.log`; then run
`moon build --target native --release` and `scripts/package.sh` directly.
Acceptance uses a temporary `HOME` for runtime state but the real home for
the build toolchain.

**A `SKIP` row appears.** `g2/g3/g5` skip when `xvfb-run` or a desktop binary
is unavailable; `b3–b6` skip when `sshd`/`ssh-keygen` is missing; the opt-in
real adapter row skips unless `M7_REAL_ACP=1`. A SKIP is not a PASS; the
summary still reports the environment limitation.

**Acceptance leaves processes or files.** It removes its temp work dir and
kills its hosts/sshd by default. Set `KEEP_ACCEPTANCE_WORK=1` to keep logs
and state for debugging (`work dir kept: ...` is printed). Leftover
`monexus-run-*` tmux sessions are cleaned by the script; for a manual run use
an isolated `TMUX_TMPDIR`.

**`sshd` cannot start on the chosen port.** Pick another random loopback
port; the bundled test harness binds an ephemeral port and retries nothing
else. Ensure the temporary config is readable by the unprivileged sshd and
that `AllowUsers` includes the test user.

**Real ACP probe reports `UNVERIFIED`/SKIP.** The account is not logged in or
the adapter download failed. This is reported as a skip, not a product
failure; run the mock path for deterministic verification.

## Resetting state

State is small and local, but it is authoritative. Before any reset:

```bash
monexus stop
cp -a ~/.monexus ~/.monexus.backup-$(date +%s)
```

Removing the state dir loses machines, workspaces, tasks, Runs, Decisions,
events and audit. For a clean demo, prefer a new state dir
(`monexus start --state-dir /tmp/monexus-demo`) instead of deleting the
default one. The first-run sample workspace is recreated automatically when
missing; existing files are never overwritten.
