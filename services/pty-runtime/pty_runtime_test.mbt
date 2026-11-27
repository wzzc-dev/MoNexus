///|
fn pty_test_env(extra : Array[(String, String)]) -> Array[(String, String)] {
  let path = match @env.get_env_var("PATH") {
    Some(value) if value != "" => value
    _ => "/usr/bin:/bin"
  }
  let env : Array[(String, String)] = [
    ("PATH", path),
    ("TERM", "xterm-256color"),
    ("LC_ALL", "C"),
  ]
  for pair in extra {
    env.push(pair)
  }
  env
}

///|
async fn pty_test_runtime(
  state : String,
  limits : PtyLimits,
) -> PtyRuntime {
  match PtyRuntime::new_with_limits(state, limits) {
    Ok(value) => value
    Err(error) => fail("cannot create PTY runtime: " + error.message)
  }
}

///|
async fn[X] pty_test_open(
  rt : PtyRuntime,
  group : @async.TaskGroup[X],
  session_id : String,
  argv : Array[String],
  cwd : String,
  env : Array[(String, String)],
  request_id : String,
  rows : Int32,
  cols : Int32,
) -> PtySessionHandle {
  let request = PtyOpenRequest::new(
    session_id=session_id,
    argv=argv,
    cwd=cwd,
    env=env,
    rows=rows,
    cols=cols,
    client_request_id=request_id,
  )
  match rt.open(group, request) {
    Ok(value) => value
    Err(error) => fail("cannot open PTY session: " + error.message)
  }
}

///|
async fn pty_test_events_text(
  rt : PtyRuntime,
  session_id : String,
  after_seq : Int64,
) -> (String, Int64) {
  let page = match
    rt.events(
      session_id,
      after_seq=after_seq,
      max_events=4_096,
      max_bytes=1_048_576,
    ) {
    Ok(value) => value
    Err(error) => fail("cannot read PTY events: " + error.message)
  }
  let mut text = ""
  let mut next_seq = after_seq
  for event in page.events {
    text = text + event.data
    next_seq = event.seq
  }
  (text, next_seq)
}

///|
async fn pty_test_wait_text(
  rt : PtyRuntime,
  session_id : String,
  needle : String,
  timeout_ms : Int,
) -> (String, Int64) {
  let deadline = @async.now() + timeout_ms.to_int64()
  let mut text = ""
  let mut seq = 0L
  while @async.now() < deadline {
    let (chunk, next_seq) = pty_test_events_text(rt, session_id, seq)
    text = text + chunk
    seq = next_seq
    if text.contains(needle) {
      return (text, seq)
    }
    @async.sleep(20)
  }
  fail("timed out waiting for " + needle + "; output was: " + text)
}

///|
async fn pty_test_wait(
  rt : PtyRuntime,
  session_id : String,
) -> PtyStatus {
  match rt.wait(session_id, timeout_ms=15_000) {
    Ok(value) => value
    Err(error) => fail("cannot wait for PTY session: " + error.message)
  }
}

///|
async fn pty_test_read_log(
  rt : PtyRuntime,
  session_id : String,
) -> String {
  let mut text = ""
  let mut offset = 0L
  while true {
    let slice = match rt.read_log(session_id, offset=offset, max_bytes=65_536) {
      Ok(value) => value
      Err(error) => fail("cannot read PTY transcript: " + error.message)
    }
    text = text + slice.data
    offset = offset + slice.bytes
    if slice.eof || slice.bytes == 0L {
      break
    }
  }
  text
}

///|
async fn pty_test_mode(path : String) -> String {
  let (code, out, _) = @process.collect_output("stat", ["-c", "%a", path]) catch {
    _ => return ""
  }
  if code == 0 {
    return out.text().trim().to_owned()
  }
  // BSD/macOS stat spelling; GNU stat exits non-zero above.
  let (fallback_code, fallback_out, _) = @process.collect_output("stat", [
    "-f", "%Lp", path,
  ]) catch {
    _ => return ""
  }
  if fallback_code != 0 {
    return ""
  }
  fallback_out.text().trim().to_owned()
}

///|
async fn pty_test_proc_exists(pid : Int) -> Bool {
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
async fn pty_test_wait_proc_gone(pid : Int, timeout_ms : Int) -> Bool {
  let deadline = @async.now() + timeout_ms.to_int64()
  while @async.now() < deadline {
    if !pty_test_proc_exists(pid) {
      return true
    }
    @async.sleep(20)
  }
  !pty_test_proc_exists(pid)
}

///|
fn pty_test_digits_after(text : String, marker : String) -> Int? {
  let start = match text.find(marker) {
    Some(index) => index + marker.length()
    None => return None
  }
  let view = text[:]
  let mut end = start
  while end < view.length() {
    let code = view.at(end).to_int()
    if code < 48 || code > 57 {
      break
    }
    end = end + 1
  }
  if end == start {
    return None
  }
  let mut value = 0
  for index in start..<end {
    let code = view.at(index).to_int()
    value = value * 10 + (code - 48)
  }
  Some(value)
}

///|
async test "open, resize, input, output and close round-trip" {
  let dir = @fs.tmpdir(prefix="monexus-pty-basic-")
  defer @fs.rmdir(dir, recursive=true)
  let state = dir + "/state"
  let rt = pty_test_runtime(state, PtyLimits::new())
  @async.with_task_group(async fn(group) -> Unit {
    let handle = pty_test_open(
      rt,
      group,
      "sess-basic",
      ["/bin/sh"],
      dir,
      pty_test_env([]),
      "req-basic",
      24,
      80,
    )
    assert_true(handle.created)
    assert_true(handle.pid > 0)
    assert_eq(handle.pgid, handle.pid)
    assert_eq(handle.rows, 24)
    assert_eq(handle.cols, 80)
    match rt.resize("sess-basic", 30, 100) {
      Ok(_) => ()
      Err(error) => fail("resize failed: " + error.message)
    }
    let resized = match rt.status("sess-basic") {
      Ok(value) => value
      Err(error) => fail("status failed: " + error.message)
    }
    assert_eq(resized.rows, 30)
    assert_eq(resized.cols, 100)
    assert_true(resized.running)
    match rt.input("sess-basic", "stty size\n") {
      Ok(_) => ()
      Err(error) => fail("input failed: " + error.message)
    }
    let (text, _) = pty_test_wait_text(rt, "sess-basic", "30 100", 5_000)
    assert_true(text.contains("30 100"))
    let page = match
      rt.events("sess-basic", after_seq=0L, max_events=256, max_bytes=65_536) {
      Ok(value) => value
      Err(error) => fail("events failed: " + error.message)
    }
    let mut previous = 0L
    for event in page.events {
      assert_true(event.seq > previous)
      previous = event.seq
    }
    let status = match rt.close("sess-basic") {
      Ok(value) => value
      Err(error) => fail("close failed: " + error.message)
    }
    assert_true(status.finalized)
    assert_true(status.cancelled)
    assert_true(!status.success)
    assert_true(!status.running)
    assert_eq(status.residual_pids.length(), 0)
    assert_true(pty_test_wait_proc_gone(handle.pid, 3_000))
    let transcript = pty_test_read_log(rt, "sess-basic")
    assert_true(transcript.contains("30 100"))
    assert_true(transcript.contains("stty size"))
    assert_eq(pty_test_mode(state), "700")
    assert_eq(pty_test_mode(rt.sessions_root()), "700")
    assert_eq(pty_test_mode(rt.sessions_root() + "/sess-basic"), "700")
    assert_eq(pty_test_mode(handle.log_path), "600")
  })
}

///|
async test "a duplicate open key returns the existing session and does not spawn twice" {
  let dir = @fs.tmpdir(prefix="monexus-pty-idempotent-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = pty_test_runtime(
    dir + "/state",
    PtyLimits::new(spawn_timeout_ms=5_000),
  )
  @async.with_task_group(async fn(group) -> Unit {
    let env = pty_test_env([])
    let first = pty_test_open(
      rt,
      group,
      "sess-dup",
      ["/bin/cat"],
      dir,
      env,
      "req-dup",
      24,
      80,
    )
    assert_true(first.created)
    let second = pty_test_open(
      rt,
      group,
      "sess-dup",
      ["/bin/cat"],
      dir,
      env,
      "req-dup",
      24,
      80,
    )
    assert_true(!second.created)
    assert_eq(second.pid, first.pid)
    let sessions = rt.list_sessions()
    assert_eq(sessions.length(), 1)
    let different_body = rt.open(
      group,
      PtyOpenRequest::new(
        session_id="sess-dup",
        argv=["/bin/cat", "-u"],
        cwd=dir,
        env=env,
        client_request_id="req-dup",
      ),
    )
    let conflict = match different_body {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::Conflict
    }
    assert_true(conflict)
    let same_request_id = rt.open(
      group,
      PtyOpenRequest::new(
        session_id="sess-other",
        argv=["/bin/cat"],
        cwd=dir,
        env=env,
        client_request_id="req-dup",
      ),
    )
    let request_conflict = match same_request_id {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::Conflict
    }
    assert_true(request_conflict)
    assert_eq(rt.list_sessions().length(), 1)
    let _ = rt.close("sess-dup")
  })
}

///|
async test "output events and the transcript stay bounded and ordered" {
  let dir = @fs.tmpdir(prefix="monexus-pty-bounded-")
  defer @fs.rmdir(dir, recursive=true)
  let limits = PtyLimits::new(
    max_event_bytes=64,
    ring_events=4,
    ring_bytes=1_024L,
    max_log_bytes=1_024L,
    max_input_bytes=32,
    spawn_timeout_ms=5_000,
    close_grace_ms=200,
    close_timeout_ms=2_000,
  )
  let rt = pty_test_runtime(dir + "/state", limits)
  @async.with_task_group(async fn(group) -> Unit {
    let request = PtyOpenRequest::new(
      session_id="sess-bounded",
      argv=[
        "/bin/sh",
        "-c",
        "i=0; while [ $i -lt 300 ]; do echo line-$i; i=$((i+1)); done",
      ],
      cwd=dir,
      env=pty_test_env([]),
      client_request_id="req-bounded",
    )
    let handle = match rt.open(group, request) {
      Ok(value) => value
      Err(error) => fail("open failed: " + error.message)
    }
    assert_true(handle.created)
    let status = pty_test_wait(rt, "sess-bounded")
    assert_true(status.finalized)
    assert_true(status.success)
    assert_true(status.output_seq > 0L)
    // Eviction is only required once more events were published than the
    // four-event ring can hold; a fast child can deliver all output in fewer
    // large reads, which legitimately fills the ring without dropping.
    assert_true(status.output_seq <= 4L || status.output_dropped)
    assert_true(status.log_truncated)
    assert_true(status.log_bytes <= 1_024L)
    let page = match
      rt.events("sess-bounded", after_seq=0L, max_events=2, max_bytes=1_048_576) {
      Ok(value) => value
      Err(error) => fail("events failed: " + error.message)
    }
    assert_true(page.events.length() > 0)
    assert_true(page.events.length() <= 2)
    let mut previous = 0L
    for event in page.events {
      assert_true(event.seq > previous)
      assert_true(@utf8.encode(event.data).length() <= 64)
      previous = event.seq
    }
    assert_true(status.output_seq <= 4L || page.dropped)
    assert_true(page.earliest_seq > 0L)
    let byte_page = match
      rt.events(
        "sess-bounded",
        after_seq=0L,
        max_events=1_000,
        max_bytes=64,
      ) {
      Ok(value) => value
      Err(error) => fail("bounded events failed: " + error.message)
    }
    let mut bytes = 0
    for event in byte_page.events {
      bytes = bytes + @utf8.encode(event.data).length()
    }
    assert_true(byte_page.events.length() > 0)
    assert_true(bytes <= 64)
    let tail = match
      rt.events(
        "sess-bounded",
        after_seq=status.output_seq,
        max_events=10,
        max_bytes=1_048_576,
      ) {
      Ok(value) => value
      Err(error) => fail("tail events failed: " + error.message)
    }
    assert_eq(tail.events.length(), 0)
    assert_eq(tail.next_seq, status.output_seq)
    let transcript = pty_test_read_log(rt, "sess-bounded")
    assert_true(transcript.contains("line-0"))
    assert_true(!transcript.contains("line-299"))
    assert_true(transcript.contains("transcript truncated"))
    let mut oversized = ""
    for _ in 0..<33 {
      oversized = oversized + "x"
    }
    let too_large = rt.input("sess-bounded", oversized)
    let rejected = match too_large {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::InvalidArgument
    }
    assert_true(rejected)
  })
}

///|
async test "close terminates the process tree and reports no residual pids" {
  let dir = @fs.tmpdir(prefix="monexus-pty-tree-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = pty_test_runtime(
    dir + "/state",
    PtyLimits::new(close_grace_ms=200, close_timeout_ms=2_000),
  )
  @async.with_task_group(async fn(group) -> Unit {
    let handle = pty_test_open(
      rt,
      group,
      "sess-tree",
      ["/bin/sh", "-c", "sleep 300 & echo TREE_$!; sleep 300"],
      dir,
      pty_test_env([]),
      "req-tree",
      24,
      80,
    )
    let (text, _) = pty_test_wait_text(rt, "sess-tree", "TREE_", 5_000)
    let child_pid = match pty_test_digits_after(text, "TREE_") {
      Some(value) => value
      None => fail("did not see the background child pid: " + text)
    }
    assert_true(child_pid > 0)
    let status = match rt.close("sess-tree") {
      Ok(value) => value
      Err(error) => fail("close failed: " + error.message)
    }
    assert_true(status.finalized)
    assert_true(status.cancelled)
    assert_true(!status.success)
    assert_eq(status.residual_pids.length(), 0)
    assert_true(pty_test_wait_proc_gone(handle.pid, 3_000))
    assert_true(pty_test_wait_proc_gone(child_pid, 3_000))
  })
}

///|
async test "a timed-out wait is never reported as success" {
  let dir = @fs.tmpdir(prefix="monexus-pty-timeout-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = pty_test_runtime(
    dir + "/state",
    PtyLimits::new(close_grace_ms=200, close_timeout_ms=2_000),
  )
  @async.with_task_group(async fn(group) -> Unit {
    let handle = pty_test_open(
      rt,
      group,
      "sess-timeout",
      ["/bin/sh", "-c", "sleep 300"],
      dir,
      pty_test_env([]),
      "req-timeout",
      24,
      80,
    )
    let status = match rt.wait("sess-timeout", timeout_ms=250) {
      Ok(value) => value
      Err(error) => fail("wait failed: " + error.message)
    }
    assert_true(status.finalized)
    assert_true(status.timed_out)
    assert_true(!status.success)
    assert_true(!status.cancelled)
    assert_true(status.signal != 0)
    assert_eq(status.residual_pids.length(), 0)
    assert_true(pty_test_wait_proc_gone(handle.pid, 3_000))
  })
}

///|
async test "environment, cwd and argv are validated and secrets are redacted" {
  let dir = @fs.tmpdir(prefix="monexus-pty-secure-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.mkdir(dir + "/.ssh", permission=0o700, allow_exist=true)
  let ssh_state = match PtyRuntime::new(dir + "/.ssh/state") {
    Ok(_) => {
      assert_true(false)
      return
    }
    Err(error) => error
  }
  assert_true(ssh_state.kind is PtyErrorKind::StateDir)
  let rt = pty_test_runtime(dir + "/state", PtyLimits::new())
  @async.with_task_group(async fn(group) -> Unit {
    let base = pty_test_env([])
    let ssh_cwd = rt.open(
      group,
      PtyOpenRequest::new(
        session_id="sess-ssh-cwd",
        argv=["/usr/bin/true"],
        cwd=dir + "/.ssh",
        env=base,
      ),
    )
    let cwd_rejected = match ssh_cwd {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::InvalidArgument
    }
    assert_true(cwd_rejected)
    let ssh_env : Array[(String, String)] = []
    for pair in base {
      ssh_env.push(pair)
    }
    ssh_env.push(("SSH_AUTH_SOCK", "/tmp/agent.sock"))
    let ssh_env_result = rt.open(
      group,
      PtyOpenRequest::new(
        session_id="sess-ssh-env",
        argv=["/usr/bin/true"],
        cwd=dir,
        env=ssh_env,
      ),
    )
    let env_rejected = match ssh_env_result {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::InvalidArgument
    }
    assert_true(env_rejected)
    let duplicate_env : Array[(String, String)] = [("DUP", "1"), ("DUP", "2")]
    let duplicate = rt.open(
      group,
      PtyOpenRequest::new(
        session_id="sess-dup-env",
        argv=["/usr/bin/true"],
        cwd=dir,
        env=duplicate_env,
      ),
    )
    let duplicate_rejected = match duplicate {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::InvalidArgument
    }
    assert_true(duplicate_rejected)
    let empty_argv = rt.open(
      group,
      PtyOpenRequest::new(session_id="sess-empty-argv", argv=[], cwd=dir),
    )
    let argv_rejected = match empty_argv {
      Ok(_) => false
      Err(error) => error.kind is PtyErrorKind::InvalidArgument
    }
    assert_true(argv_rejected)
    let secret = "SUPER_SECRET_TOKEN_1234567890"
    let secret_env = pty_test_env([("API_TOKEN", secret), ("MARKER", "visible")])
    let secret_handle = pty_test_open(
      rt,
      group,
      "sess-secret",
      ["/bin/sh", "-c", "echo $API_TOKEN"],
      dir,
      secret_env,
      "req-secret",
      24,
      80,
    )
    let secret_status = pty_test_wait(rt, "sess-secret")
    assert_true(secret_status.success)
    let (secret_events, _) = pty_test_events_text(rt, "sess-secret", 0L)
    assert_true(secret_events.contains("[redacted]"))
    assert_true(!secret_events.contains(secret))
    let secret_log = pty_test_read_log(rt, "sess-secret")
    assert_true(secret_log.contains("[redacted]"))
    assert_true(!secret_log.contains(secret))
    let env_handle = pty_test_open(
      rt,
      group,
      "sess-allowlist",
      ["/bin/sh", "-c", "env"],
      dir,
      pty_test_env([("MARKER", "visible")]),
      "req-allowlist",
      24,
      80,
    )
    let env_status = pty_test_wait(rt, "sess-allowlist")
    assert_true(env_status.success)
    let (env_out, _) = pty_test_events_text(rt, "sess-allowlist", 0L)
    assert_true(env_out.contains("MARKER=visible"))
    assert_true(env_out.contains("PATH="))
    assert_true(!env_out.contains("HOME="))
    assert_true(!env_out.contains("SSH_AUTH_SOCK"))
    let _ = env_handle
    let _ = secret_handle
  })
}
