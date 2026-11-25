///|
/// Crash recovery is tested from inside the package so the test can write the
/// same durable `runtime.exec.started` event the executor writes before it
/// spawns, then reopen the executor as a restarted process would.
async fn recovery_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async fn count_events(
  executor : RuntimeExecutor,
  run_id : String,
  kind : String,
) -> Int32 {
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
async test "restart finalizes an interrupted run as lost exactly once" {
  let root = @fs.tmpdir(prefix="rt-recovery")
  defer recovery_cleanup(root)
  let state = match RuntimeState::open(root) {
    Ok(value) => value
    Err(message) => fail("cannot open state: " + message)
  }
  let (outbox, _) = match Outbox::open(state, "rt-recovery") {
    Ok(value) => value
    Err(message) => fail("cannot open outbox: " + message)
  }
  let entries : Array[(String, @json.Json)] = [
    ("client_request_id", @contracts.json_string("req-crash")),
    ("argv", @contracts.json_string_array(["/bin/sleep", "30"])),
    ("cwd", @contracts.json_string("")),
    ("risk", @contracts.json_string(@contracts.RISK_MEDIUM)),
    ("timeout_ms", @contracts.json_int(60_000)),
    ("max_output_bytes", @contracts.json_int(1_024)),
    ("env_names", @contracts.json_string_array([])),
    ("has_stdin", @contracts.json_bool(false)),
    (
      "started_at",
      @contracts.json_string(@contracts.format_rfc3339(@async.now())),
    ),
  ]
  match outbox.append("run-crash", EVENT_EXEC_STARTED, entries) {
    Ok(_) => ()
    Err(message) => fail("cannot seed started event: " + message)
  }
  outbox.close()
  let executor = match RuntimeExecutor::open(root, "rt-recovery") {
    Ok(value) => value
    Err(message) => fail("cannot reopen executor: " + message)
  }
  let info = match executor.status("run-crash") {
    Some(value) => value
    None => fail("recovered run is missing")
  }
  assert_eq(info.status, @contracts.RUN_STATUS_LOST)
  assert_eq(info.stop_reason, STOP_REASON_HOST_RESTARTED)
  assert_eq(info.client_request_id, "req-crash")
  let terminal_events = count_events(executor, "run-crash", EVENT_EXEC_EXITED)
  inspect(terminal_events, content="1")
  executor.close()
  // A second restart must not append another terminal event for the run.
  let again = match RuntimeExecutor::open(root, "rt-recovery") {
    Ok(value) => value
    Err(message) => fail("cannot reopen executor again: " + message)
  }
  let again_info = match again.status("run-crash") {
    Some(value) => value
    None => fail("recovered run is missing after second restart")
  }
  assert_eq(again_info.status, @contracts.RUN_STATUS_LOST)
  let again_terminal = count_events(again, "run-crash", EVENT_EXEC_EXITED)
  inspect(again_terminal, content="1")
  again.close()
}
