///|
/// Pure primary-side provider tests: event tracking, dedupe/cursor semantics,
/// reconnect reconciliation and probe/profile decoding. They do not open
/// sockets; the transport-level behaviour is covered by
/// `services/runtime-node/host_e2e_test.mbt`.

///|
fn test_event(
  seq : Int64,
  run_id : String,
  run_seq : Int64,
  kind : String,
  payload : @json.Json,
) -> @transport.WireEvent {
  {
    seq,
    run_id,
    run_seq,
    kind,
    ts: @transport.wire_ts(0L),
    payload,
    hash: "",
  }
}

///|
fn test_terminal_payload(status : String, exit_code : Int) -> @json.Json {
  @contracts.json_object([
    ("status", @contracts.json_string(status)),
    ("exit_code", @contracts.json_int(exit_code)),
    ("stop_reason", @contracts.json_string("exited")),
    ("ended_at", @contracts.json_string("2026-01-01T00:00:00Z")),
  ])
}

///|
test "run tracker dedupes per-run seq and never settles from silence" {
  let tracker = RunTracker::new("rt-test")
  tracker.begin("run-1", "exec", "req-1")
  assert_eq(tracker.length(), 1)
  assert_eq(
    tracker.get("run-1").unwrap().phase.text(),
    "pending",
  )
  let started = test_event(
    1L,
    "run-1",
    1L,
    "runtime.exec.started",
    @contracts.json_null(),
  )
  assert_true(tracker.observe(started))
  assert_eq(tracker.get("run-1").unwrap().phase.text(), "running")
  assert_eq(tracker.cursor(), 1L)
  // Same event replayed: dropped, cursor does not move, phase does not reset.
  assert_true(!tracker.observe(started))
  assert_eq(tracker.cursor(), 1L)
  let stdout = test_event(
    2L,
    "run-1",
    2L,
    "runtime.exec.stdout",
    @contracts.json_null(),
  )
  assert_true(tracker.observe(stdout))
  assert_eq(tracker.cursor(), 2L)
  let exited = test_event(
    3L,
    "run-1",
    3L,
    "runtime.exec.exited",
    test_terminal_payload(@contracts.RUN_STATUS_SUCCEEDED, 0),
  )
  assert_true(tracker.observe(exited))
  let run = tracker.get("run-1").unwrap()
  assert_eq(run.phase.text(), "succeeded")
  assert_eq(run.exit_code, Some(0))
  assert_eq(run.stop_reason, "exited")
  // A late duplicate of the terminal event must not re-settle or rewind.
  assert_true(!tracker.observe(exited))
  assert_eq(tracker.cursor(), 3L)
  // Connection loss leaves settled runs alone.
  assert_eq(tracker.mark_connection_lost(), 0)
  assert_true(tracker.is_interrupted())
  tracker.mark_connection_restored()
  assert_true(!tracker.is_interrupted())
}

///|
test "run tracker marks active runs interrupted and reconciles on reconnect" {
  let tracker = RunTracker::new("rt-test")
  tracker.begin("run-2", "exec", "req-2")
  let started = test_event(
    1L,
    "run-2",
    1L,
    "runtime.exec.started",
    @contracts.json_null(),
  )
  assert_true(tracker.observe(started))
  let changed = tracker.mark_connection_lost()
  assert_eq(changed, 1)
  assert_eq(tracker.get("run-2").unwrap().phase.text(), "interrupted")
  // More output while disconnected means the run never stopped executing;
  // the event brings it back to running under the same run id.
  let resumed = test_event(
    2L,
    "run-2",
    2L,
    "runtime.exec.stdout",
    @contracts.json_null(),
  )
  assert_true(tracker.observe(resumed))
  assert_eq(tracker.get("run-2").unwrap().phase.text(), "running")
  tracker.mark_connection_restored()
  let same = tracker.reconcile_status(
    "run-2",
    @contracts.RUN_STATUS_RUNNING,
    None,
  )
  assert_true(!same)
  assert_true(
    tracker.reconcile_status(
      "run-2",
      @contracts.RUN_STATUS_SUCCEEDED,
      Some(0),
    )
  )
  assert_eq(tracker.get("run-2").unwrap().phase.text(), "succeeded")
  assert_eq(tracker.get("run-2").unwrap().exit_code, Some(0))
  // A status answer for an unknown run is ignored, never invented.
  let missing = tracker.reconcile_status(
    "run-missing",
    @contracts.RUN_STATUS_SUCCEEDED,
    None,
  )
  assert_true(!missing)
}

///|
test "run tracker is bounded" {
  let tracker = RunTracker::new("rt-test")
  let mut index = 0
  while index < MAX_TRACKED_RUNS + 16 {
    tracker.begin("run-" + index.to_string(), "exec", "req-" + index.to_string())
    index = index + 1
  }
  assert_eq(tracker.length(), MAX_TRACKED_RUNS)
  assert_true(tracker.get("run-0") is None)
  assert_true(
    tracker.get("run-" + (MAX_TRACKED_RUNS + 15).to_string()) is Some(_),
  )
}

///|
test "runtime probe decodes and converts to a machine profile" {
  let json = @contracts.json_object([
    ("runtime_id", @contracts.json_string("rt-1")),
    ("transport_version", @contracts.json_string("1.0")),
    ("protocol_version", @contracts.json_int(1)),
    (
      "capabilities",
      @contracts.json_string_array(["exec", "fs", "pty", "git"]),
    ),
    (
      "workspace_roots",
      @contracts.json_string_array(["/home/user/ws"]),
    ),
    (
      "platform",
      @contracts.json_object([
        ("os", @contracts.json_string("Linux")),
        ("arch", @contracts.json_string("x86_64")),
        ("hostname", @contracts.json_string("box")),
      ]),
    ),
    ("policy", @contracts.json_string("snapshot")),
    ("state_version", @contracts.json_int(1)),
  ])
  let probe = RuntimeProbe::from_json(json).unwrap()
  assert_eq(probe.runtime_id, "rt-1")
  assert_eq(probe.transport_version, "1.0")
  assert_eq(probe.protocol_version, 1)
  assert_eq(probe.capabilities, ["exec", "fs", "pty", "git"])
  assert_eq(probe.workspace_roots, ["/home/user/ws"])
  assert_eq(probe.os, "Linux")
  assert_eq(probe.arch, "x86_64")
  assert_eq(probe.hostname, "box")
  assert_eq(probe.policy, "snapshot")
  let profile = probe.machine_profile()
  assert_eq(profile.max_parallel, 1)
  assert_eq(profile.os, "Linux")
  assert_eq(profile.arch, "x86_64")
  assert_true(profile.notes.contains("capabilities=exec,fs,pty,git"))
  assert_true(profile.notes.contains("workspace_roots=/home/user/ws"))
  // Malformed profiles are rejected rather than half-decoded.
  assert_true(RuntimeProbe::from_json(@contracts.json_string("x")) is None)
  assert_true(
    RuntimeProbe::from_json(
      @contracts.json_object([("transport_version", @contracts.json_string("1.0"))]),
    )
    is None,
  )
}

///|
test "run and pty snapshots decode the node wire shape" {
  let run = RunSnapshot::from_json(
    @contracts.json_object([
      ("run_id", @contracts.json_string("run-1")),
      ("client_request_id", @contracts.json_string("req-1")),
      ("status", @contracts.json_string("succeeded")),
      ("exit_code", @contracts.json_int(0)),
      ("signal", @contracts.json_null()),
      ("stop_reason", @contracts.json_string("exited")),
      ("ended_at", @contracts.json_string("2026-01-01T00:00:00Z")),
      ("timed_out", @contracts.json_bool(false)),
      ("stdout_bytes", @contracts.json_int64(4L)),
      ("stderr_bytes", @contracts.json_int64(0L)),
    ]),
  ).unwrap()
  assert_eq(run.run_id, "run-1")
  assert_true(run.is_terminal())
  assert_eq(run.exit_code, Some(0))
  assert_eq(run.stdout_bytes, 4L)
  let pty = PtySnapshot::from_json(
    @contracts.json_object([
      ("session_id", @contracts.json_string("sess-1")),
      ("status", @contracts.json_string("running")),
      ("running", @contracts.json_bool(true)),
      ("success", @contracts.json_bool(false)),
      ("output_seq", @contracts.json_int64(2L)),
      ("output_dropped", @contracts.json_int64(0L)),
      ("log_bytes", @contracts.json_int64(64L)),
      ("pid", @contracts.json_int(123)),
      ("rows", @contracts.json_int(24)),
      ("cols", @contracts.json_int(80)),
    ]),
  ).unwrap()
  assert_eq(pty.session_id, "sess-1")
  assert_true(pty.running)
  assert_eq(pty.output_seq, 2L)
}

///|
test "process events settle once and a missing process record is lost" {
  let tracker = RunTracker::new("rt-process")
  tracker.begin("proc-1", "process", "crid-1")
  let started = test_event(
    1L,
    "proc-1",
    1L,
    "runtime.process.started",
    @contracts.json_object([
      ("status", @contracts.json_string(@contracts.RUN_STATUS_RUNNING)),
    ]),
  )
  assert_true(tracker.observe(started))
  assert_eq(tracker.get("proc-1").unwrap().kind, "process")
  assert_true(tracker.get("proc-1").unwrap().is_process())
  assert_eq(tracker.get("proc-1").unwrap().phase.text(), "running")
  // Stream data is polled, not evented: no stdout event exists for a process.
  let exited = test_event(
    2L,
    "proc-1",
    2L,
    "runtime.process.exited",
    @contracts.json_object([
      ("status", @contracts.json_string(@contracts.RUN_STATUS_SUCCEEDED)),
      ("exit_code", @contracts.json_int(0)),
      ("stop_reason", @contracts.json_string("exited")),
      ("ended_at", @contracts.json_string("2026-01-01T00:00:00Z")),
    ]),
  )
  assert_true(tracker.observe(exited))
  assert_eq(tracker.get("proc-1").unwrap().phase.text(), "succeeded")
  // Duplicate/replayed terminal events never re-settle.
  assert_true(!tracker.observe(exited))
  assert_eq(tracker.get("proc-1").unwrap().phase.text(), "succeeded")
  // A reconnect where the node has no record settles lost, never success.
  tracker.begin("proc-2", "process", "crid-2")
  let lost = tracker.reconcile_process_status("proc-2", None, None)
  assert_true(lost)
  assert_eq(tracker.get("proc-2").unwrap().phase.text(), "lost")
  assert_true(!tracker.reconcile_process_status("proc-2", None, None))
}

///|
test "connection loss marks process runs interrupted, not settled" {
  let tracker = RunTracker::new("rt-process")
  tracker.begin("proc-1", "process", "crid-1")
  let _ = tracker.observe(
    test_event(
      1L,
      "proc-1",
      1L,
      "runtime.process.started",
      @contracts.json_object([
        ("status", @contracts.json_string(@contracts.RUN_STATUS_RUNNING)),
      ]),
    ),
  )
  assert_eq(tracker.mark_connection_lost(), 1)
  assert_eq(tracker.get("proc-1").unwrap().phase.text(), "interrupted")
  // A terminal event replayed after reconnect still settles the same run once.
  let exited = test_event(
    2L,
    "proc-1",
    2L,
    "runtime.process.exited",
    @contracts.json_object([
      ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
      ("stop_reason", @contracts.json_string("host_restarted")),
    ]),
  )
  assert_true(tracker.observe(exited))
  assert_eq(tracker.get("proc-1").unwrap().phase.text(), "lost")
}
