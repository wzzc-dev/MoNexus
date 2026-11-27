///|
///|
/// One PTY session. The session task and the runtime share this record under
/// `PtyRuntime::mutex`; the PTY handle itself is only touched by the session
/// task and by validated input/resize calls that snapshot it.
priv struct PtySession {
  request : PtyOpenRequest
  cwd : String
  sensitive : Array[(String, String)]
  redact_hold : Int
  log_path : String
  log_file : @fs.File
  start_reported : Ref[Bool]
  start_error : Ref[String]
  finalizing : Ref[Bool]
  finalized : Ref[Bool]
  pty : Ref[@pty.Pty?]
  pid : Ref[Int]
  pgid : Ref[Int]
  task : Ref[@async.Task[Unit]?]
  next_seq : Ref[Int64]
  ring : Array[PtyOutputEvent]
  ring_bytes : Ref[Int64]
  dropped : Ref[Bool]
  log_bytes : Ref[Int64]
  log_truncated : Ref[Bool]
  pending : Ref[String]
  exit_code : Ref[Int]
  signal : Ref[Int]
  cancel_requested : Ref[Bool]
  timed_out : Ref[Bool]
  residual : Ref[Array[Int]]
  failure : Ref[String]
  rows : Ref[Int32]
  cols : Ref[Int32]
}

///|
fn pty_session_new(
  normalized : NormalizedOpen,
  log_path : String,
  log_file : @fs.File,
) -> PtySession {
  {
    request: normalized.request,
    cwd: normalized.cwd,
    sensitive: normalized.sensitive,
    redact_hold: normalized.redact_hold,
    log_path,
    log_file,
    start_reported: Ref(false),
    start_error: Ref(""),
    finalizing: Ref(false),
    finalized: Ref(false),
    pty: Ref(None),
    pid: Ref(0),
    pgid: Ref(0),
    task: Ref(None),
    next_seq: Ref(0L),
    ring: [],
    ring_bytes: Ref(0L),
    dropped: Ref(false),
    log_bytes: Ref(0L),
    log_truncated: Ref(false),
    pending: Ref(""),
    exit_code: Ref(-1),
    signal: Ref(0),
    cancel_requested: Ref(false),
    timed_out: Ref(false),
    residual: Ref([]),
    failure: Ref(""),
    rows: Ref(normalized.request.rows),
    cols: Ref(normalized.request.cols),
  }
}

///|
///|
async fn pty_report_start_error(
  rt : PtyRuntime,
  session : PtySession,
  message : String,
) -> Unit {
  rt.mutex.acquire()
  session.start_error.val = message
  session.start_reported.val = true
  session.failure.val = message
  rt.mutex.release()
}

///|
async fn pty_wait_started(
  rt : PtyRuntime,
  session : PtySession,
) -> Result[Unit, PtyError] {
  let deadline = @async.now() + rt.limits.spawn_timeout_ms.to_int64()
  while true {
    rt.mutex.acquire()
    let reported = session.start_reported.val
    let error = session.start_error.val
    let finalized = session.finalized.val
    rt.mutex.release()
    if reported {
      if error != "" {
        return Err(
          pty_error(PtyErrorKind::SpawnFailed, error)
          .with_session(session.request.session_id),
        )
      }
      return Ok(())
    }
    if finalized {
      return Err(
        pty_error(
          PtyErrorKind::SpawnFailed,
          "session ended before the child started",
        ).with_session(session.request.session_id),
      )
    }
    if @async.now() >= deadline {
      return Err(
        pty_error(
          PtyErrorKind::Timeout,
          "timed out waiting for the PTY child to start",
        ).with_session(session.request.session_id),
      )
    }
    @async.sleep(5)
  } nobreak {
    Ok(())
  }
}

///|
async fn pty_is_final(rt : PtyRuntime, session : PtySession) -> Bool {
  rt.mutex.acquire()
  let finalized = session.finalized.val
  rt.mutex.release()
  finalized
}

///|
async fn pty_is_finalizing(rt : PtyRuntime, session : PtySession) -> Bool {
  rt.mutex.acquire()
  let finalizing = session.finalizing.val
  rt.mutex.release()
  finalizing
}

///|
async fn pty_wait_final(
  rt : PtyRuntime,
  session : PtySession,
  timeout_ms : Int,
) -> Bool {
  if timeout_ms <= 0 {
    while true {
      if pty_is_final(rt, session) {
        return true
      }
      @async.sleep(20)
    } nobreak {
      ()
    }
  }
  let deadline = @async.now() + timeout_ms.to_int64()
  while true {
    if pty_is_final(rt, session) {
      return true
    }
    if @async.now() >= deadline {
      return false
    }
    @async.sleep(10)
  } nobreak {
    false
  }
}

///|
fn pty_redact(session : PtySession, text : String) -> String {
  if session.sensitive.length() == 0 || text == "" {
    return text
  }
  let mut output = text
  for pair in session.sensitive {
    output = output.replace_all(old=pair.1, new="[redacted]")
  }
  output
}

///|
/// Take at most `max_bytes` bytes from a UTF-8 string without cutting a code
/// point when possible. Used for bounded events and the capped transcript.
fn pty_utf8_prefix(text : String, max_bytes : Int) -> String {
  if max_bytes <= 0 {
    return ""
  }
  let bytes = @utf8.encode(text)
  if bytes.length() <= max_bytes {
    return text
  }
  let mut cut = max_bytes
  while cut > 0 && (bytes[cut].to_int() & 192) == 128 {
    cut = cut - 1
  }
  if cut == 0 {
    cut = max_bytes
  }
  @utf8.decode_lossy(bytes[0:cut])
}

///|
/// Append a redacted chunk to the bounded transcript. The caller holds the
/// runtime mutex. Returns the number of bytes actually stored and advances
/// `log_bytes`; once the cap is reached a final marker is written and no
/// later output is stored.
async fn pty_append_log(
  rt : PtyRuntime,
  session : PtySession,
  text : String,
) -> Int64 {
  if session.log_truncated.val || text == "" {
    return 0L
  }
  let marker = "\n[transcript truncated: max_log_bytes reached]\n"
  let marker_bytes = @utf8.encode(marker).length().to_int64()
  // Reserve room for the truncation marker from the start. Without this
  // reservation, a data write that exactly fills the cap would leave no room
  // for the marker and the transcript would end without saying it was cut.
  let data_cap = rt.limits.max_log_bytes - marker_bytes
  let data_remaining = data_cap - session.log_bytes.val
  if data_remaining <= 0L {
    // The cap was reached by an earlier write; spend the reservation on the
    // marker now that there is more output to describe.
    session.log_file.write(marker) catch { _ => () }
    session.log_bytes.val = session.log_bytes.val + marker_bytes
    session.log_truncated.val = true
    return 0L
  }
  let encoded = @utf8.encode(text)
  let total = encoded.length().to_int64()
  if total <= data_remaining {
    session.log_file.write(text) catch {
      _ => {
        session.log_truncated.val = true
        return 0L
      }
    }
    session.log_bytes.val = session.log_bytes.val + total
    return total
  }
  let prefix = pty_utf8_prefix(text, data_remaining.to_int())
  let prefix_bytes = @utf8.encode(prefix).length().to_int64()
  session.log_file.write(prefix) catch {
    _ => {
      session.log_truncated.val = true
      return 0L
    }
  }
  session.log_file.write(marker) catch { _ => () }
  let written = prefix_bytes + marker_bytes
  session.log_bytes.val = session.log_bytes.val + written
  session.log_truncated.val = true
  written
}

///|
/// Publish redacted terminal output: assign the next monotonic sequence,
/// append to the transcript, and keep a bounded ring of events. The event's
/// data is capped by `max_event_bytes`; `raw_bytes` reports how much output
/// it represents, and the transcript holds the full redacted data when the
/// ring or event cap cannot.
async fn pty_publish_text(
  rt : PtyRuntime,
  session : PtySession,
  text : String,
) -> Unit {
  if text == "" {
    return
  }
  let redacted = pty_redact(session, text)
  if redacted == "" {
    return
  }
  let raw_bytes = @utf8.encode(redacted).length().to_int64()
  rt.mutex.acquire()
  defer rt.mutex.release()
  let seq = session.next_seq.val + 1L
  session.next_seq.val = seq
  let log_offset = session.log_bytes.val
  let stored = pty_append_log(rt, session, redacted)
  let data = if raw_bytes > rt.limits.max_event_bytes.to_int64() {
    pty_utf8_prefix(redacted, rt.limits.max_event_bytes)
  } else {
    redacted
  }
  let data_bytes = @utf8.encode(data).length().to_int64()
  let event = {
    seq,
    data,
    raw_bytes,
    log_offset,
    log_bytes: stored,
    log_truncated: session.log_truncated.val,
  }
  session.ring.push(event)
  session.ring_bytes.val = session.ring_bytes.val + data_bytes
  let max_events = rt.limits.ring_events
  while session.ring.length() > max_events ||
    (session.ring_bytes.val > rt.limits.ring_bytes &&
      session.ring.length() > 1) {
    let removed = session.ring.remove(0)
    session.ring_bytes.val = session.ring_bytes.val -
      @utf8.encode(removed.data).length().to_int64()
    session.dropped.val = true
  }
}

///|
/// Feed a read chunk through the redaction hold-back buffer. Keeping the
/// last `max(secret_len - 1)` bytes means a secret split across two kernel
/// reads is still redacted as a unit before it reaches events or the log.
async fn pty_publish_chunk(
  rt : PtyRuntime,
  session : PtySession,
  chunk : String,
) -> Unit {
  if chunk == "" {
    return
  }
  rt.mutex.acquire()
  let combined = session.pending.val + chunk
  let hold = session.redact_hold
  if combined.length() <= hold {
    session.pending.val = combined
    rt.mutex.release()
    return
  }
  // Redact the whole combined text before splitting it. Redacting only the
  // published prefix would leave an occurrence that straddles the split
  // point as two partial, unmatched fragments.
  let redacted = pty_redact(session, combined)
  let cut = redacted.length() - hold
  let prefix = if cut > 0 {
    redacted.substring(start=0, end=cut)
  } else {
    ""
  }
  session.pending.val = if cut > 0 {
    redacted.substring(start=cut)
  } else {
    redacted
  }
  rt.mutex.release()
  if prefix != "" {
    pty_publish_text(rt, session, prefix)
  }
}

///|
async fn pty_flush_pending(rt : PtyRuntime, session : PtySession) -> Unit {
  rt.mutex.acquire()
  let pending = session.pending.val
  session.pending.val = ""
  rt.mutex.release()
  if pending != "" {
    pty_publish_text(rt, session, pending)
  }
}

///|
fn pty_status_of(session : PtySession) -> PtyStatus {
  let finalized = session.finalized.val
  let success = finalized && !session.cancel_requested.val &&
    !session.timed_out.val && session.exit_code.val == 0 &&
    session.signal.val == 0 && session.failure.val == ""
  {
    session_id: session.request.session_id,
    running: !finalized && !session.finalizing.val,
    finalized,
    success,
    cancelled: session.cancel_requested.val,
    timed_out: session.timed_out.val,
    exit_code: session.exit_code.val,
    signal: session.signal.val,
    pid: session.pid.val,
    pgid: session.pgid.val,
    rows: session.rows.val,
    cols: session.cols.val,
    output_seq: session.next_seq.val,
    output_dropped: session.dropped.val,
    log_path: session.log_path,
    log_bytes: session.log_bytes.val,
    log_truncated: session.log_truncated.val,
    residual_pids: session.residual.val,
    failure: session.failure.val,
  }
}

///|
fn pty_handle_of(session : PtySession, created : Bool) -> PtySessionHandle {
  {
    session_id: session.request.session_id,
    created,
    pid: session.pid.val,
    pgid: session.pgid.val,
    rows: session.rows.val,
    cols: session.cols.val,
    log_path: session.log_path,
  }
}

///|
async fn pty_cleanup_residual(pgid : Int) -> Array[Int] {
  if pgid <= 1 {
    return []
  }
  let mut residual = pty_scan_group(pgid)
  if residual.length() == 0 {
    return residual
  }
  pty_kill_group(pgid, 9)
  for _ in 0..<10 {
    @async.sleep(20)
    residual = pty_scan_group(pgid)
    if residual.length() == 0 {
      break
    }
  }
  residual
}

///|
async fn pty_finalize(
  rt : PtyRuntime,
  session : PtySession,
  exit_code : Int,
  failure : String,
) -> Unit {
  rt.mutex.acquire()
  if session.finalizing.val || session.finalized.val {
    rt.mutex.release()
    return
  }
  session.finalizing.val = true
  let pending = session.pending.val
  session.pending.val = ""
  let pgid = session.pgid.val
  rt.mutex.release()
  if pending != "" {
    pty_publish_text(rt, session, pending)
  }
  let residual = pty_cleanup_residual(pgid)
  rt.mutex.acquire()
  if exit_code >= 0 {
    session.exit_code.val = exit_code
    session.signal.val = 0
  } else {
    session.exit_code.val = -1
    session.signal.val = -exit_code
  }
  if failure != "" && session.failure.val == "" {
    session.failure.val = failure
  }
  session.residual.val = residual
  session.pty.val = None
  session.finalizing.val = false
  session.finalized.val = true
  let log_file = session.log_file
  rt.mutex.release()
  log_file.close()
}

///|
async fn pty_terminate(
  rt : PtyRuntime,
  session : PtySession,
  mark_cancelled : Bool,
  mark_timed_out : Bool,
) -> Unit {
  rt.mutex.acquire()
  if session.finalized.val {
    rt.mutex.release()
    return
  }
  // A child can exit (or the session task can begin its finalizer) just as
  // close/wait arrives. Finalization is not finished until `finalized` flips,
  // so record the caller's intent and wait for it instead of returning a
  // half-finalized status with no terminal event.
  let already_finalizing = session.finalizing.val
  if mark_cancelled {
    session.cancel_requested.val = true
  }
  if mark_timed_out {
    session.timed_out.val = true
  }
  let pgid = session.pgid.val
  let task = session.task.val
  rt.mutex.release()
  if !already_finalizing && pgid > 1 {
    pty_kill_group(pgid, 15)
    let grace_deadline = @async.now() + rt.limits.close_grace_ms.to_int64()
    while !pty_is_final(rt, session) && @async.now() < grace_deadline {
      @async.sleep(10)
    }
    if !pty_is_final(rt, session) {
      pty_kill_group(pgid, 9)
    }
  }
  let hard_deadline = @async.now() + rt.limits.close_timeout_ms.to_int64()
  while !pty_is_final(rt, session) && @async.now() < hard_deadline {
    @async.sleep(10)
  }
  if !pty_is_final(rt, session) {
    match task {
      Some(value) => value.cancel()
      None => ()
    }
    let cancel_deadline = @async.now() + rt.limits.close_timeout_ms.to_int64()
    while !pty_is_final(rt, session) && @async.now() < cancel_deadline {
      @async.sleep(10)
    }
  }
  if !pty_is_final(rt, session) {
    if pty_is_finalizing(rt, session) {
      // The session task's protected finalizer is already past the point
      // where `pty_finalize` would accept a second caller. Waiting for it is
      // the only way to return a truthful status; its cleanup is bounded (kill
      // the group, scan residuals) and it cannot be cancelled here.
      let _ = pty_wait_final(rt, session, 0)
    } else {
      // No finalizer is running, so force one instead of leaving a
      // half-finalized session. A finalizer that starts concurrently is a
      // no-op through the `finalizing` guard.
      pty_finalize(rt, session, -1, "session termination did not complete")
      let _ = pty_wait_final(rt, session, 0)
    }
  }
}

///|
async fn pty_session_main(
  rt : PtyRuntime,
  session : PtySession,
) -> Unit {
  @async.with_task_group(async fn(scope) -> Unit {
    scope.add_defer(() => {
      @async.protect_from_cancel() <| () => {
        rt.mutex.acquire()
        if !session.start_reported.val {
          session.start_reported.val = true
          session.start_error.val = "session ended before it started"
        }
        if !session.finalized.val && !session.finalizing.val {
          session.cancel_requested.val = true
        }
        rt.mutex.release()
        pty_finalize(rt, session, -1, "session ended before completion")
      }
    })
    let views : Array[StringView] = []
    for index in 1..<session.request.argv.length() {
      views.push(session.request.argv[index][:])
    }
    let env_map : Map[String, String] = Map([])
    for pair in session.request.env {
      env_map[pair.0] = pair.1
    }
    let pty = @pty.spawn(
      scope,
      rows=session.request.rows,
      cols=session.request.cols,
      session.request.argv[0][:],
      views,
      extra_env=env_map,
      inherit_env=false,
      cwd=session.cwd,
      no_wait=false,
    ) catch {
      _ => {
        pty_report_start_error(rt, session, "failed to start the PTY child")
        pty_finalize(rt, session, -1, "failed to start the PTY child")
        return
      }
    }
    let pid = @pty.Pty::pid(pty).to_int()
    rt.mutex.acquire()
    session.pty.val = Some(pty)
    session.pid.val = pid
    session.pgid.val = pid
      session.start_error.val = ""
    session.start_reported.val = true
    rt.mutex.release()
    let mut read_failure = ""
    while true {
      let chunk = pty.read_some(max_len=4_096) catch {
        _ => {
          read_failure = "terminal read failed"
          break
        }
      }
      match chunk {
        Some(data) => {
          if data.length() == 0 {
            break
          }
          pty_publish_chunk(rt, session, @utf8.decode_lossy(data[:]))
        }
        None => break
      }
    }
    let pgid = {
      rt.mutex.acquire()
      let value = session.pgid.val
      rt.mutex.release()
      value
    }
    if read_failure != "" {
      pty_kill_group(pgid, 15)
      @async.sleep(100)
      pty_kill_group(pgid, 9)
    }
    let code = pty.wait().to_int()
    pty_flush_pending(rt, session)
    pty_finalize(rt, session, code, read_failure)
  })
}
