///|
/// Streaming process runtime (A1.4).
///
/// `runtime.exec.*` runs bounded commands and publishes redacted line logs.
/// An ACP agent is different: it is long-lived, speaks a line protocol on
/// stdout, needs an open stdin, and the primary reads its output by absolute
/// byte offset so it can resume a partially consumed line after a poll. This
/// module therefore keeps bytes verbatim in per-stream rings and never applies
/// text redaction to protocol streams (redaction would corrupt JSON).
///
/// Loss semantics: a process that survives a node restart cannot be reattached
/// (A1 has no reattach protocol). Recovery durably appends a `lost` terminal
/// event with `stop_reason=host_restarted`, so the primary can never mistake a
/// restarted node for a live agent. Ring eviction is bounded and reported as a
/// gap; the reader must treat a gap on a protocol stream as fatal rather than
/// parse corrupted frames.

///|
pub const PROCESS_MAX_READ_BYTES : Int32 = 32_768

///|
pub const PROCESS_MAX_STDIN_BYTES : Int32 = 32_768

///|
const PROCESS_DEFAULT_CANCEL_WAIT_MS : Int64 = 10_000

///|
const PROCESS_DEFAULT_STDIN_TIMEOUT_MS : Int64 = 5_000

///|
/// Per-runtime bounds for streaming processes. `max_output_bytes` is the
/// retained ring capacity per stream; the pump never buffers more than that
/// and evicts oldest bytes (reporting the gap) when a reader falls behind.
pub(all) struct ProcessLimits {
  max_output_bytes : Int64
  chunk_bytes : Int32
  spawn_timeout_ms : Int64
  cancel_wait_ms : Int64
  stdin_timeout_ms : Int64
}

///|
pub fn ProcessLimits::new(
  max_output_bytes~ : Int64 = 1_048_576L,
  chunk_bytes~ : Int32 = 16_384,
  spawn_timeout_ms~ : Int64 = 5_000L,
  cancel_wait_ms~ : Int64 = PROCESS_DEFAULT_CANCEL_WAIT_MS,
  stdin_timeout_ms~ : Int64 = PROCESS_DEFAULT_STDIN_TIMEOUT_MS,
) -> ProcessLimits {
  {
    max_output_bytes: max_output_bytes.max(1_024L),
    chunk_bytes: chunk_bytes.max(64).min(PROCESS_MAX_READ_BYTES),
    spawn_timeout_ms: spawn_timeout_ms.max(100L),
    cancel_wait_ms: cancel_wait_ms.max(100L),
    stdin_timeout_ms: stdin_timeout_ms.max(100L),
  }
}

///|
/// One idempotent process start. `timeout_ms` is an explicit optional bound:
/// 0 means the process may run until cancelled (the ACP case). `env` is an
/// explicit non-inherited environment; `inherit_env` names variables the node
/// reads from its own environment (never from the primary). No shell string is
/// accepted: `argv` is executed literally.
pub(all) struct ProcessSpec {
  argv : Array[String]
  cwd : String
  env : Array[EnvPair]
  inherit_env : Array[String]
  timeout_ms : Int64
  risk : String
  max_output_bytes : Int64
}

///|
pub fn ProcessSpec::new(
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Array[EnvPair] = [],
  inherit_env~ : Array[String] = [],
  timeout_ms~ : Int64 = 0L,
  risk~ : String = "",
  max_output_bytes~ : Int64 = 0L,
) -> ProcessSpec {
  {
    argv,
    cwd,
    env,
    inherit_env,
    timeout_ms,
    risk,
    max_output_bytes: if max_output_bytes <= 0L {
      1_048_576L
    } else {
      max_output_bytes
    },
  }
}

///|
pub(all) struct ProcessInfo {
  run_id : String
  client_request_id : String
  status : String
  risk : String
  pid : Int32
  cwd : String
  started_at : String
  ended_at : String?
  exit_code : Int32?
  signal : Int32?
  stop_reason : String
  stdout_bytes : Int64
  stderr_bytes : Int64
  timed_out : Bool
  stdout_dropped : Bool
  stderr_dropped : Bool
}

///|
pub fn ProcessInfo::success(self : ProcessInfo) -> Bool {
  self.status == @contracts.RUN_STATUS_SUCCEEDED
}

///|
pub fn ProcessInfo::to_json(self : ProcessInfo) -> @json.Json {
  @contracts.json_object([
    ("run_id", @contracts.json_string(self.run_id)),
    ("client_request_id", @contracts.json_string(self.client_request_id)),
    ("status", @contracts.json_string(self.status)),
    ("risk", @contracts.json_string(self.risk)),
    ("pid", @contracts.json_int(self.pid)),
    ("cwd", @contracts.json_string(self.cwd)),
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
    ("stdout_dropped", @contracts.json_bool(self.stdout_dropped)),
    ("stderr_dropped", @contracts.json_bool(self.stderr_dropped)),
    ("success", @contracts.json_bool(self.success())),
  ])
}

///|
/// One bounded read of a process stream. `offset` is the absolute byte offset
/// of `data`'s first byte (it can be ahead of the requested offset when the
/// ring evicted older bytes); `next_offset` is the cursor to request next.
/// `gap` reports that the requested offset was no longer retained, and
/// `dropped` is sticky for the whole stream. `eof` means the stream is closed
/// and `next_offset == total_bytes`.
pub(all) struct ProcessChunk {
  run_id : String
  stream : String
  offset : Int64
  next_offset : Int64
  data_b64 : String
  eof : Bool
  gap : Bool
  dropped : Bool
  total_bytes : Int64
}

///|
pub fn ProcessChunk::to_json(self : ProcessChunk) -> @json.Json {
  @contracts.json_object([
    ("run_id", @contracts.json_string(self.run_id)),
    ("stream", @contracts.json_string(self.stream)),
    ("offset", @contracts.json_int64(self.offset)),
    ("next_offset", @contracts.json_int64(self.next_offset)),
    ("data", @contracts.json_string(self.data_b64)),
    ("eof", @contracts.json_bool(self.eof)),
    ("gap", @contracts.json_bool(self.gap)),
    ("dropped", @contracts.json_bool(self.dropped)),
    ("total_bytes", @contracts.json_int64(self.total_bytes)),
  ])
}

///|
struct RingChunk {
  offset : Int64
  data : Bytes
}

///|
/// Bounded byte ring for one stream. Bytes are retained verbatim; eviction
/// advances `base` and sets `dropped`. No await happens inside append/read, so
/// the pump and a reader cannot observe a partially appended chunk.
struct OutputRing {
  chunks : Array[RingChunk]
  base : Ref[Int64]
  end : Ref[Int64]
  dropped : Ref[Bool]
  closed : Ref[Bool]
  capacity : Int64
}

///|
fn make_output_ring(capacity : Int64) -> OutputRing {
  {
    chunks: [],
    base: Ref(0L),
    end: Ref(0L),
    dropped: Ref(false),
    closed: Ref(false),
    capacity: capacity.max(1_024L),
  }
}

///|
fn OutputRing::retained(self : OutputRing) -> Int64 {
  self.end.val - self.base.val
}

///|
fn OutputRing::append(self : OutputRing, bytes : Bytes) -> Unit {
  if bytes.length() == 0 {
    return
  }
  let offset = self.end.val
  self.chunks.push({ offset, data: bytes })
  self.end.val = offset + bytes.length().to_int64()
  self.evict()
}

///|
fn OutputRing::evict(self : OutputRing) -> Unit {
  while self.retained() > self.capacity && self.chunks.length() > 1 {
    let dropped = self.chunks.remove(0)
    self.base.val = dropped.offset + dropped.data.length().to_int64()
    self.dropped.val = true
  }
  if self.retained() > self.capacity && self.chunks.length() == 1 {
    let only = self.chunks[0]
    let total = only.data.length().to_int64()
    let keep = self.capacity
    let cut = total - keep
    if cut > 0 {
      let start = cut.to_int()
      let piece = only.data[start:only.data.length()].to_owned()
      self.chunks[0] = { offset: only.offset + cut, data: piece }
      self.base.val = only.offset + cut
      self.dropped.val = true
    }
  }
}

///|
/// Copy retained bytes starting at `from` (clamped to the retained range),
/// up to `max_bytes`. Returns the actual start offset and the bytes.
fn OutputRing::read(
  self : OutputRing,
  from : Int64,
  max_bytes : Int32,
) -> (Int64, Bytes) {
  let start = if from < self.base.val {
    self.base.val
  } else if from > self.end.val {
    self.end.val
  } else {
    from
  }
  let want = self.end.val - start
  let limit = if want <= 0L {
    0
  } else {
    want.min(max_bytes.to_int64()).to_int()
  }
  if limit == 0 {
    return (start, b"")
  }
  let out : Array[Byte] = []
  let mut cursor = start
  let stop = start + limit.to_int64()
  for chunk in self.chunks {
    let chunk_start = chunk.offset
    let chunk_end = chunk.offset + chunk.data.length().to_int64()
    if chunk_end <= cursor {
      continue
    }
    if chunk_start >= stop {
      break
    }
    let local_start = if cursor > chunk_start {
      (cursor - chunk_start).to_int()
    } else {
      0
    }
    let local_end = if stop < chunk_end {
      (stop - chunk_start).to_int()
    } else {
      chunk.data.length()
    }
    let mut index = local_start
    while index < local_end {
      out.push(chunk.data[index])
      index = index + 1
    }
    cursor = chunk_end
    if cursor >= stop {
      break
    }
  }
  (start, Bytes::from_array(out[:]))
}

///|
struct ProcessSlot {
  info : Ref[ProcessInfo]
  proc : Ref[@process.Process?]
  stdin : Ref[@process.WriteToProcess?]
  stdin_lock : @async.Mutex
  ready : Ref[Bool]
  spawn_error : Ref[String?]
  cancel_requested : Ref[Bool]
  timed_out : Ref[Bool]
  finished : Ref[Bool]
  stdout : OutputRing
  stderr : OutputRing
}

///|
fn make_process_info(
  run_id : String,
  client_request_id : String,
  risk : String,
  started_at : String,
  cwd : String,
  pid : Int32,
) -> ProcessInfo {
  {
    run_id,
    client_request_id,
    status: @contracts.RUN_STATUS_RUNNING,
    risk,
    pid,
    cwd,
    started_at,
    ended_at: None,
    exit_code: None,
    signal: None,
    stop_reason: "",
    stdout_bytes: 0L,
    stderr_bytes: 0L,
    timed_out: false,
    stdout_dropped: false,
    stderr_dropped: false,
  }
}

///|
fn make_process_slot(info : ProcessInfo, capacity : Int64) -> ProcessSlot {
  {
    info: Ref(info),
    proc: Ref(None),
    stdin: Ref(None),
    stdin_lock: @async.Mutex::Mutex(),
    ready: Ref(false),
    spawn_error: Ref(None),
    cancel_requested: Ref(false),
    timed_out: Ref(false),
    finished: Ref(false),
    stdout: make_output_ring(capacity),
    stderr: make_output_ring(capacity),
  }
}

///|
fn ring_of(slot : ProcessSlot, stream : String) -> OutputRing {
  if stream == "stdout" {
    slot.stdout
  } else {
    slot.stderr
  }
}

///|
fn slot_is_finished(slot : ProcessSlot) -> Bool {
  slot.finished.val
}

///|
/// Process info as persisted by terminal events.
fn apply_process_terminal(info : ProcessInfo, event : StoredEvent) -> ProcessInfo {
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
  let stdout_dropped = @contracts.bool_field_or(
    object,
    "stdout_dropped",
    info.stdout_dropped,
  )
  let stderr_dropped = @contracts.bool_field_or(
    object,
    "stderr_dropped",
    info.stderr_dropped,
  )
  {
    run_id: info.run_id,
    client_request_id: info.client_request_id,
    status,
    risk: info.risk,
    pid: info.pid,
    cwd: info.cwd,
    started_at: info.started_at,
    ended_at,
    exit_code,
    signal,
    stop_reason,
    stdout_bytes,
    stderr_bytes,
    timed_out,
    stdout_dropped,
    stderr_dropped,
  }
}

///|
/// The streaming-process runtime. It shares the executor's durable outbox (one
/// `(runtime_id, run_id, run_seq)` stream per run) and the same rooted work
/// directory used by `exec.start`.
pub struct ProcessRuntime {
  outbox : Outbox
  work_dir : String
  limits : ProcessLimits
  mutex : @async.Mutex
  runs : Map[String, ProcessSlot]
  by_request : Map[String, String]
}

///|
pub fn ProcessRuntime::new(
  outbox : Outbox,
  work_dir : String,
  limits : ProcessLimits,
) -> ProcessRuntime {
  {
    outbox,
    work_dir,
    limits,
    mutex: @async.Mutex::Mutex(),
    runs: Map([]),
    by_request: Map([]),
  }
}

///|
pub fn ProcessRuntime::limits(self : ProcessRuntime) -> ProcessLimits {
  self.limits
}

///|
/// Rebuild process state from the durable event replay. A process that was
/// started but has no terminal event is durably finalized as `lost`
/// (`host_restarted`); its output ring is gone, so reads report EOF with zero
/// retained bytes. A reattach-capable protocol is explicitly out of scope for
/// A1.
pub async fn ProcessRuntime::recover(
  self : ProcessRuntime,
  events : Array[StoredEvent],
) -> Result[Unit, String] {
  let recovered : Map[String, ProcessInfo] = Map([])
  let order : Array[String] = []
  let has_terminal : Map[String, Bool] = Map([])
  for event in events {
    if event.run_id == "" {
      continue
    }
    if event.kind == EVENT_PROCESS_STARTED {
      if recovered.get(event.run_id) is None {
        let object = @contracts.as_object(event.payload)
        let client_request_id = match object {
          Some(value) => @contracts.string_field_or(value, "client_request_id", "")
          None => ""
        }
        let risk = match object {
          Some(value) =>
            @contracts.string_field_or(value, "risk", @contracts.RISK_HIGH)
          None => @contracts.RISK_HIGH
        }
        let started_at = match object {
          Some(value) => @contracts.string_field_or(value, "started_at", event.ts)
          None => event.ts
        }
        let cwd = match object {
          Some(value) => @contracts.string_field_or(value, "cwd", "")
          None => ""
        }
        let pid = match object {
          Some(value) => @contracts.int_field_or(value, "pid", 0)
          None => 0
        }
        recovered.set(
          event.run_id,
          make_process_info(
            event.run_id,
            client_request_id,
            risk,
            started_at,
            cwd,
            pid,
          ),
        )
        order.push(event.run_id)
      }
    } else if event.kind == EVENT_PROCESS_EXITED {
      match recovered.get(event.run_id) {
        Some(info) => {
          recovered.set(event.run_id, apply_process_terminal(info, event))
          has_terminal.set(event.run_id, true)
        }
        None => ()
      }
    }
  }
  for run_id in order {
    let info = recovered.get(run_id).unwrap()
    let mut final_info = info
    let terminal = match has_terminal.get(run_id) {
      Some(value) => value
      None => false
    }
    if !terminal {
      // Do not report a process from a previous node instance as running.
      let ended_at = @contracts.format_rfc3339(@async.now())
      let entries : Array[(String, @json.Json)] = [
        ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
        ("stop_reason", @contracts.json_string(STOP_REASON_HOST_RESTARTED)),
        ("ended_at", @contracts.json_string(ended_at)),
        ("exit_code", @contracts.json_null()),
        ("signal", @contracts.json_null()),
        ("stdout_bytes", @contracts.json_int64(0L)),
        ("stderr_bytes", @contracts.json_int64(0L)),
        ("timed_out", @contracts.json_bool(false)),
        ("cancelled", @contracts.json_bool(false)),
        ("stdout_dropped", @contracts.json_bool(false)),
        ("stderr_dropped", @contracts.json_bool(false)),
        ("recovered", @contracts.json_bool(true)),
      ]
      match self.outbox.append(run_id, EVENT_PROCESS_EXITED, entries) {
        Ok(_) => ()
        Err(message) => return Err("cannot record recovered process: " + message)
      }
      final_info = {
        ..info,
        status: @contracts.RUN_STATUS_LOST,
        ended_at: Some(ended_at),
        exit_code: None,
        signal: None,
        stop_reason: STOP_REASON_HOST_RESTARTED,
        stdout_bytes: 0L,
        stderr_bytes: 0L,
        timed_out: false,
      }
    }
    let slot = make_process_slot(final_info, self.limits.max_output_bytes)
    slot.ready.val = true
    slot.finished.val = true
    slot.stdout.closed.val = true
    slot.stderr.closed.val = true
    if final_info.client_request_id != "" &&
      self.by_request.get(final_info.client_request_id) is None {
      self.by_request.set(final_info.client_request_id, run_id)
    }
    self.runs.set(run_id, slot)
  }
  Ok(())
}

///|
/// Idempotently start a streaming process. The same `(client_request_id)` is
/// answered with the existing run and never spawns twice. The process tree is
/// owned by `group`; cancelling that group kills it.
pub async fn ProcessRuntime::start(
  self : ProcessRuntime,
  group : @async.TaskGroup[Unit],
  client_request_id~ : String,
  run_id~ : String,
  spec~ : ProcessSpec,
) -> Result[(ProcessInfo, Bool), String] {
  match validate_resource_id(client_request_id, "client_request_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  match validate_resource_id(run_id, "run_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  if spec.timeout_ms < 0L || spec.timeout_ms > MAX_TIMEOUT_MS.to_int64() {
    return Err(
      "timeout_ms must be 0 (no timeout) or at most " +
      MAX_TIMEOUT_MS.to_string(),
    )
  }
  if spec.max_output_bytes < 1L ||
    spec.max_output_bytes > MAX_OUTPUT_BYTES_LIMIT.to_int64() {
    return Err(
      "max_output_bytes must be between 1 and " +
      MAX_OUTPUT_BYTES_LIMIT.to_string(),
    )
  }
  // Reuse the command validator for argv/env/cwd/risk rules. Its implicit
  // 300 s timeout is not used: the process keeps this spec's timeout.
  let validation_spec = CommandSpec::new(
    argv=spec.argv,
    cwd=spec.cwd,
    env=spec.env,
    inherit_env=spec.inherit_env,
    timeout_ms=DEFAULT_TIMEOUT_MS,
    risk=spec.risk,
    stdin=None,
    max_output_bytes=spec.max_output_bytes.min(
      MAX_OUTPUT_BYTES_LIMIT.to_int64(),
    ).to_int(),
  )
  match validate_command_spec(validation_spec) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  self.mutex.acquire()
  defer self.mutex.release()
  match self.by_request.get(client_request_id) {
    Some(existing) =>
      return match self.runs.get(existing) {
        Some(slot) => Ok((slot.info.val, true))
        None => Err("request id maps to a missing process")
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
  let cwd_abs = match resolve_cwd(self.work_dir, spec.cwd) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let setsid = first_existing(["/usr/bin/setsid", "/bin/setsid"])
  let kill = first_existing(["/bin/kill", "/usr/bin/kill"])
  match kill {
    Some(path) => kill_path_global.val = path
    None => kill_path_global.val = ""
  }
  let effective_risk = max_risk(
    if spec.risk == "" { @contracts.RISK_MEDIUM } else { spec.risk },
    classify_argv(spec.argv),
  )
  let started_at = @contracts.format_rfc3339(@async.now())
  let entries : Array[(String, @json.Json)] = [
    ("client_request_id", @contracts.json_string(client_request_id)),
    ("argv", @contracts.json_string_array(event_argv(spec.argv))),
    (
      "cwd",
      @contracts.json_string(normalize_rooted_path(spec.cwd).unwrap_or("")),
    ),
    ("risk", @contracts.json_string(effective_risk)),
    ("timeout_ms", @contracts.json_int64(spec.timeout_ms)),
    ("max_output_bytes", @contracts.json_int64(spec.max_output_bytes)),
    (
      "env_names",
      @contracts.json_string_array(
        env_names(validation_spec),
      ),
    ),
    ("started_at", @contracts.json_string(started_at)),
  ]
  match self.outbox.append(run_id, EVENT_PROCESS_STARTED, entries) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let info = make_process_info(
    run_id,
    client_request_id,
    effective_risk,
    started_at,
    cwd_abs,
    0,
  )
  let slot = make_process_slot(
    info,
    spec.max_output_bytes.min(self.limits.max_output_bytes),
  )
  self.runs.set(run_id, slot)
  self.by_request.set(client_request_id, run_id)
  let tree_cancel_available = setsid is Some(_) && kill is Some(_)
  group.spawn_bg(allow_failure=true, async fn() {
    self.supervise(
      slot,
      run_id,
      spec,
      program,
      cwd_abs,
      setsid,
      tree_cancel_available,
    )
  })
  let deadline = @async.now() + self.limits.spawn_timeout_ms
  while !slot.ready.val &&
        slot.spawn_error.val is None &&
        @async.now() < deadline {
    @async.sleep(2)
  }
  if slot.spawn_error.val is Some(message) {
    let terminal_deadline = @async.now() + self.limits.spawn_timeout_ms
    while !slot.finished.val && @async.now() < terminal_deadline {
      @async.sleep(2)
    }
    return Err(message)
  }
  if !slot.ready.val {
    return Err("timed out waiting for the process to spawn")
  }
  Ok((slot.info.val, false))
}

///|
async fn ProcessRuntime::supervise(
  self : ProcessRuntime,
  slot : ProcessSlot,
  run_id : String,
  spec : ProcessSpec,
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
        let child_env : Map[String, String] = Map([])
        for pair in spec.env {
          child_env.set(pair.name, pair.value)
        }
        for name in spec.inherit_env {
          match @env.get_env_var(name) {
            Some(value) => child_env.set(name, value)
            None => ()
          }
        }
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
          cancel_process_group
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
        // The start response must carry the real pid: operators and the
        // credential custody checks use it to inspect the child process
        // environment (`/proc/<pid>/environ`).
        slot.info.val = { ..slot.info.val, pid: proc.pid, }
        slot.stdin.val = Some(stdin_writer)
        let owner = self
        let _ = inner.spawn(async fn() {
          owner.pump(slot, "stdout", out_r)
        })
        let _ = inner.spawn(async fn() {
          owner.pump(slot, "stderr", err_r)
        })
        if slot.cancel_requested.val {
          proc.cancel()
        }
        slot.ready.val = true
        let code : Int32? = if spec.timeout_ms > 0L {
          match
            @async.with_timeout_opt(
              spec.timeout_ms.to_int(),
              async fn() -> Int32 { proc.wait() },
            ) {
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
        } else {
          Some(proc.wait())
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
async fn ProcessRuntime::pump(
  self : ProcessRuntime,
  slot : ProcessSlot,
  stream : String,
  reader : @process.ReadFromProcess,
) -> Unit {
  defer reader.close()
  let ring = ring_of(slot, stream)
  while true {
    let chunk = reader.read_some(max_len=self.limits.chunk_bytes) catch {
      _ => break
    }
    match chunk {
      Some(bytes) => ring.append(bytes)
      None => break
    }
  }
  ring.closed.val = true
}

///|
fn ProcessRuntime::status_of(self : ProcessRuntime, run_id : String) -> ProcessInfo? {
  match self.runs.get(run_id) {
    Some(slot) => Some(slot.info.val)
    None => None
  }
}

///|
pub fn ProcessRuntime::status(
  self : ProcessRuntime,
  run_id : String,
) -> ProcessInfo? {
  self.status_of(run_id)
}

///|
pub fn ProcessRuntime::processes(self : ProcessRuntime) -> Array[ProcessInfo] {
  let out : Array[ProcessInfo] = []
  for entry in self.runs {
    out.push(entry.1.info.val)
  }
  out.sort_by(fn(left : ProcessInfo, right : ProcessInfo) -> Int32 {
    if left.started_at == right.started_at {
      left.run_id.compare(right.run_id)
    } else {
      left.started_at.compare(right.started_at)
    }
  })
  out
}

///|
/// Read one stream chunk. Reads are non-blocking: with no new bytes the answer
/// is an empty chunk at the requested offset (or at `total_bytes` if the
/// caller asked beyond the produced range). This keeps the node's serialized
/// dispatch responsive; the primary polls.
pub fn ProcessRuntime::read_stream(
  self : ProcessRuntime,
  run_id : String,
  stream : String,
  offset : Int64,
  max_bytes : Int32,
) -> Result[ProcessChunk, String] {
  let slot = match self.runs.get(run_id) {
    Some(value) => value
    None => return Err("unknown process: " + run_id)
  }
  if stream != "stdout" && stream != "stderr" {
    return Err("stream must be stdout or stderr")
  }
  if offset < 0L {
    return Err("offset must not be negative")
  }
  let limit = max_bytes.max(1).min(PROCESS_MAX_READ_BYTES)
  let ring = ring_of(slot, stream)
  let gap = offset < ring.base.val
  let (start, bytes) = ring.read(offset, limit)
  let next_offset = start + bytes.length().to_int64()
  let data_b64 = @base64.encode(bytes[:], padding=true)
  Ok({
    run_id,
    stream,
    offset: start,
    next_offset,
    data_b64,
    eof: ring.closed.val && next_offset >= ring.end.val,
    gap,
    dropped: ring.dropped.val,
    total_bytes: ring.end.val,
  })
}

///|
/// Write bytes to the process stdin. The payload is bounded and serialized by
/// a per-process lock; a child that stops reading cannot stall the node's
/// dispatch indefinitely (the write is bounded and reports a timeout). ACP
/// traffic is line-sized, so the normal path is immediate.
pub async fn ProcessRuntime::write_stdin(
  self : ProcessRuntime,
  run_id : String,
  bytes : Bytes,
) -> Result[ProcessInfo, String] {
  let slot = match self.runs.get(run_id) {
    Some(value) => value
    None => return Err("unknown process: " + run_id)
  }
  if bytes.length() > PROCESS_MAX_STDIN_BYTES {
    return Err(
      "stdin chunk exceeds " + PROCESS_MAX_STDIN_BYTES.to_string() + " bytes",
    )
  }
  slot.stdin_lock.acquire()
  defer slot.stdin_lock.release()
  if slot_is_finished(slot) {
    return Err("process has already exited")
  }
  let writer = match slot.stdin.val {
    Some(value) => value
    None => return Err("process stdin is not available")
  }
  let outcome = @async.with_timeout_opt(
    self.limits.stdin_timeout_ms.to_int(),
    async fn() -> Bool {
      writer.write(bytes[:]) catch {
        _ => return false
      }
      true
    },
  )
  match outcome {
    Some(true) => Ok(slot.info.val)
    Some(false) => Err("cannot write to process stdin")
    None => Err("process stdin write timed out")
  }
}

///|
/// Current status of one process.
pub fn ProcessRuntime::exit(
  self : ProcessRuntime,
  run_id : String,
) -> Result[ProcessInfo, String] {
  match self.runs.get(run_id) {
    Some(slot) => Ok(slot.info.val)
    None => Err("unknown process: " + run_id)
  }
}

///|
async fn ProcessRuntime::wait_finished(
  self : ProcessRuntime,
  slot : ProcessSlot,
  timeout_ms : Int64,
) -> Bool {
  let _ = self
  let deadline = @async.now() + timeout_ms
  while !slot.finished.val && @async.now() < deadline {
    @async.sleep(5)
  }
  slot.finished.val
}

///|
/// Cancel one process. Idempotent: an already-finished process returns its
/// recorded status. A cancel never reports success. If the supervisor cannot
/// confirm termination in the bounded window, the run is durably recorded as
/// `lost` instead of pretending it stopped.
pub async fn ProcessRuntime::cancel(
  self : ProcessRuntime,
  run_id : String,
) -> Result[ProcessInfo, String] {
  let slot = match self.runs.get(run_id) {
    Some(value) => value
    None => return Err("unknown process: " + run_id)
  }
  if slot.finished.val {
    return Ok(slot.info.val)
  }
  slot.cancel_requested.val = true
  match slot.proc.val {
    Some(proc) => proc.cancel()
    None => ()
  }
  if self.wait_finished(slot, self.limits.cancel_wait_ms) {
    return Ok(slot.info.val)
  }
  if slot.finished.val {
    return Ok(slot.info.val)
  }
  let ended_at = @contracts.format_rfc3339(@async.now())
  let entries : Array[(String, @json.Json)] = [
    ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
    ("stop_reason", @contracts.json_string(STOP_REASON_PROCESS_MISSING)),
    ("ended_at", @contracts.json_string(ended_at)),
    ("exit_code", @contracts.json_null()),
    ("signal", @contracts.json_null()),
    ("stdout_bytes", @contracts.json_int64(slot.stdout.end.val)),
    ("stderr_bytes", @contracts.json_int64(slot.stderr.end.val)),
    ("timed_out", @contracts.json_bool(slot.timed_out.val)),
    ("cancelled", @contracts.json_bool(true)),
    ("stdout_dropped", @contracts.json_bool(slot.stdout.dropped.val)),
    ("stderr_dropped", @contracts.json_bool(slot.stderr.dropped.val)),
    ("recovered", @contracts.json_bool(false)),
  ]
  match self.outbox.append(run_id, EVENT_PROCESS_EXITED, entries) {
    Ok(_) => ()
    Err(message) => return Err("cannot record lost process: " + message)
  }
  let info : ProcessInfo = {
    ..slot.info.val,
    status: @contracts.RUN_STATUS_LOST,
    ended_at: Some(ended_at),
    exit_code: None,
    signal: None,
    stop_reason: STOP_REASON_PROCESS_MISSING,
    stdout_bytes: slot.stdout.end.val,
    stderr_bytes: slot.stderr.end.val,
  }
  slot.info.val = info
  slot.finished.val = true
  Ok(info)
}

///|
async fn ProcessRuntime::finalize(
  self : ProcessRuntime,
  slot : ProcessSlot,
  run_id : String,
  spawn_error : String?,
  cancelled : Bool,
  exit_code : Int32?,
  timed_out : Bool,
) -> Unit {
  if slot.finished.val {
    return
  }
  let ended_at = @contracts.format_rfc3339(@async.now())
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
    ("stdout_bytes", @contracts.json_int64(slot.stdout.end.val)),
    ("stderr_bytes", @contracts.json_int64(slot.stderr.end.val)),
    ("timed_out", @contracts.json_bool(timed_out)),
    ("cancelled", @contracts.json_bool(cancel_hit)),
    ("stdout_dropped", @contracts.json_bool(slot.stdout.dropped.val)),
    ("stderr_dropped", @contracts.json_bool(slot.stderr.dropped.val)),
    (
      "error",
      match spawn_error {
        Some(value) => @contracts.json_string(value)
        None => @contracts.json_null()
      },
    ),
  ]
  let append_ok = match self.outbox.append(run_id, EVENT_PROCESS_EXITED, entries) {
    Ok(_) => true
    Err(_) => false
  }
  if !append_ok && status == @contracts.RUN_STATUS_SUCCEEDED {
    status = @contracts.RUN_STATUS_LOST
    stop_reason = STOP_REASON_OUTBOX_ERROR
  }
  match slot.stdin.val {
    Some(writer) => writer.close()
    None => ()
  }
  slot.stdin.val = None
  slot.stdout.closed.val = true
  slot.stderr.closed.val = true
  slot.info.val = {
    ..slot.info.val,
    status,
    ended_at: Some(ended_at),
    exit_code: reported_exit,
    signal,
    stop_reason,
    stdout_bytes: slot.stdout.end.val,
    stderr_bytes: slot.stderr.end.val,
    timed_out,
    stdout_dropped: slot.stdout.dropped.val,
    stderr_dropped: slot.stderr.dropped.val,
  }
  slot.proc.val = None
  slot.finished.val = true
}
