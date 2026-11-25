///|
/// PTY crash recovery is tested from inside the package so the test can seed
/// the same durable `runtime.pty.opened` event the executor writes before it
/// spawns the session, then reopen the executor as a restarted process would.
async fn pty_recovery_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async fn pty_recovery_count(
  executor : RuntimeExecutor,
  run_id : String,
  kind : String,
) -> Int {
  let events = match executor.pending_events(2_000) {
    Ok(value) => value
    Err(message) => fail("cannot read events: " + message)
  }
  let mut count = 0
  for event in events {
    if event.run_id == run_id && event.kind == kind {
      count = count + 1
    }
  }
  count
}

///|
async fn pty_recovery_terminal_field(
  executor : RuntimeExecutor,
  run_id : String,
  field : String,
) -> String {
  let events = match executor.pending_events(2_000) {
    Ok(value) => value
    Err(message) => fail("cannot read events: " + message)
  }
  for event in events {
    if event.run_id == run_id && event.kind == EVENT_PTY_EXITED {
      match @contracts.as_object(event.payload) {
        Some(object) => return @contracts.string_field_or(object, field, "")
        None => return ""
      }
    }
  }
  ""
}

///|
async test "restart finalizes an interrupted pty session as lost exactly once" {
  let root = @fs.tmpdir(prefix="rt-pty-recovery")
  defer pty_recovery_cleanup(root)
  let state = match RuntimeState::open(root) {
    Ok(value) => value
    Err(message) => fail("cannot open state: " + message)
  }
  let (outbox, _) = match Outbox::open(state, "rt-pty-recovery") {
    Ok(value) => value
    Err(message) => fail("cannot open outbox: " + message)
  }
  let started_at = @contracts.format_rfc3339(@async.now())
  let entries : Array[(String, @json.Json)] = [
    ("client_request_id", @contracts.json_string("req-crash")),
    ("argv", @contracts.json_string_array(["/bin/sh"])),
    ("cwd", @contracts.json_string("")),
    ("rows", @contracts.json_int(24)),
    ("cols", @contracts.json_int(80)),
    ("env_names", @contracts.json_string_array(["PATH"])),
    ("log_rel", @contracts.json_string("")),
    ("started_at", @contracts.json_string(started_at)),
  ]
  match outbox.append("sess-crash", EVENT_PTY_OPENED, entries) {
    Ok(_) => ()
    Err(message) => fail("cannot seed pty opened event: " + message)
  }
  outbox.close()
  let first = match RuntimeExecutor::open(root, "rt-pty-recovery") {
    Ok(value) => value
    Err(message) => fail("cannot reopen executor: " + message)
  }
  assert_eq(
    pty_recovery_count(first, "sess-crash", EVENT_PTY_EXITED),
    1,
  )
  let info = match first.pty_status("sess-crash") {
    Ok(value) => value
    Err(error) => fail("cannot read recovered status: " + error.message)
  }
  assert_true(info.finalized)
  assert_eq(info.status, @contracts.RUN_STATUS_LOST)
  assert_eq(
    pty_recovery_terminal_field(first, "sess-crash", "stop_reason"),
    STOP_REASON_HOST_RESTARTED,
  )
  assert_true(!info.success)
  assert_eq(info.client_request_id, "req-crash")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let existing = match
      first.pty_open(
        group,
        session_id="sess-crash",
        client_request_id="req-crash",
        argv=["/bin/sh"],
      ) {
      Ok(value) => value
      Err(error) => fail("reopening a recovered session failed: " + error.message)
    }
    assert_true(!existing.is_new())
    assert_true(existing.info().finalized)
    assert_eq(existing.info().status, @contracts.RUN_STATUS_LOST)
    match
      first.pty_open(
        group,
        session_id="sess-crash",
        client_request_id="req-other",
        argv=["/bin/sh"],
      ) {
      Ok(_) => fail("a conflicting recovered request must be rejected")
      Err(error) => {
        assert_eq(error.code, @contracts.ERR_HOST)
        assert_eq(error.kind, "conflict")
      }
    }
  })
  assert_eq(pty_recovery_count(first, "sess-crash", EVENT_PTY_OPENED), 1)
  assert_eq(pty_recovery_count(first, "sess-crash", EVENT_PTY_EXITED), 1)
  match first.pty_input("sess-crash", "echo hi\n") {
    Ok(_) => fail("a recovered session must not accept input")
    Err(error) => assert_eq(error.kind, "already_closed")
  }
  match first.pty_resize("sess-crash", rows=30, cols=100) {
    Ok(_) => fail("a recovered session must not accept a resize")
    Err(error) => assert_eq(error.kind, "already_closed")
  }
  let listed = first.pty_list()
  let mut found = false
  for entry in listed {
    if entry.session_id == "sess-crash" {
      found = true
      assert_true(entry.finalized)
      assert_eq(entry.status, @contracts.RUN_STATUS_LOST)
    }
  }
  assert_true(found)
  first.close()
  let second = match RuntimeExecutor::open(root, "rt-pty-recovery") {
    Ok(value) => value
    Err(message) => fail("cannot reopen executor a second time: " + message)
  }
  assert_eq(pty_recovery_count(second, "sess-crash", EVENT_PTY_EXITED), 1)
  let reopened_info = match second.pty_status("sess-crash") {
    Ok(value) => value
    Err(error) => fail("cannot read recovered status again: " + error.message)
  }
  assert_eq(reopened_info.status, @contracts.RUN_STATUS_LOST)
  assert_eq(
    pty_recovery_terminal_field(second, "sess-crash", "stop_reason"),
    STOP_REASON_HOST_RESTARTED,
  )
  match second.pty_close("sess-crash") {
    Ok(info) => {
      assert_true(info.finalized)
      assert_true(!info.success)
    }
    Err(error) => fail("closing a recovered session failed: " + error.message)
  }
  assert_eq(pty_recovery_count(second, "sess-crash", EVENT_PTY_EXITED), 1)
  second.close()
}
