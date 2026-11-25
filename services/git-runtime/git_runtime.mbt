///|
/// A rooted git runtime. Construction resolves the workspace root once and
/// creates a 0700 operation-log directory; every later request is checked
/// against that root before git runs.
pub struct GitRuntime {
  root : String
  state_dir : String
  instance_id : String
  ops_log_path : String
  ops_log : @fs.File
  limits : GitLimits
  mutex : @async.Mutex
  next_seq : Ref[Int64]
  ops_log_bytes : Ref[Int64]
  ops_log_truncated : Ref[Bool]
  worktrees : Map[String, WorktreeInfo]
}

///|
fn random_instance_id() -> String {
  let random = @random.Rand::chacha8()
  @async.now().to_string() + "-" + random.int(limit=1_000_000_000).to_string()
}

///|
pub async fn GitRuntime::new(
  workspace_root : String,
  state_dir : String,
) -> Result[GitRuntime, GitError] {
  GitRuntime::new_with_limits(workspace_root, state_dir, GitLimits::new())
}

///|
pub async fn GitRuntime::new_with_limits(
  workspace_root : String,
  state_dir : String,
  limits : GitLimits,
) -> Result[GitRuntime, GitError] {
  let root = @fs.realpath(workspace_root) catch {
    _ => return Err(git_error(GitErrorKind::NotFound, "workspace root does not exist"))
  }
  let kind = @fs.kind(root) catch {
    _ => return Err(git_error(GitErrorKind::NotFound, "workspace root is not readable"))
  }
  if !(kind is @fs.FileKind::Directory) {
    return Err(git_error(GitErrorKind::InvalidArgument, "workspace root is not a directory"))
  }
  if root == "/" {
    return Err(
      git_error(
        GitErrorKind::OutsideRoot,
        "refusing a workspace root of / (arbitrary host paths)",
      ),
    )
  }
  @fs.mkdir(state_dir, permission=0o700, recursive=true, allow_exist=true) catch {
    _ =>
      return Err(
        git_error(GitErrorKind::Io, "cannot create state directory")
          .with_seq(0L),
      )
  }
  @fs.chmod(state_dir, 0o700) catch { _ => () }
  let instance_id = random_instance_id()
  let dir = root_join(state_dir, "git/" + instance_id)
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => return Err(git_error(GitErrorKind::Io, "cannot create git state directory"))
  }
  @fs.chmod(dir, 0o700) catch { _ => () }
  let ops_log_path = root_join(dir, "ops.log")
  let ops_log = @fs.open(
    ops_log_path,
    mode=@fs.Mode::WriteOnly,
    append=true,
    create_mode=@fs.CreateMode::OpenOrCreate,
    permission=0o600,
  ) catch {
    _ => return Err(git_error(GitErrorKind::Io, "cannot open the git operation log"))
  }
  @fs.chmod(ops_log_path, 0o600) catch { _ => () }
  Ok({
    root,
    state_dir,
    instance_id,
    ops_log_path,
    ops_log,
    limits,
    mutex: @async.Mutex::Mutex(),
    next_seq: Ref(0L),
    ops_log_bytes: Ref(0L),
    ops_log_truncated: Ref(false),
    worktrees: Map([]),
  })
}

///|
pub fn GitRuntime::root(self : GitRuntime) -> String {
  self.root
}

///|
pub fn GitRuntime::instance_id(self : GitRuntime) -> String {
  self.instance_id
}

///|
pub fn GitRuntime::ops_log_path(self : GitRuntime) -> String {
  self.ops_log_path
}

///|
pub fn GitRuntime::close(self : GitRuntime) -> Unit {
  self.ops_log.close()
}

///|
pub async fn GitRuntime::log_status(self : GitRuntime) -> GitLogStatus {
  self.mutex.acquire()
  let bytes = @fs.file_size(self.ops_log_path) catch {
    _ => self.ops_log_bytes.val
  }
  let truncated = self.ops_log_truncated.val
  self.mutex.release()
  { path: self.ops_log_path, bytes, truncated, }
}

///|
async fn begin_op(rt : GitRuntime) -> Int64 {
  rt.mutex.acquire()
  let seq = rt.next_seq.val + 1L
  rt.next_seq.val = seq
  rt.mutex.release()
  seq
}

///|
/// Append one bounded line to the operation log. The log contains no argv
/// values, paths or environment values, only the op name, sequence, outcome
/// and size counters.
async fn record_op(
  rt : GitRuntime,
  seq : Int64,
  op : String,
  outcome : String,
  stdout : Capture,
  stderr : Capture,
) -> Unit {
  rt.mutex.acquire()
  if rt.ops_log_truncated.val {
    rt.mutex.release()
    return
  }
  let truncated = stdout.truncated || stderr.truncated
  let line = "seq=" + seq.to_string() + " op=" + op + " outcome=" + outcome +
    " out_bytes=" + stdout.bytes.to_string() + " out_lines=" +
    stdout.lines.to_string() + " err_bytes=" + stderr.bytes.to_string() +
    " err_lines=" + stderr.lines.to_string() + " truncated=" +
    (if truncated { "1" } else { "0" }) + "\n"
  let line_bytes = @utf8.encode(line).length().to_int64()
  if rt.ops_log_bytes.val + line_bytes > rt.limits.ops_log_bytes {
    rt.ops_log_truncated.val = true
    let marker = "log truncated: size cap reached\n"
    let marker_bytes = @utf8.encode(marker).length().to_int64()
    if rt.ops_log_bytes.val + marker_bytes <= rt.limits.ops_log_bytes {
      rt.ops_log.write(marker) catch { _ => () }
      rt.ops_log_bytes.val = rt.ops_log_bytes.val + marker_bytes
    }
    rt.mutex.release()
    return
  }
  rt.ops_log.write(line) catch { _ => () }
  rt.ops_log_bytes.val = rt.ops_log_bytes.val + line_bytes
  rt.mutex.release()
}

///|
async fn record_rejection(
  rt : GitRuntime,
  seq : Int64,
  op : String,
  kind : GitErrorKind,
) -> Unit {
  record_op(
    rt,
    seq,
    op,
    "rejected:" + git_error_kind_label(kind),
    empty_capture(),
    empty_capture(),
  )
}

///|
fn git_error_kind_label(kind : GitErrorKind) -> String {
  match kind {
    InvalidArgument => "invalid_argument"
    NotFound => "not_found"
    OutsideRoot => "outside_root"
    NotGit => "not_git"
    Conflict => "conflict"
    SpawnFailed => "spawn_failed"
    Io => "io"
    Timeout => "timeout"
    Exit => "exit"
  }
}

///|
priv struct RawRun {
  exit_code : Int
  stdout : Capture
  stderr : Capture
}

///|
/// Run one fixed argv array with bounded stdout/stderr and a timeout. On
/// timeout the process receives SIGTERM, then SIGKILL after a grace period
/// (the async process cancellation handler); output pipes are drained by
/// reader tasks so a large diff cannot deadlock the child.
async fn run_git(
  rt : GitRuntime,
  seq : Int64,
  op : String,
  args : Array[String],
  timeout_ms : Int,
) -> Result[GitCommandResult, GitError] {
  let started = @async.now()
  let (out_reader, out_writer) = @process.read_from_process() catch {
    _ => {
      let error = git_error(
        GitErrorKind::Io,
        "cannot create git output pipe",
      ).with_seq(seq)
      record_rejection(rt, seq, op, GitErrorKind::Io)
      return Err(error)
    }
  }
  let (err_reader, err_writer) = @process.read_from_process() catch {
    _ => {
      out_reader.close()
      out_writer.close()
      let error = git_error(
        GitErrorKind::Io,
        "cannot create git error pipe",
      ).with_seq(seq)
      record_rejection(rt, seq, op, GitErrorKind::Io)
      return Err(error)
    }
  }
  let (stdin_reader, stdin_writer) = @process.pipe() catch {
    _ => {
      out_reader.close()
      out_writer.close()
      err_reader.close()
      err_writer.close()
      let error = git_error(
        GitErrorKind::Io,
        "cannot create git stdin pipe",
      ).with_seq(seq)
      record_rejection(rt, seq, op, GitErrorKind::Io)
      return Err(error)
    }
  }
  let env = git_env()
  let max_bytes = rt.limits.max_output_bytes
  let max_lines = rt.limits.max_output_lines
  let attempt = @async.with_timeout_opt(
    timeout_ms,
    async fn() -> Result[RawRun, GitError] {
      @async.with_task_group(
        async fn(group) -> Result[RawRun, GitError] {
          let stdout_task = group.spawn(
            no_wait=false,
            () => capture_stream(out_reader, max_bytes, max_lines),
          )
          let stderr_task = group.spawn(
            no_wait=false,
            () => capture_stream(err_reader, max_bytes, max_lines),
          )
          let process = @process.spawn(
            group,
            "git",
            args,
            extra_env=env,
            inherit_env=false,
            stdin=stdin_reader,
            stdout=out_writer,
            stderr=err_writer,
            cwd=rt.root,
            cancel_handler=@process.graceful_cancel(timeout=1_000),
          ) catch {
            _ => {
              stdin_writer.close()
              out_writer.close()
              err_writer.close()
              return Err(
                git_error(GitErrorKind::SpawnFailed, "cannot run git")
                  .with_seq(seq),
              )
            }
          }
          // The child owns the write ends now; closing ours lets the readers
          // see EOF when it exits, and EOF on stdin if it ever reads.
          stdin_writer.close()
          out_writer.close()
          err_writer.close()
          let exit_code = process.wait()
          let stdout = stdout_task.wait()
          let stderr = stderr_task.wait()
          Ok({ exit_code: exit_code.to_int(), stdout, stderr })
        },
      )
    },
  )
  match attempt {
    Some(Ok(raw)) => {
      let duration_ms = @async.now() - started
      let result : GitCommandResult = {
        seq,
        op,
        exit_code: raw.exit_code,
        stdout: raw.stdout.text,
        stderr: raw.stderr.text,
        stdout_bytes: raw.stdout.bytes,
        stdout_lines: raw.stdout.lines,
        stdout_kept_bytes: raw.stdout.kept_bytes,
        stderr_bytes: raw.stderr.bytes,
        stderr_lines: raw.stderr.lines,
        stderr_kept_bytes: raw.stderr.kept_bytes,
        truncated: raw.stdout.truncated || raw.stderr.truncated,
        duration_ms,
      }
      record_op(
        rt,
        seq,
        op,
        "exit:" + raw.exit_code.to_string(),
        raw.stdout,
        raw.stderr,
      )
      Ok(result)
    }
    Some(Err(error)) => {
      stdin_writer.close()
      out_writer.close()
      err_writer.close()
      record_rejection(rt, seq, op, error.kind)
      Err({ ..error, seq, })
    }
    None => {
      stdin_writer.close()
      out_writer.close()
      err_writer.close()
      record_rejection(rt, seq, op, GitErrorKind::Timeout)
      Err(
        git_error(
          GitErrorKind::Timeout,
          "git " + op + " timed out after " + timeout_ms.to_string() + "ms",
        ).with_seq(seq),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Read-only operations
// ---------------------------------------------------------------------------

///|
pub async fn GitRuntime::status(self : GitRuntime) -> Result[GitCommandResult, GitError] {
  let seq = begin_op(self)
  run_git(
    self,
    seq,
    "status",
    ["--no-pager", "status", "--porcelain=v1", "--branch"],
    self.limits.timeout_ms,
  )
}

///|
pub async fn GitRuntime::diff(
  self : GitRuntime,
  path~ : String = "",
  cached~ : Bool = false,
  range~ : String = "",
) -> Result[GitCommandResult, GitError] {
  let seq = begin_op(self)
  let mut relative = ""
  if path != "" {
    let resolved = match resolve_any(self.root, path, "diff path") {
      Ok(value) => value
      Err(error) => {
        record_rejection(self, seq, "diff", error.kind)
        return Err({ ..error, seq, })
      }
    }
    relative = resolved.relative
  }
  let range_text = range.trim()
  if range_text != "" && !valid_revision(range_text) {
    record_rejection(self, seq, "diff", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid diff range")
        .with_seq(seq),
    )
  }
  let args : Array[String] = ["--no-pager", "diff", "--no-color"]
  if cached {
    args.push("--cached")
  }
  if range_text != "" {
    args.push(range_text.to_owned())
  }
  if relative != "" {
    args.push("--")
    args.push(relative)
  }
  run_git(self, seq, "diff", args, self.limits.timeout_ms)
}

///|
pub async fn GitRuntime::log(
  self : GitRuntime,
  rev~ : String = "HEAD",
  max_count~ : Int = 0,
  path~ : String = "",
) -> Result[GitCommandResult, GitError] {
  let seq = begin_op(self)
  let rev_text = if rev.trim() == "" { "HEAD" } else { rev.trim().to_owned() }
  if !valid_revision(rev_text) {
    record_rejection(self, seq, "log", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid log revision").with_seq(seq),
    )
  }
  if max_count < 0 || max_count > 100_000 {
    record_rejection(self, seq, "log", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid max_count").with_seq(seq),
    )
  }
  let mut relative = ""
  if path != "" {
    let resolved = match resolve_any(self.root, path, "log path") {
      Ok(value) => value
      Err(error) => {
        record_rejection(self, seq, "log", error.kind)
        return Err({ ..error, seq, })
      }
    }
    relative = resolved.relative
  }
  let args : Array[String] = ["--no-pager", "log", "--no-color"]
  if max_count > 0 {
    args.push("--max-count=" + max_count.to_string())
  }
  args.push(rev_text)
  if relative != "" {
    args.push("--")
    args.push(relative)
  }
  run_git(self, seq, "log", args, self.limits.timeout_ms)
}

///|
pub async fn GitRuntime::show(
  self : GitRuntime,
  rev~ : String,
  path~ : String = "",
) -> Result[GitCommandResult, GitError] {
  let seq = begin_op(self)
  if !valid_revision(rev) {
    record_rejection(self, seq, "show", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid show revision").with_seq(seq),
    )
  }
  let mut relative = ""
  if path != "" {
    let resolved = match resolve_any(self.root, path, "show path") {
      Ok(value) => value
      Err(error) => {
        record_rejection(self, seq, "show", error.kind)
        return Err({ ..error, seq, })
      }
    }
    relative = resolved.relative
  }
  let args : Array[String] = ["--no-pager", "show", "--no-color", rev]
  if relative != "" {
    args.push("--")
    args.push(relative)
  }
  run_git(self, seq, "show", args, self.limits.timeout_ms)
}

// ---------------------------------------------------------------------------
// Branches and checkout
// ---------------------------------------------------------------------------

///|
fn parse_branches(raw : String) -> Array[GitBranch] {
  let branches : Array[GitBranch] = []
  for raw_line in raw.split("\n") {
    let line = raw_line.trim_end(chars="\r").to_owned()
    if line == "" {
      continue
    }
    let (name, rest) = match line.split_once("\t") {
      Some(value) => value
      None => continue
    }
    let (head, marker) = match rest.split_once("\t") {
      Some(value) => value
      None => ("", "")
    }
    branches.push({
      name: name.to_owned(),
      head: head.to_owned(),
      current: marker == "*",
    })
  }
  branches
}

///|
pub async fn GitRuntime::branches(self : GitRuntime) -> Result[GitBranches, GitError] {
  let seq = begin_op(self)
  let result = match
    run_git(
      self,
      seq,
      "branches",
      [
        "--no-pager",
        "branch",
        "--list",
        "--format=%(refname:short)%09%(objectname)%09%(HEAD)",
      ],
      self.limits.timeout_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let branches = if result.exit_code == 0 {
    parse_branches(result.stdout)
  } else {
    []
  }
  Ok({ result, branches, })
}

///|
/// Validate a branch name before it reaches git. This blocks option
/// injection (leading `-`), control characters and the ref characters git
/// itself forbids; the name is still passed as one argv element.
fn valid_branch_name(name : String) -> Bool {
  if name == "" || name.length() > 200 || name == "@" {
    return false
  }
  if name.has_prefix("-") || name.has_prefix("/") || name.has_suffix("/") ||
    name.has_suffix(".") || name.has_suffix(".lock") {
    return false
  }
  if name.contains("..") || name.contains("//") || name.contains("@{") {
    return false
  }
  for ch in name {
    let code = ch.to_int()
    if code < 32 || code == 32 || code == 127 {
      return false
    }
    if ch == '~' || ch == '^' || ch == ':' || ch == '?' || ch == '*' ||
      ch == '[' || ch == ']' || ch == '\\' {
      return false
    }
  }
  true
}

///|
/// Revisions may be rich (`HEAD~2`, `main...next`, tags) but must not start
/// with `-` (option injection) or contain whitespace/control bytes.
fn valid_revision(rev : StringView) -> Bool {
  if rev == "" || rev.length() > 512 || rev.has_prefix("-") {
    return false
  }
  for ch in rev {
    let code = ch.to_int()
    if code < 32 || code == 32 || code == 127 {
      return false
    }
  }
  true
}

///|
pub async fn GitRuntime::create_branch(
  self : GitRuntime,
  name~ : String,
  start~ : String = "",
) -> Result[GitCommandResult, GitError] {
  let seq = begin_op(self)
  if !valid_branch_name(name) {
    record_rejection(self, seq, "branch_create", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid branch name").with_seq(seq),
    )
  }
  let start_text = start.trim()
  if start_text != "" && !valid_revision(start_text) {
    record_rejection(self, seq, "branch_create", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid branch start point").with_seq(seq),
    )
  }
  let args : Array[String] = ["--no-pager", "branch", "--", name]
  if start_text != "" {
    args.push(start_text.to_owned())
  }
  run_git(self, seq, "branch_create", args, self.limits.timeout_ms)
}

///|
pub async fn GitRuntime::checkout(
  self : GitRuntime,
  branch~ : String,
  create~ : Bool = false,
) -> Result[GitCommandResult, GitError] {
  let seq = begin_op(self)
  if !valid_branch_name(branch) {
    record_rejection(self, seq, "checkout", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid branch name").with_seq(seq),
    )
  }
  let args : Array[String] = ["--no-pager", "checkout"]
  if create {
    args.push("-b")
    args.push(branch)
  } else {
    args.push(branch)
  }
  run_git(self, seq, "checkout", args, self.limits.timeout_ms)
}

// ---------------------------------------------------------------------------
// Worktrees
// ---------------------------------------------------------------------------

///|
struct RawWorktree {
  path : String
  head : String
  branch_ref : String
  detached : Bool
}

///|
fn parse_worktree_porcelain(raw : String) -> Array[RawWorktree] {
  let entries : Array[RawWorktree] = []
  let mut path = ""
  let mut head = ""
  let mut branch_ref = ""
  let mut detached = false
  let mut used = false
  for raw_line in raw.split("\n") {
    let line = raw_line.trim_end(chars="\r").to_owned()
    if line == "" {
      if used {
        entries.push({ path, head, branch_ref, detached, })
        path = ""
        head = ""
        branch_ref = ""
        detached = false
        used = false
      }
      continue
    }
    if line.has_prefix("worktree ") {
      path = line.substring(start=9)
      used = true
    } else if line.has_prefix("HEAD ") {
      head = line.substring(start=5)
    } else if line.has_prefix("branch ") {
      branch_ref = line.substring(start=7)
    } else if line == "detached" {
      detached = true
    }
  }
  if used {
    entries.push({ path, head, branch_ref, detached, })
  }
  entries
}

///|
fn branch_from_ref(ref : String) -> String {
  if ref.has_prefix("refs/heads/") {
    ref.substring(start=11)
  } else {
    ref
  }
}

///|
/// Read `git worktree list --porcelain` and expose only worktrees whose real
/// path is inside the root. Paths that do not resolve (removed worktrees) or
/// point elsewhere are skipped rather than leaked to the caller.
async fn collect_worktrees(
  rt : GitRuntime,
  seq : Int64,
) -> Result[GitWorktrees, GitError] {
  let result = match
    run_git(
      rt,
      seq,
      "worktree_list",
      ["--no-pager", "worktree", "list", "--porcelain"],
      rt.limits.timeout_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let raws = if result.exit_code == 0 {
    parse_worktree_porcelain(result.stdout)
  } else {
    []
  }
  let resolved : Array[(String, String, String, String, Bool)] = []
  for raw in raws {
    if raw.path == "" {
      continue
    }
    let real = @fs.realpath(raw.path) catch { _ => continue }
    if !is_within(real, rt.root) {
      continue
    }
    let relative = if real == rt.root {
      ""
    } else {
      real.substring(start=rt.root.length() + 1)
    }
    let branch = branch_from_ref(raw.branch_ref)
    let detached = raw.detached || raw.branch_ref == ""
    resolved.push((real, relative, branch, raw.head, detached))
  }
  let infos : Array[WorktreeInfo] = []
  rt.mutex.acquire()
  for entry in resolved {
    let (real, relative, branch, head, detached) = entry
    let (registered, request_id) = match rt.worktrees.get(real) {
      Some(info) => (info.registered, info.request_id)
      None => (false, "")
    }
    infos.push({
      path: real,
      relative_path: relative,
      branch,
      head,
      detached,
      main: real == rt.root,
      registered,
      request_id,
    })
  }
  rt.mutex.release()
  Ok({ result, worktrees: infos, })
}

///|
pub async fn GitRuntime::worktrees(self : GitRuntime) -> Result[GitWorktrees, GitError] {
  let seq = begin_op(self)
  collect_worktrees(self, seq)
}

///|
async fn git_trimmed(
  rt : GitRuntime,
  seq : Int64,
  op : String,
  args : Array[String],
) -> Result[String, GitError] {
  let result = match run_git(rt, seq, op, args, rt.limits.timeout_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code == 0 {
    Ok(result.stdout.trim().to_owned())
  } else {
    Err(
      git_error(GitErrorKind::Exit, "git " + op + " failed")
        .with_seq(seq)
        .with_exit(result.exit_code, result.stderr),
    )
  }
}

///|
pub async fn GitRuntime::worktree_add(
  self : GitRuntime,
  request : WorktreeAddRequest,
) -> Result[WorktreeInfo, GitError] {
  let seq = begin_op(self)
  let branch = request.branch.trim().to_owned()
  if branch != "" && !valid_branch_name(branch) {
    record_rejection(self, seq, "worktree_add", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid worktree branch").with_seq(seq),
    )
  }
  let base = request.base.trim().to_owned()
  if base != "" && !valid_revision(base) {
    record_rejection(self, seq, "worktree_add", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "invalid worktree base").with_seq(seq),
    )
  }
  let target = match resolve_any(self.root, request.path, "worktree path") {
    Ok(value) => value
    Err(error) => {
      record_rejection(self, seq, "worktree_add", error.kind)
      return Err({ ..error, seq, })
    }
  }
  // Never silently adopt a worktree another run registered, and never reuse
  // a path that already exists on disk without the caller seeing it.
  self.mutex.acquire()
  let known = self.worktrees.get(target.absolute)
  self.mutex.release()
  match known {
    Some(info) =>
      if request.client_request_id != "" &&
        info.request_id == request.client_request_id {
        record_op(
          self,
          seq,
          "worktree_add",
          "idempotent",
          empty_capture(),
          empty_capture(),
        )
        return Ok(info)
      } else {
        record_rejection(self, seq, "worktree_add", GitErrorKind::Conflict)
        return Err(
          git_error(
            GitErrorKind::Conflict,
            "worktree path is already registered by another request",
          ).with_seq(seq),
        )
      }
    None => ()
  }
  let exists = @fs.exists(target.absolute) catch { _ => true }
  if exists {
    record_rejection(self, seq, "worktree_add", GitErrorKind::Conflict)
    return Err(
      git_error(
        GitErrorKind::Conflict,
        "worktree path already exists; refusing to adopt it",
      ).with_seq(seq),
    )
  }
  let args : Array[String] = ["--no-pager", "worktree", "add"]
  if request.force {
    args.push("--force")
  }
  if branch != "" {
    args.push("-b")
    args.push(branch)
  } else {
    args.push("--detach")
  }
  args.push(target.absolute)
  if base != "" {
    args.push(base)
  }
  let result = match
    run_git(self, seq, "worktree_add", args, self.limits.timeout_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(
      git_error(GitErrorKind::Exit, "git worktree add failed")
        .with_seq(seq)
        .with_exit(result.exit_code, result.stderr),
    )
  }
  let head = match
    git_trimmed(
      self,
      seq,
      "worktree_head",
      ["-C", target.absolute, "rev-parse", "HEAD"],
    ) {
    Ok(value) => value
    Err(_) => ""
  }
  let symbolic = match
    git_trimmed(
      self,
      seq,
      "worktree_branch",
      ["-C", target.absolute, "symbolic-ref", "--quiet", "--short", "HEAD"],
    ) {
    Ok(value) => value
    Err(_) => ""
  }
  let actual_branch = if symbolic != "" {
    symbolic
  } else if branch != "" {
    branch
  } else {
    ""
  }
  let detached = symbolic == "" && branch == ""
  let info : WorktreeInfo = {
    path: target.absolute,
    relative_path: target.relative,
    branch: actual_branch,
    head,
    detached,
    main: false,
    registered: true,
    request_id: request.client_request_id,
  }
  self.mutex.acquire()
  self.worktrees.set(target.absolute, info)
  self.mutex.release()
  Ok(info)
}

///|
pub async fn GitRuntime::worktree_remove(
  self : GitRuntime,
  request : WorktreeRemoveRequest,
) -> Result[WorktreeRemoveResult, GitError] {
  let seq = begin_op(self)
  let target = match resolve_existing(self.root, request.path, "worktree path") {
    Ok(value) => value
    Err(error) => {
      record_rejection(self, seq, "worktree_remove", error.kind)
      return Err({ ..error, seq, })
    }
  }
  if target.relative == "" {
    record_rejection(self, seq, "worktree_remove", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "cannot remove the main worktree")
        .with_seq(seq),
    )
  }
  let listed = match collect_worktrees(self, seq) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut found : WorktreeInfo? = None
  for info in listed.worktrees {
    if info.path == target.absolute {
      found = Some(info)
    }
  }
  let info = match found {
    Some(value) => value
    None => {
      record_rejection(self, seq, "worktree_remove", GitErrorKind::NotFound)
      return Err(
        git_error(
          GitErrorKind::NotFound,
          "path is not a worktree of this repository",
        ).with_seq(seq),
      )
    }
  }
  if info.main {
    record_rejection(self, seq, "worktree_remove", GitErrorKind::InvalidArgument)
    return Err(
      git_error(GitErrorKind::InvalidArgument, "cannot remove the main worktree")
        .with_seq(seq),
    )
  }
  if request.expected_head != "" && request.expected_head != info.head {
    record_rejection(self, seq, "worktree_remove", GitErrorKind::Conflict)
    return Err(
      git_error(
        GitErrorKind::Conflict,
        "worktree HEAD does not match the expected head",
      ).with_seq(seq),
    )
  }
  if request.expected_branch != "" && request.expected_branch != info.branch {
    record_rejection(self, seq, "worktree_remove", GitErrorKind::Conflict)
    return Err(
      git_error(
        GitErrorKind::Conflict,
        "worktree branch does not match the expected branch",
      ).with_seq(seq),
    )
  }
  let args : Array[String] = ["--no-pager", "worktree", "remove"]
  if request.force {
    args.push("--force")
  }
  args.push(target.absolute)
  let result = match
    run_git(self, seq, "worktree_remove", args, self.limits.timeout_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(
      git_error(GitErrorKind::Exit, "git worktree remove failed")
        .with_seq(seq)
        .with_exit(result.exit_code, result.stderr),
    )
  }
  self.mutex.acquire()
  self.worktrees.remove(target.absolute)
  self.mutex.release()
  Ok({ result, removed: info, })
}
