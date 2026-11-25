# Runtime execution core (A1.1)

The transport-agnostic half of ADR-0012: idempotent command execution, bounded
output streaming, a crash-safe outbox and a rooted workspace API. It opens no
sockets, holds no credentials and does not implement pairing, TLS, WSS or the
remote RPC surface (A1.2). Everything lives in the `monexus/runtime` package
(`services/runtime`, added to `moon.work`).

## Public API

- `RuntimeExecutor::open(state_root, runtime_id)` — opens the state root,
  replays the durable outbox and durably finalizes any run that was left
  "running" by a crash as `lost` (`host_restarted`).
- `RuntimeExecutor::start(group, client_request_id~, run_id~, spec~)` —
  idempotent start. The primary assigns `run_id`; the same
  `client_request_id` always returns `Existing(run)` and never spawns a second
  process. A different request id creates a distinct run.
- `RuntimeExecutor::status(run_id)`, `runs()`, `wait_for_terminal(run_id, ms)`,
  `cancel(run_id)`, `close()`.
- `RuntimeExecutor::pending_events(limit)`, `ack_through(cursor)`, `cursor()` —
  outbox publication and acknowledgement. `StoredEvent` payloads carry
  `run_id`, `run_seq`, `kind` plus bounded fields.
- `CommandSpec::new(argv~, cwd~, env~, inherit_env~, timeout_ms~, risk~,
  stdin~, max_output_bytes~)` — argv only, no shell-string entry point;
  explicit env allowlist (`inherit_env` defaults to empty), cwd relative to
  the runtime work root, timeout and risk tier required by policy.
- `RootedDir::open/read_text/write_text/list/stat` — every path is relative,
  resolved with `realpath` and checked against the root. Writes are
  temp-file + fsync + rename and never follow a final-component symlink.

`RunInfo` and `StartOutcome` serialize with `RunInfo::to_json` so A1.2 can map
them to remote events without a second model.

## Persistence and outbox

The outbox **reuses the existing `@machines.MachineStore`** (the app's SQLite
event log with monotonic global `seq`, durable append and a unique
idempotency key) instead of adding a second store. Each runtime state root has
its own `outbox.db` (mode 0600 inside a 0700 root); the runtime never shares
the host database.

- Every event's idempotency key is `(runtime_id, run_id, run_seq)`, which is
  the ADR-0012 dedupe key.
- The publish cursor is itself a durable event (`runtime.outbox.ack` with
  `{"cursor": <seq>}`), appended in the same log as the events it
  acknowledges. `ack_through` only moves it forward; a repeated ack is a
  no-op.
- A start writes `runtime.exec.started` before the process is spawned. Stream
  events (`runtime.exec.stdout|stderr`) reference `(stream, offset, length)`
  in an append-only per-run log; they never carry the bytes, so payloads stay
  bounded (preview ≤ 200 chars). The log write is fsynced before the
  referencing event is appended.
- On restart the executor pages the whole runtime log beyond the store's
  2000-row page cap, rebuilds run state and the request-id map, and resumes
  from the last ack cursor. Acknowledged events are not re-delivered.
- A started run with no terminal event is finalized as `lost` /
  `host_restarted` during `open`, exactly once; a second restart does not
  append another terminal event. A success is downgraded to `lost`
  (`outbox_error`) if its terminal event cannot be written.

## Limits

- Output: 8 MiB per stream by default, 64 MiB hard cap, 64 KiB pipe reads,
  16 KiB line carry for secrets split across reads. One truncation event per
  stream; further output is discarded.
- Timeout: 300 s default, 86 400 000 ms maximum. Timeout and cancel both map
  to `cancelled` (`timeout` / `cancelled` stop reason) and are never reported
  as success.
- Cancel: process-group TERM → 200 ms grace → KILL via `setsid` + `kill
  -- -pid`. If the tree cannot be confirmed dead within 10 s the run is
  `lost` (`process_missing`), never success.
- State: one executor per state root. The outbox is a single SQLite
  connection and two live executors would interleave seq allocation.
- Rooted fs: the `realpath`-then-use window is not atomic (no `openat2` in
  this slice). Exploiting it needs concurrent write access to a 0700 root
  owned by the same user.

## A1.2 integration assumptions

- The primary assigns `run_id` and forwards the client's
  `client_request_id`; request retries reuse the same request id.
- The host (not this package) owns the transport and calls `start`,
  `pending_events` and `ack_through`; the ack cursor is fed back from the
  primary's acknowledgement.
- The `@async.TaskGroup` passed to `start` lives for the runtime process. Its
  cancellation kills all run process trees.
- A run's workspace root is narrowed from `state.work_dir()` to a
  primary-registered workspace; authorization and approval decisions happen
  before `start`. `CommandSpec::effective_risk` only bumps the declared tier,
  it never lowers it.
- Transport event ids may differ from local outbox ids; the dedupe identity
  to send to the primary is `(runtime_id, run_id, run_seq)`.

## Known gaps

- No WSS/TLS/pairing, remote RPC, ACP, git, PTY or UI integration (A1.0/A1.2).
- No log retention/GC; stream logs grow to the per-stream cap and stay.
- Startup replay and `pending_events` are bounded by the store page size but
  the full replay itself is linear in the number of retained events.
- A private-key block whose `BEGIN` line was written before the runtime
  started cannot be recognized; only blocks observed in-stream are dropped.
- Without `setsid`/`kill` on the host image, cancel falls back to killing the
  direct child only; grandchildren may survive.
- A crashed run is always `lost`; the primary decides whether to retry with a
  new request id.
