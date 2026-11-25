///|
/// Transport-independent PTY runtime primitives for the paired runtime
/// (ADR-0012 §4/§6). The runtime owns a real PTY and a bounded transcript;
/// it does not know about JSON-RPC, WSS, pairing or ACP.
///
/// Output is published as ordered, bounded events. Each event has a
/// per-session monotonic `seq` starting at 1 and a `log_offset` into the
/// append-only transcript, so a transport can replay via events and fall
/// back to the transcript when the in-memory ring has evicted old events.
/// The transcript itself is bounded by `PtyLimits::max_log_bytes`.

///|
pub(all) enum PtyErrorKind {
  InvalidArgument
  NotFound
  Conflict
  AlreadyClosed
  SpawnFailed
  Io
  Timeout
  StateDir
  Internal
}

///|
pub(all) struct PtyError {
  kind : PtyErrorKind
  message : String
  session_id : String
  seq : Int64
  residual_pids : Array[Int]
}

///|
fn pty_error(kind : PtyErrorKind, message : String) -> PtyError {
  {
    kind,
    message,
    session_id: "",
    seq: 0L,
    residual_pids: [],
  }
}

///|
fn PtyError::with_session(self : PtyError, session_id : String) -> PtyError {
  { ..self, session_id, }
}

///|
fn PtyError::with_seq(self : PtyError, seq : Int64) -> PtyError {
  { ..self, seq, }
}

///|
fn PtyError::with_residual(
  self : PtyError,
  residual_pids : Array[Int],
) -> PtyError {
  { ..self, residual_pids, }
}

///|
/// Per-runtime bounds. Event data is capped by `max_event_bytes`; the ring
/// keeps at most `ring_events` events and `ring_bytes` worth of data; the
/// append-only transcript stops at `max_log_bytes` and reports truncation.
pub(all) struct PtyLimits {
  max_event_bytes : Int
  ring_events : Int
  ring_bytes : Int64
  max_log_bytes : Int64
  max_input_bytes : Int
  spawn_timeout_ms : Int
  close_grace_ms : Int
  close_timeout_ms : Int
}

///|
pub fn PtyLimits::new(
  max_event_bytes~ : Int = 4_096,
  ring_events~ : Int = 256,
  ring_bytes~ : Int64 = 262_144L,
  max_log_bytes~ : Int64 = 4_194_304L,
  max_input_bytes~ : Int = 65_536,
  spawn_timeout_ms~ : Int = 10_000,
  close_grace_ms~ : Int = 1_000,
  close_timeout_ms~ : Int = 5_000,
) -> PtyLimits {
  {
    max_event_bytes: max_event_bytes.max(64),
    ring_events: ring_events.max(1),
    ring_bytes: ring_bytes.max(1_024L),
    max_log_bytes: max_log_bytes.max(1_024L),
    max_input_bytes: max_input_bytes.max(1),
    spawn_timeout_ms: spawn_timeout_ms.max(100),
    close_grace_ms: close_grace_ms.max(10),
    close_timeout_ms: close_timeout_ms.max(100),
  }
}

///|
/// An idempotent open request. `argv` is passed literally to the PTY; no
/// whole-shell string is accepted. `env` is the complete child environment
/// (the runtime never inherits its own environment). A repeat with the same
/// `session_id`, `client_request_id` and request body returns the existing
/// session instead of spawning a second process.
pub(all) struct PtyOpenRequest {
  session_id : String
  argv : Array[String]
  cwd : String
  env : Array[(String, String)]
  rows : Int32
  cols : Int32
  client_request_id : String
}

///|
pub fn PtyOpenRequest::new(
  session_id~ : String,
  argv~ : Array[String],
  cwd~ : String,
  env~ : Array[(String, String)] = [],
  rows~ : Int32 = 24,
  cols~ : Int32 = 80,
  client_request_id~ : String = "",
) -> PtyOpenRequest {
  { session_id, argv, cwd, env, rows, cols, client_request_id, }
}

///|
pub(all) struct PtySessionHandle {
  session_id : String
  created : Bool
  pid : Int
  pgid : Int
  rows : Int32
  cols : Int32
  log_path : String
}

///|
/// The current or final state of one session. `success` is true only for a
/// natural exit with code 0; a cancelled, timed-out or failed session never
/// reports success. `residual_pids` lists live processes still in the
/// session's process group after termination (setsid-escaped descendants are
/// outside the group and are documented as out of scope).
pub(all) struct PtyStatus {
  session_id : String
  running : Bool
  finalized : Bool
  success : Bool
  cancelled : Bool
  timed_out : Bool
  exit_code : Int
  signal : Int
  pid : Int
  pgid : Int
  rows : Int32
  cols : Int32
  output_seq : Int64
  output_dropped : Bool
  log_path : String
  log_bytes : Int64
  log_truncated : Bool
  residual_pids : Array[Int]
  failure : String
}

///|
pub(all) struct PtyOutputEvent {
  seq : Int64
  data : String
  raw_bytes : Int64
  log_offset : Int64
  log_bytes : Int64
  log_truncated : Bool
}

///|
pub(all) struct PtyEventPage {
  session_id : String
  events : Array[PtyOutputEvent]
  next_seq : Int64
  earliest_seq : Int64
  dropped : Bool
  log_path : String
  log_bytes : Int64
  log_truncated : Bool
}

///|
pub(all) struct PtyLogSlice {
  session_id : String
  offset : Int64
  data : String
  bytes : Int64
  eof : Bool
  log_bytes : Int64
  truncated : Bool
}
