///|
/// PTY integration (A1.1b): the runtime exposes rooted PTY sessions through
/// the same durable outbox as exec.
///
/// Contract:
///
/// - The stable caller `session_id` is the outbox `run_id`, so one session's
///   events form their own `run_seq` stream starting at 0 (`opened`).
/// - Every `PtyOutputEvent` becomes `runtime.pty.output` with the primitive's
///   per-session `seq` and its `(log_offset, log_bytes)` transcript range. The
///   payload carries a bounded preview and byte counters, never the whole
///   output.
/// - If the in-memory ring evicted events before the pump published them, the
///   pump writes one `runtime.pty.gap` event that references the transcript
///   range instead of inventing output. Replay therefore always has a
///   contiguous `run_seq` and can page the transcript for the missing bytes.
/// - `runtime.pty.exited` is written exactly once per session and never says
///   `succeeded` unless the primitive reports a natural exit with code 0.
///
/// Ownership limit: the caller's long-lived `@async.TaskGroup` owns every
/// session task; there is no detached spawn. Call `pty_close_all()` before
/// cancelling that group so each session gets a durable terminal event.
const PTY_POLL_MS : Int = 10

///|
const PTY_TERMINAL_WAIT_MS : Int64 = 5_000

///|
const PTY_SETTLE_WAIT_MS : Int64 = 5_000

///|
const PTY_GAP_PREVIEW_BYTES : Int32 = 512

///|
const PTY_PUMP_MAX_EVENTS : Int32 = 256

///|
const PTY_PUMP_MAX_BYTES : Int32 = 65_536

///|
/// Immutable snapshot of one PTY session, returned by every transport-facing
/// call. `output_seq`/`output_dropped` mirror the primitive's ring; the
/// durable outbox stream is `pending_events`.
pub(all) struct PtySessionInfo {
  session_id : String
  client_request_id : String
  created : Bool
  status : String
  finalized : Bool
  success : Bool
  cancelled : Bool
  timed_out : Bool
  running : Bool
  pid : Int
  pgid : Int
  rows : Int
  cols : Int
  output_seq : Int64
  output_dropped : Bool
  log_bytes : Int64
  log_truncated : Bool
  residual_pids : Array[Int]
  failure : String
  started_at : String
}

///|
fn pty_int_or_null(value : Int) -> @json.Json {
  if value < 0 {
    @json.Json::null()
  } else {
    @contracts.json_int(value)
  }
}

///|
fn pty_signal_or_null(value : Int) -> @json.Json {
  if value <= 0 {
    @json.Json::null()
  } else {
    @contracts.json_int(value)
  }
}

///|
fn pty_residual_json(pids : Array[Int]) -> @json.Json {
  let items : Array[@json.Json] = []
  for pid in pids {
    items.push(@contracts.json_int(pid))
  }
  @contracts.json_array(items)
}

///|
pub fn PtySessionInfo::to_json(self : PtySessionInfo) -> @json.Json {
  @contracts.json_object([
    ("session_id", @contracts.json_string(self.session_id)),
    ("client_request_id", @contracts.json_string(self.client_request_id)),
    ("created", @contracts.json_bool(self.created)),
    ("status", @contracts.json_string(self.status)),
    ("finalized", @contracts.json_bool(self.finalized)),
    ("success", @contracts.json_bool(self.success)),
    ("cancelled", @contracts.json_bool(self.cancelled)),
    ("timed_out", @contracts.json_bool(self.timed_out)),
    ("running", @contracts.json_bool(self.running)),
    ("pid", @contracts.json_int(self.pid)),
    ("pgid", @contracts.json_int(self.pgid)),
    ("rows", @contracts.json_int(self.rows)),
    ("cols", @contracts.json_int(self.cols)),
    ("output_seq", @contracts.json_int64(self.output_seq)),
    ("output_dropped", @contracts.json_bool(self.output_dropped)),
    ("log_bytes", @contracts.json_int64(self.log_bytes)),
    ("log_truncated", @contracts.json_bool(self.log_truncated)),
    ("residual_pids", pty_residual_json(self.residual_pids)),
    ("failure", @contracts.json_string(self.failure)),
    ("started_at", @contracts.json_string(self.started_at)),
  ])
}

///|
/// Result of an idempotent `pty_open`. `Existing` means the session was
/// already known (live or recovered from a previous instance): no second
/// process was spawned.
pub(all) enum PtyOpenOutcome {
  Opened(PtySessionInfo)
  Existing(PtySessionInfo)
}

///|
pub fn PtyOpenOutcome::info(self : PtyOpenOutcome) -> PtySessionInfo {
  match self {
    Opened(info) => info
    Existing(info) => info
  }
}

///|
pub fn PtyOpenOutcome::is_new(self : PtyOpenOutcome) -> Bool {
  match self {
    Opened(_) => true
    Existing(_) => false
  }
}

///|
/// Per-session outbox bookkeeping. The pump is the only writer of output/gap
/// events; `publish_lock` also orders the terminal write against the pump so
/// exactly one `runtime.pty.exited` is durable and no output is appended
/// after it.
struct PtySlot {
  session_id : String
  client_request_id : String
  started_ms : Int64
  started_at : String
  publish_lock : @async.Mutex
  terminal_written : Ref[Bool]
  last_seq : Ref[Int64]
  last_log_end : Ref[Int64]
}

///|
fn make_pty_slot(
  request : @pty_runtime.PtyOpenRequest,
  started_ms : Int64,
  started_at : String,
) -> PtySlot {
  {
    session_id: request.session_id,
    client_request_id: request.client_request_id,
    started_ms,
    started_at,
    publish_lock: @async.Mutex::Mutex(),
    terminal_written: Ref(false),
    last_seq: Ref(0L),
    last_log_end: Ref(0L),
  }
}

///|
/// Recovered session state rebuilt from the durable outbox. `mut` fields are
/// updated while replaying, then frozen for the lifetime of this executor.
struct PtyRecovered {
  session_id : String
  client_request_id : String
  started_at : String
  mut terminal : Bool
  mut status : String
  mut stop_reason : String
  mut success : Bool
  mut cancelled : Bool
  mut timed_out : Bool
  mut exit_code : Int
  mut signal : Int
  mut output_seq : Int64
  mut output_dropped : Bool
  mut log_bytes : Int64
  mut log_truncated : Bool
  log_rel : String
  rows : Int
  cols : Int
  mut failure : String
}

///|
fn PtyRecovered::info(self : PtyRecovered) -> PtySessionInfo {
  let status = if self.status == "" {
    @contracts.RUN_STATUS_LOST
  } else {
    self.status
  }
  {
    session_id: self.session_id,
    client_request_id: self.client_request_id,
    created: false,
    status,
    finalized: true,
    success: self.success,
    cancelled: self.cancelled,
    timed_out: self.timed_out,
    running: false,
    pid: 0,
    pgid: 0,
    rows: self.rows,
    cols: self.cols,
    output_seq: self.output_seq,
    output_dropped: self.output_dropped,
    log_bytes: self.log_bytes,
    log_truncated: self.log_truncated,
    residual_pids: [],
    failure: self.failure,
    started_at: self.started_at,
  }
}

///|
fn pty_map_error(error : @pty_runtime.PtyError) -> RuntimeError {
  let message = bounded_runtime_message(error.message)
  match error.kind {
    @pty_runtime.PtyErrorKind::InvalidArgument =>
      runtime_invalid("invalid_argument", message)
    @pty_runtime.PtyErrorKind::NotFound => runtime_invalid("not_found", message)
    @pty_runtime.PtyErrorKind::Conflict => runtime_host("conflict", message)
    @pty_runtime.PtyErrorKind::AlreadyClosed =>
      runtime_host("already_closed", message)
    @pty_runtime.PtyErrorKind::SpawnFailed =>
      runtime_internal("spawn_failed", message)
    @pty_runtime.PtyErrorKind::Io => runtime_internal("io", message)
    @pty_runtime.PtyErrorKind::Timeout => runtime_host("timeout", message)
    @pty_runtime.PtyErrorKind::StateDir =>
      runtime_internal("state_dir", message)
    @pty_runtime.PtyErrorKind::Internal => runtime_internal("internal", message)
  }
}

///|
/// Map a finalized primitive status to `(status, stop_reason)`. A running or
/// otherwise unverifiable session is always `lost`; success requires the
/// primitive's `success` flag and is never inferred from a missing failure.
fn pty_terminal_status(status : @pty_runtime.PtyStatus) -> (String, String) {
  if !status.finalized {
    (@contracts.RUN_STATUS_LOST, STOP_REASON_PROCESS_MISSING)
  } else if status.cancelled {
    (@contracts.RUN_STATUS_CANCELLED, STOP_REASON_CANCELLED)
  } else if status.timed_out {
    (@contracts.RUN_STATUS_CANCELLED, STOP_REASON_TIMEOUT)
  } else if status.success {
    (@contracts.RUN_STATUS_SUCCEEDED, STOP_REASON_EXITED)
  } else if status.failure.contains("spawn") ||
    status.failure.contains("start") {
    (@contracts.RUN_STATUS_FAILED, STOP_REASON_SPAWN_FAILED)
  } else if status.failure != "" {
    (@contracts.RUN_STATUS_FAILED, STOP_REASON_IO_ERROR)
  } else {
    (@contracts.RUN_STATUS_FAILED, STOP_REASON_EXITED)
  }
}

///|
fn pty_status_text(status : @pty_runtime.PtyStatus) -> String {
  if !status.finalized {
    @contracts.RUN_STATUS_RUNNING
  } else {
    let (text, _) = pty_terminal_status(status)
    text
  }
}

///|
fn pty_info_from_status(
  status : @pty_runtime.PtyStatus,
  client_request_id : String,
  created : Bool,
  started_at : String,
) -> PtySessionInfo {
  {
    session_id: status.session_id,
    client_request_id,
    created,
    status: pty_status_text(status),
    finalized: status.finalized,
    success: status.success,
    cancelled: status.cancelled,
    timed_out: status.timed_out,
    running: status.running,
    pid: status.pid,
    pgid: status.pgid,
    rows: status.rows.to_int(),
    cols: status.cols.to_int(),
    output_seq: status.output_seq,
    output_dropped: status.output_dropped,
    log_bytes: status.log_bytes,
    log_truncated: status.log_truncated,
    residual_pids: status.residual_pids,
    failure: bounded_runtime_message(status.failure),
    started_at,
  }
}

///|
fn pty_started_at_of(slot : PtySlot?) -> String {
  match slot {
    Some(value) => value.started_at
    None => ""
  }
}

///|
/// Reject a cwd that is lexically or really inside a `.ssh` component. The
/// PTY primitive applies the same rule; this is the early, workspace-root
/// aware check.
fn pty_path_has_ssh(path : String) -> Bool {
  for part in path.split("/") {
    if part == ".ssh" {
      return true
    }
  }
  false
}

///|
/// Resolve the PTY cwd under a workspace root. The default root is the
/// runtime work root. Absolute paths must already be inside the real root;
/// relative paths are resolved with `realpath` and rejected on escape,
/// symlink or a `.ssh` component.
async fn RuntimeExecutor::resolve_pty_cwd(
  self : RuntimeExecutor,
  cwd : String,
  workspace_root : String,
) -> Result[(String, String), RuntimeError] {
  let root_input = workspace_root.trim().to_owned()
  let root_base = if root_input == "" {
    self.state.work_dir()
  } else {
    root_input
  }
  let rooted = match RootedDir::open(root_base) {
    Ok(value) => value
    Err(message) => return Err(runtime_invalid("path_denied", message))
  }
  let root = rooted.root
  if pty_path_has_ssh(root) {
    return Err(
      runtime_invalid("path_denied", "workspace root must not be inside .ssh"),
    )
  }
  let requested = cwd.trim().to_owned()
  let relative = if requested == "" {
    ""
  } else if requested.has_prefix("/") {
    if requested == root {
      ""
    } else if requested.has_prefix(root + "/") {
      match normalize_rooted_path(requested.substring(start=root.length() + 1)) {
        Ok(value) => value
        Err(message) => return Err(runtime_invalid("path_denied", message))
      }
    } else {
      // Allow a spelling through a symlink only if it resolves back under the
      // real root; anything else is an absolute escape.
      let real = @fs.realpath(requested) catch {
        _ =>
          return Err(
            runtime_invalid("path_denied", "cwd is outside the workspace root"),
          )
      }
      if real == root {
        ""
      } else if real.has_prefix(root + "/") {
        match normalize_rooted_path(real.substring(start=root.length() + 1)) {
          Ok(value) => value
          Err(message) => return Err(runtime_invalid("path_denied", message))
        }
      } else {
        return Err(
          runtime_invalid("path_denied", "cwd is outside the workspace root"),
        )
      }
    }
  } else {
    match normalize_rooted_path(requested) {
      Ok(value) => value
      Err(message) => return Err(runtime_invalid("path_denied", message))
    }
  }
  if relative == "" {
    return Ok((root, ""))
  }
  let absolute = match RootedDir::resolve_existing(rooted, relative) {
    Ok(value) => value
    Err(message) => return Err(runtime_invalid("path_denied", message))
  }
  let kind = @fs.kind(absolute, follow_symlink=true) catch {
    _ => return Err(runtime_invalid("invalid_argument", "cwd does not exist"))
  }
  if !(kind is @fs.FileKind::Directory) {
    return Err(runtime_invalid("invalid_argument", "cwd is not a directory"))
  }
  if pty_path_has_ssh(absolute) {
    return Err(runtime_invalid("path_denied", "cwd must not be inside .ssh"))
  }
  Ok((absolute, relative))
}

///|
fn pty_opened_entries(
  request : @pty_runtime.PtyOpenRequest,
  relative_cwd : String,
  log_rel : String,
  started_at : String,
) -> Array[(String, @json.Json)] {
  let names : Array[String] = []
  for pair in request.env {
    names.push(pair.0)
  }
  [
    ("client_request_id", @contracts.json_string(request.client_request_id)),
    ("argv", @contracts.json_string_array(event_argv(request.argv))),
    ("cwd", @contracts.json_string(relative_cwd)),
    ("rows", @contracts.json_int(request.rows.to_int())),
    ("cols", @contracts.json_int(request.cols.to_int())),
    ("env_names", @contracts.json_string_array(names)),
    ("log_rel", @contracts.json_string(log_rel)),
    ("started_at", @contracts.json_string(started_at)),
  ]
}

///|
fn pty_terminal_entries(
  slot : PtySlot,
  status : @pty_runtime.PtyStatus,
  ended_ms : Int64,
) -> Array[(String, @json.Json)] {
  let (status_text, stop_reason) = pty_terminal_status(status)
  let duration_ms = if ended_ms > slot.started_ms {
    ended_ms - slot.started_ms
  } else {
    0L
  }
  [
    ("session_id", @contracts.json_string(status.session_id)),
    ("status", @contracts.json_string(status_text)),
    ("stop_reason", @contracts.json_string(stop_reason)),
    ("success", @contracts.json_bool(status.success)),
    ("cancelled", @contracts.json_bool(status.cancelled)),
    ("timed_out", @contracts.json_bool(status.timed_out)),
    ("exit_code", pty_int_or_null(status.exit_code)),
    ("signal", pty_signal_or_null(status.signal)),
    ("output_seq", @contracts.json_int64(status.output_seq)),
    ("output_dropped", @contracts.json_bool(status.output_dropped)),
    ("log_bytes", @contracts.json_int64(status.log_bytes)),
    ("log_truncated", @contracts.json_bool(status.log_truncated)),
    ("residual_pids", pty_residual_json(status.residual_pids)),
    ("failure", @contracts.json_string(bounded_runtime_message(status.failure))),
    ("ended_at", @contracts.json_string(@contracts.format_rfc3339(ended_ms))),
    ("duration_ms", @contracts.json_int64(duration_ms)),
    ("recovered", @contracts.json_bool(false)),
  ]
}

///|
fn pty_recovered_terminal_entries(
  record : PtyRecovered,
  ended_ms : Int64,
) -> Array[(String, @json.Json)] {
  [
    ("session_id", @contracts.json_string(record.session_id)),
    ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
    ("stop_reason", @contracts.json_string(STOP_REASON_HOST_RESTARTED)),
    ("success", @contracts.json_bool(false)),
    ("cancelled", @contracts.json_bool(false)),
    ("timed_out", @contracts.json_bool(false)),
    ("exit_code", @json.Json::null()),
    ("signal", @json.Json::null()),
    ("output_seq", @contracts.json_int64(record.output_seq)),
    ("output_dropped", @contracts.json_bool(record.output_dropped)),
    ("log_bytes", @contracts.json_int64(record.log_bytes)),
    ("log_truncated", @contracts.json_bool(record.log_truncated)),
    ("residual_pids", pty_residual_json([])),
    ("failure", @contracts.json_string("")),
    ("ended_at", @contracts.json_string(@contracts.format_rfc3339(ended_ms))),
    ("duration_ms", @contracts.json_int64(0L)),
    ("recovered", @contracts.json_bool(true)),
  ]
}

///|
/// Build a recovered record from a `runtime.pty.opened` payload.
fn pty_recovered_from_opened(event : StoredEvent) -> PtyRecovered {
  let object = @contracts.as_object(event.payload)
  let request_id = match object {
    Some(value) => @contracts.string_field_or(value, "client_request_id", "")
    None => ""
  }
  let started_at = match object {
    Some(value) => @contracts.string_field_or(value, "started_at", event.ts)
    None => event.ts
  }
  let log_rel = match object {
    Some(value) => @contracts.string_field_or(value, "log_rel", "")
    None => ""
  }
  let rows = match object {
    Some(value) => @contracts.int_field_or(value, "rows", 24)
    None => 24
  }
  let cols = match object {
    Some(value) => @contracts.int_field_or(value, "cols", 80)
    None => 80
  }
  {
    session_id: event.run_id,
    client_request_id: request_id,
    started_at,
    terminal: false,
    status: "",
    stop_reason: "",
    success: false,
    cancelled: false,
    timed_out: false,
    exit_code: -1,
    signal: 0,
    output_seq: 0L,
    output_dropped: false,
    log_bytes: 0L,
    log_truncated: false,
    log_rel,
    rows,
    cols,
    failure: "",
  }
}

///|
fn pty_recovered_apply_terminal(record : PtyRecovered, event : StoredEvent) -> Unit {
  let object = @contracts.as_object(event.payload)
  let payload = match object {
    Some(value) => value
    None => return
  }
  record.terminal = true
  record.status = @contracts.string_field_or(
    payload,
    "status",
    @contracts.RUN_STATUS_LOST,
  )
  record.stop_reason = @contracts.string_field_or(payload, "stop_reason", "")
  record.success = @contracts.bool_field_or(payload, "success", false)
  record.cancelled = @contracts.bool_field_or(payload, "cancelled", false)
  record.timed_out = @contracts.bool_field_or(payload, "timed_out", false)
  record.exit_code = @contracts.int_field_or(payload, "exit_code", -1)
  record.signal = @contracts.int_field_or(payload, "signal", 0)
  record.output_seq = @contracts.int64_field_or(
    payload,
    "output_seq",
    record.output_seq,
  )
  record.output_dropped = @contracts.bool_field_or(
    payload,
    "output_dropped",
    record.output_dropped,
  )
  record.log_bytes = @contracts.int64_field_or(
    payload,
    "log_bytes",
    record.log_bytes,
  )
  record.log_truncated = @contracts.bool_field_or(
    payload,
    "log_truncated",
    record.log_truncated,
  )
  record.failure = @contracts.string_field_or(payload, "failure", record.failure)
}

///|
/// Replay PTY events and finalize every session that was left open by the
/// previous runtime instance. Exactly one `runtime.pty.exited` is appended per
/// such session, and a later reopen returns the recovered `Existing` state
/// instead of spawning a second process.
async fn RuntimeExecutor::recover_pty(
  self : RuntimeExecutor,
  events : Array[StoredEvent],
) -> Result[Unit, String] {
  let records : Map[String, PtyRecovered] = Map([])
  let order : Array[String] = []
  for event in events {
    if event.run_id == "" {
      continue
    }
    if event.kind == EVENT_PTY_OPENED {
      if records.get(event.run_id) is None {
        records.set(event.run_id, pty_recovered_from_opened(event))
        order.push(event.run_id)
      }
    } else if event.kind == EVENT_PTY_EXITED {
      match records.get(event.run_id) {
        Some(record) => pty_recovered_apply_terminal(record, event)
        None => ()
      }
    }
  }
  for session_id in order {
    let record = match records.get(session_id) {
      Some(value) => value
      None => continue
    }
    if !record.terminal {
      let entries = pty_recovered_terminal_entries(record, @async.now())
      match self.outbox.append(session_id, EVENT_PTY_EXITED, entries) {
        Ok(_) => ()
        Err(message) =>
          return Err("cannot record recovered PTY session: " + message)
      }
      record.terminal = true
      record.status = @contracts.RUN_STATUS_LOST
      record.stop_reason = STOP_REASON_HOST_RESTARTED
      record.success = false
      record.cancelled = false
      record.timed_out = false
    }
    self.pty_recovered.set(session_id, record)
    if record.client_request_id != "" {
      self.pty_recovered_requests.set(record.client_request_id, session_id)
    }
  }
  Ok(())
}

///|
fn RuntimeExecutor::state_relative(self : RuntimeExecutor, path : String) -> String {
  let root = self.state.root()
  if path == root {
    ""
  } else if path.has_prefix(root + "/") {
    path.substring(start=root.length() + 1)
  } else {
    ""
  }
}

///|
/// Publish one bounded output event. Returns an error only for a durable
/// outbox failure; the pump stops publishing in that case and the terminal
/// writer records the session state.
async fn RuntimeExecutor::pty_publish_output(
  self : RuntimeExecutor,
  slot : PtySlot,
  event : @pty_runtime.PtyOutputEvent,
) -> Result[Unit, String] {
  slot.publish_lock.acquire()
  defer slot.publish_lock.release()
  if slot.terminal_written.val {
    return Ok(())
  }
  let preview = if event.data.length() > PREVIEW_CHARS.to_int() {
    event.data[:PREVIEW_CHARS.to_int()].to_string()
  } else {
    event.data
  }
  let entries : Array[(String, @json.Json)] = [
    ("session_id", @contracts.json_string(slot.session_id)),
    ("pty_seq", @contracts.json_int64(event.seq)),
    ("data", @contracts.json_string(preview)),
    ("raw_bytes", @contracts.json_int64(event.raw_bytes)),
    ("log_offset", @contracts.json_int64(event.log_offset)),
    ("log_bytes", @contracts.json_int64(event.log_bytes)),
    ("log_truncated", @contracts.json_bool(event.log_truncated)),
  ]
  match self.outbox.append(slot.session_id, EVENT_PTY_OUTPUT, entries) {
    Ok(_) => {
      slot.last_seq.val = event.seq
      slot.last_log_end.val = event.log_offset + event.log_bytes
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// Publish a transcript catch-up event for an evicted sequence range.
async fn RuntimeExecutor::pty_publish_gap(
  self : RuntimeExecutor,
  slot : PtySlot,
  from_seq : Int64,
  to_seq : Int64,
  from_offset : Int64,
  to_offset : Int64,
) -> Result[Unit, String] {
  if to_seq < from_seq {
    return Ok(())
  }
  let mut end_offset = to_offset
  if end_offset < from_offset {
    end_offset = from_offset
  }
  let mut preview = ""
  if end_offset > from_offset {
    match
      self.pty.read_log(
        slot.session_id,
        offset=from_offset,
        max_bytes=PTY_GAP_PREVIEW_BYTES.to_int(),
      ) {
      Ok(slice) => preview = slice.data
      Err(_) => ()
    }
  }
  slot.publish_lock.acquire()
  defer slot.publish_lock.release()
  if slot.terminal_written.val {
    return Ok(())
  }
  let entries : Array[(String, @json.Json)] = [
    ("session_id", @contracts.json_string(slot.session_id)),
    ("from_seq", @contracts.json_int64(from_seq)),
    ("to_seq", @contracts.json_int64(to_seq)),
    ("log_offset", @contracts.json_int64(from_offset)),
    ("log_bytes", @contracts.json_int64(end_offset - from_offset)),
    ("preview", @contracts.json_string(preview)),
  ]
  match self.outbox.append(slot.session_id, EVENT_PTY_GAP, entries) {
    Ok(_) => {
      if to_seq > slot.last_seq.val {
        slot.last_seq.val = to_seq
      }
      if end_offset > slot.last_log_end.val {
        slot.last_log_end.val = end_offset
      }
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// Publish the one terminal event for a session. Idempotent: after the first
/// successful append every later call is a no-op.
async fn RuntimeExecutor::pty_publish_terminal(
  self : RuntimeExecutor,
  slot : PtySlot,
  status : @pty_runtime.PtyStatus,
) -> Result[Unit, RuntimeError] {
  slot.publish_lock.acquire()
  defer slot.publish_lock.release()
  if slot.terminal_written.val {
    return Ok(())
  }
  let entries = pty_terminal_entries(slot, status, @async.now())
  match self.outbox.append(slot.session_id, EVENT_PTY_EXITED, entries) {
    Ok(_) => {
      slot.terminal_written.val = true
      Ok(())
    }
    Err(message) =>
      Err(
        runtime_internal(
          "outbox_error",
          "cannot append the PTY terminal event: " + message,
        ),
      )
  }
}

///|
/// Drain one page from the ring. A sequence gap means the ring evicted events
/// the pump had not published; one gap event covers the transcript range.
async fn RuntimeExecutor::pty_drain_page(
  self : RuntimeExecutor,
  slot : PtySlot,
  page : @pty_runtime.PtyEventPage,
) -> Result[Unit, String] {
  if page.events.is_empty() {
    return Ok(())
  }
  let first = page.events[0]
  if first.seq > slot.last_seq.val + 1L {
    match
      self.pty_publish_gap(
        slot,
        slot.last_seq.val + 1L,
        first.seq - 1L,
        slot.last_log_end.val,
        first.log_offset,
      ) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  for event in page.events {
    if slot.terminal_written.val {
      return Ok(())
    }
    match self.pty_publish_output(slot, event) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  Ok(())
}

///|
/// The session pump: publish output in order until the session finalizes,
/// then write exactly one terminal event.
async fn RuntimeExecutor::pty_pump_loop(
  self : RuntimeExecutor,
  slot : PtySlot,
) -> Result[Unit, String] {
  while true {
    if slot.terminal_written.val {
      return Ok(())
    }
    let page = match
      self.pty.events(
        slot.session_id,
        after_seq=slot.last_seq.val,
        max_events=PTY_PUMP_MAX_EVENTS.to_int(),
        max_bytes=PTY_PUMP_MAX_BYTES.to_int(),
      ) {
      Ok(value) => value
      Err(error) => return Err(bounded_runtime_message(error.message))
    }
    if !page.events.is_empty() {
      match self.pty_drain_page(slot, page) {
        Ok(_) => ()
        Err(message) => return Err(message)
      }
      continue
    }
    let status = match self.pty.status(slot.session_id) {
      Ok(value) => value
      Err(error) => return Err(bounded_runtime_message(error.message))
    }
    if status.finalized {
      // A final re-check catches output that landed between the two reads.
      if status.output_seq > slot.last_seq.val {
        let page2 = match
          self.pty.events(
            slot.session_id,
            after_seq=slot.last_seq.val,
            max_events=PTY_PUMP_MAX_EVENTS.to_int(),
            max_bytes=PTY_PUMP_MAX_BYTES.to_int(),
          ) {
          Ok(value) => value
          Err(error) => return Err(bounded_runtime_message(error.message))
        }
        if !page2.events.is_empty() {
          match self.pty_drain_page(slot, page2) {
            Ok(_) => ()
            Err(message) => return Err(message)
          }
          continue
        }
        match
          self.pty_publish_gap(
            slot,
            slot.last_seq.val + 1L,
            status.output_seq,
            slot.last_log_end.val,
            status.log_bytes,
          ) {
          Ok(_) => ()
          Err(message) => return Err(message)
        }
      }
      match self.pty_publish_terminal(slot, status) {
        Ok(_) => ()
        Err(_) => ()
      }
      return Ok(())
    }
    if status.output_seq > slot.last_seq.val {
      let page2 = match
        self.pty.events(
          slot.session_id,
          after_seq=slot.last_seq.val,
          max_events=PTY_PUMP_MAX_EVENTS.to_int(),
          max_bytes=PTY_PUMP_MAX_BYTES.to_int(),
        ) {
        Ok(value) => value
        Err(error) => return Err(bounded_runtime_message(error.message))
      }
      if !page2.events.is_empty() {
        match self.pty_drain_page(slot, page2) {
          Ok(_) => ()
          Err(message) => return Err(message)
        }
      } else {
        match
          self.pty_publish_gap(
            slot,
            slot.last_seq.val + 1L,
            status.output_seq,
            slot.last_log_end.val,
            status.log_bytes,
          ) {
          Ok(_) => ()
          Err(message) => return Err(message)
        }
      }
      continue
    }
    @async.sleep(PTY_POLL_MS)
  }
  Ok(())
}

///|
/// Pump wrapper. On cancellation (task-group teardown) it settles with a
/// bounded, cancellation-protected final drain so a terminal event is still
/// written when possible.
async fn RuntimeExecutor::pty_pump(self : RuntimeExecutor, slot : PtySlot) -> Unit {
  let attempt : Result[Unit, String]? = @async.handle_cancellation(async fn() {
    try {
      self.pty_pump_loop(slot)
    } catch {
      error => Err(bounded_runtime_message(error.to_string()))
    }
  })
  match attempt {
    Some(_) => ()
    None =>
      @async.protect_from_cancel(async fn() {
        self.pty_settle(slot)
      })
  }
}

///|
/// Bounded final drain used when the owning group is cancelled. It waits for
/// the primitive to finalize (its own cancellation handler terminates the
/// process group), drains the ring once and publishes a terminal event. If the
/// session never finalizes it is recorded as `lost`, never as success.
async fn RuntimeExecutor::pty_settle(self : RuntimeExecutor, slot : PtySlot) -> Unit {
  let deadline = @async.now() + PTY_SETTLE_WAIT_MS
  let mut status : @pty_runtime.PtyStatus? = None
  while @async.now() < deadline {
    let current = match self.pty.status(slot.session_id) {
      Ok(value) => Some(value)
      Err(_) => None
    }
    match current {
      Some(value) => {
        status = Some(value)
        if value.finalized {
          break
        }
      }
      None => break
    }
    @async.sleep(PTY_POLL_MS)
  }
  let page = match
    self.pty.events(
      slot.session_id,
      after_seq=slot.last_seq.val,
      max_events=PTY_PUMP_MAX_EVENTS.to_int(),
      max_bytes=PTY_PUMP_MAX_BYTES.to_int(),
    ) {
    Ok(value) => Some(value)
    Err(_) => None
  }
  match page {
    Some(value) => {
      let _ = self.pty_drain_page(slot, value)
    }
    None => ()
  }
  match status {
    Some(value) => {
      let _ = self.pty_publish_terminal(slot, value)
    }
    None => ()
  }
}

///|
/// Wait until the pump has published the terminal event, then publish it
/// ourselves if the pump cannot. This keeps close/wait from returning before
/// the terminal event is durable.
async fn RuntimeExecutor::pty_ensure_terminal(
  self : RuntimeExecutor,
  slot : PtySlot,
  status : @pty_runtime.PtyStatus,
) -> Result[Unit, RuntimeError] {
  if !status.finalized || slot.terminal_written.val {
    return Ok(())
  }
  let deadline = @async.now() + PTY_TERMINAL_WAIT_MS
  while !slot.terminal_written.val && @async.now() < deadline {
    @async.sleep(5)
  }
  if slot.terminal_written.val {
    return Ok(())
  }
  self.pty_publish_terminal(slot, status)
}

///|
fn RuntimeExecutor::require_open(self : RuntimeExecutor) -> Result[Unit, RuntimeError] {
  if self.closed.val {
    Err(runtime_internal("internal", "runtime executor is closed"))
  } else {
    Ok(())
  }
}

///|
/// Idempotently open a PTY session.
///
/// - `session_id` is stable; the same session and body returns `Existing`
///   without spawning a second process.
/// - A different body or `client_request_id` for the same session is a
///   stable `conflict`.
/// - After a restart, a session recorded in the outbox is returned as
///   `Existing` (finalized `lost`) and never respawned; use a new
///   `session_id` for a new process.
/// - `cwd` is resolved under `workspace_root` (default: the runtime work
///   root); `..`, absolute escapes and symlink escapes are rejected.
/// - The session task is spawned into the caller's long-lived `group`.
pub async fn[X] RuntimeExecutor::pty_open(
  self : RuntimeExecutor,
  group : @async.TaskGroup[X],
  session_id~ : String,
  client_request_id~ : String = "",
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Array[(String, String)] = [],
  rows~ : Int32 = 24,
  cols~ : Int32 = 80,
  workspace_root~ : String = "",
) -> Result[PtyOpenOutcome, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_resource_id(session_id, "session_id") {
    Ok(_) => ()
    Err(message) => return Err(runtime_invalid("invalid_argument", message))
  }
  if client_request_id != "" {
    match validate_resource_id(client_request_id, "client_request_id") {
      Ok(_) => ()
      Err(message) => return Err(runtime_invalid("invalid_argument", message))
    }
  }
  match self.pty_recovered.get(session_id) {
    Some(record) =>
      if record.client_request_id == client_request_id {
        return Ok(PtyOpenOutcome::Existing(record.info()))
      } else {
        return Err(
          runtime_host(
            "conflict",
            "session_id is bound to a different open request from a previous runtime instance",
          ),
        )
      }
    None => ()
  }
  if client_request_id != "" {
    match self.pty_recovered_requests.get(client_request_id) {
      Some(other) =>
        if other != session_id {
          return Err(
            runtime_host(
              "conflict",
              "client_request_id is bound to another recovered session",
            ),
          )
        }
      None => ()
    }
  }
  let (cwd_abs, cwd_rel) = match
    self.resolve_pty_cwd(cwd, workspace_root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let request = @pty_runtime.PtyOpenRequest::new(
    session_id~,
    argv~,
    cwd=cwd_abs,
    env~,
    rows~,
    cols~,
    client_request_id~,
  )
  let handle = match self.pty.open(group, request) {
    Ok(value) => value
    Err(error) => return Err(pty_map_error(error))
  }
  let status = match self.pty.status(session_id) {
    Ok(value) => value
    Err(error) => return Err(pty_map_error(error))
  }
  if !handle.created {
    let slot = self.pty_slots.get(session_id)
    return Ok(
      PtyOpenOutcome::Existing(
        pty_info_from_status(
          status,
          client_request_id,
          false,
          pty_started_at_of(slot),
        ),
      ),
    )
  }
  let started_ms = @async.now()
  let started_at = @contracts.format_rfc3339(started_ms)
  let slot = make_pty_slot(request, started_ms, started_at)
  self.pty_slots.set(session_id, slot)
  let log_rel = self.state_relative(handle.log_path)
  let entries = pty_opened_entries(request, cwd_rel, log_rel, started_at)
  match self.outbox.append(session_id, EVENT_PTY_OPENED, entries) {
    Ok(_) => ()
    Err(message) => {
      let _ = self.pty.close(session_id)
      self.pty_slots.remove(session_id)
      return Err(
        runtime_internal(
          "outbox_error",
          "cannot append the PTY open event: " + message,
        ),
      )
    }
  }
  let exec = self
  let slot_ref = slot
  group.spawn_bg(allow_failure=true, async fn() {
    exec.pty_pump(slot_ref)
  })
  Ok(
    PtyOpenOutcome::Opened(
      pty_info_from_status(status, client_request_id, true, started_at),
    ),
  )
}

///|
/// Send UTF-8 input to a live session. Input is never logged or published.
pub async fn RuntimeExecutor::pty_input(
  self : RuntimeExecutor,
  session_id : String,
  data : String,
) -> Result[Unit, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.pty_recovered.get(session_id) is Some(_) &&
    self.pty_slots.get(session_id) is None {
    return Err(
      runtime_host(
        "already_closed",
        "session belongs to a previous runtime instance and cannot accept input",
      ),
    )
  }
  match self.pty.input(session_id, data) {
    Ok(_) => Ok(())
    Err(error) => Err(pty_map_error(error))
  }
}

///|
/// Send raw bytes to a live session.
pub async fn RuntimeExecutor::pty_input_bytes(
  self : RuntimeExecutor,
  session_id : String,
  data : Bytes,
) -> Result[Unit, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.pty_recovered.get(session_id) is Some(_) &&
    self.pty_slots.get(session_id) is None {
    return Err(
      runtime_host(
        "already_closed",
        "session belongs to a previous runtime instance and cannot accept input",
      ),
    )
  }
  match self.pty.input_bytes(session_id, data) {
    Ok(_) => Ok(())
    Err(error) => Err(pty_map_error(error))
  }
}

///|
pub async fn RuntimeExecutor::pty_resize(
  self : RuntimeExecutor,
  session_id : String,
  rows~ : Int32,
  cols~ : Int32,
) -> Result[Unit, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.pty_recovered.get(session_id) is Some(_) &&
    self.pty_slots.get(session_id) is None {
    return Err(
      runtime_host(
        "already_closed",
        "session belongs to a previous runtime instance and cannot be resized",
      ),
    )
  }
  match self.pty.resize(session_id, rows, cols) {
    Ok(_) => Ok(())
    Err(error) => Err(pty_map_error(error))
  }
}

///|
/// Terminate a live session's process group (TERM, grace, KILL) and wait for
/// the durable terminal event. A recovered session is already terminal and is
/// returned unchanged.
pub async fn RuntimeExecutor::pty_close(
  self : RuntimeExecutor,
  session_id : String,
) -> Result[PtySessionInfo, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.pty_slots.get(session_id) is None {
    match self.pty_recovered.get(session_id) {
      Some(record) => return Ok(record.info())
      None =>
        return Err(
          runtime_invalid("not_found", "unknown PTY session: " + session_id),
        )
    }
  }
  let status = match self.pty.close(session_id) {
    Ok(value) => value
    Err(error) => return Err(pty_map_error(error))
  }
  let slot = match self.pty_slots.get(session_id) {
    Some(value) => value
    None =>
      return Ok(
        pty_info_from_status(status, "", false, ""),
      )
  }
  match self.pty_ensure_terminal(slot, status) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok(
    pty_info_from_status(
      status,
      slot.client_request_id,
      false,
      slot.started_at,
    ),
  )
}

///|
/// Wait for a session to finish. A positive timeout terminates the process
/// group; the result is then `cancelled`/`timeout`, never a success.
pub async fn RuntimeExecutor::pty_wait(
  self : RuntimeExecutor,
  session_id : String,
  timeout_ms~ : Int = 0,
) -> Result[PtySessionInfo, RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.pty_slots.get(session_id) is None {
    match self.pty_recovered.get(session_id) {
      Some(record) => return Ok(record.info())
      None =>
        return Err(
          runtime_invalid("not_found", "unknown PTY session: " + session_id),
        )
    }
  }
  let status = match self.pty.wait(session_id, timeout_ms~) {
    Ok(value) => value
    Err(error) => return Err(pty_map_error(error))
  }
  let slot = match self.pty_slots.get(session_id) {
    Some(value) => value
    None => return Ok(pty_info_from_status(status, "", false, ""))
  }
  match self.pty_ensure_terminal(slot, status) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok(
    pty_info_from_status(
      status,
      slot.client_request_id,
      false,
      slot.started_at,
    ),
  )
}

///|
/// Current state of a session, live or recovered.
pub async fn RuntimeExecutor::pty_status(
  self : RuntimeExecutor,
  session_id : String,
) -> Result[PtySessionInfo, RuntimeError] {
  let live = match self.pty.status(session_id) {
    Ok(value) => Some(value)
    Err(error) => {
      match error.kind {
        @pty_runtime.PtyErrorKind::NotFound => None
        _ => return Err(pty_map_error(error))
      }
    }
  }
  match live {
    Some(status) => {
      let slot = self.pty_slots.get(session_id)
      let request_id = match slot {
        Some(value) => value.client_request_id
        None => ""
      }
      Ok(
        pty_info_from_status(
          status,
          request_id,
          false,
          pty_started_at_of(slot),
        ),
      )
    }
    None =>
      match self.pty_recovered.get(session_id) {
        Some(record) => Ok(record.info())
        None =>
          Err(
            runtime_invalid("not_found", "unknown PTY session: " + session_id),
          )
      }
  }
}

///|
/// Live ring events after `after_seq`, bounded by count and bytes. For a
/// recovered session the ring is gone; the durable outbox and transcript are
/// the replay source.
pub async fn RuntimeExecutor::pty_events(
  self : RuntimeExecutor,
  session_id : String,
  after_seq~ : Int64 = 0L,
  max_events~ : Int = 256,
  max_bytes~ : Int = 65_536,
) -> Result[@pty_runtime.PtyEventPage, RuntimeError] {
  match
    self.pty.events(
      session_id,
      after_seq~,
      max_events~,
      max_bytes~,
    ) {
    Ok(value) => Ok(value)
    Err(error) => {
      match error.kind {
        @pty_runtime.PtyErrorKind::NotFound =>
          match self.pty_recovered.get(session_id) {
            Some(record) =>
              Ok({
                session_id,
                events: [],
                next_seq: after_seq,
                earliest_seq: 0L,
                dropped: false,
                log_path: "",
                log_bytes: record.log_bytes,
                log_truncated: record.log_truncated,
              })
            None =>
              Err(
                runtime_invalid("not_found", "unknown PTY session: " + session_id),
              )
          }
        _ => Err(pty_map_error(error))
      }
    }
  }
}

///|
/// Read a bounded slice of the redacted transcript. A recovered session falls
/// back to the persisted transcript path recorded in the open event, with a
/// containment check.
pub async fn RuntimeExecutor::pty_read_log(
  self : RuntimeExecutor,
  session_id : String,
  offset~ : Int64 = 0L,
  max_bytes~ : Int = 65_536,
) -> Result[@pty_runtime.PtyLogSlice, RuntimeError] {
  match self.pty.read_log(session_id, offset~, max_bytes~) {
    Ok(value) => Ok(value)
    Err(error) => {
      match error.kind {
        @pty_runtime.PtyErrorKind::NotFound =>
          match self.pty_recovered.get(session_id) {
            Some(record) =>
              self.pty_read_recovered_log(record, offset, max_bytes)
            None =>
              Err(
                runtime_invalid("not_found", "unknown PTY session: " + session_id),
              )
          }
        _ => Err(pty_map_error(error))
      }
    }
  }
}

///|
async fn RuntimeExecutor::pty_read_recovered_log(
  self : RuntimeExecutor,
  record : PtyRecovered,
  offset : Int64,
  max_bytes : Int,
) -> Result[@pty_runtime.PtyLogSlice, RuntimeError] {
  if offset < 0L {
    return Err(runtime_invalid("invalid_argument", "offset must be non-negative"))
  }
  if record.log_rel == "" {
    return Ok({
      session_id: record.session_id,
      offset,
      data: "",
      bytes: 0L,
      eof: true,
      log_bytes: 0L,
      truncated: record.log_truncated,
    })
  }
  let root = self.state.root()
  let candidate = root + "/" + record.log_rel
  let real = @fs.realpath(candidate) catch {
    _ =>
      return Err(
        runtime_invalid("not_found", "session transcript is not available"),
      )
  }
  if !(real == root || real.has_prefix(root + "/")) {
    return Err(
      runtime_internal("state_dir", "session transcript escaped the state root"),
    )
  }
  let kind = @fs.kind(real, follow_symlink=true) catch {
    _ => return Err(runtime_invalid("not_found", "session transcript is not available"))
  }
  if !(kind is @fs.FileKind::Regular) {
    return Err(
      runtime_internal("state_dir", "session transcript is not a regular file"),
    )
  }
  let limit = max_bytes.max(1).min(1_048_576)
  let size = @fs.file_size(real) catch {
    _ => return Err(runtime_internal("io", "cannot stat the session transcript"))
  }
  if offset >= size {
    return Ok({
      session_id: record.session_id,
      offset,
      data: "",
      bytes: 0L,
      eof: true,
      log_bytes: size,
      truncated: record.log_truncated,
    })
  }
  let file = @fs.open(
    real,
    mode=@fs.Mode::ReadOnly,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    _ => return Err(runtime_internal("io", "cannot open the session transcript"))
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
      _ => return Err(runtime_internal("io", "cannot read the session transcript"))
    }
    if count <= 0 {
      break
    }
    got = got + count
  }
  let bytes = Bytes::from_fixedarray(buffer, len=got)
  Ok({
    session_id: record.session_id,
    offset,
    data: @utf8.decode_lossy(bytes[:]),
    bytes: got.to_int64(),
    eof: offset + got.to_int64() >= size,
    log_bytes: size,
    truncated: record.log_truncated,
  })
}

///|
/// Every known session, live or recovered, sorted by `session_id`.
pub async fn RuntimeExecutor::pty_list(
  self : RuntimeExecutor,
) -> Array[PtySessionInfo] {
  let result : Array[PtySessionInfo] = []
  for status in self.pty.list_sessions() {
    let slot = self.pty_slots.get(status.session_id)
    let request_id = match slot {
      Some(value) => value.client_request_id
      None => ""
    }
    result.push(
      pty_info_from_status(
        status,
        request_id,
        false,
        pty_started_at_of(slot),
      ),
    )
  }
  for session_id, record in self.pty_recovered {
    let mut live = false
    for info in result {
      if info.session_id == session_id {
        live = true
      }
    }
    if !live {
      result.push(record.info())
    }
  }
  result.sort_by(fn(left : PtySessionInfo, right : PtySessionInfo) -> Int32 {
    left.session_id.compare(right.session_id)
  })
  result
}

///|
/// Close every live session before the owning task group shuts down, so every
/// session gets a durable terminal event. Idempotent for already-closed
/// sessions. Returns the first failure after attempting all sessions.
pub async fn RuntimeExecutor::pty_close_all(
  self : RuntimeExecutor,
) -> Result[Array[PtySessionInfo], RuntimeError] {
  match self.require_open() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let ids : Array[String] = []
  for session_id, _slot in self.pty_slots {
    ids.push(session_id)
  }
  ids.sort_by(fn(left : String, right : String) -> Int32 {
    left.compare(right)
  })
  let result : Array[PtySessionInfo] = []
  let mut failure : RuntimeError? = None
  for session_id in ids {
    match self.pty_close(session_id) {
      Ok(info) => result.push(info)
      Err(error) =>
        if failure is None {
          failure = Some(error)
        }
    }
  }
  match failure {
    Some(error) => Err(error)
    None => Ok(result)
  }
}
