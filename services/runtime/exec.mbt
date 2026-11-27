///|
/// Stop reasons reported on a terminal event. `cancelled`/`timeout` are never
/// mapped to `succeeded`; a lost run is `lost` (contracts).
pub const STOP_REASON_EXITED : String = "exited"

///|
pub const STOP_REASON_CANCELLED : String = "cancelled"

///|
pub const STOP_REASON_TIMEOUT : String = "timeout"

///|
pub const STOP_REASON_SPAWN_FAILED : String = "spawn_failed"

///|
pub const STOP_REASON_HOST_RESTARTED : String = "host_restarted"

///|
pub const STOP_REASON_PROCESS_MISSING : String = "process_missing"

///|
pub const STOP_REASON_IO_ERROR : String = "io_error"

///|
pub const STOP_REASON_OUTBOX_ERROR : String = "outbox_error"

///|
const CHUNK_BYTES : Int32 = 65_536

///|
const PREVIEW_CHARS : Int32 = 200

///|
const MAX_LINE_CARRY : Int32 = 16_384

///|
const SPAWN_READY_TIMEOUT_MS : Int64 = 5_000

///|
const CANCEL_WAIT_TIMEOUT_MS : Int64 = 10_000

///|
/// Immutable snapshot of one run, returned by every transport-facing call.
pub(all) struct RunInfo {
  run_id : String
  client_request_id : String
  status : String
  risk : String
  started_at : String
  ended_at : String?
  exit_code : Int32?
  signal : Int32?
  stop_reason : String
  stdout_bytes : Int64
  stderr_bytes : Int64
  timed_out : Bool
  truncated_stdout : Bool
  truncated_stderr : Bool
}

///|
pub fn RunInfo::to_json(self : RunInfo) -> @json.Json {
  @contracts.json_object([
    ("run_id", @contracts.json_string(self.run_id)),
    ("client_request_id", @contracts.json_string(self.client_request_id)),
    ("status", @contracts.json_string(self.status)),
    ("risk", @contracts.json_string(self.risk)),
    ("started_at", @contracts.json_string(self.started_at)),
    (
      "ended_at",
      match self.ended_at {
        Some(value) => @contracts.json_string(value)
        None => @contracts.json_null()
      },
    ),
    (
      "exit_code",
      match self.exit_code {
        Some(value) => @contracts.json_int(value)
        None => @contracts.json_null()
      },
    ),
    (
      "signal",
      match self.signal {
        Some(value) => @contracts.json_int(value)
        None => @contracts.json_null()
      },
    ),
    ("stop_reason", @contracts.json_string(self.stop_reason)),
    ("stdout_bytes", @contracts.json_int64(self.stdout_bytes)),
    ("stderr_bytes", @contracts.json_int64(self.stderr_bytes)),
    ("timed_out", @contracts.json_bool(self.timed_out)),
    ("truncated_stdout", @contracts.json_bool(self.truncated_stdout)),
    ("truncated_stderr", @contracts.json_bool(self.truncated_stderr)),
  ])
}

///|
/// Result of an idempotent `start`. `Existing` means the client request id was
/// already seen: no second process was spawned.
pub(all) enum StartOutcome {
  Started(RunInfo)
  Existing(RunInfo)
}

///|
pub fn StartOutcome::info(self : StartOutcome) -> RunInfo {
  match self {
    Started(info) => info
    Existing(info) => info
  }
}

///|
pub fn StartOutcome::is_new(self : StartOutcome) -> Bool {
  match self {
    Started(_) => true
    Existing(_) => false
  }
}

///|
/// Mutable per-run bookkeeping. Output offsets and truncation flags are only
/// touched while holding `log_lock`, so the two pumps cannot interleave a log
/// write with a seq allocation.
struct RunSlot {
  info : Ref[RunInfo]
  started_ms : Int64
  proc : Ref[@process.Process?]
  ready : Ref[Bool]
  spawn_error : Ref[String?]
  cancel_requested : Ref[Bool]
  timed_out : Ref[Bool]
  finished : Ref[Bool]
  log_lock : @async.Mutex
  stdout_path : String
  stderr_path : String
  stdout_offset : Ref[Int64]
  stderr_offset : Ref[Int64]
  stdout_truncated : Ref[Bool]
  stderr_truncated : Ref[Bool]
  stdout_carry : Ref[String]
  stderr_carry : Ref[String]
  stdout_in_pem : Ref[Bool]
  stderr_in_pem : Ref[Bool]
  log_error : Ref[String?]
  max_output_bytes : Int32
}

///|
fn stream_path(slot : RunSlot, stream : String) -> String {
  if stream == "stdout" {
    slot.stdout_path
  } else {
    slot.stderr_path
  }
}

///|
fn stream_offset(slot : RunSlot, stream : String) -> Int64 {
  if stream == "stdout" {
    slot.stdout_offset.val
  } else {
    slot.stderr_offset.val
  }
}

///|
fn set_stream_offset(slot : RunSlot, stream : String, value : Int64) -> Unit {
  if stream == "stdout" {
    slot.stdout_offset.val = value
  } else {
    slot.stderr_offset.val = value
  }
}

///|
fn was_truncated(slot : RunSlot, stream : String) -> Bool {
  if stream == "stdout" {
    slot.stdout_truncated.val
  } else {
    slot.stderr_truncated.val
  }
}

///|
fn mark_truncated(slot : RunSlot, stream : String) -> Unit {
  if stream == "stdout" {
    slot.stdout_truncated.val = true
  } else {
    slot.stderr_truncated.val = true
  }
}

///|
fn carry_of(slot : RunSlot, stream : String) -> String {
  if stream == "stdout" {
    slot.stdout_carry.val
  } else {
    slot.stderr_carry.val
  }
}

///|
fn set_carry(slot : RunSlot, stream : String, value : String) -> Unit {
  if stream == "stdout" {
    slot.stdout_carry.val = value
  } else {
    slot.stderr_carry.val = value
  }
}

///|
fn in_pem_of(slot : RunSlot, stream : String) -> Bool {
  if stream == "stdout" {
    slot.stdout_in_pem.val
  } else {
    slot.stderr_in_pem.val
  }
}

///|
fn set_in_pem(slot : RunSlot, stream : String, value : Bool) -> Unit {
  if stream == "stdout" {
    slot.stdout_in_pem.val = value
  } else {
    slot.stderr_in_pem.val = value
  }
}

///|
/// The node-local executor. All state lives under one runtime state root; the
/// executor is transport-agnostic and opens no sockets.
///
/// Ownership limit for this slice: one executor per state root. The outbox is
/// a single SQLite connection, and two live executors on the same root would
/// interleave seq allocation.
pub struct RuntimeExecutor {
  state : RuntimeState
  outbox : Outbox
  runtime_id : String
  mutex : @async.Mutex
  runs : Map[String, RunSlot]
  by_request : Map[String, String]
  closed : Ref[Bool]
  /// PTY sessions are owned by this runtime and live under
  /// `<state root>/pty/<instance>/`. The runtime is created once per
  /// executor; sessions are spawned into the caller's long-lived group.
  pty : @pty_runtime.PtyRuntime
  pty_limits : @pty_runtime.PtyLimits
  pty_slots : Map[String, PtySlot]
  pty_recovered : Map[String, PtyRecovered]
  pty_recovered_requests : Map[String, String]
  /// Git is opt-in: `open_git(workspace_root)` binds one rooted GitRuntime to
  /// this executor. Its operation log lives under `<state root>/git/`.
  git : Ref[@git_runtime.GitRuntime?]
  git_root : Ref[String]
  git_limits : @git_runtime.GitLimits
  /// Streaming ACP-process runtime (A1.4), sharing the same durable outbox and
  /// rooted work directory. It is transport-agnostic and owns no socket.
  process : ProcessRuntime
}

///|
/// Rebuild one run's state from the replay of its events.
struct RecoveredRun {
  mut info : RunInfo
  mut has_terminal : Bool
  mut stdout_bytes : Int64
  mut stderr_bytes : Int64
  mut truncated_stdout : Bool
  mut truncated_stderr : Bool
}

///|
fn recovered_start_info(event : StoredEvent) -> RunInfo {
  let object = @contracts.as_object(event.payload)
  let request = match object {
    Some(value) => @contracts.string_field_or(value, "client_request_id", "")
    None => ""
  }
  let risk = match object {
    Some(value) =>
      @contracts.string_field_or(value, "risk", @contracts.RISK_MEDIUM)
    None => @contracts.RISK_MEDIUM
  }
  let started_at = match object {
    Some(value) => @contracts.string_field_or(value, "started_at", event.ts)
    None => event.ts
  }
  {
    run_id: event.run_id,
    client_request_id: request,
    status: @contracts.RUN_STATUS_RUNNING,
    risk,
    started_at,
    ended_at: None,
    exit_code: None,
    signal: None,
    stop_reason: "",
    stdout_bytes: 0L,
    stderr_bytes: 0L,
    timed_out: false,
    truncated_stdout: false,
    truncated_stderr: false,
  }
}

///|
fn apply_terminal(info : RunInfo, event : StoredEvent) -> RunInfo {
  let object = match @contracts.as_object(event.payload) {
    Some(value) => value
    None => return info
  }
  let status = @contracts.string_field_or(
    object,
    "status",
    @contracts.RUN_STATUS_LOST,
  )
  let stop_reason = @contracts.string_field_or(object, "stop_reason", "")
  let ended_at = @contracts.string_field(object, "ended_at")
  let exit_code = @contracts.int_field(object, "exit_code")
  let signal = @contracts.int_field(object, "signal")
  let stdout_bytes = @contracts.int64_field_or(
    object,
    "stdout_bytes",
    info.stdout_bytes,
  )
  let stderr_bytes = @contracts.int64_field_or(
    object,
    "stderr_bytes",
    info.stderr_bytes,
  )
  let timed_out = @contracts.bool_field_or(object, "timed_out", false)
  let truncated_stdout = @contracts.bool_field_or(
    object,
    "truncated_stdout",
    info.truncated_stdout,
  )
  let truncated_stderr = @contracts.bool_field_or(
    object,
    "truncated_stderr",
    info.truncated_stderr,
  )
  {
    run_id: info.run_id,
    client_request_id: info.client_request_id,
    status,
    risk: info.risk,
    started_at: info.started_at,
    ended_at,
    exit_code,
    signal,
    stop_reason,
    stdout_bytes,
    stderr_bytes,
    timed_out,
    truncated_stdout,
    truncated_stderr,
  }
}

///|
fn make_run_slot(
  info : RunInfo,
  started_ms : Int64,
  out_path : String,
  err_path : String,
  max_output_bytes : Int32,
) -> RunSlot {
  {
    info: Ref(info),
    started_ms,
    proc: Ref(None),
    ready: Ref(false),
    spawn_error: Ref(None),
    cancel_requested: Ref(false),
    timed_out: Ref(false),
    finished: Ref(false),
    log_lock: @async.Mutex::Mutex(),
    stdout_path: out_path,
    stderr_path: err_path,
    stdout_offset: Ref(0L),
    stderr_offset: Ref(0L),
    stdout_truncated: Ref(false),
    stderr_truncated: Ref(false),
    stdout_carry: Ref(""),
    stderr_carry: Ref(""),
    stdout_in_pem: Ref(false),
    stderr_in_pem: Ref(false),
    log_error: Ref(None),
    max_output_bytes,
  }
}

///|
async fn RuntimeExecutor::recover(
  self : RuntimeExecutor,
  events : Array[StoredEvent],
) -> Result[Unit, String] {
  let recovered : Map[String, RecoveredRun] = Map([])
  let order : Array[String] = []
  for event in events {
    if event.run_id == "" {
      continue
    }
    match recovered.get(event.run_id) {
      Some(run) =>
        if event.kind == EVENT_EXEC_STARTED {
          let _ = run
        } else if event.kind == EVENT_EXEC_STDOUT ||
          event.kind == EVENT_EXEC_STDERR {
          let object = @contracts.as_object(event.payload)
          let offset = match object {
            Some(value) => @contracts.int64_field_or(value, "offset", 0L)
            None => 0L
          }
          let length = match object {
            Some(value) => @contracts.int64_field_or(value, "length", 0L)
            None => 0L
          }
          let end = offset + length
          if event.kind == EVENT_EXEC_STDOUT {
            if end > run.stdout_bytes {
              run.stdout_bytes = end
            }
          } else if end > run.stderr_bytes {
            run.stderr_bytes = end
          }
        } else if event.kind == EVENT_EXEC_TRUNCATED {
          let object = @contracts.as_object(event.payload)
          let stream = match object {
            Some(value) => @contracts.string_field_or(value, "stream", "")
            None => ""
          }
          if stream == "stdout" {
            run.truncated_stdout = true
          } else if stream == "stderr" {
            run.truncated_stderr = true
          }
        } else if event.kind == EVENT_EXEC_EXITED {
          run.info = apply_terminal(run.info, event)
          run.has_terminal = true
        }
      None =>
        if event.kind == EVENT_EXEC_STARTED {
          let info = recovered_start_info(event)
          recovered.set(event.run_id, {
            info,
            has_terminal: false,
            stdout_bytes: 0L,
            stderr_bytes: 0L,
            truncated_stdout: false,
            truncated_stderr: false,
          })
          order.push(event.run_id)
        }
    }
  }
  for run_id in order {
    let run = recovered.get(run_id).unwrap()
    let started_ms = @async.now()
    let paths = match self.state.ensure_run_logs(run_id) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    let (out_path, err_path) = paths
    let mut info = run.info
    if !run.has_terminal {
      // A started run with no terminal event was interrupted by a crash or a
      // process kill. It can never be reported as success.
      let ended_at = @contracts.format_rfc3339(started_ms)
      let terminal_entries : Array[(String, @json.Json)] = [
        ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
        ("stop_reason", @contracts.json_string(STOP_REASON_HOST_RESTARTED)),
        ("ended_at", @contracts.json_string(ended_at)),
        ("exit_code", @contracts.json_null()),
        ("signal", @contracts.json_null()),
        ("stdout_bytes", @contracts.json_int64(run.stdout_bytes)),
        ("stderr_bytes", @contracts.json_int64(run.stderr_bytes)),
        ("timed_out", @contracts.json_bool(false)),
        ("cancelled", @contracts.json_bool(false)),
        ("truncated_stdout", @contracts.json_bool(run.truncated_stdout)),
        ("truncated_stderr", @contracts.json_bool(run.truncated_stderr)),
        ("recovered", @contracts.json_bool(true)),
      ]
      match self.outbox.append(run_id, EVENT_EXEC_EXITED, terminal_entries) {
        Ok(_) => ()
        Err(message) => return Err("cannot record recovered run: " + message)
      }
      info = {
        run_id: info.run_id,
        client_request_id: info.client_request_id,
        status: @contracts.RUN_STATUS_LOST,
        risk: info.risk,
        started_at: info.started_at,
        ended_at: Some(ended_at),
        exit_code: None,
        signal: None,
        stop_reason: STOP_REASON_HOST_RESTARTED,
        stdout_bytes: run.stdout_bytes,
        stderr_bytes: run.stderr_bytes,
        timed_out: false,
        truncated_stdout: run.truncated_stdout,
        truncated_stderr: run.truncated_stderr,
      }
    } else {
      info = {
        run_id: info.run_id,
        client_request_id: info.client_request_id,
        status: info.status,
        risk: info.risk,
        started_at: info.started_at,
        ended_at: info.ended_at,
        exit_code: info.exit_code,
        signal: info.signal,
        stop_reason: info.stop_reason,
        stdout_bytes: run.stdout_bytes,
        stderr_bytes: run.stderr_bytes,
        timed_out: info.timed_out,
        truncated_stdout: run.truncated_stdout,
        truncated_stderr: run.truncated_stderr,
      }
    }
    let slot = make_run_slot(info, started_ms, out_path, err_path, 0)
    slot.stdout_offset.val = run.stdout_bytes
    slot.stderr_offset.val = run.stderr_bytes
    slot.stdout_truncated.val = run.truncated_stdout
    slot.stderr_truncated.val = run.truncated_stderr
    slot.finished.val = true
    if slot.info.val.client_request_id != "" &&
      self.by_request.get(slot.info.val.client_request_id) is None {
      self.by_request.set(slot.info.val.client_request_id, run_id)
    }
    self.runs.set(run_id, slot)
  }
  Ok(())
}

///|
/// Open the runtime execution core at `state_root`. Any run (exec or PTY)
/// that was left "running" by a crash is durably finalized as `lost` before
/// this call returns, so a restarted runtime never pretends a run is still
/// alive.
pub async fn RuntimeExecutor::open(
  state_root : String,
  runtime_id : String,
) -> Result[RuntimeExecutor, String] {
  RuntimeExecutor::open_with_limits(
    state_root,
    runtime_id,
    pty_limits=@pty_runtime.PtyLimits::new(),
    git_limits=@git_runtime.GitLimits::new(),
  )
}

///|
/// Open with explicit PTY and git limits. Defaults are
/// `PtyLimits::new()` (4 KiB events, 256-event / 256 KiB ring, 4 MiB
/// transcript) and `GitLimits::new()` (256 KiB / 4096 lines per stream,
/// 60 s timeout, 1 MiB op log).
pub async fn RuntimeExecutor::open_with_limits(
  state_root : String,
  runtime_id : String,
  pty_limits~ : @pty_runtime.PtyLimits,
  git_limits~ : @git_runtime.GitLimits,
) -> Result[RuntimeExecutor, String] {
  let state = match RuntimeState::open(state_root) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let (outbox, events) = match Outbox::open(state, runtime_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let pty = match
    @pty_runtime.PtyRuntime::new_with_limits(state.root(), pty_limits) {
    Ok(value) => value
    Err(error) => {
      outbox.close()
      return Err("cannot create PTY runtime: " + error.message)
    }
  }
  let executor = {
    state,
    outbox,
    runtime_id,
    mutex: @async.Mutex::Mutex(),
    runs: Map([]),
    by_request: Map([]),
    closed: Ref(false),
    pty,
    pty_limits,
    pty_slots: Map([]),
    pty_recovered: Map([]),
    pty_recovered_requests: Map([]),
    git: Ref(None),
    git_root: Ref(""),
    git_limits,
    process: ProcessRuntime::new(outbox, state.work_dir(), ProcessLimits::new()),
  }
  match executor.recover(events) {
    Ok(_) => ()
    Err(message) => {
      executor.outbox.close()
      return Err(message)
    }
  }
  match executor.recover_pty(events) {
    Ok(_) => ()
    Err(message) => {
      executor.outbox.close()
      return Err(message)
    }
  }
  match executor.process.recover(events) {
    Ok(_) => ()
    Err(message) => {
      executor.outbox.close()
      return Err(message)
    }
  }
  Ok(executor)
}

///|
pub fn RuntimeExecutor::runtime_id(self : RuntimeExecutor) -> String {
  self.runtime_id
}

///|
pub fn RuntimeExecutor::state_root(self : RuntimeExecutor) -> String {
  self.state.root()
}

///|
/// The streaming-process runtime bound to this executor's outbox and work
/// root. Node dispatch uses this for `runtime.process.*`.
pub fn RuntimeExecutor::process(self : RuntimeExecutor) -> ProcessRuntime {
  self.process
}

///|
pub fn RuntimeExecutor::status(
  self : RuntimeExecutor,
  run_id : String,
) -> RunInfo? {
  match self.runs.get(run_id) {
    Some(slot) => Some(slot.info.val)
    None => None
  }
}

///|
pub fn RuntimeExecutor::runs(self : RuntimeExecutor) -> Array[RunInfo] {
  let out : Array[RunInfo] = []
  for entry in self.runs {
    out.push(entry.1.info.val)
  }
  // Stable order by start time, then id.
  out.sort_by(fn(left : RunInfo, right : RunInfo) -> Int32 {
    if left.started_at == right.started_at {
      left.run_id.compare(right.run_id)
    } else {
      left.started_at.compare(right.started_at)
    }
  })
  out
}

///|
pub fn RuntimeExecutor::cursor(self : RuntimeExecutor) -> Int64 {
  self.outbox.cursor()
}

///|
pub async fn RuntimeExecutor::pending_events(
  self : RuntimeExecutor,
  limit : Int32,
) -> Result[Array[StoredEvent], String] {
  self.outbox.pending(limit)
}

///|
/// Advance the publish cursor. Ack events are durable and monotonic; a
/// restart resumes from the last acked global seq, so acknowledged events are
/// not re-delivered.
pub async fn RuntimeExecutor::ack_through(
  self : RuntimeExecutor,
  cursor : Int64,
) -> Result[Unit, String] {
  self.outbox.ack(cursor)
}

///|
/// Resolve a bare program name against the *host* PATH (the child gets only
/// the explicit env allowlist). Absolute paths are accepted; relative paths
/// containing a separator are rejected so a spec cannot silently depend on
/// the executor's own cwd.
async fn resolve_program(program : String) -> Result[String, String] {
  if program.contains("/") {
    if !program.has_prefix("/") {
      return Err(
        "relative program paths are not supported; use an absolute path or a bare name",
      )
    }
    let exists = @fs.exists(program) catch { _ => false }
    if !exists {
      return Err("program does not exist: " + program)
    }
    return Ok(program)
  }
  let path_var = match @env.get_env_var("PATH") {
    Some(value) => value
    None => "/usr/local/bin:/usr/bin:/bin"
  }
  for dir in path_var.split(":") {
    let candidate = if dir == "" {
      "/" + program
    } else {
      dir.to_owned() + "/" + program
    }
    let exists = @fs.exists(candidate) catch { _ => false }
    if exists {
      let kind = @fs.kind(candidate, follow_symlink=true) catch {
        _ => @fs.FileKind::Unknown
      }
      if kind is @fs.FileKind::Regular {
        return Ok(candidate)
      }
    }
  }
  Err("program not found on PATH: " + program)
}

///|
async fn first_existing(paths : Array[String]) -> String? {
  for path in paths {
    let exists = @fs.exists(path) catch { _ => false }
    if exists {
      return Some(path)
    }
  }
  None
}

///|
let kill_path_global : Ref[String] = Ref("/bin/kill")

///|
/// Signal the whole process group led by `pid`. The child is spawned through
/// `setsid`, which execs in place for a freshly forked child, so the group id
/// equals the child pid.
async fn signal_group(signal : String, pid : Int32) -> Unit {
  let kill = kill_path_global.val
  if kill == "" {
    return
  }
  let pid_text = pid.to_string()
  let _ = @process.run(kill, ["-" + signal, "--", "-" + pid_text]) catch {
    _ => 0
  }
}

///|
/// Cancellation handler used by both external `cancel` and task-group teardown:
/// TERM the group, give it a short grace period, then KILL it. This also
/// reaps grandchildren that inherited the group.
async fn cancel_process_group(pid : Int32) -> Unit {
  signal_group("TERM", pid)
  @async.sleep(200)
  signal_group("KILL", pid)
}

///|
/// Resolve the command cwd under the runtime work root. Returns the absolute
/// real path; a cwd that resolves outside the root is rejected.
async fn resolve_cwd(work_dir : String, cwd : String) -> Result[String, String] {
  let rooted = match RootedDir::open(work_dir) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let relative = match normalize_rooted_path(cwd) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let absolute = if relative == "" {
    rooted.root
  } else {
    match RootedDir::resolve_existing(rooted, relative) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
  }
  let kind = @fs.kind(absolute, follow_symlink=true) catch {
    error => return Err("cannot stat cwd: " + error.to_string())
  }
  guard kind is Directory else { return Err("cwd is not a directory") }
  Ok(absolute)
}

///|
fn build_child_env(spec : CommandSpec) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  for pair in spec.env {
    env.set(pair.name, pair.value)
  }
  for name in spec.inherit_env {
    match @env.get_env_var(name) {
      Some(value) => env.set(name, value)
      None => ()
    }
  }
  env
}

///|
fn env_names(spec : CommandSpec) -> Array[String] {
  let names : Array[String] = []
  for pair in spec.env {
    names.push(pair.name)
  }
  for name in spec.inherit_env {
    names.push(name)
  }
  names
}

///|
fn bounded_message(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() <= 400 {
    redacted
  } else {
    redacted[:400].to_string() + "...[truncated]"
  }
}

///|
/// Idempotently start a command. The `(client_request_id, run_id)` pair is
/// decided by the primary; the same request id always returns the existing
/// run and never spawns a second process.
///
/// The process is spawned inside `group`, which must outlive the run (the
/// host's root task group in production, the test task group in tests).
/// Cancelling that group cancels the run and kills the process tree.
pub async fn RuntimeExecutor::start(
  self : RuntimeExecutor,
  group : @async.TaskGroup[Unit],
  client_request_id~ : String,
  run_id~ : String,
  spec~ : CommandSpec,
) -> Result[StartOutcome, String] {
  match validate_resource_id(client_request_id, "client_request_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  match validate_resource_id(run_id, "run_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  match validate_command_spec(spec) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  self.mutex.acquire()
  defer self.mutex.release()
  if self.closed.val {
    return Err("runtime executor is closed")
  }
  match self.by_request.get(client_request_id) {
    Some(existing) =>
      return match self.runs.get(existing) {
        Some(slot) => Ok(Existing(slot.info.val))
        None => Err("request id maps to a missing run")
      }
    None => ()
  }
  if self.runs.get(run_id) is Some(_) {
    return Err("run_id already exists for a different client_request_id")
  }
  let program = match resolve_program(spec.argv[0]) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let cwd_abs = match resolve_cwd(self.state.work_dir(), spec.cwd) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let setsid = first_existing(["/usr/bin/setsid", "/bin/setsid"])
  let kill = first_existing(["/bin/kill", "/usr/bin/kill"])
  let ps = first_existing(["/bin/ps", "/usr/bin/ps"])
  match kill {
    Some(path) => kill_path_global.val = path
    None => kill_path_global.val = ""
  }
  let (out_path, err_path) = match self.state.ensure_run_logs(run_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let started_ms = @async.now()
  let started_at = @contracts.format_rfc3339(started_ms)
  let effective_risk = spec.effective_risk()
  let entries : Array[(String, @json.Json)] = [
    ("client_request_id", @contracts.json_string(client_request_id)),
    ("argv", @contracts.json_string_array(event_argv(spec.argv))),
    (
      "cwd",
      @contracts.json_string(normalize_rooted_path(spec.cwd).unwrap_or("")),
    ),
    ("risk", @contracts.json_string(effective_risk)),
    ("timeout_ms", @contracts.json_int(spec.timeout_ms)),
    ("max_output_bytes", @contracts.json_int(spec.max_output_bytes)),
    ("env_names", @contracts.json_string_array(env_names(spec))),
    ("has_stdin", @contracts.json_bool(spec.stdin is Some(_))),
    ("started_at", @contracts.json_string(started_at)),
  ]
  match self.outbox.append(run_id, EVENT_EXEC_STARTED, entries) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let info : RunInfo = {
    run_id,
    client_request_id,
    status: @contracts.RUN_STATUS_RUNNING,
    risk: effective_risk,
    started_at,
    ended_at: None,
    exit_code: None,
    signal: None,
    stop_reason: "",
    stdout_bytes: 0L,
    stderr_bytes: 0L,
    timed_out: false,
    truncated_stdout: false,
    truncated_stderr: false,
  }
  let slot = make_run_slot(
    info,
    started_ms,
    out_path,
    err_path,
    spec.max_output_bytes,
  )
  self.runs.set(run_id, slot)
  self.by_request.set(client_request_id, run_id)
  let exec = self
  // macOS has no `setsid` binary; there the tree is walked with `ps` instead.
  let tree_cancel_available = kill is Some(_) &&
    (setsid is Some(_) || ps is Some(_))
  group.spawn_bg(allow_failure=true, async fn() {
    exec.supervise(
      slot, run_id, spec, program, cwd_abs, setsid, tree_cancel_available,
    )
  })
  // Wait until the supervisor has either spawned the process or failed, so
  // `start` never returns for a request that silently did not spawn.
  let deadline = @async.now() + SPAWN_READY_TIMEOUT_MS
  while !slot.ready.val &&
        slot.spawn_error.val is None &&
        @async.now() < deadline {
    @async.sleep(2)
  }
  if slot.spawn_error.val is Some(message) {
    let terminal_deadline = @async.now() + SPAWN_READY_TIMEOUT_MS
    while !slot.finished.val && @async.now() < terminal_deadline {
      @async.sleep(2)
    }
    return Err(message)
  }
  if !slot.ready.val {
    return Err("timed out waiting for the command to spawn")
  }
  Ok(Started(slot.info.val))
}

///|
async fn RuntimeExecutor::supervise(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  spec : CommandSpec,
  program : String,
  cwd_abs : String,
  setsid : String?,
  tree_cancel_available : Bool,
) -> Unit {
  let exit_code : Ref[Int32?] = Ref(None)
  let timed_out : Ref[Bool] = Ref(false)
  let timed_out_flag = timed_out
  let exit_ref = exit_code
  let attempt : Result[Unit, String]? = @async.handle_cancellation(async fn() {
    try {
      @async.with_task_group(async fn(inner : @async.TaskGroup[Unit]) -> Unit {
        let (out_r, out_w) = @process.read_from_process()
        let (err_r, err_w) = @process.read_from_process()
        let (stdin_input, stdin_writer) = @process.write_to_process()
        let child_env = build_child_env(spec)
        let args : Array[String] = []
        for index in 1..<spec.argv.length() {
          args.push(spec.argv[index])
        }
        let (spawn_cmd, spawn_args) = match setsid {
          Some(path) => {
            let with_program : Array[String] = [program]
            for arg in args {
              with_program.push(arg)
            }
            (path, with_program)
          }
          None => (program, args)
        }
        let cancel_handler : @process.CancellationHandler = if tree_cancel_available {
          match setsid {
            Some(_) => cancel_process_group
            None => cancel_process_tree
          }
        } else {
          @process.hard_cancel()
        }
        let proc = @process.spawn(
          inner,
          spawn_cmd,
          spawn_args,
          extra_env=child_env,
          inherit_env=false,
          stdin=stdin_input,
          stdout=out_w,
          stderr=err_w,
          cwd=cwd_abs,
          cancel_handler~,
        )
        slot.proc.val = Some(proc)
        // Output pumps start after spawn; the unique write ends are already
        // closed by the runtime, so EOF is observed when the child exits.
        let exec = self
        let _ = inner.spawn(async fn() {
          exec.pump(slot, run_id, "stdout", out_r)
        })
        let _ = inner.spawn(async fn() {
          exec.pump(slot, run_id, "stderr", err_r)
        })
        match spec.stdin {
          Some(text) => {
            let _ = inner.spawn(async fn() {
              defer stdin_writer.close()
              stdin_writer.write(text) catch {
                _ => ()
              }
            })
          }
          None => stdin_writer.close()
        }
        if slot.cancel_requested.val {
          proc.cancel()
        }
        slot.ready.val = true
        let code : Int32? = try {
          match
            @async.with_timeout_opt(spec.timeout_ms, async fn() -> Int32 {
              proc.wait()
            }) {
            Some(value) => Some(value)
            None => {
              timed_out_flag.val = true
              slot.timed_out.val = true
              proc.cancel()
              Some(
                @async.protect_from_cancel(async fn() -> Int32 { proc.wait() }),
              )
            }
          }
        } catch {
          _ => None
        }
        exit_ref.val = code
      })
      Ok(())
    } catch {
      error => Err(bounded_message(error.to_string()))
    }
  })
  let cancelled = match attempt {
    Some(Ok(_)) => false
    Some(Err(message)) => {
      slot.spawn_error.val = Some(message)
      false
    }
    None => true
  }
  let spawn_error = slot.spawn_error.val
  @async.protect_from_cancel(async fn() {
    self.finalize(
      slot,
      run_id,
      spawn_error,
      cancelled,
      exit_code.val,
      timed_out.val,
    )
  })
}

///|
/// Stream one pipe to the run log until EOF. The chunk size bounds both the
/// in-memory buffer and each event payload.
async fn RuntimeExecutor::pump(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  stream : String,
  reader : @process.ReadFromProcess,
) -> Unit {
  defer reader.close()
  while true {
    let chunk = reader.read_some(max_len=CHUNK_BYTES) catch { _ => break }
    match chunk {
      Some(bytes) => self.record_chunk(slot, run_id, stream, bytes)
      None => break
    }
  }
  self.flush_carry(slot, run_id, stream)
}

///|
/// Redact one complete line. PEM private-key bodies are dropped entirely
/// (state is kept per stream, so a key block spanning chunks is still
/// removed). Returns `None` when the line must not be logged at all.
fn redact_line(line : String, in_pem : Bool) -> (String?, Bool) {
  let lower = line.to_lower()
  if lower.contains("-----begin") && lower.contains("private key") {
    return (Some("-----BEGIN PRIVATE KEY-----[redacted]"), true)
  }
  if in_pem {
    if lower.contains("-----end") && lower.contains("private key") {
      return (Some("-----END PRIVATE KEY-----"), false)
    }
    return (None, true)
  }
  (Some(@contracts.redact_secrets(line)), false)
}

///|
/// Process decoded stdout/stderr bytes: assemble complete lines (so a secret
/// split across a pipe read is still seen as one line), redact, then append
/// to the run log with a bounded budget.
async fn RuntimeExecutor::record_chunk(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  stream : String,
  bytes : Bytes,
) -> Unit {
  let decoded = @utf8.decode_lossy(bytes[:], ignore_bom=false)
  if decoded == "" {
    return
  }
  slot.log_lock.acquire()
  defer slot.log_lock.release()
  if was_truncated(slot, stream) {
    return
  }
  let combined = carry_of(slot, stream) + decoded
  let split_at = combined.rev_find("\n")
  let mut complete = ""
  let mut rest = combined
  match split_at {
    Some(index) => {
      let cut = index.to_int() + 1
      complete = combined[:cut].to_string()
      rest = combined[cut:].to_string()
    }
    None => ()
  }
  if rest.length() > MAX_LINE_CARRY {
    // No newline for a very long stretch: flush a prefix and keep a bounded
    // tail so memory and latency stay bounded.
    let keep = 1_024
    let cut = rest.length() - keep
    complete = complete + rest[:cut].to_string() + "\n"
    rest = rest[cut:].to_string()
  }
  set_carry(slot, stream, rest)
  let logged = self.redact_buffer(slot, stream, complete)
  if logged != "" {
    self.append_stream_text(slot, run_id, stream, logged)
  }
}

///|
/// Flush the trailing partial line at EOF.
async fn RuntimeExecutor::flush_carry(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  stream : String,
) -> Unit {
  slot.log_lock.acquire()
  defer slot.log_lock.release()
  if was_truncated(slot, stream) {
    return
  }
  let carry = carry_of(slot, stream)
  if carry == "" {
    return
  }
  set_carry(slot, stream, "")
  let logged = self.redact_buffer(slot, stream, carry)
  if logged != "" {
    self.append_stream_text(slot, run_id, stream, logged)
  }
}

///|
/// Redact a multi-line buffer, mutating the per-stream PEM state.
fn RuntimeExecutor::redact_buffer(
  self : RuntimeExecutor,
  slot : RunSlot,
  stream : String,
  text : String,
) -> String {
  let mut in_pem = in_pem_of(slot, stream)
  let mut out = ""
  for raw in text.split("\n") {
    let line = raw.to_string()
    if line == "" {
      continue
    }
    let (redacted, next_pem) = redact_line(line, in_pem)
    in_pem = next_pem
    match redacted {
      Some(value) => out = out + value + "\n"
      None => ()
    }
  }
  set_in_pem(slot, stream, in_pem)
  out
}

///|
/// Append redacted text to the run's stream log, bounded by max_output_bytes.
/// Log write happens before the event append: an event never references bytes
/// that are not already durable.
async fn RuntimeExecutor::append_stream_text(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  stream : String,
  text : String,
) -> Unit {
  let offset = stream_offset(slot, stream)
  let budget = slot.max_output_bytes.to_int64() - offset
  if budget <= 0 {
    mark_truncated(slot, stream)
    self.record_truncation(slot, run_id, stream)
    return
  }
  let mut to_write = text
  let mut truncated_now = false
  if text.length().to_int64() > budget {
    to_write = text[:budget.to_int()].to_string()
    truncated_now = true
  }
  let path = stream_path(slot, stream)
  let write_ok = try {
    @fs.write_file(
      path,
      to_write,
      create_mode=@fs.CreateMode::OpenOrCreate,
      permission=0o600,
      append=true,
      sync=@fs.SyncMode::Data,
    )
    true
  } catch {
    error => {
      slot.log_error.val = Some(bounded_message(error.to_string()))
      false
    }
  }
  if !write_ok {
    mark_truncated(slot, stream)
    self.record_truncation(slot, run_id, stream)
    return
  }
  let length = to_write.length().to_int64()
  let new_offset = offset + length
  set_stream_offset(slot, stream, new_offset)
  if truncated_now {
    mark_truncated(slot, stream)
    self.record_truncation(slot, run_id, stream)
  }
  if length > 0 {
    let kind = if stream == "stdout" {
      EVENT_EXEC_STDOUT
    } else {
      EVENT_EXEC_STDERR
    }
    let preview = if to_write.length() > PREVIEW_CHARS {
      to_write[:PREVIEW_CHARS].to_string()
    } else {
      to_write
    }
    let entries : Array[(String, @json.Json)] = [
      ("stream", @contracts.json_string(stream)),
      ("offset", @contracts.json_int64(offset)),
      ("length", @contracts.json_int64(length)),
      ("preview", @contracts.json_string(preview)),
    ]
    match self.outbox.append(run_id, kind, entries) {
      Ok(_) => ()
      Err(message) => {
        slot.log_error.val = Some("outbox: " + bounded_message(message))
        mark_truncated(slot, stream)
      }
    }
  }
}

///|
async fn RuntimeExecutor::record_truncation(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  stream : String,
) -> Unit {
  let entries : Array[(String, @json.Json)] = [
    ("stream", @contracts.json_string(stream)),
    ("limit_bytes", @contracts.json_int(slot.max_output_bytes)),
  ]
  match self.outbox.append(run_id, EVENT_EXEC_TRUNCATED, entries) {
    Ok(_) => ()
    Err(message) =>
      slot.log_error.val = Some("outbox: " + bounded_message(message))
  }
}

///|
/// Finalize a run exactly once. The terminal event is appended before the
/// in-memory status is published, and success is downgraded when spawn, log
/// or outbox errors mean the run cannot be trusted.
async fn RuntimeExecutor::finalize(
  self : RuntimeExecutor,
  slot : RunSlot,
  run_id : String,
  spawn_error : String?,
  cancelled : Bool,
  exit_code : Int32?,
  timed_out : Bool,
) -> Unit {
  if slot.finished.val {
    return
  }
  let ended_ms = @async.now()
  let ended_at = @contracts.format_rfc3339(ended_ms)
  let cancel_hit = cancelled || slot.cancel_requested.val
  let mut status = @contracts.RUN_STATUS_FAILED
  let mut stop_reason = STOP_REASON_EXITED
  if cancel_hit {
    status = @contracts.RUN_STATUS_CANCELLED
    stop_reason = STOP_REASON_CANCELLED
  } else if timed_out {
    status = @contracts.RUN_STATUS_CANCELLED
    stop_reason = STOP_REASON_TIMEOUT
  } else if spawn_error is Some(_) {
    status = @contracts.RUN_STATUS_FAILED
    stop_reason = STOP_REASON_SPAWN_FAILED
  } else if slot.log_error.val is Some(_) {
    status = @contracts.RUN_STATUS_FAILED
    stop_reason = STOP_REASON_IO_ERROR
  } else {
    match exit_code {
      Some(0) => {
        status = @contracts.RUN_STATUS_SUCCEEDED
        stop_reason = STOP_REASON_EXITED
      }
      _ => {
        status = @contracts.RUN_STATUS_FAILED
        stop_reason = STOP_REASON_EXITED
      }
    }
  }
  let signal : Int32? = match exit_code {
    Some(code) => if code < 0 { Some(-code) } else { None }
    None => None
  }
  let reported_exit : Int32? = match exit_code {
    Some(code) => if code >= 0 { Some(code) } else { None }
    None => None
  }
  let stdout_bytes = slot.stdout_offset.val
  let stderr_bytes = slot.stderr_offset.val
  let entries : Array[(String, @json.Json)] = [
    ("status", @contracts.json_string(status)),
    ("stop_reason", @contracts.json_string(stop_reason)),
    ("ended_at", @contracts.json_string(ended_at)),
    (
      "exit_code",
      match reported_exit {
        Some(value) => @contracts.json_int(value)
        None => @contracts.json_null()
      },
    ),
    (
      "signal",
      match signal {
        Some(value) => @contracts.json_int(value)
        None => @contracts.json_null()
      },
    ),
    ("stdout_bytes", @contracts.json_int64(stdout_bytes)),
    ("stderr_bytes", @contracts.json_int64(stderr_bytes)),
    ("timed_out", @contracts.json_bool(timed_out)),
    ("cancelled", @contracts.json_bool(cancel_hit)),
    ("truncated_stdout", @contracts.json_bool(slot.stdout_truncated.val)),
    ("truncated_stderr", @contracts.json_bool(slot.stderr_truncated.val)),
    (
      "error",
      match spawn_error {
        Some(value) => @contracts.json_string(value)
        None =>
          match slot.log_error.val {
            Some(value) => @contracts.json_string(value)
            None => @contracts.json_null()
          }
      },
    ),
    ("duration_ms", @contracts.json_int64(ended_ms - slot.started_ms)),
  ]
  let append_ok = match self.outbox.append(run_id, EVENT_EXEC_EXITED, entries) {
    Ok(_) => true
    Err(_) => false
  }
  if !append_ok && status == @contracts.RUN_STATUS_SUCCEEDED {
    status = @contracts.RUN_STATUS_LOST
    stop_reason = STOP_REASON_OUTBOX_ERROR
  }
  slot.timed_out.val = timed_out
  let info : RunInfo = {
    run_id,
    client_request_id: slot.info.val.client_request_id,
    status,
    risk: slot.info.val.risk,
    started_at: slot.info.val.started_at,
    ended_at: Some(ended_at),
    exit_code: reported_exit,
    signal,
    stop_reason,
    stdout_bytes,
    stderr_bytes,
    timed_out,
    truncated_stdout: slot.stdout_truncated.val,
    truncated_stderr: slot.stderr_truncated.val,
  }
  slot.info.val = info
  slot.proc.val = None
  slot.finished.val = true
}

///|
async fn RuntimeExecutor::wait_finished(
  self : RuntimeExecutor,
  slot : RunSlot,
  timeout_ms : Int64,
) -> Bool {
  let deadline = @async.now() + timeout_ms
  while !slot.finished.val && @async.now() < deadline {
    @async.sleep(5)
  }
  slot.finished.val
}

///|
/// Cancel one run and wait for its terminal event. The process group is
/// signalled (TERM, grace, KILL); a run that cannot be confirmed terminated is
/// reported as `lost`, never `succeeded`.
pub async fn RuntimeExecutor::cancel(
  self : RuntimeExecutor,
  run_id : String,
) -> Result[RunInfo, String] {
  let slot = match self.runs.get(run_id) {
    Some(value) => value
    None => return Err("unknown run: " + run_id)
  }
  if slot.finished.val {
    return Ok(slot.info.val)
  }
  slot.cancel_requested.val = true
  match slot.proc.val {
    Some(proc) => proc.cancel()
    None => ()
  }
  if self.wait_finished(slot, CANCEL_WAIT_TIMEOUT_MS) {
    return Ok(slot.info.val)
  }
  // The supervisor did not finalize in time. Do not claim success; record a
  // lost run so the primary sees an unverifiable outcome.
  slot.finished.val = true
  let info : RunInfo = {
    run_id,
    client_request_id: slot.info.val.client_request_id,
    status: @contracts.RUN_STATUS_LOST,
    risk: slot.info.val.risk,
    started_at: slot.info.val.started_at,
    ended_at: Some(@contracts.format_rfc3339(@async.now())),
    exit_code: None,
    signal: None,
    stop_reason: STOP_REASON_PROCESS_MISSING,
    stdout_bytes: slot.stdout_offset.val,
    stderr_bytes: slot.stderr_offset.val,
    timed_out: slot.timed_out.val,
    truncated_stdout: slot.stdout_truncated.val,
    truncated_stderr: slot.stderr_truncated.val,
  }
  slot.info.val = info
  Err("cancelled run did not terminate in time: " + run_id)
}

///|
/// Wait for a run to reach a terminal state, bounded by `timeout_ms`.
pub async fn RuntimeExecutor::wait_for_terminal(
  self : RuntimeExecutor,
  run_id : String,
  timeout_ms : Int64,
) -> RunInfo? {
  let slot = match self.runs.get(run_id) {
    Some(value) => value
    None => return None
  }
  if self.wait_finished(slot, timeout_ms) {
    Some(slot.info.val)
  } else {
    None
  }
}

///|
/// Close the outbox and the git operation log. Active runs and PTY sessions
/// should be cancelled/closed first; the task group that owns them also
/// kills their process trees when it is cancelled. Call `pty_close_all()`
/// before cancelling that group so every PTY session gets a durable terminal
/// event; `close()` itself is synchronous and cannot terminate a PTY.
pub fn RuntimeExecutor::close(self : RuntimeExecutor) -> Unit {
  self.closed.val = true
  match self.git.val {
    Some(git) => git.close()
    None => ()
  }
  self.outbox.close()
}
