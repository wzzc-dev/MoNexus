///|
/// Task / Run scheduling, the evidence gate, and session search (M5).
///
/// A Run is the only thing that executes. Dispatch is idempotent by
/// `idempotency_key`; placement is decided once and written to the Run;
/// capacity is per machine (`max_parallel`, default 4) and overflow stays
/// `queued`. A successful main step always enters `verifying`: the project/
/// task `verify[]` commands run on the Run's worktree, their output becomes an
/// Artifact, and only a pass (or an explicit waiver Decision) settles
/// `succeeded`.

///|
const RUN_OUTPUT_CAP : Int = 65_536

///|
const ARTIFACT_READ_CAP : Int = 262_144

///|
const RUN_DEFAULT_TIMEOUT_S : Int = 600

///|
const VERIFY_DEFAULT_TIMEOUT_S : Int = 300

///|
fn task_invalid(message : String) -> @contracts.RpcError {
  @contracts.workspace_error(@contracts.WORKSPACE_ERR_INVALID, message)
}

///|
fn task_not_found(message : String) -> @contracts.RpcError {
  @contracts.workspace_error(@contracts.WORKSPACE_ERR_NOT_FOUND, message)
}

///|
fn task_conflict(message : String) -> @contracts.RpcError {
  @contracts.workspace_error(@contracts.WORKSPACE_ERR_CONFLICT, message)
}

///|
async fn task_io_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  error : @contracts.RpcError,
) -> Unit {
  send_machine_error(state, sink, request, client_request_id, error)
}

///|
/// Attach session/worktree ids to a Run without changing its state. Emits
/// `run.progress` with the full record so a reconnect rebuilds the page.
async fn attach_run_fields(
  state : HostState,
  run_id : String,
  worktree_id~ : String = "",
  session_id~ : String = "",
) -> Result[@contracts.RunRecord, String] {
  state.mutex.acquire()
  let current = match state.store.get_run(run_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      return Err("run not found: " + run_id)
    }
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  let updated = {
    ..current,
    worktree_id: if worktree_id == "" {
      current.worktree_id
    } else {
      worktree_id
    },
    session_id: if session_id == "" { current.session_id } else { session_id },
    updated_at: @contracts.format_rfc3339(@async.now()),
  }
  let outcome = state.append_run_event(
    @contracts.EVENT_RUN_PROGRESS,
    run_id,
    updated.to_json(),
    updated,
  )
  state.mutex.release()
  match outcome {
    Ok(_) => Ok(updated)
    Err(message) => Err(message)
  }
}

///|
fn run_event_for_status(status : String) -> String {
  match status {
    "queued" => @contracts.EVENT_RUN_QUEUED
    "running" => @contracts.EVENT_RUN_STARTED
    "verifying" => @contracts.EVENT_RUN_VERIFYING
    "waiting_approval" => @contracts.EVENT_RUN_WAITING_APPROVAL
    "succeeded" => @contracts.EVENT_RUN_SUCCEEDED
    "failed" => @contracts.EVENT_RUN_FAILED
    "cancelled" => @contracts.EVENT_RUN_CANCELLED
    "lost" => @contracts.EVENT_RUN_LOST
    _ => @contracts.EVENT_RUN_PROGRESS
  }
}

///|
fn truncate_output(text : String, cap : Int) -> String {
  if text.length() <= cap {
    text
  } else {
    text.substring(start=0, end=cap) + "\n... (truncated)"
  }
}

// ---------------------------------------------------------------------------
// State transitions (single authority: host, event + projection together)
// ---------------------------------------------------------------------------

///|
/// Apply one Run transition. Re-reads the Run under the mutex so a concurrent
/// cancel cannot be overwritten by a late executor step.
async fn transition_run(
  state : HostState,
  run_id : String,
  to : String,
  stop_reason~ : String = "",
  summary~ : String = "",
  error_text~ : String = "",
  session_id~ : String = "",
  worktree_id~ : String = "",
) -> Result[@contracts.RunRecord, String] {
  state.mutex.acquire()
  let current = match state.store.get_run(run_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      return Err("run not found: " + run_id)
    }
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  if current.status == to {
    state.mutex.release()
    return Ok(current)
  }
  if !@contracts.run_transition_allowed(current.status, to) {
    state.mutex.release()
    return Err(
      "illegal run transition " + current.status + " -> " + to,
    )
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let terminal = @contracts.run_status_is_terminal(to)
  // Summaries and errors are shown in the Inbox and written to events; a
  // credential echoed by a command must be redacted first (ADR-0006 §5).
  let safe_summary = if summary == "" {
    current.output_summary
  } else {
    @contracts.redact_secrets(summary)
  }
  let safe_error = if error_text == "" {
    current.last_error
  } else {
    @contracts.redact_secrets(error_text)
  }
  let updated = {
    ..current,
    status: to,
    stop_reason: if stop_reason == "" {
      current.stop_reason
    } else {
      stop_reason
    },
    output_summary: safe_summary,
    last_error: safe_error,
    session_id: if session_id == "" { current.session_id } else { session_id },
    worktree_id: if worktree_id == "" { current.worktree_id } else { worktree_id },
    started_at: if to == @contracts.RUN_STATUS_RUNNING &&
      current.started_at == "" {
      timestamp
    } else {
      current.started_at
    },
    finished_at: if terminal { timestamp } else { current.finished_at },
    updated_at: timestamp,
  }
  let outcome = state.append_run_event(
    run_event_for_status(to),
    run_id,
    updated.to_json(),
    updated,
  )
  state.mutex.release()
  match outcome {
    Ok(_) => {
      // A2.1: an ephemeral environment is destroyed when its Run reaches a
      // terminal state. This is idempotent and never touches a shared env.
      if terminal {
        finalize_run_environment(state, updated)
      }
      Ok(updated)
    }
    Err(message) => Err(message)
  }
}

///|
async fn transition_task(
  state : HostState,
  task_id : String,
  to : String,
  summary~ : String = "",
  cancel_reason~ : String = "",
) -> Result[@contracts.TaskRecord, String] {
  state.mutex.acquire()
  let current = match state.store.get_task(task_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      return Err("task not found: " + task_id)
    }
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  if current.status == to {
    state.mutex.release()
    return Ok(current)
  }
  if !@contracts.task_transition_allowed(current.status, to) {
    state.mutex.release()
    return Err("illegal task transition " + current.status + " -> " + to)
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  let updated = {
    ..current,
    status: to,
    result_summary: if summary == "" {
      current.result_summary
    } else {
      summary
    },
    cancel_reason: if cancel_reason == "" {
      current.cancel_reason
    } else {
      cancel_reason
    },
    updated_at: timestamp,
  }
  let event_type = if to == @contracts.TASK_STATUS_CANCELLED {
    @contracts.EVENT_TASK_CANCELLED
  } else {
    @contracts.EVENT_TASK_STATUS_CHANGED
  }
  let outcome = state.append_task_event(
    event_type,
    task_id,
    updated.to_json(),
    updated,
  )
  state.mutex.release()
  match outcome {
    Ok(_) => Ok(updated)
    Err(message) => Err(message)
  }
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

///|
fn local_max_parallel() -> Int {
  match @env.get_env_var("MONEXUS_MAX_PARALLEL") {
    Some(value) => {
      let parsed = @string.parse_int(value.trim()) catch { _ => 0 }
      if parsed > 0 { parsed } else { 4 }
    }
    None => 4
  }
}

///|
/// Capacity of one machine. Local defaults to 4 (or MONEXUS_MAX_PARALLEL);
/// SSH machines use the `max_parallel` reported by their probe.
fn machine_max_parallel(state : HostState, machine_id : String) -> Int {
  if machine_id == "" {
    return local_max_parallel()
  }
  match state.store.get_machine(machine_id) {
    Ok(Some(record)) =>
      match record.profile {
        Some(profile) =>
          if profile.max_parallel > 0 {
            profile.max_parallel
          } else {
            4
          }
        None => 4
      }
    _ => 4
  }
}

///|
fn machine_available(state : HostState, machine_id : String) -> Bool {
  if machine_id == "" {
    return true
  }
  match state.store.get_machine(machine_id) {
    Ok(Some(record)) =>
      record.status == @contracts.MACHINE_STATUS_ONLINE ||
      record.status == @contracts.MACHINE_STATUS_DEGRADED
    _ => false
  }
}

///|
/// Capability match: requested arch / os / toolchain against the machine
/// profile. Local capabilities are probed on demand (uname + `command -v`).
async fn machine_matches(
  state : HostState,
  machine_id : String,
  want_arch : String,
  want_os : String,
  want_tool : String,
) -> Bool {
  if want_arch == "" && want_os == "" && want_tool == "" {
    state.mutex.acquire()
    let available = machine_available(state, machine_id)
    state.mutex.release()
    return available
  }
  let (os, arch, tools) = if machine_id == "" {
    probe_local_capabilities()
  } else {
    state.mutex.acquire()
    let found = match state.store.get_machine(machine_id) {
      Ok(Some(record)) =>
        if record.status == @contracts.MACHINE_STATUS_ONLINE ||
          record.status == @contracts.MACHINE_STATUS_DEGRADED {
          match record.profile {
            Some(profile) => {
              let tools : Map[String, String] = Map([])
              for name, path in profile.toolchains {
                tools.set(name, path)
              }
              (profile.os, profile.arch, tools)
            }
            None => ("", "", Map([]))
          }
        } else {
          ("", "", Map([]))
        }
      _ => ("", "", Map([]))
    }
    state.mutex.release()
    found
  }
  if want_arch != "" && arch != want_arch {
    return false
  }
  if want_os != "" && !os.to_lower().contains(want_os.to_lower()) {
    return false
  }
  if want_tool != "" && tools.get(want_tool) is None {
    return false
  }
  true
}

///|
/// Probe the local machine once per dispatch with requirements. Result is
/// (os, arch, toolchain map).
async fn probe_local_capabilities() -> (String, String, Map[String, String]) {
  let script = "uname -s; uname -m; " +
    "for t in git gcc clang cmake moon node bun python3; do " +
    "command -v \"$t\" >/dev/null 2>&1 && echo \"$t\"; done"
  let collected = @async.with_timeout_opt(
    5_000,
    async fn() {
      let (_, stdout, _) = @process.collect_output("/bin/sh", ["-c", script]) catch {
        _ => return ""
      }
      stdout.text() catch { _ => "" }
    },
  )
  let text = match collected {
    Some(value) => value
    None => ""
  }
  let tools : Map[String, String] = Map([])
  let lines : Array[String] = []
  for piece in text.split("\n") {
    let line = piece.to_string().trim().to_string()
    if line != "" {
      lines.push(line)
    }
  }
  // Requirement matching uses lower-case names; `uname -s` reports Darwin.
  let raw_os = if lines.length() > 0 { lines[0] } else { "" }
  let os = if raw_os.to_lower() == "darwin" { "macos" } else { raw_os }
  let arch = if lines.length() > 1 { lines[1] } else { "" }
  for index in 2..<lines.length() {
    let name = lines[index]
    tools.set(name, name)
  }
  (os, arch, tools)
}

///|
/// Start every queued Run that fits its machine's capacity, in creation
/// order. Guarded by `dispatching` so concurrent settles cannot double-start.
async fn dispatch_queued(state : HostState) -> Unit {
  state.mutex.acquire()
  if state.dispatching.val {
    state.mutex.release()
    return
  }
  state.dispatching.val = true
  state.mutex.release()
  let mut progressed = true
  while progressed {
    progressed = false
    state.mutex.acquire()
    let queued = match state.store.list_runs("", @contracts.RUN_STATUS_QUEUED) {
      Ok(value) => value
      Err(message) => {
        println("monexus-host: cannot list queued runs: " + message)
        []
      }
    }
    let mut chosen : @contracts.RunRecord? = None
    for candidate in queued {
      if chosen is Some(_) {
        continue
      }
      if !machine_available(state, candidate.machine_id) {
        continue
      }
      let capacity = machine_max_parallel(state, candidate.machine_id)
      let active = match
        state.store.count_slot_runs(candidate.machine_id) {
        Ok(value) => value
        Err(_) => capacity
      }
      if active < capacity {
        chosen = Some(candidate)
      }
    }
    state.mutex.release()
    match chosen {
      Some(record) => {
        match
          transition_run(
            state,
            record.id,
            @contracts.RUN_STATUS_RUNNING,
          ) {
          Ok(_) => progressed = true
          Err(message) => {
            println("monexus-host: cannot start run " + record.id + ": " + message)
            let _ = transition_run(
              state,
              record.id,
              @contracts.RUN_STATUS_FAILED,
              stop_reason="dispatch_failed",
              error_text=message,
            )
          }
        }
        match state.group.val {
          Some(group) =>
            group.spawn_bg(
              allow_failure=true,
              () => execute_started_run(state, record.id)
            )
          None => ()
        }
      }
      None => ()
    }
  }
  state.mutex.acquire()
  state.dispatching.val = false
  state.mutex.release()
}

// ---------------------------------------------------------------------------
// Run execution
// ---------------------------------------------------------------------------

///|
async fn execute_started_run(state : HostState, run_id : String) -> Unit {
  let outcome = execute_run_body(state, run_id) catch {
    error => Err(error.to_string())
  }
  match outcome {
    Ok(_) => ()
    Err(message) => {
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason="run_error",
        error_text=message,
      )
    }
  }
  update_task_rollup_for_run(state, run_id)
  dispatch_queued(state)
}

///|
/// Resolve the execution directory, creating a host-managed worktree for a
/// git workspace when the Run does not name one.
async fn resolve_run_cwd(
  state : HostState,
  run : @contracts.RunRecord,
) -> Result[String, String] {
  // Environment runs execute in the container workdir. Never create a host
  // worktree outside the mounted root for them: the workspace root (or the
  // registered worktree root) is what the plan mounts.
  if run.environment_id != "" {
    if run.worktree_id != "" {
      let record = match state.store.get_worktree(run.worktree_id) {
        Ok(Some(value)) => value
        Ok(None) => return Err("worktree not found")
        Err(message) => return Err(message)
      }
      return Ok(record.path)
    }
    let workspace = match state.store.get_workspace(run.workspace_id) {
      Ok(Some(value)) => value
      Ok(None) => return Err("workspace not found")
      Err(message) => return Err(message)
    }
    return Ok(workspace.root)
  }
  if run.worktree_id != "" {
    let record = match state.store.get_worktree(run.worktree_id) {
      Ok(Some(value)) => value
      Ok(None) => return Err("worktree not found")
      Err(message) => return Err(message)
    }
    return Ok(record.path)
  }
  let workspace = match state.store.get_workspace(run.workspace_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("workspace not found")
    Err(message) => return Err(message)
  }
  if !workspace.is_git {
    return Ok(workspace.root)
  }
  let provider = match
    open_provider(state, workspace.machine_id, workspace.root) {
    Ok(value) => value
    Err(error) => return Err(error.message)
  }
  let short = run.id.substring(start=run.id.length() - 8)
  let path = workspace.root + "-monexus-" + short
  let branch = "monexus/" + short
  match provider.create_worktree(path, branch, "") {
    Ok(_) => ()
    Err(error) => return Err(error.to_string())
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  let record : @contracts.WorktreeRecord = {
    id: @contracts.new_id("wt", @async.now()),
    workspace_id: workspace.id,
    machine_id: workspace.machine_id,
    branch,
    path,
    base: "",
    state: @contracts.WORKTREE_STATE_READY,
    created_at: timestamp,
    updated_at: timestamp,
  }
  state.mutex.acquire()
  let made = state.append_worktree_event(
    @contracts.EVENT_WORKTREE_READY,
    record.id,
    @contracts.worktree_event_payload(record),
    Some(record),
    None,
  )
  state.mutex.release()
  match made {
    Ok(_) => ()
    Err(message) => return Err("cannot record worktree: " + message)
  }
  match attach_run_fields(state, run.id, worktree_id=record.id) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  Ok(path)
}

///|
async fn execute_run_body(
  state : HostState,
  run_id : String,
) -> Result[Unit, String] {
  state.mutex.acquire()
  let loaded = state.store.get_run(run_id)
  state.mutex.release()
  let run = match loaded {
    Ok(Some(value)) => value
    Ok(None) => return Err("run not found")
    Err(message) => return Err(message)
  }
  if run.status != @contracts.RUN_STATUS_RUNNING {
    return Ok(())
  }
  if !machine_available(state, run.machine_id) {
    let _ = transition_run(
      state,
      run_id,
      @contracts.RUN_STATUS_FAILED,
      stop_reason="machine_unavailable",
      error_text="machine is offline before the run started",
    )
    return Ok(())
  }
  let cwd = match resolve_run_cwd(state, run) {
    Ok(value) => value
    Err(message) => {
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason="readiness_failed",
        error_text=message,
      )
      return Ok(())
    }
  }
  // Re-read: resolve_run_cwd may have attached the worktree id.
  state.mutex.acquire()
  let current = match state.store.get_run(run_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      return Ok(())
    }
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  state.mutex.release()
  if current.status != @contracts.RUN_STATUS_RUNNING {
    return Ok(())
  }
  // Main step. Command runs go through the durable (tmux) path so a host
  // restart can reattach; recovery settles a failed/lost command itself.
  let step = if current.mode == @contracts.RUN_MODE_AGENT {
    match run_agent_step(state, current, cwd) {
      Ok(session_id) => Ok(Completed("agent session " + session_id + " completed"))
      Err(message) => Err(message)
    }
  } else if current.environment_id != "" {
    // A container Run has no tmux session on the host; execute it directly in
    // the environment and keep the output artifact.
    match run_command_step(state, current, cwd) {
      Ok((_kind, detail)) => Ok(Completed(detail))
      Err(message) => Err(message)
    }
  } else {
    execute_command_run(state, current, cwd)
  }
  match step {
    Ok(Completed(summary)) => {
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_RUNNING,
        summary~,
      )
      run_verification(state, run_id, cwd)
    }
    Ok(Recovered(reason)) => {
      // Recovery already settled or escalated this Run. Do not settle again.
      recovery_event(state, run_id, "run.recovery.handled", reason)
    }
    Err(message) => {
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason="execution_failed",
        error_text=message,
      )
    }
  }
  Ok(())
}

///|
/// Command mode: one `sh -c` command in the Run's worktree. Output is kept as
/// a bounded Artifact; the exit code decides success.
async fn run_command_step(
  state : HostState,
  run : @contracts.RunRecord,
  cwd : String,
) -> Result[(String, String), String] {
  if run.command.trim() == "" {
    return Err("run has no command")
  }
  // Runs with an environment execute inside its container; file and git
  // operations keep using the workspace transport through `run_exec_checked`.
  let result = match
    run_exec_checked(
      state,
      run,
      run.command,
      cwd,
      RUN_DEFAULT_TIMEOUT_S,
    ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let output = truncate_output(
    result.stdout + result.stderr,
    RUN_OUTPUT_CAP,
  )
  let _ = write_run_artifact(
    state,
    run.id,
    "run-output.log",
    output,
    "run_output",
    "text/plain",
  )
  if result.timed_out {
    return Err("command timed out")
  }
  if result.exit_code != 0 {
    return Err(
      "command exited with code " +
      result.exit_code.to_string() +
      ": " +
      truncate_output(output, 500),
    )
  }
  Ok(("command", "exit 0"))
}

///|


///|
/// Agent mode: start an ACP session through the M4 handler on the local
/// worktree, wait for the turn to finish, then stop it. Returns the session
/// id. SSH-backed agents remain unsupported (M4 boundary, documented).
async fn run_agent_step(
  state : HostState,
  run : @contracts.RunRecord,
  cwd : String,
) -> Result[String, String] {
  if run.machine_id != "" {
    return Err("agent runs are local-only in M5 (M4 boundary)")
  }
  let spec = @agent.AgentSpec::new(
    agent_id=run.agent_id,
    mode=@contracts.AGENT_MODE_ACP,
    command=run.agent_command,
    args=run.agent_args,
    cwd~,
    env=run.agent_env,
  )
  let readiness = @agent.probe_agent(spec) catch {
    error => return Err("agent readiness probe failed: " + error.to_string())
  }
  if !readiness.ok {
    return Err(
      "agent readiness failed: " + readiness.error,
    )
  }
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  let sink : Sink = {
    queue,
    subscribed: Ref(false),
    closed: Ref(false),
  }
  let request_params = @contracts.agent_start_params(
    "run:" + run.id + ":agent-start",
    run.agent_id,
    @contracts.AGENT_MODE_ACP,
    run.agent_command,
    run.agent_args,
    cwd,
    run.workspace_id,
    run.worktree_id,
    run.prompt,
    4096,
    run.agent_env,
    task_id=run.task_id,
  )
  let request : @contracts.RpcRequest = {
    id: "run:" + run.id + ":agent-start",
    method: @contracts.METHOD_AGENT_START,
    params: request_params,
  }
  handle_agent_start(state, sink, request, "run:" + run.id + ":agent-start")
  let response = @async.with_timeout_opt(
    5_000,
    async fn() { queue.get() },
  )
  let text = match response {
    Some(value) => value
    None => return Err("agent.start did not respond")
  }
  let session_id = match extract_session_id(text) {
    Some(value) => value
    None => return Err("agent.start failed: " + truncate_output(text, 500))
  }
  let _ = attach_run_fields(state, run.id, session_id~)
  // Wait for the initial turn to finish (idle) or the session to fail.
  let deadline = @async.now() + (RUN_DEFAULT_TIMEOUT_S.to_int64() * 1_000L)
  let mut failure = ""
  while @async.now() < deadline {
    @async.sleep(150)
    state.mutex.acquire()
    let record = match state.store.get_agent_session(session_id) {
      Ok(Some(value)) => Some(value)
      _ => None
    }
    let cancelled = match state.store.get_run(run.id) {
      Ok(Some(value)) =>
        value.status == @contracts.RUN_STATUS_CANCELLED
      _ => false
    }
    // A permission request pauses the turn. The Run must keep waiting while
    // the Decision is pending, and must not succeed when the owner denied it
    // or the decision expired. The ACP reply (written by decision.respond)
    // resumes the same session for an allow.
    let mut decision_failure = ""
    match state.store.list_decisions("", session_id) {
      Ok(decisions) =>
        for decision in decisions {
          if decision.kind != @contracts.DECISION_KIND_PERMISSION {
            continue
          }
          if decision.status == @contracts.DECISION_STATUS_EXPIRED {
            decision_failure = "permission decision expired: " + decision.id
          } else if decision.status == @contracts.DECISION_STATUS_ANSWERED {
            let mut rejected = decision.option_id == "" ||
              decision.option_id.has_prefix("reject")
            for option in decision.options {
              if option.option_id == decision.option_id &&
                option.kind.has_prefix("reject") {
                rejected = true
              }
            }
            if rejected {
              decision_failure = "permission denied by owner: " + decision.id
            } else if decision.delivery_error != "" {
              decision_failure = "permission answer was not delivered: " +
                decision.delivery_error
            }
          }
        }
      Err(_) => ()
    }
    state.mutex.release()
    if decision_failure != "" {
      failure = decision_failure
      break
    }
    match record {
      Some(session) => {
        if cancelled {
          return Err("run cancelled")
        }
        if session.state == @contracts.AGENT_STATE_IDLE {
          stop_internal_session(state, session_id)
          return Ok(session_id)
        }
        if session.state == @contracts.AGENT_STATE_FAILED ||
          session.state == @contracts.AGENT_STATE_STOPPED ||
          session.state == @contracts.AGENT_STATE_EXITED ||
          session.state == @contracts.AGENT_STATE_LOST ||
          session.state == @contracts.AGENT_STATE_INTERRUPTED {
          failure = "agent session ended: " + session.state +
            (if session.last_error == "" {
              ""
            } else {
              " (" + session.last_error + ")"
            })
          break
        }
      }
      None => {
        failure = "agent session disappeared"
        break
      }
    }
  }
  if failure == "" {
    failure = "agent turn timed out after " +
      RUN_DEFAULT_TIMEOUT_S.to_string() + "s"
  }
  stop_internal_session(state, session_id)
  Err(failure)
}

///|
async fn stop_internal_session(state : HostState, session_id : String) -> Unit {
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  let sink : Sink = { queue, subscribed: Ref(false), closed: Ref(false) }
  let params = @contracts.agent_stop_params("run-stop-" + session_id, session_id)
  let request : @contracts.RpcRequest = {
    id: "run-stop-" + session_id,
    method: @contracts.METHOD_AGENT_STOP,
    params,
  }
  handle_agent_stop(state, sink, request, "run-stop-" + session_id)
}

///|
fn extract_session_id(text : String) -> String? {
  let parsed = @json.parse(text) catch { _ => return None }
  let object = match @contracts.as_object(parsed) {
    Some(value) => value
    None => return None
  }
  let result = match object.get("result") {
    Some(@json.Json::Object(fields)) => fields
    _ => return None
  }
  let session = match result.get("session") {
    Some(@json.Json::Object(fields)) => fields
    _ => return None
  }
  @contracts.string_field(session, "id")
}

// ---------------------------------------------------------------------------
// Evidence gate
// ---------------------------------------------------------------------------

///|
/// Run `verify[]` in the Run's worktree. Every command gets an Evidence row
/// and an Artifact with its output. All pass -> succeeded; any fail -> a
/// `verify` Decision; no silent success.
async fn run_verification(state : HostState, run_id : String, cwd : String) -> Unit {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  let task = match state.load_task(run.task_id) {
    Ok(value) => value
    Err(_) => return
  }
  if run.status != @contracts.RUN_STATUS_RUNNING &&
    run.status != @contracts.RUN_STATUS_VERIFYING {
    return
  }
  match
    transition_run(
      state,
      run_id,
      @contracts.RUN_STATUS_VERIFYING,
      stop_reason="verifying",
    ) {
    Ok(_) => ()
    Err(message) => {
      println("monexus-host: cannot enter verifying: " + message)
      return
    }
  }
  let verify = task.verify
  if verify.is_empty() {
    settle_verified(state, run_id, "no verify[] declared; gate passes")
    return
  }
  // Verification follows the same dispatch as the main step: inside the
  // environment container when the Run carries one, otherwise on the
  // workspace transport (opened once for all verify commands).
  let provider : @workspace.WorkspaceProvider? = if run.environment_id == "" {
    let workspace = match state.load_workspace(run.workspace_id) {
      Ok(value) => value
      Err(message) => {
        let _ = transition_run(
          state,
          run_id,
          @contracts.RUN_STATUS_FAILED,
          stop_reason="verify_setup_failed",
          error_text=message,
        )
        return
      }
    }
    match open_provider(state, workspace.machine_id, workspace.root) {
      Ok(value) => Some(value)
      Err(error) => {
        let _ = transition_run(
          state,
          run_id,
          @contracts.RUN_STATUS_FAILED,
          stop_reason="verify_setup_failed",
          error_text=error.message,
        )
        return
      }
    }
  } else {
    None
  }
  let mut failures = 0
  let mut index = 0
  for command in verify {
    index = index + 1
    if !run_is_active(state, run_id) {
      return
    }
    let kind = verify_kind(command)
    let started = @contracts.format_rfc3339(@async.now())
    let evidence_id = @contracts.new_id("evd", @async.now())
    let exec_result = if run.environment_id != "" {
      run_exec_in_environment(state, run, command, VERIFY_DEFAULT_TIMEOUT_S)
    } else {
      match provider {
        Some(value) =>
          match
            value.exec(
              command,
              cwd~,
              timeout_seconds=VERIFY_DEFAULT_TIMEOUT_S,
            ) {
            Ok(result) =>
              Ok({
                exit_code: result.exit_code,
                stdout: result.stdout,
                stderr: result.stderr,
                timed_out: result.timed_out,
              })
            Err(error) => Err(error.to_string())
          }
        None => Err("verify provider is unavailable")
      }
    }
    let (exit_code, output, timed_out, exec_error) = match exec_result {
      Ok(result) => (
        result.exit_code,
        truncate_output(result.stdout + result.stderr, RUN_OUTPUT_CAP),
        result.timed_out,
        "",
      )
      Err(message) =>
        (-1, "verify command failed to run: " + message, true, message)
    }
    let passed = exit_code == 0 && !timed_out
    let artifact_id = write_run_artifact(
      state,
      run_id,
      "verify-" + index.to_string() + "-" + kind + ".log",
      output,
      "verify_output",
      "text/plain",
    )
    let base_evidence = @contracts.EvidenceRecord::new(
      id=evidence_id,
      run_id~,
      name="verify[" + index.to_string() + "]",
      kind~,
      command~,
      started_at=started,
    )
    let evidence : @contracts.EvidenceRecord = {
      ..base_evidence,
      exit_code,
      passed,
      timed_out,
      artifact_id,
      excerpt: truncate_output(output, 1_000),
      finished_at: @contracts.format_rfc3339(@async.now()),
    }
    state.mutex.acquire()
    // Use the live projection: the Run moved to verifying after it was read,
    // and the evidence transaction rewrites the run row too.
    let latest = match state.store.get_run(run_id) {
      Ok(Some(value)) => value
      _ => run
    }
    let recorded = state.append_evidence_event(
      @contracts.EVENT_RUN_EVIDENCE,
      evidence_id,
      evidence.to_json(),
      evidence,
      latest,
    )
    state.mutex.release()
    match recorded {
      Ok(_) => ()
      Err(message) => {
        println("monexus-host: cannot persist evidence: " + message)
      }
    }
    if !passed {
      failures = failures + 1
      // Record the first failure reason on the run for the Run detail page.
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_VERIFYING,
        summary="verify failed: " + command,
        error_text=exec_error,
      )
    }
  }
  if failures == 0 {
    settle_verified(state, run_id, "verify[] passed")
  } else {
    match
      transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_WAITING_APPROVAL,
        stop_reason="verify_failed",
        summary=verify_fail_summary(state, run_id, failures),
      ) {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot enter waiting_approval: " + message)
    }
    request_verify_decision(state, run_id, failures)
    let _ = transition_task(
      state,
      task.id,
      @contracts.TASK_STATUS_WAITING_APPROVAL,
      summary="verify failed; owner decision requested",
    )
  }
}

///|
fn verify_fail_summary(
  state : HostState,
  run_id : String,
  failures : Int,
) -> String {
  let total = match state.store.list_evidence(run_id) {
    Ok(items) => items.length()
    Err(_) => failures
  }
  "verify failed (" + failures.to_string() + "/" +
  total.to_string() + " commands)"
}

///|
fn verify_kind(command : String) -> String {
  let lower = command.to_lower()
  if lower.contains("test") || lower.contains("pytest") ||
    lower.contains("moon test") || lower.contains("cargo test") {
    "test"
  } else if lower.contains("lint") || lower.contains("clippy") ||
    lower.contains("eslint") || lower.contains("ruff") {
    "lint"
  } else {
    "build"
  }
}

///|
async fn settle_verified(state : HostState, run_id : String, summary : String) -> Unit {
  match
    transition_run(
      state,
      run_id,
      @contracts.RUN_STATUS_SUCCEEDED,
      stop_reason="verified",
      summary~,
    ) {
    Ok(_) => ()
    Err(message) => {
      println("monexus-host: cannot settle run " + run_id + ": " + message)
    }
  }
}

///|
async fn request_verify_decision(
  state : HostState,
  run_id : String,
  failures : Int,
) -> Unit {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  let task = match state.load_task(run.task_id) {
    Ok(value) => value
    Err(_) => return
  }
  let detail = "Run " + run_id + " on " +
    (if run.machine_id == "" { "local" } else { run.machine_id }) +
    " failed " + failures.to_string() + " verify command(s).\n" +
    "Task: " + task.title + "\nWorktree: " + run.worktree_id +
    "\nChoose waive to accept the result anyway, retry to run the gate again, or fail to settle the run as failed."
  let options : Array[@contracts.DecisionOption] = [
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_WAIVE,
      name="Waive (settle succeeded)",
      kind="allow_once",
    ),
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_RETRY,
      name="Retry verification",
      kind="allow_once",
    ),
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_FAIL,
      name="Fail the run",
      kind="reject_once",
    ),
  ]
  let decision = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", @async.now()),
    kind=@contracts.DECISION_KIND_VERIFY,
    title="Evidence gate failed: " + task.title,
    detail~,
    session_id="",
    agent_id=run.agent_id,
    options~,
    created_at=@contracts.format_rfc3339(@async.now()),
    run_id=run_id,
  )
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    decision.id,
    @contracts.decision_payload(decision),
    decision,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => {
      println("monexus-host: cannot persist verify decision: " + message)
    }
  }
}

///|
/// Owner answered a verify Decision: waive settles succeeded with the failed
/// evidence marked waived; retry re-runs the gate; fail settles failed.
async fn handle_verify_decision_respond(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  record : @contracts.DecisionRecord,
  option_id : String,
  answer_text : String,
  answered_by : String,
) -> Unit {
  let run_id = record.run_id
  if run_id == "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("verify decision has no run_id"),
    )
    return
  }
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_not_found(message))
      return
    }
  }
  let chosen = if option_id == "" {
    @contracts.DECISION_OPTION_FAIL
  } else {
    option_id
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  let answered = {
    ..record,
    status: @contracts.DECISION_STATUS_ANSWERED,
    option_id: chosen,
    answer_text,
    answered_by: if answered_by == "" { "owner" } else { answered_by },
    answered_at: timestamp,
  }
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_RESPONDED,
    answered.id,
    @contracts.decision_payload(answered),
    answered,
  )
  let _ = state.store.search_index(
    "decision/" + answered.id,
    "decision",
    answered.id,
    answered.title,
    answered.title + "\n" + answered.detail + "\n" + answered.answer_text,
    answered.created_at,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("cannot persist decision answer: " + message),
      )
      return
    }
  }
  audit(
    state,
    "decision.respond",
    if answered.answered_by == "" { "owner" } else { answered.answered_by },
    "decision/" + answered.id,
    "answered",
    target=run_id,
    policy=answered.kind,
    detail="option " + chosen + "\n" + answer_text,
    decision_id=answered.id,
    run_id=run_id,
  )
  match chosen {
    "waive" => {
      waive_failed_evidence(state, run_id)
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_SUCCEEDED,
        stop_reason="verify_waived",
        summary="owner waived failed verify evidence",
      )
      update_task_rollup_for_run(state, run_id)
    }
    "retry" => {
      match
        transition_run(
          state,
          run_id,
          @contracts.RUN_STATUS_VERIFYING,
          stop_reason="verify_retry",
        ) {
        Ok(updated) => {
          let cwd = match run_worktree_path(state, updated) {
            Ok(value) => value
            Err(message) => {
              task_io_error(
                state,
                sink,
                request,
                client_request_id,
                task_conflict(message),
              )
              return
            }
          }
          match state.group.val {
            Some(group) =>
              group.spawn_bg(
                allow_failure=true,
                () => run_verification(state, run_id, cwd)
              )
            None => ()
          }
        }
        Err(message) => {
          task_io_error(
            state,
            sink,
            request,
            client_request_id,
            task_conflict(message),
          )
          return
        }
      }
    }
    _ => {
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason="verify_failed",
        summary="owner failed the run after verify",
      )
      update_task_rollup_for_run(state, run_id)
    }
  }
  let result = @contracts.decision_result(answered)
  send_machine_result(state, sink, request, client_request_id, result)
  dispatch_queued(state)
}

///|
async fn waive_failed_evidence(state : HostState, run_id : String) -> Unit {
  let items = match state.store.list_evidence(run_id) {
    Ok(value) => value
    Err(_) => []
  }
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  for item in items {
    if !item.passed && !item.waived {
      let updated = { ..item, waived: true }
      state.mutex.acquire()
      let _ = state.append_evidence_event(
        @contracts.EVENT_RUN_EVIDENCE,
        updated.id,
        updated.to_json(),
        updated,
        run,
      )
      state.mutex.release()
    }
  }
}

///|
fn run_worktree_path(
  state : HostState,
  run : @contracts.RunRecord,
) -> Result[String, String] {
  if run.worktree_id != "" {
    match state.store.get_worktree(run.worktree_id) {
      Ok(Some(record)) => return Ok(record.path)
      Ok(None) => return Err("worktree not found")
      Err(message) => return Err(message)
    }
  }
  match state.store.get_workspace(run.workspace_id) {
    Ok(Some(record)) => Ok(record.root)
    Ok(None) => Err("workspace not found")
    Err(message) => Err(message)
  }
}

///|
async fn run_is_active(state : HostState, run_id : String) -> Bool {
  state.mutex.acquire()
  let active = match state.store.get_run(run_id) {
    Ok(Some(record)) => record.status == @contracts.RUN_STATUS_VERIFYING
    _ => false
  }
  state.mutex.release()
  active
}

///|
async fn write_run_artifact(
  state : HostState,
  run_id : String,
  name : String,
  text : String,
  kind : String,
  media_type : String,
) -> String {
  let dir = state.state_dir + "/runs/" + run_id
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/" + name
  // Artifacts are owner-readable logs: redact credential-looking values
  // before the bytes reach disk or an event payload.
  let text = @contracts.redact_secrets(text)
  let written = @fs.write_file(path, text, permission=0o600) catch {
    error => {
      println("monexus-host: cannot write run artifact: " + error.to_string())
      return ""
    }
  }
  ignore(written)
  let now = @async.now()
  let artifact = @contracts.ArtifactRecord::new(
    id=@contracts.new_id("art", now),
    session_id="",
    kind~,
    uri=path,
    digest=content_digest(text),
    size=text.length(),
    media_type~,
    created_at=@contracts.format_rfc3339(now),
    run_id~,
  )
  state.mutex.acquire()
  let recorded = state.append_artifact_event(
    @contracts.EVENT_ARTIFACT_CREATED,
    artifact.id,
    @contracts.artifact_payload(artifact),
    artifact,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => artifact.id
    Err(message) => {
      println("monexus-host: cannot record run artifact: " + message)
      ""
    }
  }
}

// ---------------------------------------------------------------------------
// Task rollup
// ---------------------------------------------------------------------------

///|
async fn update_task_rollup_for_run(state : HostState, run_id : String) -> Unit {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  update_task_rollup(state, run.task_id)
}

///|
/// Aggregate all Runs of a Task. Waiting dominates running; the Task only
/// succeeds when every Run succeeded.
async fn update_task_rollup(state : HostState, task_id : String) -> Unit {
  state.mutex.acquire()
  let task = match state.store.get_task(task_id) {
    Ok(Some(value)) => value
    _ => {
      state.mutex.release()
      return
    }
  }
  if @contracts.task_status_is_terminal(task.status) ||
    task.status == @contracts.TASK_STATUS_DRAFT ||
    task.status == @contracts.TASK_STATUS_PLANNED {
    state.mutex.release()
    return
  }
  let runs = match state.store.list_runs(task_id, "") {
    Ok(value) => value
    Err(_) => {
      state.mutex.release()
      return
    }
  }
  state.mutex.release()
  if runs.is_empty() {
    return
  }
  let mut succeeded = 0
  let mut failed = 0
  let mut cancelled = 0
  let mut waiting = 0
  let mut active = 0
  for run in runs {
    match run.status {
      "succeeded" => succeeded = succeeded + 1
      "failed" | "lost" => failed = failed + 1
      "cancelled" => cancelled = cancelled + 1
      "waiting_approval" | "waiting_input" => waiting = waiting + 1
      _ => active = active + 1
    }
  }
  let total = runs.length()
  let status = if waiting > 0 {
    @contracts.TASK_STATUS_WAITING_APPROVAL
  } else if active > 0 {
    @contracts.TASK_STATUS_RUNNING
  } else if failed > 0 {
    @contracts.TASK_STATUS_FAILED
  } else if succeeded == total {
    @contracts.TASK_STATUS_SUCCEEDED
  } else if cancelled == total {
    @contracts.TASK_STATUS_CANCELLED
  } else {
    @contracts.TASK_STATUS_FAILED
  }
  let summary = succeeded.to_string() + "/" + total.to_string() +
    " runs succeeded" +
    (if failed > 0 {
      ", " + failed.to_string() + " failed"
    } else {
      ""
    }) +
    (if waiting > 0 {
      ", " + waiting.to_string() + " waiting"
    } else {
      ""
    })
  if task.status != status && @contracts.task_transition_allowed(task.status, status) {
    let _ = transition_task(state, task_id, status, summary~)
  } else if task.status == @contracts.TASK_STATUS_WAITING_APPROVAL &&
    status == @contracts.TASK_STATUS_WAITING_APPROVAL {
    // Refresh the summary without a state change.
    state.mutex.acquire()
    let updated = { ..task, result_summary: summary }
    let _ = state.append_task_event(
      @contracts.EVENT_TASK_STATUS_CHANGED,
      task_id,
      updated.to_json(),
      updated,
    )
    state.mutex.release()
  }
}

// ---------------------------------------------------------------------------
// Cancellation
// ---------------------------------------------------------------------------

///|
async fn cancel_run_internal(state : HostState, run_id : String, reason : String) -> Result[
  @contracts.RunRecord,
  String,
] {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if @contracts.run_status_is_terminal(run.status) {
    return Ok(run)
  }
  if run.session_id != "" {
    stop_internal_session(state, run.session_id)
  }
  expire_run_decisions(state, run_id)
  match
    transition_run(
      state,
      run_id,
      @contracts.RUN_STATUS_CANCELLED,
      stop_reason="cancelled",
      summary=reason,
    ) {
    Ok(value) => Ok(value)
    Err(message) => Err(message)
  }
}

///|
async fn expire_run_decisions(state : HostState, run_id : String) -> Unit {
  let pending = match
    state.store.list_decisions(@contracts.DECISION_STATUS_PENDING, "") {
    Ok(value) => value
    Err(_) => []
  }
  for decision in pending {
    if decision.run_id != run_id {
      continue
    }
    let expired = {
      ..decision,
      status: @contracts.DECISION_STATUS_EXPIRED,
      answered_by: "host",
      answered_at: @contracts.format_rfc3339(@async.now()),
      delivery_error: "run cancelled before the decision was answered",
    }
    state.mutex.acquire()
    let _ = state.append_decision_event(
      @contracts.EVENT_DECISION_EXPIRED,
      expired.id,
      @contracts.decision_payload(expired),
      expired,
    )
    state.mutex.release()
    audit(
      state,
      "decision.expire",
      "host",
      "decision/" + expired.id,
      "expired",
      target=run_id,
      policy=expired.kind,
      detail="run was cancelled before the decision was answered",
      decision_id=expired.id,
      run_id~,
    )
  }
}

// ---------------------------------------------------------------------------
// Simple loaders
// ---------------------------------------------------------------------------

///|
async fn HostState::load_task(self : HostState, task_id : String) -> Result[
  @contracts.TaskRecord,
  String,
] {
  self.mutex.acquire()
  let result = match self.store.get_task(task_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err("task not found: " + task_id)
    Err(message) => Err(message)
  }
  self.mutex.release()
  result
}

///|
async fn HostState::load_run(self : HostState, run_id : String) -> Result[
  @contracts.RunRecord,
  String,
] {
  self.mutex.acquire()
  let result = match self.store.get_run(run_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err("run not found: " + run_id)
    Err(message) => Err(message)
  }
  self.mutex.release()
  result
}

///|
async fn HostState::load_workspace(self : HostState, workspace_id : String) -> Result[
  @contracts.WorkspaceRecord,
  String,
] {
  self.mutex.acquire()
  let result = match self.store.get_workspace(workspace_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err("workspace not found: " + workspace_id)
    Err(message) => Err(message)
  }
  self.mutex.release()
  result
}

// ---------------------------------------------------------------------------
// RPC handlers
// ---------------------------------------------------------------------------

///|
async fn handle_project_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let name = @contracts.string_field_or(request.params, "name", "").trim().to_string()
  if name == "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("missing project name"),
    )
    return
  }
  let verify = @contracts.verify_list_param(request.params, "verify")
  let now = @async.now()
  let record = @contracts.ProjectRecord::new(
    id=@contracts.new_id("prj", now),
    name~,
    repo_url=@contracts.string_field_or(request.params, "repo_url", ""),
    default_branch=@contracts.string_field_or(
      request.params,
      "default_branch",
      "main",
    ),
    verify~,
    created_at=@contracts.format_rfc3339(now),
  )
  state.mutex.acquire()
  let appended = state.append_project_event(
    @contracts.EVENT_PROJECT_CREATED,
    record.id,
    record.to_json(),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.json_object([("project", record.to_json())]),
      )
    Err(message) =>
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("cannot persist project: " + message),
      )
  }
}

///|
async fn handle_project_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  let records = match state.store.list_projects() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid("cannot list projects: " + message),
      )
      return
    }
  }
  state.mutex.release()
  let items : Array[@json.Json] = []
  for record in records {
    items.push(record.to_json())
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("projects", @contracts.json_array(items))]),
  )
}

///|
async fn handle_task_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let title = @contracts.string_field_or(request.params, "title", "").trim().to_string()
  if title == "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("missing task title"),
    )
    return
  }
  let requested_status = @contracts.string_field_or(
    request.params,
    "status",
    @contracts.TASK_STATUS_DRAFT,
  )
  if requested_status != @contracts.TASK_STATUS_DRAFT &&
    requested_status != @contracts.TASK_STATUS_PLANNED &&
    requested_status != @contracts.TASK_STATUS_READY {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("task status must be draft, planned or ready"),
    )
    return
  }
  let parent_id = @contracts.string_field_or(request.params, "parent_id", "")
  let project_id = @contracts.string_field_or(request.params, "project_id", "")
  let workspace_id = @contracts.string_field_or(
    request.params,
    "workspace_id",
    "",
  )
  let agent_id = @contracts.string_field_or(request.params, "agent_id", "")
  let mut verify = @contracts.verify_list_param(request.params, "verify")
  // Per-Task skill bindings are exact tuples declared by the owner (ADR-0015
  // §4.1). They only affect sessions created for this Task; triggers build
  // Tasks through `TaskRecord::new` and therefore cannot add or modify them.
  let skills = match @contracts.skill_bindings_param(request.params) {
    Some(value) => value
    None => {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid(
          "skills must be an array of exact name/version/content_hash/mode bindings",
        ),
      )
      return
    }
  }
  state.mutex.acquire()
  if parent_id != "" {
    match state.store.get_task(parent_id) {
      Ok(Some(_)) => ()
      Ok(None) => {
        state.mutex.release()
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_not_found("parent task not found"),
        )
        return
      }
      Err(message) => {
        state.mutex.release()
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_invalid("cannot read parent task: " + message),
        )
        return
      }
    }
  }
  if project_id != "" {
    match state.store.get_project(project_id) {
      Ok(Some(project)) =>
        if verify.is_empty() {
          verify = project.verify
        }
      Ok(None) => {
        state.mutex.release()
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_not_found("project not found"),
        )
        return
      }
      Err(message) => {
        state.mutex.release()
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_invalid("cannot read project: " + message),
        )
        return
      }
    }
  }
  let now = @async.now()
  let record = @contracts.TaskRecord::new(
    id=@contracts.new_id("tsk", now),
    title~,
    goal=@contracts.string_field_or(request.params, "goal", ""),
    parent_id~,
    project_id~,
    agent_id~,
    workspace_id~,
    verify~,
    created_at=@contracts.format_rfc3339(now),
    status=requested_status,
    skills~,
  )
  let appended = state.append_task_event(
    @contracts.EVENT_TASK_CREATED,
    record.id,
    record.to_json(),
    record,
  )
  if agent_id != "" {
    let _ = state.append_task_event(
      @contracts.EVENT_TASK_ASSIGNED,
      record.id,
      record.to_json(),
      record,
    )
  }
  state.mutex.release()
  match appended {
    Ok(_) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.task_result(record),
      )
    Err(message) =>
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("cannot persist task: " + message),
      )
  }
}

///|
async fn handle_task_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let status = @contracts.string_field_or(request.params, "status", "")
  let parent_id = @contracts.string_field_or(request.params, "parent_id", "")
  state.mutex.acquire()
  let records = match state.store.list_tasks(status, parent_id) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid("cannot list tasks: " + message),
      )
      return
    }
  }
  state.mutex.release()
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.tasks_result(records),
  )
}

///|
async fn handle_task_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let task_id = match @contracts.task_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_invalid(message))
      return
    }
  }
  state.mutex.acquire()
  let task = match state.store.get_task(task_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_not_found("task not found"),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid("cannot read task: " + message),
      )
      return
    }
  }
  let runs = match state.store.list_runs(task_id, "") {
    Ok(value) => value
    Err(_) => []
  }
  let children = match state.store.list_tasks("", task_id) {
    Ok(value) => value
    Err(_) => []
  }
  state.mutex.release()
  let run_items : Array[@json.Json] = []
  for run in runs {
    run_items.push(run.to_json())
  }
  let child_items : Array[@json.Json] = []
  for child in children {
    child_items.push(child.to_json())
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("task", task.to_json()),
      ("runs", @contracts.json_array(run_items)),
      ("children", @contracts.json_array(child_items)),
    ]),
  )
}

///|
async fn handle_task_cancel(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let task_id = match @contracts.task_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_invalid(message))
      return
    }
  }
  let reason = @contracts.string_field_or(request.params, "reason", "owner cancelled")
  let task = match state.load_task(task_id) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_not_found(message))
      return
    }
  }
  if @contracts.task_status_is_terminal(task.status) {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_conflict("task is already " + task.status),
    )
    return
  }
  state.mutex.acquire()
  let runs = match state.store.list_runs(task_id, "") {
    Ok(value) => value
    Err(_) => []
  }
  state.mutex.release()
  for run in runs {
    if !@contracts.run_status_is_terminal(run.status) {
      let _ = cancel_run_internal(state, run.id, "task cancelled")
    }
  }
  match transition_task(state, task_id, @contracts.TASK_STATUS_CANCELLED, cancel_reason=reason) {
    Ok(updated) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.task_result(updated),
      )
    Err(message) =>
      task_io_error(state, sink, request, client_request_id, task_conflict(message))
  }
  dispatch_queued(state)
}

///|
async fn handle_run_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let task_id = match @contracts.task_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_invalid(message))
      return
    }
  }
  let task = match state.load_task(task_id) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_not_found(message))
      return
    }
  }
    let idempotency_key = @contracts.string_field_or(
    request.params,
    "idempotency_key",
    "",
  )
  if idempotency_key != "" {
    state.mutex.acquire()
    let existing = match state.store.find_run_by_idempotency(idempotency_key) {
      Ok(value) => value
      Err(_) => None
    }
    state.mutex.release()
    match existing {
      Some(run) => {
        send_machine_result(
          state,
          sink,
          request,
          client_request_id,
          @contracts.run_result(run),
        )
        return
      }
      None => ()
    }
  }
if @contracts.task_status_is_terminal(task.status) {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_conflict("task is already " + task.status),
    )
    return
  }
  if task.status == @contracts.TASK_STATUS_DRAFT ||
    task.status == @contracts.TASK_STATUS_PLANNED {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_conflict("task must be ready before dispatch (status=" + task.status + ")"),
    )
    return
  }
  let workspace_id = match @contracts.string_field(request.params, "workspace_id") {
    Some(value) if value.trim() != "" => value
    _ => task.workspace_id
  }
  if workspace_id == "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("run needs a workspace_id"),
    )
    return
  }
  state.mutex.acquire()
  let workspace_exists = match state.store.get_workspace(workspace_id) {
    Ok(Some(_)) => true
    _ => false
  }
  state.mutex.release()
  if !workspace_exists {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_not_found("workspace not found"),
    )
    return
  }
  let mode = @contracts.string_field_or(request.params, "mode", @contracts.RUN_MODE_COMMAND)
  if mode != @contracts.RUN_MODE_COMMAND && mode != @contracts.RUN_MODE_AGENT {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("mode must be command or agent"),
    )
    return
  }
  let command = @contracts.string_field_or(request.params, "command", "")
  let prompt = @contracts.string_field_or(request.params, "prompt", task.goal)
  let agent_id = @contracts.string_field_or(request.params, "agent_id", task.agent_id)
  if mode == @contracts.RUN_MODE_COMMAND && command.trim() == "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("command runs need a command"),
    )
    return
  }
  if mode == @contracts.RUN_MODE_AGENT && agent_id == "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("agent runs need an agent_id"),
    )
    return
  }
  // Risk policy. A denied command never becomes a Run. A high-risk command
  // becomes an approval Decision: the Run is created in `waiting_approval`
  // and only returns to the queue when the owner approves it.
  let policy = if mode == @contracts.RUN_MODE_COMMAND {
    @contracts.evaluate_command_policy(command)
  } else {
    {
      risk: @contracts.RISK_LOW,
      action: @contracts.POLICY_ALLOW,
      reason: "agent tool calls are governed by the ACP permission model",
    }
  }
  if policy.action == @contracts.POLICY_DENY {
    audit(
      state,
      "policy.deny",
      "host",
      "run/pending",
      "denied",
      target=task_id,
      policy=@contracts.POLICY_DENY,
      risk=policy.risk,
      detail=policy.reason + "\ncommand: " + command,
    )
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_conflict("command denied by policy: " + policy.reason),
    )
    return
  }
  audit(
    state,
    "policy.verdict",
    "host",
    "run/pending",
    policy.action,
    target=task_id,
    policy=policy.action,
    risk=policy.risk,
    detail=policy.reason + "\ncommand: " + command,
  )
  // Placement: explicit machine, or capability match over local + registered
  // machines. Requirements come from the optional `requires` object.
  let requires = match request.params.get("requires") {
    Some(@json.Json::Object(fields)) => fields
    _ => Map([])
  }
  let want_arch = @contracts.string_field_or(requires, "arch", "")
  let want_os = @contracts.string_field_or(requires, "os", "")
  let want_tool = @contracts.string_field_or(requires, "tool", "")
  let explicit_machine = @contracts.string_field_or(request.params, "machine_id", "")
  let mut machine_id = explicit_machine
  if explicit_machine == "" &&
    (want_arch != "" || want_os != "" || want_tool != "") {
    state.mutex.acquire()
    let machines = match state.store.list_machines() {
      Ok(value) => value
      Err(_) => []
    }
    state.mutex.release()
    let mut selected = ""
    if machine_matches(state, "", want_arch, want_os, want_tool) {
      selected = ""
    } else {
      for record in machines {
        if selected != "" {
          continue
        }
        if machine_matches(state, record.id, want_arch, want_os, want_tool) {
          selected = record.id
        }
      }
    }
    if selected == "" && !machine_matches(state, "", want_arch, want_os, want_tool) {
      // No candidate satisfied the requirements (including local).
      let local_ok = machine_matches(state, "", want_arch, want_os, want_tool)
      if !local_ok && selected == "" {
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_conflict("no machine matches the requested capabilities"),
        )
        return
      }
    }
    machine_id = selected
  } else if explicit_machine != "" {
    state.mutex.acquire()
    let exists = match state.store.get_machine(explicit_machine) {
      Ok(Some(_)) => true
      _ => false
    }
    state.mutex.release()
    if !exists {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_not_found("machine not found"),
      )
      return
    }
    if !machine_matches(state, explicit_machine, want_arch, want_os, want_tool) {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("machine does not match the requested capabilities"),
      )
      return
    }
  }
  if mode == @contracts.RUN_MODE_AGENT && machine_id != "" {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("agent runs are local-only in M5"),
    )
    return
  }
  let worktree_id = @contracts.string_field_or(request.params, "worktree_id", "")
  if worktree_id != "" {
    state.mutex.acquire()
    let valid = match state.store.get_worktree(worktree_id) {
      Ok(Some(record)) => record.workspace_id == workspace_id
      _ => false
    }
    state.mutex.release()
    if !valid {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_not_found("worktree not found for this workspace"),
      )
      return
    }
  }
  // A2.1: an explicit or active environment owns execution for this exact
  // target. The Run keeps the environment id so every step (command,
  // verification, diff) dispatches through the same container. Agent runs
  // through environments are A2.2 scope and are rejected here.
  let requested_environment = @contracts.string_field_or(
    request.params,
    "environment_id",
    "",
  )
  let resolved_environment : @contracts.EnvironmentRecord? = if requested_environment != "" {
    let loaded = match environment_record_by_id(state, requested_environment) {
      Ok(Some(value)) => value
      Ok(None) => {
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_not_found("environment not found"),
        )
        return
      }
      Err(error) => {
        task_io_error(state, sink, request, client_request_id, error)
        return
      }
    }
    if loaded.workspace_id != workspace_id ||
      loaded.worktree_id != worktree_id {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("environment does not belong to this target"),
      )
      return
    }
    if loaded.state != @contracts.ENVIRONMENT_STATE_RUNNING {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("environment is not running (state=" + loaded.state + ")"),
      )
      return
    }
    Some(loaded)
  } else {
    active_environment_for_target(state, workspace_id, worktree_id)
  }
  let run_environment_id = match resolved_environment {
    Some(environment) => environment.id
    None => ""
  }
  match resolved_environment {
    Some(environment) => {
      if mode == @contracts.RUN_MODE_AGENT {
        task_io_error(
          state,
          sink,
          request,
          client_request_id,
          task_invalid(
            "agent runs with an environment are not supported in A2.1 (A2.2)",
          ),
        )
        return
      }
      if environment.machine_id != "" {
        if machine_id != "" && machine_id != environment.machine_id {
          task_io_error(
            state,
            sink,
            request,
            client_request_id,
            task_conflict("environment machine does not match the requested machine"),
          )
          return
        }
        machine_id = environment.machine_id
      } else if machine_id != "" {
        if !machine_is_local(state, machine_id) {
          task_io_error(
            state,
            sink,
            request,
            client_request_id,
            task_conflict(
              "environment is local but the run requested a remote machine",
            ),
          )
          return
        }
      }
      if want_arch != "" || want_os != "" || want_tool != "" {
        if !machine_matches(state, machine_id, want_arch, want_os, want_tool) {
          task_io_error(
            state,
            sink,
            request,
            client_request_id,
            task_conflict(
              "environment machine does not match the requested capabilities",
            ),
          )
          return
        }
      }
    }
    None => ()
  }
  let now = @async.now()
  // Credentials must not be persisted with the Run (ADR-0006 §5). Secret-
  // looking env names are replaced with a marker; the agent account on the
  // machine holds the real credential.
  let raw_env = @contracts.agent_env_from_object(request.params, "agent_env")
  let agent_env : Map[String, String] = Map([])
  for name, value in raw_env {
    agent_env.set(
      name,
      if @contracts.is_secret_key_name(name) { "[redacted]" } else { value },
    )
  }
  let created = @contracts.RunRecord::new(
    id=@contracts.new_id("run", now),
    task_id~,
    agent_id~,
    machine_id~,
    workspace_id~,
    worktree_id~,
    mode~,
    command~,
    prompt~,
    idempotency_key~,
    created_at=@contracts.format_rfc3339(now),
    agent_command=@contracts.string_field_or(request.params, "agent_command", ""),
    agent_args=@contracts.string_array_field(request.params, "agent_args"),
    agent_env~,
    environment_id=run_environment_id,
  )
  let record = if policy.action == @contracts.POLICY_ASK {
    {
      ..created,
      status: @contracts.RUN_STATUS_WAITING_APPROVAL,
      stop_reason: "policy_approval",
    }
  } else {
    created
  }
  state.mutex.acquire()
  let appended = state.append_run_event(
    run_event_for_status(record.status),
    record.id,
    record.to_json(),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_conflict("cannot persist run: " + message),
      )
      return
    }
  }
  if policy.action == @contracts.POLICY_ASK {
    request_approval_decision(state, record.id, policy.risk, policy.reason)
  }
  match
    transition_task(
      state,
      task_id,
      @contracts.TASK_STATUS_RUNNING,
      summary="dispatched run " + record.id,
    ) {
    Ok(_) => ()
    Err(_) => ()
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.run_result(record),
  )
  dispatch_queued(state)
}

///|
async fn handle_run_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let task_id = @contracts.string_field_or(request.params, "task_id", "")
  let status = @contracts.string_field_or(request.params, "status", "")
  state.mutex.acquire()
  let records = match state.store.list_runs(task_id, status) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid("cannot list runs: " + message),
      )
      return
    }
  }
  state.mutex.release()
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.runs_result(records),
  )
}

///|
async fn handle_run_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let run_id = match @contracts.run_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_invalid(message))
      return
    }
  }
  state.mutex.acquire()
  let loaded = match state.store.get_run(run_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err("run not found")
    Err(message) => Err(message)
  }
  state.mutex.release()
  let run = match loaded {
    Ok(value) => value
    Err(message) => {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_not_found(message),
      )
      return
    }
  }
  state.mutex.acquire()
  let evidence = match state.store.list_evidence(run_id) {
    Ok(value) => value
    Err(_) => []
  }
  let artifacts = match state.store.list_run_artifacts(run_id) {
    Ok(value) => value
    Err(_) => []
  }
  state.mutex.release()
  let diff = run_diff_text(state, run)
  let evidence_items : Array[@json.Json] = []
  for item in evidence {
    evidence_items.push(item.to_json())
  }
  let artifact_items : Array[@json.Json] = []
  for item in artifacts {
    artifact_items.push(item.to_json())
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("run", run.to_json()),
      ("evidence", @contracts.json_array(evidence_items)),
      ("artifacts", @contracts.json_array(artifact_items)),
      ("diff", @contracts.json_string(diff)),
    ]),
  )
}

///|
/// Uncommitted diff of the Run's worktree. Empty for non-git workspaces.
async fn run_diff_text(state : HostState, run : @contracts.RunRecord) -> String {
  let cwd = match run_worktree_path(state, run) {
    Ok(value) => value
    Err(_) => return ""
  }
  let result = match
    run_exec_checked(
      state,
      run,
      "git --no-pager diff --no-color HEAD",
      cwd,
      60,
    ) {
    Ok(value) => value
    Err(_) => return ""
  }
  truncate_output(result.stdout, RUN_OUTPUT_CAP)
}

///|
async fn handle_run_cancel(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let run_id = match @contracts.run_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_invalid(message))
      return
    }
  }
  match
    cancel_run_internal(
      state,
      run_id,
      @contracts.string_field_or(request.params, "reason", "owner cancelled"),
    ) {
    Ok(updated) => {
      update_task_rollup_for_run(state, run_id)
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.run_result(updated),
      )
    }
    Err(message) =>
      task_io_error(state, sink, request, client_request_id, task_conflict(message))
  }
  dispatch_queued(state)
}

///|
async fn handle_artifact_read(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let artifact_id = match @contracts.artifact_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      task_io_error(state, sink, request, client_request_id, task_invalid(message))
      return
    }
  }
  state.mutex.acquire()
  let loaded = match state.store.get_artifact(artifact_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err("artifact not found")
    Err(message) => Err(message)
  }
  state.mutex.release()
  let artifact = match loaded {
    Ok(value) => value
    Err(message) => {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_not_found(message),
      )
      return
    }
  }
  // Artifacts are host-written files under the state dir; refuse anything
  // else so the RPC cannot be used as an arbitrary file read.
  if !artifact.uri.has_prefix(state.state_dir) {
    task_io_error(
      state,
      sink,
      request,
      client_request_id,
      task_invalid("artifact is outside the state directory"),
    )
    return
  }
  let text = @fs.read_file(artifact.uri).text() catch {
    error => {
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_not_found("cannot read artifact: " + error.to_string()),
      )
      return
    }
  }
  let truncated = text.length() > ARTIFACT_READ_CAP
  let body = if truncated {
    text.substring(start=0, end=ARTIFACT_READ_CAP)
  } else {
    text
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("artifact", artifact.to_json()),
      ("text", @contracts.json_string(body)),
      ("truncated", @contracts.json_bool(truncated)),
    ]),
  )
}

///|
async fn handle_events_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let since_seq = @contracts.int64_field_or(request.params, "since", 0L)
  let limit = @contracts.int_field_or(request.params, "limit", 100)
  state.mutex.acquire()
  let events = match state.store.load_events_since(since_seq, limit) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid("cannot list events: " + message),
      )
      return
    }
  }
  state.mutex.release()
  let items : Array[@json.Json] = []
  for event in events {
    items.push(event.to_json())
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("events", @contracts.json_array(items)),
      ("next_seq", @contracts.json_int64(state.event_seq())),
    ]),
  )
}

///|
async fn handle_search_sessions(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let query = @contracts.string_field_or(request.params, "query", "")
  let limit = @contracts.int_field_or(request.params, "limit", 20)
  state.mutex.acquire()
  let hits = match state.store.search_docs(query, limit) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      task_io_error(
        state,
        sink,
        request,
        client_request_id,
        task_invalid("search failed: " + message),
      )
      return
    }
  }
  let backend = state.store.search_backend()
  state.mutex.release()
  let result = @contracts.json_object([
    ("hits", @contracts.json_array(hits.map(fn(hit) { hit.to_json() }))),
    ("backend", @contracts.json_string(backend)),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}
