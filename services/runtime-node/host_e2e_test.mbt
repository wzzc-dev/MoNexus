///|
/// Runtime node end-to-end tests (A1.2b).
///
/// Each test generates a throwaway PKI with `openssl`, starts a pinned-TLS
/// primary, pairs a real `NodeHost` with a one-time code and serves the
/// paired session. Every runtime method is then called through the
/// primary-side `RuntimeMachine` provider against the real runtime execution
/// core in a temporary workspace.
///
/// Nothing here touches the user's SSH files: the only network endpoint is
/// 127.0.0.1 with a throwaway CA and a pinned leaf fingerprint.

///|
struct HostPki {
  dir : String
  ca_file : String
  leaf_cert : String
  leaf_key : String
  leaf_sha : String
}

///|
async fn host_sh(dir : String, script : String) -> Unit {
  let collected = @process.collect_output("sh", ["-c", script], cwd=dir) catch {
    _ => fail("cannot run the shell helper")
  }
  let (code, _stdout, stderr) = collected
  if code != 0 {
    let message = stderr.text() catch { _ => "helper failed" }
    fail("shell helper failed: " + message)
  }
}

///|
async fn host_make_pki() -> HostPki {
  let dir = @fs.tmpdir(prefix="monexus-runtime-node-e2e-")
  let script = "set -e\n" +
    "umask 077\n" +
    "openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -keyout ca.key -out ca.pem -subj '/CN=MoNexus Node Test CA' -addext 'basicConstraints=critical,CA:TRUE' 2>/dev/null\n" +
    "openssl req -newkey rsa:2048 -nodes -sha256 -keyout leaf.key -out leaf.csr -subj '/CN=localhost' 2>/dev/null\n" +
    "printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\\nextendedKeyUsage=serverAuth\\n' > leaf.ext\n" +
    "openssl x509 -req -sha256 -days 2 -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -extfile leaf.ext 2>/dev/null\n" +
    "openssl x509 -in leaf.pem -outform DER -out leaf.der\n" +
    "chmod 600 ca.key leaf.key ca.pem leaf.pem\n"
  host_sh(dir, script)
  let leaf_der = @fs.read_file(dir + "/leaf.der") catch {
    _ => fail("cannot read the leaf certificate")
  }
  {
    dir,
    ca_file: dir + "/ca.pem",
    leaf_cert: dir + "/leaf.pem",
    leaf_key: dir + "/leaf.key",
    leaf_sha: @transport.certificate_fingerprint(leaf_der.binary().exact_view()),
  }
}

///|
struct NodeHarness {
  host : NodeHost
  machine : @provider_runtime.RuntimeMachine
  server : @transport.PrimaryServer
  state : @transport.PrimaryState
  pki : HostPki
  base : String
  workspace : String
  runtime_id : String
}

///|
async fn host_wait_for(
  label : String,
  timeout_ms : Int64,
  predicate : () -> Bool,
) -> Unit {
  let started = @async.now()
  while !predicate() {
    if @async.now() - started > timeout_ms {
      fail(label + " timed out")
    }
    @async.sleep(20)
  }
}

///|
fn host_mode(path : String) -> Int {
  match @transport.stat_path(path) {
    Some(info) => info.mode & 0o777
    None => -1
  }
}

///|
fn host_sub(json : @json.Json, key : String) -> @json.Json {
  match @contracts.as_object(json) {
    Some(object) =>
      match object.get(key) {
        Some(value) => value
        None => @contracts.json_null()
      }
    None => @contracts.json_null()
  }
}

///|
fn host_string(json : @json.Json, key : String) -> String {
  match @contracts.as_object(json) {
    Some(object) => @contracts.string_field_or(object, key, "")
    None => ""
  }
}

///|
fn host_int64(json : @json.Json, key : String) -> Int64 {
  match @contracts.as_object(json) {
    Some(object) => @contracts.int64_field_or(object, key, 0L)
    None => 0L
  }
}

///|
fn host_bool(json : @json.Json, key : String) -> Bool {
  match @contracts.as_object(json) {
    Some(object) => @contracts.bool_field_or(object, key, false)
    None => false
  }
}

///|
fn host_array(json : @json.Json, key : String) -> Array[@json.Json] {
  match @contracts.as_object(json) {
    Some(object) =>
      match object.get(key) {
        Some(@json.Json::Array(items)) => items
        _ => []
      }
    None => []
  }
}

///|
fn host_count(text : String, needle : String) -> Int {
  let mut count = 0
  for piece in text.split(needle) {
    let _ = piece
    count = count + 1
  }
  count - 1
}

///|
fn host_audit_count(state : @transport.PrimaryState, action : String) -> Int {
  let mut count = 0
  for event in state.audit_events() {
    if host_string(event, "action") == action {
      count = count + 1
    }
  }
  count
}

///|
/// Run one scenario: PKI, primary server, paired node host and a live
/// provider channel. `body` runs while the session is connected; afterwards
/// the primary drains so `node_serve` stops cleanly.
async fn host_run_scenario(
  prefix : String,
  runtime_id : String,
  server_heartbeat_ms : Int64,
  server_heartbeat_missed : Int,
  node_heartbeat_ms : Int64,
  backoff_ms : Int64,
  max_attempts : Int,
  pty_limits : @pty_runtime.PtyLimits?,
  body : async (NodeHarness) -> Unit,
) -> Unit {
  let pki = host_make_pki()
  defer @fs.rmdir(pki.dir, recursive=true)
  let base = @fs.tmpdir(prefix=prefix)
  defer @fs.rmdir(base, recursive=true)
  let workspace = base + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true, allow_exist=false) catch {
    _ => fail("cannot create the test workspace")
  }
  let handlers = @transport.HandlerRegistry::new()
  let tls = @transport.TlsServerConfig::new(
    bind_host="127.0.0.1",
    bind_port=0,
    certificate_file=pki.leaf_cert,
    private_key_file=pki.leaf_key,
    handshake_timeout_ms=5_000L,
  )
  let server_config = @transport.ServerConfig::new(
    tls~,
    policy=@transport.CredentialPolicy::until_revoked(),
    heartbeat_interval_ms=server_heartbeat_ms,
    heartbeat_max_missed=server_heartbeat_missed,
    hello_timeout_ms=5_000L,
  )
  let server = match
    @transport.PrimaryServer::open(
      server_config,
      @transport.StateStore::memory(),
      handlers,
    ) {
    Ok(value) => value
    Err(message) => fail("cannot open the primary server: " + message)
  }
  let outcome : Ref[@transport.NodeRunOutcome?] = Ref(None)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    group.spawn_bg(() => server.run())
    defer server.close()
    let host = match
      NodeHost::open(
        runtime_id,
        state_base=base,
        workspace_root=workspace,
        policy=Some(PolicyGate::allow_workspace(workspace)),
        pty_limits~,
      ) {
      Ok(value) => value
      Err(message) => fail("cannot open the node host: " + message)
    }
    let state = server.primary_state()
    let secret = match state.create_pairing_code() {
      Ok(value) => value
      Err(message) => fail("cannot create a pairing code: " + message)
    }
    let client = @transport.TlsClientConfig::new(
      host="127.0.0.1",
      port=server.port(),
      ca_certificate_file=pki.ca_file,
      expected_leaf_sha256=pki.leaf_sha,
      server_name="localhost",
    )
    let node_config = @transport.NodeConfig::new(
      runtime_id~,
      tls=client,
      heartbeat_interval_ms=node_heartbeat_ms,
      poll_timeout_ms=20L,
      backoff_base_ms=backoff_ms,
      backoff_cap_ms=backoff_ms,
      jitter_ms=0L,
      max_attempts~,
    )
    match host.pair(node_config, secret.code) {
      Ok(_) => ()
      Err(message) => fail("pairing failed: " + message)
    }
    assert_true(@fs.exists(host.token_path()) catch { _ => false })
    group.spawn_bg(() => {
      outcome.val = Some(host.serve(node_config))
    })
    let machine = @provider_runtime.RuntimeMachine::new(state, runtime_id)
    host_wait_for("runtime session", 10_000L, () => machine.is_connected())
    let harness : NodeHarness = {
      host,
      machine,
      server,
      state,
      pki,
      base,
      workspace,
      runtime_id,
    }
    body(harness)
    server.drain()
    let started = @async.now()
    while outcome.val is None && @async.now() - started < 15_000L {
      @async.sleep(20)
    }
  })
  assert_true(outcome.val is Some(_))
}

///|
async test "node host pairs, serves, probes, runs fs and fails closed" {
  host_run_scenario(
    "mn-node-basic",
    "rt-node-basic",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    async fn(h) {
      // State layout: 0700 directory, 0600 identity and token.
      assert_eq(host_mode(h.host.state_dir()), 0o700)
      assert_eq(host_mode(h.host.token_path()), 0o600)
      assert_eq(host_mode(h.host.state_dir() + "/identity.json"), 0o600)
      assert_eq(host_mode(h.workspace), 0o700)
      // Probe: a real node profile, no ACP connection involved.
      let probe = match h.machine.probe() {
        Ok(value) => value
        Err(error) => fail("probe failed: " + error.message)
      }
      assert_eq(probe.runtime_id, "rt-node-basic")
      assert_eq(probe.transport_version, @transport.PROTOCOL_VERSION_TEXT)
      assert_eq(probe.protocol_version, @transport.PROTOCOL_VERSION)
      assert_true(probe.capabilities.contains("exec"))
      assert_true(probe.capabilities.contains("fs"))
      assert_true(probe.capabilities.contains("pty"))
      assert_true(probe.capabilities.contains("git"))
      assert_eq(probe.workspace_roots, [h.host.workspace_root()])
      assert_eq(probe.policy, "snapshot")
      assert_true(probe.os != "")
      let profile = probe.machine_profile()
      assert_eq(profile.max_parallel, 1)
      assert_true(profile.notes.contains("capabilities=exec,fs,pty,git"))
      // fs write is idempotent by client_request_id: the replay returns the
      // recorded result and the second content never reaches the core.
      let written = match
        h.machine.fs_write(
          path="notes.txt",
          content="hello node",
          client_request_id="fs-1",
        ) {
        Ok(value) => value
        Err(error) => fail("fs write failed: " + error.message)
      }
      assert_eq(host_int64(written, "bytes"), 10L)
      let replay = match
        h.machine.fs_write(
          path="notes.txt",
          content="SHOULD NOT REPLACE",
          client_request_id="fs-1",
        ) {
        Ok(value) => value
        Err(error) => fail("duplicate fs write failed: " + error.message)
      }
      assert_eq(written.stringify(), replay.stringify())
      let read = match h.machine.fs_read(path="notes.txt") {
        Ok(value) => value
        Err(error) => fail("fs read failed: " + error.message)
      }
      assert_eq(host_string(read, "data"), "hello node")
      assert_true(!host_bool(read, "truncated"))
      let stat = match h.machine.fs_stat(path="notes.txt") {
        Ok(value) => value
        Err(error) => fail("fs stat failed: " + error.message)
      }
      assert_eq(host_string(stat, "kind"), "file")
      let listing = match h.machine.fs_list() {
        Ok(value) => value
        Err(error) => fail("fs list failed: " + error.message)
      }
      let mut saw_notes = false
      for entry in host_array(listing, "entries") {
        if host_string(entry, "name") == "notes.txt" {
          saw_notes = true
        }
      }
      assert_true(saw_notes)
      // The rooted workspace rejects escaping paths.
      match h.machine.fs_read(path="../outside.txt") {
        Ok(_) => fail("a path escape must be denied")
        Err(error) => assert_eq(error.code, @transport.ERR_PATH_DENIED)
      }
      // A snapshot is installed now; replacing it with fail-closed denies
      // mutating calls while reads keep working.
      h.host.set_policy(PolicyGate::fail_closed())
      match
        h.machine.fs_write(
          path="denied.txt",
          content="x",
          client_request_id="fs-2",
        ) {
        Ok(_) => fail("a write must fail closed without a snapshot")
        Err(error) => assert_eq(error.code, @transport.ERR_POLICY_STALE)
      }
      match
        h.machine.exec_start(
          run_id="run-denied",
          client_request_id="exec-denied",
          argv=["/bin/sh", "-c", "echo nope"],
        ) {
        Ok(_) => fail("exec start must fail closed without a snapshot")
        Err(error) => assert_eq(error.code, @transport.ERR_POLICY_STALE)
      }
      match h.machine.fs_read(path="notes.txt") {
        Ok(_) => ()
        Err(_) => fail("reads must keep working under fail-closed")
      }
      h.host.set_policy(PolicyGate::allow_workspace(h.workspace))
      // Revocation drops the live channel and prevents reuse.
      let revoked = match h.state.revoke("rt-node-basic", "test revoke") {
        Ok(value) => value
        Err(message) => fail("cannot revoke the runtime: " + message)
      }
      assert_true(revoked >= 1)
      host_wait_for("channel drop", 5_000L, () => !h.machine.is_connected())
      match h.machine.fs_read(path="notes.txt") {
        Ok(_) => fail("a revoked runtime must not serve requests")
        Err(error) => assert_eq(error.code, @contracts.ERR_HOST)
      }
    },
  )
}

///|
async test "exec runs, refuses duplicates and replays across reconnect" {
  // The server times out a silent connection after one missed 150 ms
  // heartbeat while the node only heartbeats every 5 s, so the link drops
  // mid-exec and the node reconnects with backoff.
  host_run_scenario(
    "mn-node-exec",
    "rt-node-exec",
    150L,
    1,
    5_000L,
    300L,
    0,
    None,
    async fn(h) {
      let tracker = @provider_runtime.RunTracker::new(h.runtime_id)
      let run_id = "run-exec-1"
      let client_request_id = "exec-1"
      tracker.begin(run_id, "exec", client_request_id)
      let (started, existing) = match
        h.machine.exec_start(
          run_id~,
          client_request_id~,
          argv=[
            "/bin/sh",
            "-c",
            "sleep 1.2; echo out; echo err 1>&2; exit 0",
          ],
        ) {
        Ok(value) => value
        Err(error) => fail("exec start failed: " + error.message)
      }
      assert_true(!existing)
      assert_eq(started.run_id, run_id)
      // A duplicate start with the same client_request_id returns the recorded
      // run and never spawns the second command.
      let (duplicate, duplicate_existing) = match
        h.machine.exec_start(
          run_id~,
          client_request_id~,
          argv=["/bin/sh", "-c", "touch dup-marker.txt"],
        ) {
        Ok(value) => value
        Err(error) => fail("duplicate exec start failed: " + error.message)
      }
      // The node's recorded replay carries the original response, so the
      // `existing` flag is the first answer; the run id and effects are what
      // prove no second execution happened.
      let _ = duplicate_existing
      assert_eq(duplicate.run_id, run_id)
      // Pump events until the run settles, marking the interruption when the
      // channel drops. The run must never settle from silence alone.
      let mut saw_interrupted = false
      let started_at = @async.now()
      while true {
        let _ = h.machine.mark_interrupted(tracker)
        let _ = h.machine.pump_events(tracker)
        let run = match tracker.get(run_id) {
          Some(value) => value
          None => fail("the tracked run disappeared")
        }
        if run.phase.text() == "interrupted" {
          saw_interrupted = true
        }
        if run.phase.is_settled() {
          break
        }
        if @async.now() - started_at > 15_000L {
          fail("the run did not settle after reconnect")
        }
        @async.sleep(20)
      }
      assert_true(saw_interrupted)
      let settled = match tracker.get(run_id) {
        Some(value) => value
        None => fail("the tracked run disappeared")
      }
      assert_eq(settled.run_id, run_id)
      assert_eq(settled.phase.text(), "succeeded")
      assert_eq(settled.exit_code, Some(0))
      assert_true(h.machine.is_connected())
      // Reconnect happened: at least two authenticated sessions were opened.
      assert_true(host_audit_count(h.state, "runtime.session_opened") >= 2)
      // Replaying the accepted tap settles nothing twice: no new events, no
      // cursor movement, same phase and exit code.
      let cursor = tracker.cursor()
      let replayed = h.machine.pump_events(tracker)
      assert_eq(replayed, 0)
      assert_eq(tracker.cursor(), cursor)
      assert_eq(tracker.get(run_id).unwrap().phase.text(), "succeeded")
      // Exactly one terminal event for the run.
      let mut terminals = 0
      for event in h.state.events_since(h.runtime_id, 0L) {
        if event.run_id == run_id && event.kind == "runtime.exec.exited" {
          terminals = terminals + 1
        }
      }
      assert_eq(terminals, 1)
      // The duplicate start really did not execute.
      let listing = match h.machine.fs_list() {
        Ok(value) => value
        Err(error) => fail("fs list failed: " + error.message)
      }
      for entry in host_array(listing, "entries") {
        assert_true(host_string(entry, "name") != "dup-marker.txt")
      }
      // Status after the fact reads the recorded run, not a new execution.
      let status = match h.machine.exec_status(run_id) {
        Ok(Some(value)) => value
        Ok(None) => fail("exec status lost the run")
        Err(error) => fail("exec status failed: " + error.message)
      }
      assert_eq(status.status, @contracts.RUN_STATUS_SUCCEEDED)
      assert_eq(status.exit_code, Some(0))
      assert_eq(status.run_id, run_id)
      // Cancel path: a long run is stopped by a later request.
      tracker.begin("run-exec-2", "exec", "exec-2")
      let (_, _) = match
        h.machine.exec_start(
          run_id="run-exec-2",
          client_request_id="exec-2",
          argv=["/bin/sh", "-c", "sleep 30"],
        ) {
        Ok(value) => value
        Err(error) => fail("cancel test start failed: " + error.message)
      }
      let cancelled = match
        h.machine.exec_cancel("run-exec-2", client_request_id="cancel-1") {
        Ok(value) => value
        Err(error) => fail("exec cancel failed: " + error.message)
      }
      assert_true(
        cancelled.status == @contracts.RUN_STATUS_CANCELLED ||
        cancelled.status == @contracts.RUN_STATUS_FAILED,
      )
      let cancel_started = @async.now()
      while @async.now() - cancel_started < 15_000L {
        let _ = h.machine.pump_events(tracker)
        let run = match tracker.get("run-exec-2") {
          Some(value) => value
          None => fail("the cancelled run disappeared")
        }
        if run.phase.is_settled() {
          break
        }
        @async.sleep(20)
      }
      assert_eq(tracker.get("run-exec-2").unwrap().phase.text(), "cancelled")
    },
  )
}

///|
async test "pty sessions and git methods run through the paired transport" {
  // A tiny output ring forces `runtime.pty.gap` events; the node must pass
  // them through with transcript offsets so the primary can catch up.
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
  host_run_scenario(
    "mn-node-pty-git",
    "rt-node-pty-git",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    Some(limits),
    async fn(h) {
      // A real repository in the node workspace.
      host_sh(
        h.workspace,
        "git init -q\n" +
        "git config user.email test@example.invalid\n" +
        "git config user.name 'Node Test'\n" +
        "printf 'one\\n' > a.txt\n" +
        "git add a.txt\n" +
        "git commit -q -m 'initial commit'\n",
      )
      let tracker = @provider_runtime.RunTracker::new(h.runtime_id)
      let session_id = "sess-1"
      tracker.begin(session_id, "pty", "pty-1")
      let (session, existing) = match
        h.machine.pty_open(
          session_id~,
          client_request_id="pty-1",
          argv=[
            "/bin/sh",
            "-c",
            "sleep 0.4; i=0; while [ $i -lt 200 ]; do printf 'chunk-%03d-abcdefghijklmnopqrstuvwxyz\\n' $i; i=$((i+1)); done",
          ],
          rows=24,
          cols=80,
          workspace_root=h.host.workspace_root(),
        ) {
        Ok(value) => value
        Err(error) => fail("pty open failed: " + error.message)
      }
      assert_true(!existing)
      assert_eq(session.session_id, session_id)
      // A duplicate open returns the existing session without spawning again.
      let (duplicate, duplicate_existing) = match
        h.machine.pty_open(
          session_id~,
          client_request_id="pty-1",
          argv=["/bin/sh", "-c", "echo should-not-run"],
          workspace_root=h.host.workspace_root(),
        ) {
        Ok(value) => value
        Err(error) => fail("duplicate pty open failed: " + error.message)
      }
      let _ = duplicate_existing
      assert_eq(duplicate.session_id, session_id)
      match
        h.machine.pty_input(
          session_id~,
          data="echo hello\\n",
          client_request_id="pty-input-1",
        ) {
        Ok(_) => ()
        Err(error) => fail("pty input failed: " + error.message)
      }
      // The same client_request_id returns the recorded acknowledgement.
      match
        h.machine.pty_input(
          session_id~,
          data="echo SECOND-TYPED\\n",
          client_request_id="pty-input-1",
        ) {
        Ok(_) => ()
        Err(error) => fail("duplicate pty input failed: " + error.message)
      }
      match
        h.machine.pty_resize(
          session_id~,
          rows=40,
          cols=100,
          client_request_id="pty-resize-1",
        ) {
        Ok(_) => ()
        Err(error) => fail("pty resize failed: " + error.message)
      }
      let status = match h.machine.pty_status(session_id) {
        Ok(value) => value
        Err(error) => fail("pty status failed: " + error.message)
      }
      assert_eq(status.session_id, session_id)
      let started_at = @async.now()
      while true {
        let _ = h.machine.pump_events(tracker)
        let run = match tracker.get(session_id) {
          Some(value) => value
          None => fail("the tracked pty session disappeared")
        }
        if run.phase.is_settled() {
          break
        }
        if @async.now() - started_at > 20_000L {
          fail("the pty session did not settle")
        }
        @async.sleep(20)
      }
      assert_eq(tracker.get(session_id).unwrap().phase.text(), "succeeded")
      // Gap events carry the transcript range and offsets, so no output seq
      // is silently lost.
      let mut gap_count = 0
      let mut typed_twice = false
      let mut spawned_again = false
      let mut output_text = ""
      for event in h.state.events_since(h.runtime_id, 0L) {
        if event.run_id != session_id {
          continue
        }
        if event.kind == "runtime.pty.gap" {
          gap_count = gap_count + 1
          assert_true(host_int64(event.payload, "to_seq") >= host_int64(event.payload, "from_seq"))
          assert_true(host_int64(event.payload, "log_bytes") >= 0L)
        } else if event.kind == "runtime.pty.output" {
          output_text = output_text + host_string(event.payload, "data")
        }
      }
      assert_true(gap_count > 0)
      if host_count(output_text, "SECOND-TYPED") > 0 {
        typed_twice = true
      }
      if output_text.contains("should-not-run") {
        spawned_again = true
      }
      assert_true(!typed_twice)
      assert_true(!spawned_again)
      let final_status = match h.machine.pty_status(session_id) {
        Ok(value) => value
        Err(error) => fail("pty status after exit failed: " + error.message)
      }
      assert_eq(final_status.status, @contracts.RUN_STATUS_SUCCEEDED)
      assert_true(final_status.log_bytes > 0L)
      let closed = match
        h.machine.pty_close(session_id, client_request_id="pty-close-1") {
        Ok(value) => value
        Err(error) => fail("pty close failed: " + error.message)
      }
      assert_eq(closed.session_id, session_id)
      // Git: status, diff, log, branches, worktrees and log replay.
      let status_json = match h.machine.git_status() {
        Ok(value) => value
        Err(error) => fail("git status failed: " + error.message)
      }
      assert_true(host_bool(status_json, "success"))
      host_sh(h.workspace, "printf 'two\\n' >> a.txt\n")
      let diff = match h.machine.git_diff(path="a.txt") {
        Ok(value) => value
        Err(error) => fail("git diff failed: " + error.message)
      }
      assert_true(host_string(diff, "stdout_preview").contains("+two"))
      let log = match h.machine.git_log(rev="HEAD", max_count=5) {
        Ok(value) => value
        Err(error) => fail("git log failed: " + error.message)
      }
      assert_true(host_string(log, "stdout_preview").contains("initial commit"))
      let log_op = host_string(log, "op_id")
      assert_true(log_op != "")
      let replayed_log = match
        h.machine.git_read_output(op_id=log_op, stream="stdout", offset=0L) {
        Ok(value) => value
        Err(error) => fail("git read_output failed: " + error.message)
      }
      assert_true(host_string(replayed_log, "data").contains("initial commit"))
      assert_eq(host_string(replayed_log, "op_id"), log_op)
      let show = match h.machine.git_show(rev="HEAD", path="a.txt") {
        Ok(value) => value
        Err(error) => fail("git show failed: " + error.message)
      }
      assert_true(host_bool(show, "success"))
      let branches = match h.machine.git_branches() {
        Ok(value) => value
        Err(error) => fail("git branches failed: " + error.message)
      }
      assert_true(host_array(branches, "branches").length() >= 1)
      let created = match
        h.machine.git_branch_create(name="feature", client_request_id="git-branch-1") {
        Ok(value) => value
        Err(error) => fail("git branch create failed: " + error.message)
      }
      assert_true(host_bool(created, "success"))
      let replay_created = match
        h.machine.git_branch_create(name="feature", client_request_id="git-branch-1") {
        Ok(value) => value
        Err(error) => fail("duplicate git branch create failed: " + error.message)
      }
      assert_eq(created.stringify(), replay_created.stringify())
      let after_branch = match h.machine.git_branches() {
        Ok(value) => value
        Err(error) => fail("git branches failed: " + error.message)
      }
      let mut saw_feature = false
      for branch in host_array(after_branch, "branches") {
        if host_string(branch, "name") == "feature" {
          saw_feature = true
        }
      }
      assert_true(saw_feature)
      let checked_out = match
        h.machine.git_checkout(branch="feature", client_request_id="git-checkout-1") {
        Ok(value) => value
        Err(error) => fail("git checkout failed: " + error.message)
      }
      assert_true(host_bool(checked_out, "success"))
      let worktrees = match h.machine.git_worktrees() {
        Ok(value) => value
        Err(error) => fail("git worktrees failed: " + error.message)
      }
      assert_true(host_array(worktrees, "worktrees").length() >= 1)
      // `git worktree add` creates the branch it is given, so this one must
      // not exist yet.
      let added = match
        h.machine.git_worktree_add(
          path="wt",
          branch="wt-branch",
          client_request_id="git-wt-add-1",
        ) {
        Ok(value) => value
        Err(error) => fail("git worktree add failed: " + error.message)
      }
      assert_true(host_bool(host_sub(added, "result"), "success"))
      let after_add = match h.machine.git_worktrees() {
        Ok(value) => value
        Err(error) => fail("git worktrees failed: " + error.message)
      }
      let mut saw_wt = false
      for worktree in host_array(after_add, "worktrees") {
        if host_string(worktree, "relative_path") == "wt" {
          saw_wt = true
        }
      }
      assert_true(saw_wt)
      let removed = match
        h.machine.git_worktree_remove(
          path="wt",
          client_request_id="git-wt-remove-1",
        ) {
        Ok(value) => value
        Err(error) => fail("git worktree remove failed: " + error.message)
      }
      assert_true(host_bool(host_sub(removed, "result"), "success"))
    },
  )
}
