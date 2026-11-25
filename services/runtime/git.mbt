///|
/// Git integration (A1.1b): rooted git operations are published through the
/// runtime's durable outbox under the fixed `run_id` `git`.
///
/// Contract:
///
/// - Every operation is a fixed argv array inside `GitRuntime`; the runtime
///   wrapper never builds a shell string.
/// - `GitRuntime` result stdout/stderr are already bounded. The wrapper
///   additionally redacts them, writes them to a 0600 per-operation log under
///   `<state root>/logs/git/<instance>/<seq>/` and publishes only bounded
///   previews and byte counters in the event payload.
/// - A non-zero git exit is a *result* (`success=false`, `exit_code` set);
///   spawn, timeout, path and protocol failures are errors published as
///   `runtime.git.errored` and returned as a `RuntimeError` with the mapped
///   JSON-RPC code.
/// - `worktree_add`/`worktree_remove` events carry path, relative_path,
///   branch, head, detached/main/registered and the caller `request_id` so the
///   host can enforce its leases without a second query. The runtime never
///   adopts a worktree path registered by another request.
const GIT_RUN_ID : String = "git"

///|
const GIT_PREVIEW_CHARS : Int32 = 512

///|
const GIT_READ_MAX_BYTES : Int32 = 1_048_576

///|
/// A bounded snapshot of one git operation.
pub(all) struct GitOpOutcome {
  op : String
  op_id : String
  op_seq : Int64
  run_seq : Int64
  event_seq : Int64
  exit_code : Int
  success : Bool
  truncated : Bool
  stdout_bytes : Int64
  stderr_bytes : Int64
  stdout_lines : Int64
  stderr_lines : Int64
  stdout_kept_bytes : Int64
  stderr_kept_bytes : Int64
  duration_ms : Int64
  stdout_preview : String
  stderr_preview : String
  stdout_log : String
  stderr_log : String
}

///|
pub fn GitOpOutcome::to_json(self : GitOpOutcome) -> @json.Json {
  @contracts.json_object([
    ("op", @contracts.json_string(self.op)),
    ("op_id", @contracts.json_string(self.op_id)),
    ("op_seq", @contracts.json_int64(self.op_seq)),
    ("run_seq", @contracts.json_int64(self.run_seq)),
    ("event_seq", @contracts.json_int64(self.event_seq)),
    ("exit_code", @contracts.json_int(self.exit_code)),
    ("success", @contracts.json_bool(self.success)),
    ("truncated", @contracts.json_bool(self.truncated)),
    ("stdout_bytes", @contracts.json_int64(self.stdout_bytes)),
    ("stderr_bytes", @contracts.json_int64(self.stderr_bytes)),
    ("stdout_lines", @contracts.json_int64(self.stdout_lines)),
    ("stderr_lines", @contracts.json_int64(self.stderr_lines)),
    ("stdout_kept_bytes", @contracts.json_int64(self.stdout_kept_bytes)),
    ("stderr_kept_bytes", @contracts.json_int64(self.stderr_kept_bytes)),
    ("duration_ms", @contracts.json_int64(self.duration_ms)),
    ("stdout_preview", @contracts.json_string(self.stdout_preview)),
    ("stderr_preview", @contracts.json_string(self.stderr_preview)),
    ("stdout_log", @contracts.json_string(self.stdout_log)),
    ("stderr_log", @contracts.json_string(self.stderr_log)),
  ])
}

///|
pub(all) struct GitBranchesOutcome {
  result : GitOpOutcome
  branches : Array[@git_runtime.GitBranch]
}

///|
pub(all) struct GitWorktreesOutcome {
  result : GitOpOutcome
  worktrees : Array[@git_runtime.WorktreeInfo]
}

///|
pub(all) struct GitWorktreeOutcome {
  result : GitOpOutcome
  worktree : @git_runtime.WorktreeInfo
}

///|
pub(all) struct GitWorktreeRemoveOutcome {
  result : GitOpOutcome
  removed : @git_runtime.WorktreeInfo
}

///|
/// A bounded slice of one operation's redacted output log.
pub(all) struct GitOutputSlice {
  op_id : String
  stream : String
  offset : Int64
  data : String
  bytes : Int64
  eof : Bool
  log_bytes : Int64
}

///|
fn git_map_error(error : @git_runtime.GitError) -> RuntimeError {
  let mut message = bounded_runtime_message(error.message)
  if error.stderr != "" {
    let stderr = bounded_runtime_message(error.stderr)
    message = bounded_runtime_message(message + ": " + stderr)
  }
  match error.kind {
    @git_runtime.GitErrorKind::InvalidArgument =>
      runtime_invalid("invalid_argument", message)
    @git_runtime.GitErrorKind::NotFound => runtime_invalid("not_found", message)
    @git_runtime.GitErrorKind::OutsideRoot =>
      runtime_invalid("path_denied", message)
    @git_runtime.GitErrorKind::NotGit => runtime_host("not_git", message)
    @git_runtime.GitErrorKind::Conflict => runtime_host("conflict", message)
    @git_runtime.GitErrorKind::SpawnFailed =>
      runtime_internal("spawn_failed", message)
    @git_runtime.GitErrorKind::Io => runtime_internal("io", message)
    @git_runtime.GitErrorKind::Timeout => runtime_host("timeout", message)
    @git_runtime.GitErrorKind::Exit => runtime_host("exit", message)
  }
}

///|
fn git_path_has_ssh(path : String) -> Bool {
  for part in path.split("/") {
    if part == ".ssh" {
      return true
    }
  }
  false
}

///|
fn git_reject_ssh_path(path : String, label : String) -> Result[Unit, RuntimeError] {
  if git_path_has_ssh(path) {
    Err(runtime_invalid("path_denied", label + " must not be inside .ssh"))
  } else {
    Ok(())
  }
}

///|
fn git_preview(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() > GIT_PREVIEW_CHARS.to_int() {
    redacted[:GIT_PREVIEW_CHARS.to_int()].to_string()
  } else {
    redacted
  }
}

///|
fn git_op_id(git : @git_runtime.GitRuntime, seq : Int64) -> String {
  if seq <= 0L {
    ""
  } else {
    git.instance_id() + "/" + seq.to_string()
  }
}

///|
async fn RuntimeExecutor::require_git(
  self : RuntimeExecutor,
) -> Result[@git_runtime.GitRuntime, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.git.val {
    Some(git) => Ok(git)
    None => Err(runtime_not_enabled())
  }
}

///|
/// Bind git for this executor. Idempotent for the same real workspace root;
/// a different root is a conflict. The git operation log lives under the
/// runtime state root and never in the workspace.
pub async fn RuntimeExecutor::open_git(
  self : RuntimeExecutor,
  workspace_root~ : String,
) -> Result[String, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let requested = workspace_root.trim().to_owned()
  if requested == "" {
    return Err(runtime_invalid("invalid_argument", "workspace_root is required"))
  }
  let real = @fs.realpath(requested) catch {
    _ => return Err(runtime_invalid("not_found", "workspace root does not exist"))
  }
  if real == "/" {
    return Err(
      runtime_invalid("path_denied", "refusing / as a workspace root"),
    )
  }
  match git_reject_ssh_path(real, "workspace root") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.git.val {
    Some(existing) =>
      if existing.root() == real {
        Ok(real)
      } else {
        Err(
          runtime_host(
            "conflict",
            "this runtime is already bound to a different workspace root",
          ),
        )
      }
    None => {
      let created = match
        @git_runtime.GitRuntime::new_with_limits(
          real,
          self.state.root(),
          self.git_limits,
        ) {
        Ok(value) => value
        Err(error) => return Err(git_map_error(error))
      }
      self.git.val = Some(created)
      self.git_root.val = created.root()
      Ok(created.root())
    }
  }
}

///|
pub fn RuntimeExecutor::git_workspace_root(self : RuntimeExecutor) -> String {
  self.git_root.val
}

///|
pub fn RuntimeExecutor::git_instance_id(self : RuntimeExecutor) -> String {
  match self.git.val {
    Some(git) => git.instance_id()
    None => ""
  }
}

///|
/// Directory holding one operation's output logs. Created 0700; the files are
/// written 0600.
async fn RuntimeExecutor::git_op_log_dir(
  self : RuntimeExecutor,
  git : @git_runtime.GitRuntime,
  seq : Int64,
) -> String {
  let relative = "git/" + git.instance_id() + "/" + seq.to_string()
  let dir = self.state.logs_dir() + "/" + relative
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => return ""
  }
  @fs.chmod(dir, 0o700) catch { _ => () }
  dir
}

///|
async fn RuntimeExecutor::git_write_output_log(
  self : RuntimeExecutor,
  git : @git_runtime.GitRuntime,
  seq : Int64,
  stream : String,
  text : String,
) -> String {
  if seq <= 0L {
    return ""
  }
  let dir = self.git_op_log_dir(git, seq)
  if dir == "" {
    return ""
  }
  let path = dir + "/" + stream + ".log"
  @fs.write_file(
    path,
    @contracts.redact_secrets(text),
    create_mode=@fs.CreateMode::CreateNew,
    permission=0o600,
    sync=@fs.SyncMode::Data,
  ) catch {
    _ => return ""
  }
  @fs.chmod(path, 0o600) catch { _ => () }
  "logs/git/" + git.instance_id() + "/" + seq.to_string() + "/" + stream + ".log"
}

///|
fn git_result_entries(result : @git_runtime.GitCommandResult) -> Array[(String, @json.Json)] {
  [
    ("op", @contracts.json_string(result.op)),
    ("op_seq", @contracts.json_int64(result.seq)),
    ("exit_code", @contracts.json_int(result.exit_code)),
    ("success", @contracts.json_bool(result.exit_code == 0)),
    ("duration_ms", @contracts.json_int64(result.duration_ms)),
    ("stdout_bytes", @contracts.json_int64(result.stdout_bytes)),
    ("stdout_lines", @contracts.json_int64(result.stdout_lines)),
    ("stdout_kept_bytes", @contracts.json_int64(result.stdout_kept_bytes)),
    ("stderr_bytes", @contracts.json_int64(result.stderr_bytes)),
    ("stderr_lines", @contracts.json_int64(result.stderr_lines)),
    ("stderr_kept_bytes", @contracts.json_int64(result.stderr_kept_bytes)),
    ("truncated", @contracts.json_bool(result.truncated)),
  ]
}

///|
fn git_worktree_entries(
  info : @git_runtime.WorktreeInfo,
) -> Array[(String, @json.Json)] {
  [
    ("path", @contracts.json_string(info.path)),
    ("relative_path", @contracts.json_string(info.relative_path)),
    ("branch", @contracts.json_string(info.branch)),
    ("head", @contracts.json_string(info.head)),
    ("detached", @contracts.json_bool(info.detached)),
    ("main", @contracts.json_bool(info.main)),
    ("registered", @contracts.json_bool(info.registered)),
    ("request_id", @contracts.json_string(info.request_id)),
  ]
}

///|
fn git_worktree_to_json(info : @git_runtime.WorktreeInfo) -> @json.Json {
  @contracts.json_object(git_worktree_entries(info))
}

///|
fn git_branch_to_json(branch : @git_runtime.GitBranch) -> @json.Json {
  @contracts.json_object([
    ("name", @contracts.json_string(branch.name)),
    ("head", @contracts.json_string(branch.head)),
    ("current", @contracts.json_bool(branch.current)),
  ])
}

///|
fn git_worktrees_json(infos : Array[@git_runtime.WorktreeInfo]) -> @json.Json {
  let items : Array[@json.Json] = []
  for info in infos {
    items.push(git_worktree_to_json(info))
  }
  @contracts.json_array(items)
}

///|
fn git_branches_json(branches : Array[@git_runtime.GitBranch]) -> @json.Json {
  let items : Array[@json.Json] = []
  for branch in branches {
    items.push(git_branch_to_json(branch))
  }
  @contracts.json_array(items)
}

///|
/// Publish one successful (or non-zero-exit) git operation and build its
/// outcome. `extra` entries are appended for worktree events.
async fn RuntimeExecutor::git_publish_result(
  self : RuntimeExecutor,
  git : @git_runtime.GitRuntime,
  kind : String,
  result : @git_runtime.GitCommandResult,
  extra : Array[(String, @json.Json)],
) -> Result[GitOpOutcome, RuntimeError] {
  let stdout_log = self.git_write_output_log(
    git,
    result.seq,
    "stdout",
    result.stdout,
  )
  let stderr_log = self.git_write_output_log(
    git,
    result.seq,
    "stderr",
    result.stderr,
  )
  let stdout_preview = git_preview(result.stdout)
  let stderr_preview = git_preview(result.stderr)
  let entries = git_result_entries(result)
  entries.push(("stdout_log", @contracts.json_string(stdout_log)))
  entries.push(("stderr_log", @contracts.json_string(stderr_log)))
  entries.push(("stdout_preview", @contracts.json_string(stdout_preview)))
  entries.push(("stderr_preview", @contracts.json_string(stderr_preview)))
  entries.push(("op_id", @contracts.json_string(git_op_id(git, result.seq))))
  for entry in extra {
    entries.push(entry)
  }
  let stored = match self.outbox.append(GIT_RUN_ID, kind, entries) {
    Ok(value) => value
    Err(message) =>
      return Err(
        runtime_internal(
          "outbox_error",
          "cannot append the git result event: " + message,
        ),
      )
  }
  Ok({
    op: result.op,
    op_id: git_op_id(git, result.seq),
    op_seq: result.seq,
    run_seq: stored.run_seq,
    event_seq: stored.seq,
    exit_code: result.exit_code,
    success: result.exit_code == 0,
    truncated: result.truncated,
    stdout_bytes: result.stdout_bytes,
    stderr_bytes: result.stderr_bytes,
    stdout_lines: result.stdout_lines,
    stderr_lines: result.stderr_lines,
    stdout_kept_bytes: result.stdout_kept_bytes,
    stderr_kept_bytes: result.stderr_kept_bytes,
    duration_ms: result.duration_ms,
    stdout_preview,
    stderr_preview,
    stdout_log,
    stderr_log,
  })
}

///|
/// Publish a git error and map it to a runtime/RPC error. The error's
/// `run_seq` points at the durable errored event so a reconnecting primary can
/// correlate the response with the event stream.
async fn RuntimeExecutor::git_publish_error(
  self : RuntimeExecutor,
  git : @git_runtime.GitRuntime,
  op : String,
  error : @git_runtime.GitError,
) -> RuntimeError {
  let mapped = git_map_error(error)
  if error.seq <= 0L {
    return mapped
  }
  let entries : Array[(String, @json.Json)] = [
    ("op", @contracts.json_string(op)),
    ("op_seq", @contracts.json_int64(error.seq)),
    ("op_id", @contracts.json_string(git_op_id(git, error.seq))),
    ("code", @contracts.json_int(mapped.code)),
    ("kind", @contracts.json_string(mapped.kind)),
    ("message", @contracts.json_string(mapped.message)),
    ("exit_code", pty_int_or_null(error.exit_code)),
    ("stderr_preview", @contracts.json_string(git_preview(error.stderr))),
  ]
  match self.outbox.append(GIT_RUN_ID, EVENT_GIT_ERRORED, entries) {
    Ok(stored) => mapped.with_run_seq(stored.run_seq)
    Err(_) => mapped
  }
}

///|
/// A synthetic outcome used by the idempotent worktree-add replay, which
/// returns an existing registration without a new git command.
fn git_synthetic_outcome(
  op : String,
  stored : StoredEvent,
) -> GitOpOutcome {
  {
    op,
    op_id: "",
    op_seq: 0L,
    run_seq: stored.run_seq,
    event_seq: stored.seq,
    exit_code: 0,
    success: true,
    truncated: false,
    stdout_bytes: 0L,
    stderr_bytes: 0L,
    stdout_lines: 0L,
    stderr_lines: 0L,
    stdout_kept_bytes: 0L,
    stderr_kept_bytes: 0L,
    duration_ms: 0L,
    stdout_preview: "",
    stderr_preview: "",
    stdout_log: "",
    stderr_log: "",
  }
}

///|
fn git_check_input_path(path : String, label : String) -> Result[Unit, RuntimeError] {
  if path == "" {
    return Ok(())
  }
  git_reject_ssh_path(path, label)
}

///|
pub async fn RuntimeExecutor::git_status(
  self : RuntimeExecutor,
) -> Result[GitOpOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git.status() {
    Ok(result) =>
      self.git_publish_result(git, EVENT_GIT_RESULT, result, [])
    Err(error) => Err(self.git_publish_error(git, "status", error))
  }
}

///|
pub async fn RuntimeExecutor::git_diff(
  self : RuntimeExecutor,
  path~ : String = "",
  cached~ : Bool = false,
  range~ : String = "",
) -> Result[GitOpOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git_check_input_path(path, "diff path") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match git.diff(path~, cached~, range~) {
    Ok(result) =>
      self.git_publish_result(git, EVENT_GIT_RESULT, result, [])
    Err(error) => Err(self.git_publish_error(git, "diff", error))
  }
}

///|
pub async fn RuntimeExecutor::git_log(
  self : RuntimeExecutor,
  rev~ : String = "HEAD",
  max_count~ : Int = 0,
  path~ : String = "",
) -> Result[GitOpOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git_check_input_path(path, "log path") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match git.log(rev~, max_count~, path~) {
    Ok(result) =>
      self.git_publish_result(git, EVENT_GIT_RESULT, result, [])
    Err(error) => Err(self.git_publish_error(git, "log", error))
  }
}

///|
pub async fn RuntimeExecutor::git_show(
  self : RuntimeExecutor,
  rev~ : String,
  path~ : String = "",
) -> Result[GitOpOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git_check_input_path(path, "show path") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match git.show(rev~, path~) {
    Ok(result) =>
      self.git_publish_result(git, EVENT_GIT_RESULT, result, [])
    Err(error) => Err(self.git_publish_error(git, "show", error))
  }
}

///|
pub async fn RuntimeExecutor::git_branches(
  self : RuntimeExecutor,
) -> Result[GitBranchesOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git.branches() {
    Ok(value) => {
      let extra : Array[(String, @json.Json)] = [
        ("branch_count", @contracts.json_int(value.branches.length())),
      ]
      let result = match
        self.git_publish_result(git, EVENT_GIT_RESULT, value.result, extra) {
        Ok(outcome) => outcome
        Err(error) => return Err(error)
      }
      Ok({ result, branches: value.branches, })
    }
    Err(error) => Err(self.git_publish_error(git, "branches", error))
  }
}

///|
pub async fn RuntimeExecutor::git_create_branch(
  self : RuntimeExecutor,
  name~ : String,
  start~ : String = "",
) -> Result[GitOpOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git.create_branch(name~, start~) {
    Ok(result) =>
      self.git_publish_result(
        git,
        EVENT_GIT_RESULT,
        result,
        [("branch", @contracts.json_string(name))],
      )
    Err(error) => Err(self.git_publish_error(git, "branch_create", error))
  }
}

///|
pub async fn RuntimeExecutor::git_checkout(
  self : RuntimeExecutor,
  branch~ : String,
  create~ : Bool = false,
) -> Result[GitOpOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git.checkout(branch~, create~) {
    Ok(result) =>
      self.git_publish_result(
        git,
        EVENT_GIT_RESULT,
        result,
        [("branch", @contracts.json_string(branch))],
      )
    Err(error) => Err(self.git_publish_error(git, "checkout", error))
  }
}

///|
pub async fn RuntimeExecutor::git_worktrees(
  self : RuntimeExecutor,
) -> Result[GitWorktreesOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match git.worktrees() {
    Ok(value) => {
      let extra : Array[(String, @json.Json)] = [
        ("worktree_count", @contracts.json_int(value.worktrees.length())),
      ]
      let result = match
        self.git_publish_result(git, EVENT_GIT_RESULT, value.result, extra) {
        Ok(outcome) => outcome
        Err(error) => return Err(error)
      }
      Ok({ result, worktrees: value.worktrees, })
    }
    Err(error) => Err(self.git_publish_error(git, "worktrees", error))
  }
}

///|
/// Add a rooted worktree. The path must be workspace-relative or already
/// inside the root; `.ssh` and escaping paths are rejected. A path already
/// registered by another request is a conflict, never silently adopted.
pub async fn RuntimeExecutor::git_worktree_add(
  self : RuntimeExecutor,
  path~ : String,
  branch~ : String = "",
  base~ : String = "",
  client_request_id~ : String = "",
  force~ : Bool = false,
) -> Result[GitWorktreeOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if path.trim() == "" {
    return Err(runtime_invalid("invalid_argument", "worktree path is required"))
  }
  match git_check_input_path(path, "worktree path") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if client_request_id != "" {
    match validate_resource_id(client_request_id, "client_request_id") {
      Ok(_) => ()
      Err(message) => return Err(runtime_invalid("invalid_argument", message))
    }
  }
  let request = @git_runtime.WorktreeAddRequest::new(
    path~,
    branch~,
    base~,
    client_request_id~,
    force~,
  )
  match git.worktree_add(request) {
    Ok(info) => {
      let entries : Array[(String, @json.Json)] = [
        ("op", @contracts.json_string("worktree_add")),
        ("request_id", @contracts.json_string(info.request_id)),
      ]
      for entry in git_worktree_entries(info) {
        entries.push(entry)
      }
      let stored = match
        self.outbox.append(GIT_RUN_ID, EVENT_GIT_WORKTREE_ADDED, entries) {
        Ok(value) => value
        Err(message) =>
          return Err(
            runtime_internal(
              "outbox_error",
              "cannot append the worktree event: " + message,
            ),
          )
      }
      Ok({
        result: git_synthetic_outcome("worktree_add", stored),
        worktree: info,
      })
    }
    Err(error) =>
      Err(self.git_publish_error(git, "worktree_add", error))
  }
}

///|
/// Remove a worktree after validating its expected head/branch. The event
/// carries the removed worktree metadata for the host's lease rules.
pub async fn RuntimeExecutor::git_worktree_remove(
  self : RuntimeExecutor,
  path~ : String,
  force~ : Bool = false,
  expected_head~ : String = "",
  expected_branch~ : String = "",
) -> Result[GitWorktreeRemoveOutcome, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if path.trim() == "" {
    return Err(runtime_invalid("invalid_argument", "worktree path is required"))
  }
  match git_check_input_path(path, "worktree path") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let request = @git_runtime.WorktreeRemoveRequest::new(
    path~,
    force~,
    expected_head~,
    expected_branch~,
  )
  match git.worktree_remove(request) {
    Ok(value) => {
      let entries : Array[(String, @json.Json)] = [
        ("op", @contracts.json_string("worktree_remove")),
      ]
      for entry in git_worktree_entries(value.removed) {
        entries.push(entry)
      }
      let result = match
        self.git_publish_result(
          git,
          EVENT_GIT_WORKTREE_REMOVED,
          value.result,
          entries,
        ) {
        Ok(outcome) => outcome
        Err(error) => return Err(error)
      }
      Ok({ result, removed: value.removed, })
    }
    Err(error) =>
      Err(self.git_publish_error(git, "worktree_remove", error))
  }
}

///|
fn git_valid_stream(stream : String) -> Bool {
  stream == "stdout" || stream == "stderr"
}

///|
fn git_valid_op_seq(text : String) -> Bool {
  if text == "" || text.length() > 19 {
    return false
  }
  for ch in text {
    let code = ch.to_int()
    if code < 48 || code > 57 {
      return false
    }
  }
  true
}

///|
/// Read a bounded slice of one operation's redacted output log. `op_id` is
/// `"<git instance id>/<op seq>"` as published in the event payload.
pub async fn RuntimeExecutor::git_read_output(
  self : RuntimeExecutor,
  op_id~ : String,
  stream~ : String = "stdout",
  offset~ : Int64 = 0L,
  max_bytes~ : Int = 65_536,
) -> Result[GitOutputSlice, RuntimeError] {
  let git = match self.require_git() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if offset < 0L {
    return Err(runtime_invalid("invalid_argument", "offset must be non-negative"))
  }
  if !git_valid_stream(stream) {
    return Err(runtime_invalid("invalid_argument", "stream must be stdout|stderr"))
  }
  let (instance_view, seq_view) = match op_id.split_once("/") {
    Some(value) => value
    None => return Err(runtime_invalid("invalid_argument", "op_id must be <instance>/<seq>"))
  }
  let instance = instance_view.to_owned()
  let seq_text = seq_view.to_owned()
  if instance != git.instance_id() {
    return Err(runtime_invalid("not_found", "unknown git operation"))
  }
  if !git_valid_op_seq(seq_text) {
    return Err(runtime_invalid("invalid_argument", "invalid git operation sequence"))
  }
  let logs_root = self.state.logs_dir()
  let candidate = logs_root + "/git/" + instance + "/" + seq_text + "/" +
    stream + ".log"
  let real = @fs.realpath(candidate) catch {
    _ => return Err(runtime_invalid("not_found", "git output is not available"))
  }
  if !(real == logs_root || real.has_prefix(logs_root + "/")) {
    return Err(
      runtime_internal("state_dir", "git output escaped the log root"),
    )
  }
  let kind = @fs.kind(real, follow_symlink=true) catch {
    _ => return Err(runtime_invalid("not_found", "git output is not available"))
  }
  if !(kind is @fs.FileKind::Regular) {
    return Err(
      runtime_internal("state_dir", "git output is not a regular file"),
    )
  }
  let limit = max_bytes.max(1).min(GIT_READ_MAX_BYTES.to_int())
  let size = @fs.file_size(real) catch {
    _ => return Err(runtime_internal("io", "cannot stat git output"))
  }
  if offset >= size {
    return Ok({
      op_id,
      stream,
      offset,
      data: "",
      bytes: 0L,
      eof: true,
      log_bytes: size,
    })
  }
  let file = @fs.open(
    real,
    mode=@fs.Mode::ReadOnly,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    _ => return Err(runtime_internal("io", "cannot open git output"))
  }
  defer file.close()
  let available = size - offset
  let requested = if available > limit.to_int64() {
    limit
  } else {
    available.to_int()
  }
  let buffer : FixedArray[Byte] = FixedArray::make(requested, b'\x00')
  let mut got = 0
  while got < requested {
    let count = file.read_at(
      buffer,
      position=offset + got.to_int64(),
      offset=got,
      len=requested - got,
    ) catch {
      _ => return Err(runtime_internal("io", "cannot read git output"))
    }
    if count <= 0 {
      break
    }
    got = got + count
  }
  let bytes = Bytes::from_fixedarray(buffer, len=got)
  Ok({
    op_id,
    stream,
    offset,
    data: @utf8.decode_lossy(bytes[:]),
    bytes: got.to_int64(),
    eof: offset + got.to_int64() >= size,
    log_bytes: size,
  })
}
