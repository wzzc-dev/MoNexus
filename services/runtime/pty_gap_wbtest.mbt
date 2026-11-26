///|
async fn pty_gap_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
fn pty_gap_event_string(event : StoredEvent, name : String) -> String {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.string_field_or(object, name, "")
    None => ""
  }
}

///|
fn pty_gap_event_int64(event : StoredEvent, name : String) -> Int64 {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.int64_field_or(object, name, 0L)
    None => 0L
  }
}

///|
async fn pty_gap_events_for(
  executor : RuntimeExecutor,
  run_id : String,
) -> Array[StoredEvent] {
  let events = match executor.pending_events(2_000) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events: " + message)
  }
  let out : Array[StoredEvent] = []
  for event in events {
    if event.run_id == run_id {
      out.push(event)
    }
  }
  out
}

///|
/// Whitebox coverage for the PTY gap path (A1.1b).
///
/// The ring is deliberately smaller than the child's output, so by the time a
/// page can be read the ring has already evicted earlier sequences. Draining
/// that page must publish exactly one `runtime.pty.gap` for the missing range,
/// before the page's output events, with transcript offsets that chain into
/// them: the gap starts at the published transcript cursor, covers
/// `log_bytes`, and the next output's range starts exactly where it ends.
///
/// `pty_drain_page` is driven directly here, with no pump task competing for
/// the ring, so "evicted before the pump drained it" is a deterministic state
/// rather than the scheduling race the end-to-end test used to depend on.
async test "pty drain publishes one gap event for an evicted range" {
  let root = @fs.tmpdir(prefix="rt-pty-gap")
  defer pty_gap_cleanup(root)
  let limits = @pty_runtime.PtyLimits::new(
    max_event_bytes=64,
    ring_events=2,
    ring_bytes=4_096L,
    max_log_bytes=65_536L,
    max_input_bytes=4_096,
    spawn_timeout_ms=5_000,
    close_grace_ms=200,
    close_timeout_ms=2_000,
  )
  let executor = match
    RuntimeExecutor::open_with_limits(
      root,
      "rt-pty-gap",
      pty_limits=limits,
      git_limits=@git_runtime.GitLimits::new(),
    ) {
    Ok(value) => value
    Err(message) => fail("cannot open runtime executor: " + message)
  }
  defer executor.close()
  let script = root + "/gap.sh"
  // Six separate lines, spaced so each one is its own terminal read and
  // therefore its own ring event.
  @fs.write_file(
    script,
    "printf 'one\\n'\n" +
    "sleep 0.03\n" +
    "printf 'two\\n'\n" +
    "sleep 0.03\n" +
    "printf 'three\\n'\n" +
    "sleep 0.03\n" +
    "printf 'four\\n'\n" +
    "sleep 0.03\n" +
    "printf 'five\\n'\n" +
    "sleep 0.03\n" +
    "printf 'six\\n'\n",
    create_mode=@fs.CreateMode::CreateNew,
    permission=0o600,
    sync=@fs.SyncMode::Data,
  ) catch {
    _ => fail("cannot write the pty script")
  }
  let request = @pty_runtime.PtyOpenRequest::new(
    session_id="sess-gap",
    argv=["/bin/sh", "gap.sh"],
    cwd=root,
    env=[("PATH", "/usr/local/bin:/usr/bin:/bin")],
    rows=24,
    cols=80,
    client_request_id="req-gap",
  )
  // The primitive runs the session task itself; no executor pump is started,
  // so the ring keeps the events until this test drains them.
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    match executor.pty.open(group, request) {
      Ok(_) => ()
      Err(error) => fail("pty open failed: " + error.message)
    }
    let deadline = @async.now() + 10_000L
    while true {
      let status = match executor.pty.status("sess-gap") {
        Ok(value) => value
        Err(error) => fail("cannot read pty status: " + error.message)
      }
      if status.finalized {
        break
      }
      if @async.now() > deadline {
        fail("the pty session did not finalize")
      }
      @async.sleep(10)
    }
  })
  let page = match
    executor.pty.events(
      "sess-gap",
      after_seq=0L,
      max_events=8,
      max_bytes=1_048_576,
    ) {
    Ok(value) => value
    Err(error) => fail("cannot read pty events: " + error.message)
  }
  // ring_events=2 keeps only the two newest events; everything older is gone.
  assert_eq(page.events.length(), 2)
  let first = page.events[0]
  let last = page.events[1]
  assert_eq(page.earliest_seq, first.seq)
  assert_true(first.seq >= 3L)
  assert_eq(last.seq, first.seq + 1L)
  let before = pty_gap_events_for(executor, "sess-gap")
  assert_eq(before.length(), 0)
  // A slot that has published nothing yet starts at sequence 0 and transcript
  // offset 0, exactly as a fresh pump would.
  let slot = make_pty_slot(request, 0L, @contracts.format_rfc3339(@async.now()))
  assert_eq(slot.last_seq.val, 0L)
  match executor.pty_drain_page(slot, page) {
    Ok(_) => ()
    Err(message) => fail("pty drain failed: " + message)
  }
  let after = pty_gap_events_for(executor, "sess-gap")
  assert_eq(after.length(), 3)
  // One gap for the evicted range, then the page's output events in order.
  let gap = after[0]
  assert_eq(gap.kind, EVENT_PTY_GAP)
  assert_eq(pty_gap_event_int64(gap, "from_seq"), 1L)
  assert_eq(pty_gap_event_int64(gap, "to_seq"), first.seq - 1L)
  assert_eq(pty_gap_event_int64(gap, "log_offset"), 0L)
  assert_eq(pty_gap_event_int64(gap, "log_bytes"), first.log_offset)
  let transcript = match
    executor.pty_read_log("sess-gap", offset=0L, max_bytes=512) {
    Ok(value) => value
    Err(error) => fail("cannot read pty transcript: " + error.message)
  }
  assert_eq(pty_gap_event_string(gap, "preview"), transcript.data)
  let first_output = after[1]
  assert_eq(first_output.kind, EVENT_PTY_OUTPUT)
  assert_eq(pty_gap_event_int64(first_output, "pty_seq"), first.seq)
  assert_eq(pty_gap_event_int64(first_output, "log_offset"), first.log_offset)
  assert_eq(pty_gap_event_int64(first_output, "log_bytes"), first.log_bytes)
  let second_output = after[2]
  assert_eq(second_output.kind, EVENT_PTY_OUTPUT)
  assert_eq(pty_gap_event_int64(second_output, "pty_seq"), last.seq)
  assert_eq(pty_gap_event_int64(second_output, "log_offset"), last.log_offset)
  assert_eq(pty_gap_event_int64(second_output, "log_bytes"), last.log_bytes)
  // The slot now tracks the tail of the page, so a second drain at that
  // cursor has nothing left to publish.
  assert_eq(slot.last_seq.val, last.seq)
  assert_eq(slot.last_log_end.val, last.log_offset + last.log_bytes)
  let tail = match
    executor.pty.events("sess-gap", after_seq=slot.last_seq.val) {
    Ok(value) => value
    Err(error) => fail("cannot read the pty tail: " + error.message)
  }
  assert_eq(tail.events.length(), 0)
  match executor.pty_drain_page(slot, tail) {
    Ok(_) => ()
    Err(message) => fail("the trailing pty drain failed: " + message)
  }
  assert_eq(pty_gap_events_for(executor, "sess-gap").length(), 3)
}
