///|
async fn pty_test_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async fn pty_open_executor(root : String, runtime_id : String) -> RuntimeExecutor {
  match RuntimeExecutor::open(root, runtime_id) {
    Ok(value) => value
    Err(message) => fail("cannot open runtime executor: " + message)
  }
}

///|
fn pty_test_env() -> Array[(String, String)] {
  [("PATH", "/usr/local/bin:/usr/bin:/bin"), ("TERM", "xterm-256color")]
}

///|
async fn pty_events_for(
  executor : RuntimeExecutor,
  session_id : String,
) -> Array[StoredEvent] {
  let events = match executor.pending_events(4_000) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events: " + message)
  }
  let out : Array[StoredEvent] = []
  for event in events {
    if event.run_id == session_id {
      out.push(event)
    }
  }
  out
}

///|
fn pty_event_string(event : StoredEvent, name : String) -> String {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.string_field_or(object, name, "")
    None => ""
  }
}

///|
fn pty_event_int(event : StoredEvent, name : String) -> Int {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.int_field_or(object, name, 0)
    None => 0
  }
}

///|
fn pty_event_int64(event : StoredEvent, name : String) -> Int64 {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.int64_field_or(object, name, 0L)
    None => 0L
  }
}

///|
fn pty_event_bool(event : StoredEvent, name : String) -> Bool {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.bool_field_or(object, name, false)
    None => false
  }
}

///|
async fn pty_wait_until(
  predicate : async () -> Bool,
  timeout_ms : Int64,
) -> Bool {
  let deadline = @async.now() + timeout_ms
  while !predicate() && @async.now() < deadline {
    @async.sleep(10)
  }
  predicate()
}

///|
async fn pty_read_log_all(
  executor : RuntimeExecutor,
  session_id : String,
) -> String {
  let mut text = ""
  let mut offset = 0L
  while true {
    let slice = match
      executor.pty_read_log(session_id, offset~, max_bytes=65_536) {
      Ok(value) => value
      Err(error) => fail("cannot read pty transcript: " + error.message)
    }
    text = text + slice.data
    if slice.eof || slice.bytes == 0L {
      break
    }
    offset = offset + slice.bytes
  }
  text
}

///|
fn pty_count_kind(events : Array[StoredEvent], kind : String) -> Int {
  let mut count = 0
  for event in events {
    if event.kind == kind {
      count = count + 1
    }
  }
  count
}

///|
async fn pty_file_mode(path : String) -> String {
  let has_usr_bin = @fs.exists("/usr/bin/stat") catch { _ => false }
  let stat = if has_usr_bin { "/usr/bin/stat" } else { "/bin/stat" }
  let code_and_output = @process.collect_output(stat, ["-c", "%a", path]) catch {
    _ => return "stat-failed"
  }
  let (code, output, _) = code_and_output
  if code != 0 {
    // BSD/macOS stat spelling; GNU stat exits non-zero above.
    let fallback = @process.collect_output(stat, ["-f", "%Lp", path]) catch {
      _ => return "stat-failed"
    }
    let (fallback_code, fallback_output, _) = fallback
    if fallback_code != 0 {
      return "stat-failed"
    }
    let fallback_text = fallback_output.text() catch { _ => "" }
    return fallback_text.trim().to_owned()
  }
  let text = output.text() catch { _ => "" }
  text.trim().to_owned()
}

///|
async fn pty_process_alive(pid : Int) -> Bool {
  if pid <= 0 {
    return false
  }
  let has_usr_bin = @fs.exists("/usr/bin/kill") catch { _ => false }
  let kill = if has_usr_bin { "/usr/bin/kill" } else { "/bin/kill" }
  let (code, _, _) = @process.collect_output(
    kill,
    ["-0", pid.to_string()],
  ) catch {
    _ => return false
  }
  code == 0
}

///|
async fn pty_open_shell(
  executor : RuntimeExecutor,
  group : @async.TaskGroup[Unit],
  session_id : String,
  request_id : String,
  argv : Array[String],
) -> PtySessionInfo {
  match
    executor.pty_open(
      group,
      session_id~,
      client_request_id=request_id,
      argv~,
      env=pty_test_env(),
    ) {
    Ok(outcome) => outcome.info()
    Err(error) => fail("pty_open failed: " + error.message)
  }
}

///|
async test "pty open, input, resize and close are published through the outbox" {
  let root = @fs.tmpdir(prefix="rt-pty-basic")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-basic")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let opened = pty_open_shell(
      executor,
      group,
      "sess-basic",
      "req-basic",
      ["/bin/sh"],
    )
    assert_true(opened.created)
    assert_eq(opened.status, @contracts.RUN_STATUS_RUNNING)
    assert_true(opened.pid > 0)
    match executor.pty_input("sess-basic", "printf 'pty-hello\\n'\n") {
      Ok(_) => ()
      Err(error) => fail("pty input failed: " + error.message)
    }
    let saw = pty_wait_until(
      async fn() {
        let text = pty_read_log_all(executor, "sess-basic")
        text.contains("pty-hello")
      },
      5_000,
    )
    assert_true(saw)
    match executor.pty_resize("sess-basic", rows=40, cols=120) {
      Ok(_) => ()
      Err(error) => fail("pty resize failed: " + error.message)
    }
    let status = match executor.pty_status("sess-basic") {
      Ok(value) => value
      Err(error) => fail("pty status failed: " + error.message)
    }
    assert_eq(status.rows, 40)
    assert_eq(status.cols, 120)
    let closed = match executor.pty_close("sess-basic") {
      Ok(value) => value
      Err(error) => fail("pty close failed: " + error.message)
    }
    assert_true(closed.finalized)
    assert_true(closed.cancelled)
    assert_true(!closed.success)
    assert_eq(closed.status, @contracts.RUN_STATUS_CANCELLED)
    let events = pty_events_for(executor, "sess-basic")
    assert_true(events.length() >= 3)
    assert_eq(events[0].kind, EVENT_PTY_OPENED)
    assert_eq(events[0].run_seq, 0L)
    assert_eq(events[events.length() - 1].kind, EVENT_PTY_EXITED)
    let mut expected_run_seq = 0L
    for event in events {
      assert_eq(event.run_seq, expected_run_seq)
      expected_run_seq = expected_run_seq + 1
    }
    let terminal = events[events.length() - 1]
    assert_eq(pty_event_string(terminal, "status"), @contracts.RUN_STATUS_CANCELLED)
    assert_eq(pty_event_string(terminal, "stop_reason"), STOP_REASON_CANCELLED)
    assert_true(!pty_event_bool(terminal, "success"))
    let transcript = pty_read_log_all(executor, "sess-basic")
    assert_true(transcript.contains("pty-hello"))
    inspect(pty_count_kind(events, EVENT_PTY_EXITED), content="1")
  })
  executor.close()
}

///|
async test "duplicate pty open never spawns a second process" {
  let root = @fs.tmpdir(prefix="rt-pty-idem")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-idem")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let first = pty_open_shell(
      executor,
      group,
      "sess-idem",
      "req-idem",
      ["/bin/sh"],
    )
    assert_true(first.created)
    let duplicate = match
      executor.pty_open(
        group,
        session_id="sess-idem",
        client_request_id="req-idem",
        argv=["/bin/sh"],
        env=pty_test_env(),
      ) {
      Ok(value) => value
      Err(error) => fail("duplicate open failed: " + error.message)
    }
    assert_true(!duplicate.is_new())
    assert_eq(duplicate.info().pid, first.pid)
    match
      executor.pty_open(
        group,
        session_id="sess-idem",
        client_request_id="req-idem",
        argv=["/bin/sh", "-c", "sleep 5"],
        env=pty_test_env(),
      ) {
      Ok(_) => fail("a conflicting body must not open a second session")
      Err(error) => assert_eq(error.kind, "conflict")
    }
    match
      executor.pty_open(
        group,
        session_id="sess-idem",
        client_request_id="req-other",
        argv=["/bin/sh"],
        env=pty_test_env(),
      ) {
      Ok(_) => fail("a conflicting request must not open a second session")
      Err(error) => assert_eq(error.kind, "conflict")
    }
    let events = pty_events_for(executor, "sess-idem")
    inspect(pty_count_kind(events, EVENT_PTY_OPENED), content="1")
    match executor.pty_close("sess-idem") {
      Ok(_) => ()
      Err(error) => fail("pty close failed: " + error.message)
    }
    inspect(pty_count_kind(pty_events_for(executor, "sess-idem"), EVENT_PTY_EXITED), content="1")
  })
  executor.close()
}

///|
async test "pty transcript replay covers ring eviction with no seq gap" {
  let root = @fs.tmpdir(prefix="rt-pty-gap")
  defer pty_test_cleanup(root)
  let limits = @pty_runtime.PtyLimits::new(
    max_event_bytes=64,
    ring_events=1,
    ring_bytes=1_024L,
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
    Err(message) => fail("cannot open executor: " + message)
  }
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let script = "sleep 0.3; i=0; while [ $i -lt 400 ]; do printf 'chunk-%03d-abcdefghijklmnopqrstuvwxyz\\n' $i; i=$((i+1)); done"
    let _ = pty_open_shell(
      executor,
      group,
      "sess-gap",
      "req-gap",
      ["/bin/sh", "-c", script],
    )
    let waited = match executor.pty_wait("sess-gap", timeout_ms=15_000) {
      Ok(value) => value
      Err(error) => fail("pty wait failed: " + error.message)
    }
    assert_true(waited.finalized)
    assert_true(waited.success)
    assert_eq(waited.status, @contracts.RUN_STATUS_SUCCEEDED)
    let events = pty_events_for(executor, "sess-gap")
    assert_eq(events[0].kind, EVENT_PTY_OPENED)
    assert_eq(events[events.length() - 1].kind, EVENT_PTY_EXITED)
    let terminal = events[events.length() - 1]
    let terminal_output_seq = pty_event_int64(terminal, "output_seq")
    assert_true(terminal_output_seq > 0L)
    let mut replay = ""
    let mut next_seq = 1L
    let mut gap_count = 0
    let mut output_count = 0
    for event in events {
      if event.kind == EVENT_PTY_OUTPUT {
        assert_eq(pty_event_int64(event, "pty_seq"), next_seq)
        next_seq = next_seq + 1L
        output_count = output_count + 1
        let offset = pty_event_int64(event, "log_offset")
        let length = pty_event_int64(event, "log_bytes")
        if length > 0L {
          let slice = match
            executor.pty_read_log(
              "sess-gap",
              offset=offset,
              max_bytes=length.to_int(),
            ) {
            Ok(value) => value
            Err(error) =>
              fail("cannot replay output from transcript: " + error.message)
          }
          replay = replay + slice.data
        }
      } else if event.kind == EVENT_PTY_GAP {
        gap_count = gap_count + 1
        let from_seq = pty_event_int64(event, "from_seq")
        let to_seq = pty_event_int64(event, "to_seq")
        assert_eq(from_seq, next_seq)
        assert_true(to_seq >= from_seq)
        next_seq = to_seq + 1L
        let offset = pty_event_int64(event, "log_offset")
        let length = pty_event_int64(event, "log_bytes")
        if length > 0L {
          let slice = match
            executor.pty_read_log(
              "sess-gap",
              offset=offset,
              max_bytes=length.to_int(),
            ) {
            Ok(value) => value
            Err(error) =>
              fail("cannot replay gap from transcript: " + error.message)
          }
          replay = replay + slice.data
        }
      }
    }
    assert_eq(next_seq - 1L, terminal_output_seq)
    assert_true(gap_count > 0)
    assert_true(output_count > 0)
    assert_true(replay.contains("chunk-000"))
    assert_true(replay.contains("chunk-399"))
    let transcript = pty_read_log_all(executor, "sess-gap")
    assert_true(transcript.contains("chunk-000"))
    assert_true(transcript.contains("chunk-399"))
  })
  executor.close()
}

///|
async test "pty timeout terminates the process group and never succeeds" {
  let root = @fs.tmpdir(prefix="rt-pty-timeout")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-timeout")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let opened = pty_open_shell(
      executor,
      group,
      "sess-timeout",
      "req-timeout",
      ["/bin/sh", "-c", "sleep 30"],
    )
    let pid = opened.pid
    assert_true(pid > 0)
    let status = match executor.pty_wait("sess-timeout", timeout_ms=200) {
      Ok(value) => value
      Err(error) => fail("pty wait failed: " + error.message)
    }
    assert_true(status.finalized)
    assert_true(status.timed_out)
    assert_true(!status.success)
    assert_eq(status.status, @contracts.RUN_STATUS_CANCELLED)
    assert_eq(status.residual_pids.length(), 0)
    let alive = pty_process_alive(pid)
    assert_true(!alive)
    let events = pty_events_for(executor, "sess-timeout")
    let terminal = events[events.length() - 1]
    assert_eq(terminal.kind, EVENT_PTY_EXITED)
    assert_eq(pty_event_string(terminal, "stop_reason"), STOP_REASON_TIMEOUT)
    assert_true(!pty_event_bool(terminal, "success"))
    inspect(pty_count_kind(events, EVENT_PTY_EXITED), content="1")
  })
  executor.close()
}

///|
async test "pty close kills a long-running session and records cancellation" {
  let root = @fs.tmpdir(prefix="rt-pty-close")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-close")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let opened = pty_open_shell(
      executor,
      group,
      "sess-close",
      "req-close",
      ["/bin/sh", "-c", "sleep 30"],
    )
    let pid = opened.pid
    let closed = match executor.pty_close("sess-close") {
      Ok(value) => value
      Err(error) => fail("pty close failed: " + error.message)
    }
    assert_true(closed.cancelled)
    assert_true(!closed.success)
    let alive = pty_process_alive(pid)
    assert_true(!alive)
    let events = pty_events_for(executor, "sess-close")
    let terminal = events[events.length() - 1]
    assert_eq(terminal.kind, EVENT_PTY_EXITED)
    assert_eq(pty_event_string(terminal, "status"), @contracts.RUN_STATUS_CANCELLED)
    assert_true(!pty_event_bool(terminal, "success"))
  })
  executor.close()
}

///|
async test "pty_close_all finalizes every session at shutdown" {
  let root = @fs.tmpdir(prefix="rt-pty-closeall")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-closeall")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let _ = pty_open_shell(
      executor,
      group,
      "sess-a",
      "req-a",
      ["/bin/sh", "-c", "sleep 30"],
    )
    let _ = pty_open_shell(
      executor,
      group,
      "sess-b",
      "req-b",
      ["/bin/sh", "-c", "sleep 30"],
    )
    let closed = match executor.pty_close_all() {
      Ok(value) => value
      Err(error) => fail("pty_close_all failed: " + error.message)
    }
    assert_eq(closed.length(), 2)
    for info in closed {
      assert_true(info.finalized)
      assert_true(info.cancelled)
      assert_true(!info.success)
    }
    for session_id in ["sess-a", "sess-b"] {
      let events = pty_events_for(executor, session_id)
      inspect(pty_count_kind(events, EVENT_PTY_EXITED), content="1")
      let terminal = events[events.length() - 1]
      assert_eq(terminal.kind, EVENT_PTY_EXITED)
      assert_true(!pty_event_bool(terminal, "success"))
    }
    let listed = executor.pty_list()
    assert_true(listed.length() >= 2)
  })
  executor.close()
}

///|
async test "pty transcript and events redact secret-named env values" {
  let root = @fs.tmpdir(prefix="rt-pty-redact")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-redact")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let args : Array[String] = [
      "/bin/sh", "-c", "printf '%s\\n' \"$API_TOKEN\"",
    ]
    let env : Array[(String, String)] = [
      ("PATH", "/usr/local/bin:/usr/bin:/bin"),
      ("API_TOKEN", "sk-supersecret-value-123"),
    ]
    let outcome = match
      executor.pty_open(
        group,
        session_id="sess-redact",
        client_request_id="req-redact",
        argv=args,
        env~,
      ) {
      Ok(value) => value
      Err(error) => fail("pty open failed: " + error.message)
    }
    assert_true(outcome.is_new())
    let waited = match executor.pty_wait("sess-redact") {
      Ok(value) => value
      Err(error) => fail("pty wait failed: " + error.message)
    }
    assert_true(waited.success)
    let transcript = pty_read_log_all(executor, "sess-redact")
    assert_true(transcript.contains("[redacted]"))
    assert_true(!transcript.contains("sk-supersecret-value-123"))
    let events = pty_events_for(executor, "sess-redact")
    for event in events {
      let data = pty_event_string(event, "data")
      let preview = pty_event_string(event, "preview")
      let failure = pty_event_string(event, "failure")
      assert_true(!data.contains("sk-supersecret-value-123"))
      assert_true(!preview.contains("sk-supersecret-value-123"))
      assert_true(!failure.contains("sk-supersecret-value-123"))
    }
    let session_root = executor.state_root() + "/pty"
    let instances = @fs.readdir(session_root) catch {
      _ => fail("cannot list pty state")
    }
    assert_true(instances.length() > 0)
    let instance_dir = session_root + "/" + instances[0]
    let session_dir = instance_dir + "/sess-redact"
    assert_eq(pty_file_mode(session_dir), "700")
    assert_eq(pty_file_mode(session_dir + "/transcript.log"), "600")
  })
  executor.close()
}

///|
async test "ack and restart do not redeliver pty events" {
  let root = @fs.tmpdir(prefix="rt-pty-ack")
  defer pty_test_cleanup(root)
  let executor = pty_open_executor(root, "rt-pty-ack")
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let _ = pty_open_shell(
      executor,
      group,
      "sess-ack",
      "req-ack",
      ["/bin/sh", "-c", "printf 'ack-output\\n'"],
    )
    let _ = match executor.pty_wait("sess-ack") {
      Ok(value) => value
      Err(error) => fail("pty wait failed: " + error.message)
    }
    let events = pty_events_for(executor, "sess-ack")
    assert_true(events.length() > 0)
    let last_seq = events[events.length() - 1].seq
    match executor.ack_through(last_seq) {
      Ok(_) => ()
      Err(message) => fail("ack failed: " + message)
    }
  })
  let before = match executor.pending_events(100) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events: " + message)
  }
  inspect(before.length(), content="0")
  let cursor = executor.cursor()
  executor.close()
  let reopened = match RuntimeExecutor::open(root, "rt-pty-ack") {
    Ok(value) => value
    Err(message) => fail("cannot reopen executor: " + message)
  }
  assert_eq(reopened.cursor(), cursor)
  let after = match reopened.pending_events(100) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events after restart: " + message)
  }
  inspect(after.length(), content="0")
  let info = match reopened.pty_status("sess-ack") {
    Ok(value) => value
    Err(error) => fail("cannot read recovered pty status: " + error.message)
  }
  assert_eq(info.status, @contracts.RUN_STATUS_SUCCEEDED)
  reopened.close()
}
