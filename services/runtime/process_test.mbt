///|
/// Streaming-process runtime tests (A1.4). Every test uses a fresh temp state
/// root; processes are argv-only and cancelled through the runtime, never by
/// sending text to a shell.

///|
async fn process_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
async fn process_executor(root : String) -> RuntimeExecutor {
  match RuntimeExecutor::open(root, "rt-process") {
    Ok(value) => value
    Err(message) => fail("cannot open runtime executor: " + message)
  }
}

///|
async fn process_wait(
  runtime : ProcessRuntime,
  run_id : String,
  timeout_ms : Int64,
) -> ProcessInfo {
  let deadline = @async.now() + timeout_ms
  while @async.now() < deadline {
    match runtime.exit(run_id) {
      Ok(info) =>
        if info.status != @contracts.RUN_STATUS_RUNNING {
          return info
        }
      Err(_) => ()
    }
    @async.sleep(10)
  }
  fail("process did not settle: " + run_id)
}

///|
async fn chunk_text(runtime : ProcessRuntime, run_id : String, stream : String) -> String {
  let mut offset = 0L
  let mut text = ""
  while true {
    let chunk = match runtime.read_stream(run_id, stream, offset, 32_768) {
      Ok(value) => value
      Err(message) => fail("cannot read " + stream + ": " + message)
    }
    if chunk.data_b64 != "" {
      let bytes = @base64.decode(chunk.data_b64) catch {
        _ => fail("invalid base64 chunk")
      }
      text = text + bytes_to_text(bytes)
    }
    offset = chunk.next_offset
    if chunk.eof {
      return text
    }
    if chunk.gap || chunk.dropped {
      fail(stream + " stream lost bytes before the test read it")
    }
    if chunk.data_b64 == "" {
      @async.sleep(5)
    }
  }
  text
}

///|
fn bytes_to_text(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes[:], ignore_bom=false)
}

///|
async test "process start streams stdout/stderr/exit and is argv-only" {
  let root = @fs.tmpdir(prefix="rt-proc-stream")
  defer process_cleanup(root)
  let executor = process_executor(root)
  let runtime = executor.process()
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = ProcessSpec::new(argv=[
      "/bin/sh", "-c", "printf 'hello'; printf 'oops' >&2; exit 3",
    ])
    let (info, existing) = match
      runtime.start(group, client_request_id="crid-stream", run_id="proc-stream", spec~) {
      Ok(value) => value
      Err(message) => fail("start failed: " + message)
    }
    assert_true(!existing)
    assert_eq(info.status, @contracts.RUN_STATUS_RUNNING)
    let done = process_wait(runtime, "proc-stream", 10_000L)
    assert_eq(done.status, @contracts.RUN_STATUS_FAILED)
    assert_eq(done.exit_code, Some(3))
    assert_eq(done.stop_reason, "exited")
    assert_eq(chunk_text(runtime, "proc-stream", "stdout"), "hello")
    assert_eq(chunk_text(runtime, "proc-stream", "stderr"), "oops")
  })
}

///|
async test "same client_request_id starts exactly one streaming process" {
  let root = @fs.tmpdir(prefix="rt-proc-idem")
  defer process_cleanup(root)
  let executor = process_executor(root)
  let runtime = executor.process()
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = ProcessSpec::new(argv=["/bin/sh", "-c", "sleep 0.2"])
    let (first, first_existing) = match
      runtime.start(group, client_request_id="crid-1", run_id="proc-1", spec~) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    let (second, second_existing) = match
      runtime.start(group, client_request_id="crid-1", run_id="proc-1", spec~) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    assert_true(!first_existing)
    assert_true(second_existing)
    assert_eq(first.pid, second.pid)
    assert_eq(runtime.processes().length(), 1)
    let _ = process_wait(runtime, "proc-1", 10_000L)
  })
}

///|
async test "process stdin reaches the child and cancel settles the run" {
  let root = @fs.tmpdir(prefix="rt-proc-stdin")
  defer process_cleanup(root)
  let executor = process_executor(root)
  let runtime = executor.process()
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = ProcessSpec::new(argv=["/bin/sh", "-c", "cat"])
    let (_info, _existing) = match
      runtime.start(group, client_request_id="crid-stdin", run_id="proc-stdin", spec~) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    match runtime.write_stdin("proc-stdin", @utf8.encode("ping\n")) {
      Ok(_) => ()
      Err(message) => fail("stdin write failed: " + message)
    }
    // The child echoes the line on stdout without a newline requirement.
    let deadline = @async.now() + 10_000L
    let mut seen = false
    while !seen && @async.now() < deadline {
      let chunk = match runtime.read_stream("proc-stdin", "stdout", 0L, 32_768) {
        Ok(value) => value
        Err(_) => fail("cannot read stdout")
      }
      if chunk.data_b64 != "" {
        let bytes = @base64.decode(chunk.data_b64) catch {
          _ => fail("invalid base64")
        }
        if bytes_to_text(bytes).contains("ping") {
          seen = true
        }
      }
      if !seen {
        @async.sleep(10)
      }
    }
    assert_true(seen)
    let cancelled = match runtime.cancel("proc-stdin") {
      Ok(value) => value
      Err(message) => fail("cancel failed: " + message)
    }
    assert_eq(cancelled.status, @contracts.RUN_STATUS_CANCELLED)
    assert_eq(cancelled.stop_reason, "cancelled")
  })
}

///|
async test "process cancel kills the process group" {
  let root = @fs.tmpdir(prefix="rt-proc-group")
  defer process_cleanup(root)
  let executor = process_executor(root)
  let runtime = executor.process()
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = ProcessSpec::new(argv=[
      "/bin/sh", "-c", "sleep 30 & echo $! > child.pid; wait",
    ])
    let (_info, _existing) = match
      runtime.start(group, client_request_id="crid-group", run_id="proc-group", spec~) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    let pid_path = root + "/work/child.pid"
    let deadline = @async.now() + 10_000L
    while !(@fs.exists(pid_path) catch { _ => false }) &&
      @async.now() < deadline {
      @async.sleep(10)
    }
    let pid_text = @fs.read_file(pid_path).text() catch {
      _ => fail("child pid file was not written")
    }
    let child_pid = pid_text.trim().to_owned()
    assert_true(child_pid != "")
    let _ = match runtime.cancel("proc-group") {
      Ok(value) => value
      Err(message) => fail(message)
    }
    @async.sleep(300)
    let code = @process.run(
      "/bin/sh",
      ["-c", "kill -0 " + child_pid + " 2>/dev/null"],
    ) catch {
      _ => -1
    }
    assert_true(code != 0)
  })
}

///|
async test "process timeout cancels and marks timed_out" {
  let root = @fs.tmpdir(prefix="rt-proc-timeout")
  defer process_cleanup(root)
  let executor = process_executor(root)
  let runtime = executor.process()
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = ProcessSpec::new(
      argv=["/bin/sh", "-c", "sleep 10"],
      timeout_ms=150L,
    )
    let (_info, _existing) = match
      runtime.start(
        group,
        client_request_id="crid-timeout",
        run_id="proc-timeout",
        spec~,
      ) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    let done = process_wait(runtime, "proc-timeout", 10_000L)
    assert_eq(done.status, @contracts.RUN_STATUS_CANCELLED)
    assert_eq(done.stop_reason, "timeout")
    assert_true(done.timed_out)
  })
}

///|
async test "node restart marks a started process lost, not succeeded" {
  let root = @fs.tmpdir(prefix="rt-proc-recover")
  defer process_cleanup(root)
  let state = match RuntimeState::open(root) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let (outbox, _events) = match Outbox::open(state, "rt-process") {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let runtime = ProcessRuntime::new(outbox, state.work_dir(), ProcessLimits::new())
  let started_at = "2026-01-01T00:00:00.000Z"
  let payload = @contracts.json_object([
    ("run_id", @contracts.json_string("proc-lost")),
    ("run_seq", @contracts.json_int64(0L)),
    ("kind", @contracts.json_string(EVENT_PROCESS_STARTED)),
    ("client_request_id", @contracts.json_string("crid-lost")),
    ("argv", @contracts.json_string_array(["cat"])),
    ("cwd", @contracts.json_string("")),
    ("risk", @contracts.json_string(@contracts.RISK_MEDIUM)),
    ("started_at", @contracts.json_string(started_at)),
  ])
  let event : StoredEvent = {
    seq: 1L,
    run_seq: 0L,
    run_id: "proc-lost",
    kind: EVENT_PROCESS_STARTED,
    ts: started_at,
    payload,
  }
  match runtime.recover([event]) {
    Ok(_) => ()
    Err(message) => fail("recover failed: " + message)
  }
  let info = match runtime.exit("proc-lost") {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(info.status, @contracts.RUN_STATUS_LOST)
  assert_eq(info.stop_reason, "host_restarted")
  assert_eq(info.exit_code, None)
  // The recovered run is closed: reads report EOF and no bytes, never a
  // fabricated success.
  let chunk = match runtime.read_stream("proc-lost", "stdout", 0L, 1_024) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_true(chunk.eof)
  assert_eq(chunk.data_b64, "")
}

///|
async test "process events carry env names but never env values" {
  let root = @fs.tmpdir(prefix="rt-proc-env")
  defer process_cleanup(root)
  let executor = process_executor(root)
  let runtime = executor.process()
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = ProcessSpec::new(
      argv=["/usr/bin/env"],
      env=[EnvPair::new("MONEXUS_TEST_TOKEN", "sk-test-value-123")],
      inherit_env=[],
    )
    let (_info, _existing) = match
      runtime.start(group, client_request_id="crid-env", run_id="proc-env", spec~) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    let done = process_wait(runtime, "proc-env", 10_000L)
    assert_eq(done.status, @contracts.RUN_STATUS_SUCCEEDED)
    let out = chunk_text(runtime, "proc-env", "stdout")
    // The explicit env pair reaches the child; nothing is inherited from the
    // test process (the node's own environment is allowlisted separately).
    assert_true(out.contains("MONEXUS_TEST_TOKEN=sk-test-value-123"))
    assert_true(!out.contains("PATH="))
    let events = match executor.pending_events(64) {
      Ok(value) => value
      Err(message) => fail("cannot read events: " + message)
    }
    let mut started_payload = ""
    for event in events {
      if event.run_id == "proc-env" && event.kind == EVENT_PROCESS_STARTED {
        started_payload = event.payload.stringify()
      }
    }
    assert_true(started_payload != "")
    // Durable events name the environment, never its values.
    assert_true(started_payload.contains("\"MONEXUS_TEST_TOKEN\""))
    assert_true(!started_payload.contains("sk-test-value-123"))
  })
}
