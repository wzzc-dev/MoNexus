# Runtime PTY and git integration (A1.1b merge)

This slice wires the standalone PTY and git primitives (`services/pty-runtime`,
`services/git-runtime`) into the runtime execution core (`monexus/runtime`).
Every session and every git operation is published through the same durable
outbox, `run_seq` and ack cursor that exec already uses. Transport, TLS,
pairing, the remote RPC surface and host wiring remain out of scope; those are
A1.2b's job. See `docs/runtime-exec-core.md` for the exec/outbox contract and
`docs/runtime-protocol.md` for the transport draft.

## Construction and ownership

- `RuntimeExecutor::open(state_root, runtime_id)` keeps its existing meaning
  and now also creates the PTY runtime at `state_root`, with default
  `PtyLimits`/`GitLimits`.
- `RuntimeExecutor::open_with_limits(state_root, runtime_id, pty_limits~,
  git_limits~)` is the same constructor with explicit bounds; tests use it to
  exercise ring eviction and output caps.
- One executor per state root is still required: the outbox is one SQLite
  connection and recovery assumes a single writer.
- The PTY runtime is constructed with the caller-provided 0700 state root and
  writes sessions under `<state_root>/pty/<instance_id>/<session_id>/`
  (directory 0700, `transcript.log` 0600).
- The caller's long-lived `@async.TaskGroup` owns every PTY session task.
  `pty_open` spawns into that group; there is no detached spawn. Before
  cancelling the group, call `pty_close_all()` so each session gets a durable
  terminal event. `close()` closes the git runtime and the outbox; it does not
  terminate live PTY sessions for you.
- Git is bound lazily with `open_git(workspace_root~)`. The same real root is
  idempotent; a different root is a `conflict`. Git state and per-operation
  output logs live under `<state_root>/logs/git/<instance_id>/<op_seq>/`
  (directory 0700, files 0600), never in the workspace.

## PTY API

```moonbit
pub async fn[X] RuntimeExecutor::pty_open(
  self, group : @async.TaskGroup[X],
  session_id~ : String, client_request_id~ : String = "",
  argv~ : Array[String], cwd~ : String = "",
  env~ : Array[(String, String)] = [], rows~ : Int32 = 24, cols~ : Int32 = 80,
  workspace_root~ : String = "",
) -> Result[PtyOpenOutcome, RuntimeError]

pub async fn RuntimeExecutor::pty_input(self, session_id : String, data : String) -> Result[Unit, RuntimeError]
pub async fn RuntimeExecutor::pty_input_bytes(self, session_id : String, data : Bytes) -> Result[Unit, RuntimeError]
pub async fn RuntimeExecutor::pty_resize(self, session_id : String, rows~ : Int32, cols~ : Int32) -> Result[Unit, RuntimeError]
pub async fn RuntimeExecutor::pty_close(self, session_id : String) -> Result[PtySessionInfo, RuntimeError]
pub async fn RuntimeExecutor::pty_wait(self, session_id : String, timeout_ms~ : Int = 0) -> Result[PtySessionInfo, RuntimeError]
pub async fn RuntimeExecutor::pty_status(self, session_id : String) -> Result[PtySessionInfo, RuntimeError]
pub async fn RuntimeExecutor::pty_events(self, session_id : String, after_seq~ : Int64 = 0L, max_events~ : Int = 256, max_bytes~ : Int = 65_536) -> Result[@pty_runtime.PtyEventPage, RuntimeError]
pub async fn RuntimeExecutor::pty_read_log(self, session_id : String, offset~ : Int64 = 0L, max_bytes~ : Int = 65_536) -> Result[@pty_runtime.PtyLogSlice, RuntimeError]
pub async fn RuntimeExecutor::pty_list(self) -> Array[PtySessionInfo]
pub async fn RuntimeExecutor::pty_close_all(self) -> Result[Array[PtySessionInfo], RuntimeError]
```

Semantics:

- `session_id` is the stable caller identity and the outbox `run_id`.
  `client_request_id` is optional; when present it is validated and bound to
  the session. Repeating `pty_open` with the same session id, request id and
  body returns `Existing(info)` and never spawns a second process. A
  different body or a different `client_request_id` for the same session is a
  stable `conflict`. The primitive's own idempotency check backs this up.
- After a restart, a session recorded in the outbox is returned as
  `Existing` with `status=lost` and `finalized=true`; it is never respawned.
  Use a new `session_id` for a new process. A recovered session accepts
  `pty_status`, `pty_events` (empty ring), `pty_read_log`, `pty_close` and
  `pty_wait`; `pty_input`/`pty_resize` return `already_closed`.
- `argv` is passed literally; no shell string. `env` is the complete child
  environment (nothing inherited implicitly). Secret-named env values are
  redacted to `[redacted]` in the transcript, including across chunk
  boundaries.
- `cwd` is resolved under `workspace_root` (default: the runtime work root);
  absolute paths must be inside it, `..` segments are rejected, symlink
  escapes are rejected after `realpath`, and `.ssh` is refused. The runtime
  never touches the user's `~/.ssh`.
- `pty_input` is never logged or published. `rows`/`cols` default to 24×80.
- `pty_wait(timeout_ms > 0)` terminates the session's process group on
  timeout (TERM → grace → KILL) and reports `cancelled`/`timeout`, never
  success. `pty_close` does the same and waits for the durable terminal
  event. `pty_close_all` closes every live session, returns the infos, and
  is idempotent for sessions that already finished.

### PTY errors

`RuntimeError { code, kind, message, run_seq }` uses the contracts JSON-RPC
codes: invalid argument/not found → `ERR_INVALID_PARAMS`; conflict,
already-closed and timeout → `ERR_HOST`; spawn/io/state-dir/internal →
`ERR_INTERNAL`. Kinds: `invalid_argument`, `not_found`, `path_denied`,
`conflict`, `not_enabled`, `already_closed`, `spawn_failed`, `io`, `timeout`,
`state_dir`, `outbox_error`, `internal`. Messages are redacted and capped at
512 characters.

## PTY event and replay contract

All PTY events use `run_id = session_id`. `run_seq` starts at 0 and is
contiguous; a successful publication is the only thing that advances the
pump's local cursor, so a failed append is retried before anything newer is
written.

| kind | when | payload (bounded) |
| --- | --- | --- |
| `runtime.pty.opened` | exactly once, `run_seq=0` | `session_id`, `client_request_id`, redacted `argv`, relative `cwd`, `rows`, `cols`, `env_names`, `log_rel`, `started_at` |
| `runtime.pty.output` | per primitive `PtyOutputEvent` the pump could read | `session_id`, `pty_seq`, `data` (200-char preview), `raw_bytes`, `log_offset`, `log_bytes` stored, `log_truncated` |
| `runtime.pty.gap` | the ring evicted events before publication | `session_id`, `from_seq`, `to_seq`, `log_offset`, `log_bytes`, `preview` (≤512) |
| `runtime.pty.exited` | exactly once, at finalization | `session_id`, `status`, `stop_reason`, `success`, `cancelled`, `timed_out`, `exit_code`, `signal`, `output_seq`, `output_dropped`, `log_bytes`, `log_truncated`, `residual_pids`, `failure`, `ended_at`, `duration_ms`, `recovered` |

Properties:

- The primitive's per-session `seq` starts at 1 and increases by one per
  output event. Output events carry that `pty_seq`; a gap covers the missing
  range `from_seq..to_seq` inclusive. The terminal event's `output_seq` is
  the last primitive sequence, so a consumer can assert it consumed exactly
  `output_seq` sequences (output + gap ranges) with no hole.
- Output payloads never carry the bytes. `log_offset`/`log_bytes` point into
  the redacted append-only transcript; page it with `pty_read_log(offset~,
  max_bytes~)` (or read the file at `log_rel` from the open event if the
  session was recovered and the primitive no longer knows it). An output
  event whose stored range was capped reports `log_truncated=true`.
- The in-memory ring is an optimisation; `pty_events` may evict and reports
  `dropped`. The durable outbox plus transcript are the replay source. For a
  recovered session the ring is gone, `pty_events` returns an empty page and
  `log_bytes`/`log_truncated` from the terminal event remain authoritative.
- A cancelled or timed-out session is never `succeeded`. A session that was
  running at restart is finalized as `lost`/`host_restarted` exactly once
  during `open` with `recovered=true`; a second restart does not append
  another terminal event. If the terminal append fails, the pump downgrades
  success to `outbox_error`; a session that cannot be verified as finalized
  is published as `lost`/`process_missing`.

A1.2b should treat PTY events exactly like exec events: forward
`(runtime_id, run_id, run_seq)`, ack the global `cursor`, dedupe on the same
triple, and resolve output bytes through `log_offset`/`log_bytes` rather than
inventing them from previews. An `output_dropped`/gap sequence means the
transport must page the transcript before declaring the stream complete.

## Git API

```moonbit
pub async fn RuntimeExecutor::open_git(self, workspace_root~ : String) -> Result[String, RuntimeError]
pub fn RuntimeExecutor::git_workspace_root(self) -> String
pub fn RuntimeExecutor::git_instance_id(self) -> String

pub async fn RuntimeExecutor::git_status(self) -> Result[GitOpOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_diff(self, path~ : String = "", cached~ : Bool = false, range~ : String = "") -> Result[GitOpOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_log(self, rev~ : String = "HEAD", max_count~ : Int = 0, path~ : String = "") -> Result[GitOpOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_show(self, rev~ : String, path~ : String = "") -> Result[GitOpOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_branches(self) -> Result[GitBranchesOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_create_branch(self, name~ : String, start~ : String = "") -> Result[GitOpOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_checkout(self, branch~ : String, create~ : Bool = false) -> Result[GitOpOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_worktrees(self) -> Result[GitWorktreesOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_worktree_add(self, path~ : String, branch~ : String = "", base~ : String = "", client_request_id~ : String = "", force~ : Bool = false) -> Result[GitWorktreeOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_worktree_remove(self, path~ : String, force~ : Bool = false, expected_head~ : String = "", expected_branch~ : String = "") -> Result[GitWorktreeRemoveOutcome, RuntimeError]
pub async fn RuntimeExecutor::git_read_output(self, op_id~ : String, stream~ : String = "stdout", offset~ : Int64 = 0L, max_bytes~ : Int = 65_536) -> Result[GitOutputSlice, RuntimeError]
```

Semantics:

- Every operation is a fixed argv array inside `GitRuntime`; the runtime
  wrapper never builds a shell string, and revisions/branch names are
  validated before reaching git (no option injection).
- `path`, `rev` and worktree paths are rooted in the workspace root.
  Absolute paths inside the root are accepted; `..`, absolute escapes and
  symlink escapes are rejected with `path_denied`; `.ssh` components are
  refused by the wrapper; the workspace root `/` is refused.
- A non-zero git exit is a *result*, not an RPC error: the call returns `Ok`
  with `success=false`, `exit_code` set and the event published. Spawn,
  timeout, path, not-a-repository and protocol failures return `Err` and
  publish `runtime.git.errored` first, with `error.run_seq` pointing at that
  event. Mapping: invalid argument/not found/outside root →
  `ERR_INVALID_PARAMS` (`invalid_argument`/`not_found`/`path_denied`);
  not-a-repository/conflict/timeout/exit → `ERR_HOST`
  (`not_git`/`conflict`/`timeout`/`exit`); spawn/io → `ERR_INTERNAL`.
- Worktree add refuses to reuse a path that already exists on disk or that
  another request registered; a repeat with the same non-empty request id is
  idempotent and returns the existing registration (no new git command).
  Worktree remove validates `expected_head`/`expected_branch` when provided
  and refuses to remove the main worktree. Both operations publish the
  worktree metadata (`path`, `relative_path`, `branch`, `head`, `detached`,
  `main`, `registered`, `request_id`) so the host can enforce leases without
  a second query.

## Git event contract

All git events use the fixed `run_id = "git"`, so their `run_seq` is one
contiguous stream starting at 0 across every operation on this executor.

| kind | when | payload (besides result fields) |
| --- | --- | --- |
| `runtime.git.result` | status/diff/log/show/branches/create-branch/checkout/worktrees and successful worktree remove | `op`, `op_seq`, `op_id`, `exit_code`, `success`, `duration_ms`, byte/line/kept counters, `truncated`, `stdout_log`, `stderr_log`, `stdout_preview`, `stderr_preview`; `branch`/`branch_count`/`worktree_count` where relevant |
| `runtime.git.errored` | any `GitError` that is not a plain non-zero result | `op`, `op_seq`, `op_id`, `code`, `kind`, redacted `message`, `exit_code`, `stderr_preview` |
| `runtime.git.worktree_added` | every successful worktree add (including idempotent replays) | `op="worktree_add"`, `request_id`, full worktree metadata |
| `runtime.git.worktree_removed` | every successful worktree remove | result fields plus `op="worktree_remove"` and the removed worktree metadata |

`op_id` is `"<git instance id>/<op_seq>"`. The event carries bounded
previews (≤512 chars, redacted); the full kept stdout/stderr for the
operation is written redacted and 0600 at the state-relative paths in
`stdout_log`/`stderr_log` and can be paged with
`git_read_output(op_id~, stream~, offset~, max_bytes~)` (≤1 MiB per call).
A1.2b should use the event previews for live display, the output logs for
full retrieval, and the `request_id`/`head`/`branch` fields for lease rules.

## Limits

PTY defaults (`@pty_runtime.PtyLimits::new()`):

- Event data ≤4 KiB; ring ≤256 events and ≤256 KiB; transcript ≤4 MiB
  (further output is counted and dropped, `log_truncated` set).
- Input ≤64 KiB per call; spawn timeout 10 s; close grace 1 s, close timeout
  5 s.
- Runtime pump: 10 ms poll, ≤256 events/64 KiB per page, gap preview ≤512
  bytes. Terminal waits are bounded at 5 s. Transcript reads default to
  64 KiB per call, maximum 1 MiB.

Git defaults (`@git_runtime.GitLimits::new()`):

- ≤256 KiB and ≤4096 lines per stream (stdout and stderr separately; excess
  is counted and dropped, `truncated=true`); command timeout 60 s; operation
  log ≤1 MiB.
- Wrapper previews ≤512 characters; `git_read_output` pages ≤1 MiB per call.

Persistence: state root, `work/`, `logs/`, PTY session dirs and git operation
dirs are 0700; `outbox.db`, transcripts and git output logs are 0600. Nothing
is written to the user's home directory or `~/.ssh`.

## A1.2b call pattern

- Pass the process-long `TaskGroup` to `pty_open`; call `pty_close_all()`
  before cancelling it. A recovered session is `Existing` + `lost`; never
  ask the primitive to respawn it.
- Ack with the global outbox `seq` (`ack_through`); dedupe on
  `(runtime_id, run_id, run_seq)`. PTY `run_id` is the caller's `session_id`;
  git uses `"git"`. A restart resumes at the durable cursor, so acknowledged
  events are not re-delivered.
- For PTY output, map `pty_seq` to ordering and `log_offset`/`log_bytes` to
  transcript retrieval; do not forward `data` as the full chunk. On
  `runtime.pty.gap`, page the transcript; on `dropped`, the ring is not the
  source of truth.
- For git, keep the non-zero-exit/result distinction: an `Ok` outcome with
  `success=false` is not a transport error. Use `op_id` for
  `git_read_output` and the worktree event fields for lease decisions.
- Call `open_git` before any git method; a runtime that has not bound a root
  returns `not_enabled`. `git_read_output` only accepts the current
  instance id, so a restarted runtime cannot read a previous instance's
  operation dirs through the runtime API.

## Tests

`services/runtime` now has 30 tests (all passing; full repository suite 223
tests, all passing). New coverage includes PTY open/echo/input/resize/close,
duplicate-open idempotency and conflicts, ring-eviction gaps with transcript
replay, timeout/close process-group termination, `pty_close_all`, redaction,
PTY ack/restart, PTY crash recovery, git status/diff/log/show/branches,
rooted path rejection (`..`, absolute, symlink, `.ssh`), worktree metadata
and lease fields, bounded/redacted output logs and `git_read_output`, and git
ack/restart.

## Known gaps

- No transport, TLS, pairing, ACP or host wiring (A1.2b). No remote RPC
  method names are registered here.
- PTY transcripts and git operation logs are retained; there is no GC yet.
  Ring eviction means live consumers must fall back to the transcript.
- If the pump is wedged at shutdown, `pty_close`/`pty_close_all` still bound
  their wait, and the session is published as lost rather than success, but
  the terminal event may be written by `pty_settle` after the caller's
  timeout.
- The git worktree registry is in-memory. After a restart, worktrees created
  by the previous instance appear as `registered=false` with an empty
  `request_id`; the host must not treat that as a lease it owns.
- The `realpath`-then-use window remains non-atomic (no `openat2`); exploiting
  it needs concurrent write access to a 0700 root owned by the same user.
- `.ssh` rejection is path-component based; there is no attempt to inspect
  repository config or hooks that could reach outside the root through git
  itself.
