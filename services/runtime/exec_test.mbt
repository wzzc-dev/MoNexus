///|
/// Runtime execution-core tests. Every test uses a fresh temp state root and
/// removes it afterwards; nothing is written outside the temp root.
async fn test_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async fn open_test_executor(root : String) -> RuntimeExecutor {
  match RuntimeExecutor::open(root, "rt-test") {
    Ok(value) => value
    Err(message) => fail("cannot open runtime executor: " + message)
  }
}

///|
async fn start_run(
  executor : RuntimeExecutor,
  group : @async.TaskGroup[Unit],
  client_request_id : String,
  run_id : String,
  spec : CommandSpec,
) -> StartOutcome {
  match executor.start(group, client_request_id~, run_id~, spec~) {
    Ok(value) => value
    Err(message) => fail("start failed: " + message)
  }
}

///|
async fn await_terminal(executor : RuntimeExecutor, run_id : String) -> RunInfo {
  match executor.wait_for_terminal(run_id, 15_000) {
    Some(info) => info
    None => fail("run did not reach a terminal state: " + run_id)
  }
}

///|
async fn all_events(executor : RuntimeExecutor) -> Array[StoredEvent] {
  match executor.pending_events(2_000) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events: " + message)
  }
}

///|
fn event_field(event : StoredEvent, name : String) -> String {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.string_field_or(object, name, "")
    None => ""
  }
}

///|
async fn wait_until(predicate : async () -> Bool, timeout_ms : Int64) -> Bool {
  let deadline = @async.now() + timeout_ms
  while !predicate() && @async.now() < deadline {
    @async.sleep(10)
  }
  predicate()
}

///|
async fn file_mode(path : String) -> String {
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
async fn file_text(path : String) -> String {
  let data = @fs.read_file(path) catch { _ => return "" }
  data.text() catch {
    _ => ""
  }
}

///|
/// Portable liveness probe: Linux `/proc` does not exist on macOS.
async fn exec_test_pid_alive(pid : Int) -> Bool {
  if pid <= 0 {
    return false
  }
  let has_usr_bin = @fs.exists("/usr/bin/kill") catch { _ => false }
  let kill = if has_usr_bin { "/usr/bin/kill" } else { "/bin/kill" }
  let (code, _, _) = @process.collect_output(kill, ["-0", pid.to_string()]) catch {
    _ => return false
  }
  code == 0
}

///|
fn option_int(value : Int32?) -> Int32 {
  match value {
    Some(inner) => inner
    None => -1
  }
}

///|
async test "same client_request_id starts exactly one process" {
  let root = @fs.tmpdir(prefix="rt-idem")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=[
      "/bin/sh", "-c", "sleep 0.2; printf 'done\\n'",
    ])
    let first = start_run(executor, group, "req-1", "run-1", spec)
    assert_true(first.is_new())
    let duplicate = start_run(executor, group, "req-1", "run-1", spec)
    assert_true(!duplicate.is_new())
    assert_eq(duplicate.info().run_id, "run-1")
    let other = start_run(executor, group, "req-2", "run-2", spec)
    assert_true(other.is_new())
    assert_eq(other.info().run_id, "run-2")
    let info1 = await_terminal(executor, "run-1")
    let info2 = await_terminal(executor, "run-2")
    assert_eq(info1.status, @contracts.RUN_STATUS_SUCCEEDED)
    assert_eq(info2.status, @contracts.RUN_STATUS_SUCCEEDED)
    let replay = start_run(executor, group, "req-1", "run-1", spec)
    assert_true(!replay.is_new())
    assert_eq(replay.info().status, @contracts.RUN_STATUS_SUCCEEDED)
    let events = all_events(executor)
    let mut started_for_run_1 = 0
    for event in events {
      if event.run_id == "run-1" && event.kind == EVENT_EXEC_STARTED {
        started_for_run_1 = started_for_run_1 + 1
      }
    }
    inspect(started_for_run_1, content="1")
    inspect(executor.runs().length(), content="2")
  })
  executor.close()
}

///|
async test "stdout and stderr stay split and seq is monotonic" {
  let root = @fs.tmpdir(prefix="rt-streams")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=[
      "/bin/sh", "-c", "printf 'out-one\\n'; printf 'err-one\\n' 1>&2; printf 'out-two\\n'; exit 7",
    ])
    let _ = start_run(executor, group, "req-split", "run-split", spec)
    let info = await_terminal(executor, "run-split")
    assert_eq(info.status, @contracts.RUN_STATUS_FAILED)
    assert_eq(option_int(info.exit_code), 7)
    assert_eq(info.stop_reason, STOP_REASON_EXITED)
    let events = all_events(executor)
    let mut last_seq = 0L
    let mut stdout_text = ""
    let mut stderr_text = ""
    let mut last_run_seq = -1L
    for event in events {
      assert_true(event.seq > last_seq)
      last_seq = event.seq
      if event.run_id == "run-split" {
        assert_true(event.run_seq > last_run_seq)
        last_run_seq = event.run_seq
        if event.kind == EVENT_EXEC_STDOUT {
          stdout_text = stdout_text + event_field(event, "preview")
        } else if event.kind == EVENT_EXEC_STDERR {
          stderr_text = stderr_text + event_field(event, "preview")
        }
      }
    }
    assert_true(stdout_text.contains("out-one"))
    assert_true(stdout_text.contains("out-two"))
    assert_true(stderr_text.contains("err-one"))
    assert_true(!stdout_text.contains("err-one"))
    assert_true(!stderr_text.contains("out-one"))
    let log_dir = executor.state_root() + "/logs/run-split"
    assert_eq(file_text(log_dir + "/stdout.log"), "out-one\nout-two\n")
    assert_eq(file_text(log_dir + "/stderr.log"), "err-one\n")
  })
  executor.close()
}

///|
async test "stdin is passed to the child and closed" {
  let root = @fs.tmpdir(prefix="rt-stdin")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=["/bin/cat"], stdin=Some("hello-stdin\n"))
    let _ = start_run(executor, group, "req-stdin", "run-stdin", spec)
    let info = await_terminal(executor, "run-stdin")
    assert_eq(info.status, @contracts.RUN_STATUS_SUCCEEDED)
    let log = file_text(executor.state_root() + "/logs/run-stdin/stdout.log")
    assert_eq(log, "hello-stdin\n")
  })
  executor.close()
}

///|
async test "output is bounded and truncation is reported once" {
  let root = @fs.tmpdir(prefix="rt-bounded")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(
      argv=[
        "/bin/sh", "-c", "i=0; while [ $i -lt 400 ]; do printf a; i=$((i+1)); done; printf '\\ntail\\n'",
      ],
      max_output_bytes=64,
    )
    let _ = start_run(executor, group, "req-bound", "run-bound", spec)
    let info = await_terminal(executor, "run-bound")
    assert_true(info.truncated_stdout)
    assert_eq(info.stdout_bytes, 64L)
    let log_path = executor.state_root() + "/logs/run-bound/stdout.log"
    let size = @fs.file_size(log_path) catch { _ => -1L }
    assert_true(size >= 0L && size <= 64L)
    let events = all_events(executor)
    let mut truncation_events = 0
    for event in events {
      if event.run_id == "run-bound" &&
        event.kind == EVENT_EXEC_TRUNCATED &&
        event_field(event, "stream") == "stdout" {
        truncation_events = truncation_events + 1
      }
    }
    inspect(truncation_events, content="1")
  })
  executor.close()
}

///|
async test "cancel terminates the process tree and never reports success" {
  let root = @fs.tmpdir(prefix="rt-cancel")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  let pid_path = executor.state_root() + "/work/cancel.pid"
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=[
      "/bin/sh", "-c", "printf '%d' $$ > cancel.pid; sleep 30",
    ])
    let _ = start_run(executor, group, "req-cancel", "run-cancel", spec)
    let appeared = wait_until(
      async fn() -> Bool { @fs.exists(pid_path) catch { _ => false } },
      3_000,
    )
    assert_true(appeared)
    let pid = @string.parse_int(file_text(pid_path)) catch { _ => -1 }
    assert_true(pid > 0)
    let info = match executor.cancel("run-cancel") {
      Ok(value) => value
      Err(message) => fail("cancel failed: " + message)
    }
    assert_eq(info.status, @contracts.RUN_STATUS_CANCELLED)
    assert_eq(info.stop_reason, STOP_REASON_CANCELLED)
    let terminal = await_terminal(executor, "run-cancel")
    assert_eq(terminal.status, @contracts.RUN_STATUS_CANCELLED)
    let gone = wait_until(
      async fn() -> Bool { !exec_test_pid_alive(pid) },
      3_000,
    )
    assert_true(gone)
  })
  executor.close()
}

///|
async test "timeout is reported as cancelled, never success" {
  let root = @fs.tmpdir(prefix="rt-timeout")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  let pid_path = executor.state_root() + "/work/timeout.pid"
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(
      argv=["/bin/sh", "-c", "printf '%d' $$ > timeout.pid; sleep 30"],
      timeout_ms=200,
    )
    let _ = start_run(executor, group, "req-timeout", "run-timeout", spec)
    let info = await_terminal(executor, "run-timeout")
    assert_eq(info.status, @contracts.RUN_STATUS_CANCELLED)
    assert_eq(info.stop_reason, STOP_REASON_TIMEOUT)
    assert_true(info.timed_out)
    let pid = @string.parse_int(file_text(pid_path)) catch { _ => -1 }
    assert_true(pid > 0)
    let gone = wait_until(
      async fn() -> Bool { !exec_test_pid_alive(pid) },
      3_000,
    )
    assert_true(gone)
  })
  executor.close()
}

///|
async test "secrets are redacted in logs and events" {
  let root = @fs.tmpdir(prefix="rt-secrets")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let rooted = match RootedDir::open(executor.state_root() + "/work") {
      Ok(value) => value
      Err(message) => fail("cannot open work root: " + message)
    }
    let secret_text = "password=hunter2\nsk-abcdefghijklmnop\nplain line\n"
    match rooted.write_text("input.txt", secret_text) {
      Ok(_) => ()
      Err(message) => fail("cannot write fixture: " + message)
    }
    let spec = CommandSpec::new(argv=["/bin/cat", "input.txt"], env=[
      EnvPair::new("SERVICE_TOKEN", "envsecretvalue"),
    ])
    let _ = start_run(executor, group, "req-secret", "run-secret", spec)
    let info = await_terminal(executor, "run-secret")
    assert_eq(info.status, @contracts.RUN_STATUS_SUCCEEDED)
    let log = file_text(executor.state_root() + "/logs/run-secret/stdout.log")
    assert_true(!log.contains("hunter2"))
    assert_true(!log.contains("sk-abcdefghijklmnop"))
    assert_true(log.contains("[redacted]"))
    for event in all_events(executor) {
      let encoded = event.payload.stringify()
      assert_true(!encoded.contains("hunter2"))
      assert_true(!encoded.contains("sk-abcdefghijklmnop"))
      assert_true(!encoded.contains("envsecretvalue"))
    }
  })
  executor.close()
}

///|
async test "unexecutable program is recorded as failed, never success" {
  let root = @fs.tmpdir(prefix="rt-spawnfail")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  let not_executable = executor.state_root() + "/work/not-executable.txt"
  @fs.write_file(not_executable, "not a program", permission=0o644) catch {
    _ => fail("cannot write fixture")
  }
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=[not_executable])
    // The failure can surface either as a spawn error (start returns Err) or
    // as a non-zero exit of the launcher; both must end as failed.
    match
      executor.start(
        group,
        client_request_id="req-fail",
        run_id="run-fail",
        spec~,
      ) {
      Ok(_) => ()
      Err(_) => ()
    }
    let info = match executor.wait_for_terminal("run-fail", 5_000) {
      Some(value) => value
      None => fail("failed run has no terminal state")
    }
    assert_eq(info.status, @contracts.RUN_STATUS_FAILED)
    assert_true(
      info.stop_reason == STOP_REASON_SPAWN_FAILED ||
      info.stop_reason == STOP_REASON_EXITED,
    )
    let retry = start_run(executor, group, "req-fail", "run-fail", spec)
    assert_true(!retry.is_new())
    assert_eq(retry.info().status, @contracts.RUN_STATUS_FAILED)
  })
  executor.close()
}

///|
async test "restart resumes from the acked cursor without redelivery" {
  let root = @fs.tmpdir(prefix="rt-restart")
  defer test_cleanup(root)
  let first = open_test_executor(root)
  let max_seq = Ref(0L)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=["/bin/sh", "-c", "printf 'persisted\\n'"])
    let _ = start_run(first, group, "req-restart", "run-restart", spec)
    let info = await_terminal(first, "run-restart")
    assert_eq(info.status, @contracts.RUN_STATUS_SUCCEEDED)
    for event in all_events(first) {
      if event.seq > max_seq.val {
        max_seq.val = event.seq
      }
    }
    assert_true(max_seq.val > 0L)
    match first.ack_through(max_seq.val) {
      Ok(_) => ()
      Err(message) => fail("ack failed: " + message)
    }
    assert_eq(first.cursor(), max_seq.val)
  })
  first.close()
  let second = open_test_executor(root)
  assert_eq(second.cursor(), max_seq.val)
  let pending = all_events(second)
  inspect(pending.length(), content="0")
  let recovered = match second.status("run-restart") {
    Some(value) => value
    None => fail("recovered run is missing")
  }
  assert_eq(recovered.status, @contracts.RUN_STATUS_SUCCEEDED)
  assert_eq(option_int(recovered.exit_code), 0)
  match second.ack_through(max_seq.val) {
    Ok(_) => ()
    Err(message) => fail("repeat ack failed: " + message)
  }
  assert_eq(second.cursor(), max_seq.val)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=["/bin/sh", "-c", "printf 'after\\n'"])
    let _ = start_run(second, group, "req-after", "run-after", spec)
    let info = await_terminal(second, "run-after")
    assert_eq(info.status, @contracts.RUN_STATUS_SUCCEEDED)
    let events = all_events(second)
    assert_true(events.length() > 0)
    assert_true(events[0].seq > max_seq.val)
    assert_eq(events[0].run_seq, 0L)
  })
  second.close()
}

///|
async test "state root, run log dir and stream logs have private modes" {
  let root = @fs.tmpdir(prefix="rt-modes")
  defer test_cleanup(root)
  let executor = open_test_executor(root)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec = CommandSpec::new(argv=["/usr/bin/true"])
    let _ = start_run(executor, group, "req-mode", "run-mode", spec)
    let _ = await_terminal(executor, "run-mode")
    assert_eq(file_mode(executor.state_root()), "700")
    let logs = executor.state_root() + "/logs"
    let run_logs = logs + "/run-mode"
    assert_eq(file_mode(logs), "700")
    assert_eq(file_mode(run_logs), "700")
    assert_eq(file_mode(run_logs + "/stdout.log"), "600")
    assert_eq(file_mode(run_logs + "/stderr.log"), "600")
    assert_eq(file_mode(executor.state_root() + "/outbox.db"), "600")
  })
  executor.close()
}
