///|
/// Rooted git primitives for the remote runtime (ADR-0012 §4/§6).
///
/// Every operation is a fixed argv array, never a shell string. The runtime
/// only accepts workspace-relative paths (or absolute paths already under the
/// registered root); paths are normalised, resolved with `realpath` where
/// they exist, and rejected when they leave the root through `..`, an
/// absolute prefix or a symlink. This package does not know about JSON-RPC,
/// leases or ACP; it returns plain results and a monotonic operation
/// sequence that the runtime core can put in its outbox.

///|
pub(all) enum GitErrorKind {
  InvalidArgument
  NotFound
  OutsideRoot
  NotGit
  Conflict
  SpawnFailed
  Io
  Timeout
  Exit
}

///|
pub(all) struct GitError {
  kind : GitErrorKind
  message : String
  seq : Int64
  exit_code : Int
  stderr : String
}

///|
fn git_error(kind : GitErrorKind, message : String) -> GitError {
  { kind, message, seq: 0L, exit_code: 0, stderr: "", }
}

///|
fn GitError::with_seq(self : GitError, seq : Int64) -> GitError {
  { ..self, seq, }
}

///|
fn GitError::with_exit(
  self : GitError,
  exit_code : Int,
  stderr : String,
) -> GitError {
  { ..self, exit_code, stderr, }
}

///|
/// Per-runtime output bounds. `max_output_bytes`/`max_output_lines` apply to
/// stdout and stderr separately; excess data is counted and dropped, never
/// buffered without a bound.
pub(all) struct GitLimits {
  max_output_bytes : Int
  max_output_lines : Int
  timeout_ms : Int
  ops_log_bytes : Int64
}

///|
pub fn GitLimits::new(
  max_output_bytes~ : Int = 262_144,
  max_output_lines~ : Int = 4_096,
  timeout_ms~ : Int = 60_000,
  ops_log_bytes~ : Int64 = 1_048_576L,
) -> GitLimits {
  {
    max_output_bytes: max_output_bytes.max(1_024),
    max_output_lines: max_output_lines.max(16),
    timeout_ms: timeout_ms.max(1_000),
    ops_log_bytes: ops_log_bytes.max(1_024L),
  }
}

///|
pub(all) struct GitCommandResult {
  seq : Int64
  op : String
  exit_code : Int
  stdout : String
  stderr : String
  stdout_bytes : Int64
  stdout_lines : Int64
  stdout_kept_bytes : Int64
  stderr_bytes : Int64
  stderr_lines : Int64
  stderr_kept_bytes : Int64
  truncated : Bool
  duration_ms : Int64
}

///|
pub fn GitCommandResult::ok(self : GitCommandResult) -> Bool {
  self.exit_code == 0
}

///|
pub(all) struct GitBranch {
  name : String
  head : String
  current : Bool
}

///|
pub(all) struct GitBranches {
  result : GitCommandResult
  branches : Array[GitBranch]
}

///|
/// Metadata for one worktree. `registered` is true only when this runtime
/// instance created it; a matching path that this runtime did not create is
/// reported as unregistered instead of being silently adopted.
pub(all) struct WorktreeInfo {
  path : String
  relative_path : String
  branch : String
  head : String
  detached : Bool
  main : Bool
  registered : Bool
  request_id : String
}

///|
pub(all) struct GitWorktrees {
  result : GitCommandResult
  worktrees : Array[WorktreeInfo]
}

///|
pub(all) struct WorktreeAddRequest {
  path : String
  branch : String
  base : String
  client_request_id : String
  force : Bool
}

///|
pub fn WorktreeAddRequest::new(
  path~ : String,
  branch~ : String = "",
  base~ : String = "",
  client_request_id~ : String = "",
  force~ : Bool = false,
) -> WorktreeAddRequest {
  { path, branch, base, client_request_id, force, }
}

///|
pub(all) struct WorktreeRemoveRequest {
  path : String
  force : Bool
  expected_head : String
  expected_branch : String
}

///|
pub fn WorktreeRemoveRequest::new(
  path~ : String,
  force~ : Bool = false,
  expected_head~ : String = "",
  expected_branch~ : String = "",
) -> WorktreeRemoveRequest {
  { path, force, expected_head, expected_branch, }
}

///|
pub(all) struct WorktreeRemoveResult {
  result : GitCommandResult
  removed : WorktreeInfo
}

///|
pub(all) struct GitLogStatus {
  path : String
  bytes : Int64
  truncated : Bool
}
