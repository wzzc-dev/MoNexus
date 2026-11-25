///|
/// M6 recovery: durable tmux reattach, stop reasons, retry policy and the
/// audit trail (architecture §13).
///
/// Invariant: silence is not exit. A Run is only settled from an observed
/// exit code or a verified command result. When the host cannot observe the
/// process it records `stop_reason=unverifiable`, never auto-retries, and
/// raises a Decision for the owner.

///|
/// Result of a command step. `Completed` means the main step finished and the
/// evidence gate should run; `Recovered` means recovery already settled or
/// escalated the Run, so the caller must not settle it again.
enum RunStep {
  Completed(String)
  Recovered(String)
}

///|
/// How often a durable run is polled. Short at first so fast commands do not
/// pay a full second, then backs off to keep SSH polling cheap.
fn poll_base_ms() -> Int {
  match @env.get_env_var("MONEXUS_RECOVERY_POLL_MS") {
    Some(value) => {
      let parsed = @string.parse_int(value.trim()) catch { _ => 0 }
      if parsed > 20 { parsed } else { 120 }
    }
    None => 120
  }
}

///|
/// How long polling errors may persist before the Run is declared
/// unverifiable. A short SSH drop is tolerated inside this window.
fn unverifiable_ms() -> Int64 {
  match @env.get_env_var("MONEXUS_RECOVERY_UNVERIFIABLE_MS") {
    Some(value) => {
      let parsed = @string.parse_int64(value.trim()) catch { _ => 0L }
      if parsed > 0L { parsed } else { 15_000L }
    }
    None => 15_000L
  }
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------

///|
/// Append one `audit.recorded` event. All strings are redacted by
/// `AuditRecord::new`, so a secret cannot reach the log or the event stream.
async fn audit(
  state : HostState,
  action : String,
  actor : String,
  subject : String,
  outcome : String,
  target~ : String = "",
  policy~ : String = "",
  risk~ : String = "",
  detail~ : String = "",
  decision_id~ : String = "",
  run_id~ : String = "",
) -> Unit {
  let now = @async.now()
  let record = @contracts.AuditRecord::new(
    id=@contracts.new_id("aud", now),
    action~,
    actor~,
    subject~,
    outcome~,
    ts=@contracts.format_rfc3339(now),
    target~,
    policy~,
    risk~,
    detail~,
    decision_id~,
    run_id~,
  )
  state.mutex.acquire()
  let _ = state.append_event(
    @contracts.EVENT_AUDIT_RECORDED,
    "audit/" + record.id,
    record.to_json(),
  )
  state.mutex.release()
}

///|
async fn recovery_event(
  state : HostState,
  run_id : String,
  action : String,
  detail : String,
) -> Unit {
  let payload = @contracts.json_object([
    ("run_id", @contracts.json_string(run_id)),
    ("action", @contracts.json_string(action)),
    ("detail", @contracts.json_string(@contracts.redact_secrets(detail))),
    ("ts", @contracts.json_string(@contracts.format_rfc3339(@async.now()))),
  ])
  state.mutex.acquire()
  let _ = state.append_event(@contracts.EVENT_RUN_RECOVERED, run_id, payload)
  state.mutex.release()
}

// ---------------------------------------------------------------------------
// Durable handle plumbing
// ---------------------------------------------------------------------------

///|
fn run_handle(run : @contracts.RunRecord) -> @workspace.DurableHandle? {
  if run.durable != "tmux" || run.tmux_session == "" {
    return None
  }
  Some({
    durable: true,
    session: run.tmux_session,
    log_path: run.log_path,
    exit_path: run.exit_path,
  })
}

///|
async fn persist_durable_handle(
  state : HostState,
  run_id : String,
  handle : @workspace.DurableHandle,
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
    tmux_session: handle.session,
    log_path: handle.log_path,
    exit_path: handle.exit_path,
    durable: if handle.durable { "tmux" } else { "direct" },
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
async fn run_status_of(state : HostState, run_id : String) -> String {
  state.mutex.acquire()
  let status = match state.store.get_run(run_id) {
    Ok(Some(value)) => value.status
    _ => ""
  }
  state.mutex.release()
  status
}

// ---------------------------------------------------------------------------
// Stop policy: retry once, then ask the owner
// ---------------------------------------------------------------------------

///|
fn stop_reason_is_retryable(stop_reason : String) -> Bool {
  stop_reason == @contracts.STOP_REASON_EXITED ||
  stop_reason == @contracts.STOP_REASON_LOST
}

///|
fn has_pending_decision(
  state : HostState,
  run_id : String,
  kind : String,
) -> Bool {
  let pending = match state.store.list_decisions(@contracts.DECISION_STATUS_PENDING, "") {
    Ok(value) => value
    Err(_) => []
  }
  for record in pending {
    if record.run_id == run_id && (kind == "" || record.kind == kind) {
      return true
    }
  }
  false
}

///|
/// A retry Run clones the original placement/command/worktree. The clone is
/// keyed with a stable `idempotency_key`, so a second reconcile pass (or a
/// duplicate Decision answer) returns the existing Run instead of creating a
/// second one.
async fn create_retry_run(
  state : HostState,
  original : @contracts.RunRecord,
  actor : String,
  explicit : Bool,
) -> Result[@contracts.RunRecord, String] {
  let attempt = original.attempt + 1
  let base_key = if original.idempotency_key != "" {
    original.idempotency_key
  } else {
    original.id
  }
  let key = base_key + "/retry/" + attempt.to_string()
  state.mutex.acquire()
  let existing = match state.store.find_run_by_idempotency(key) {
    Ok(value) => value
    Err(_) => None
  }
  match existing {
    Some(record) => {
      state.mutex.release()
      return Ok(record)
    }
    None => ()
  }
  let now = @async.now()
  let record : @contracts.RunRecord = {
    ..original,
    id: @contracts.new_id("run", now),
    status: @contracts.RUN_STATUS_QUEUED,
    stop_reason: "",
    idempotency_key: key,
    attempt,
    tmux_session: "",
    log_path: "",
    exit_path: "",
    durable: "",
    exit_code: -1,
    retried_from: original.id,
    session_id: "",
    output_summary: "",
    last_error: "",
    created_at: @contracts.format_rfc3339(now),
    started_at: "",
    finished_at: "",
    updated_at: @contracts.format_rfc3339(now),
  }
  let appended = state.append_run_event(
    @contracts.EVENT_RUN_QUEUED,
    record.id,
    record.to_json(),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => return Err("cannot persist retry run: " + message)
  }
  audit(
    state,
    "run.retry",
    actor,
    "run/" + record.id,
    "queued",
    target=record.task_id,
    policy=if explicit { "owner" } else { "auto_once" },
    detail="retry of " + original.id + " (attempt " + attempt.to_string() +
    ", stop_reason=" + original.stop_reason + ")",
    run_id=record.id,
  )
  recovery_event(
    state,
    record.id,
    "run.retry",
    "attempt " + attempt.to_string() + " of " + original.id,
  )
  dispatch_queued(state)
  Ok(record)
}

///|
/// Raise the recovery Decision for a Run the host cannot settle alone. The
/// Decision is deduplicated: a second crash must not create a second queue
/// item for the same Run.
async fn request_recovery_decision(
  state : HostState,
  run_id : String,
  stop_reason : String,
  detail : String,
) -> Unit {
  if has_pending_decision(state, run_id, @contracts.DECISION_KIND_RECOVERY) {
    return
  }
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  let task_title = match state.load_task(run.task_id) {
    Ok(task) => task.title
    Err(_) => run.task_id
  }
  let options : Array[@contracts.DecisionOption] = [
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_RETRY,
      name="Retry (new attempt)",
      kind="allow_once",
    ),
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_FAIL,
      name="Fail the run",
      kind="reject_once",
    ),
  ]
  let record = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", @async.now()),
    kind=@contracts.DECISION_KIND_RECOVERY,
    title="Run stopped: " + task_title,
    detail=detail + "\nRun: " + run_id + "\nStop reason: " + stop_reason +
    "\nAttempt: " + run.attempt.to_string() +
    "\nRetrying may duplicate side effects; the host never retries an unverifiable run automatically.",
    session_id="",
    agent_id=run.agent_id,
    options~,
    created_at=@contracts.format_rfc3339(@async.now()),
    run_id~,
  )
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    record.id,
    @contracts.decision_payload(record),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot persist recovery decision: " + message)
  }
  audit(
    state,
    "recovery.escalate",
    "host",
    "run/" + run_id,
    stop_reason,
    target=run.task_id,
    policy=if stop_reason == @contracts.STOP_REASON_UNVERIFIABLE {
      "never_auto_retry"
    } else {
      "retry_exhausted"
    },
    detail="decision " + record.id + ": " + detail,
    decision_id=record.id,
    run_id~,
  )
}

///|
/// Apply the stop policy after a Run stopped with an observed reason.
/// `exited`/`lost` retry once automatically; `unverifiable` goes straight to
/// the owner Decision.
async fn apply_stop_policy(
  state : HostState,
  run_id : String,
  stop_reason : String,
  detail : String,
) -> Unit {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  audit(
    state,
    "run.stop",
    "host",
    "run/" + run_id,
    stop_reason,
    target=run.task_id,
    policy=if stop_reason_is_retryable(stop_reason) {
      "retry_once"
    } else {
      "ask_owner"
    },
    detail="status=" + run.status + " attempt=" + run.attempt.to_string() +
    " " + detail,
    run_id~,
  )
  if stop_reason_is_retryable(stop_reason) && run.attempt < 2 {
    match create_retry_run(state, run, "host", false) {
      Ok(_) => {
        recovery_event(
          state,
          run_id,
          "run.retry.auto",
          "auto retry after " + stop_reason,
        )
      }
      Err(message) => {
        println("monexus-host: cannot create retry run: " + message)
        request_recovery_decision(state, run_id, stop_reason, detail)
      }
    }
    update_task_rollup_for_run(state, run_id)
    return
  }
  request_recovery_decision(state, run_id, stop_reason, detail)
  update_task_rollup_for_run(state, run_id)
}

// ---------------------------------------------------------------------------
// Durable monitor
// ---------------------------------------------------------------------------

///|
/// Poll a durable Run until it exits or becomes unobservable. Called from a
/// live dispatch and from startup reattach; both paths settle through the
/// same stop policy.
async fn monitor_durable_run(
  state : HostState,
  run_id : String,
  cwd : String,
  provider : @workspace.WorkspaceProvider,
  handle : @workspace.DurableHandle,
  timeout_seconds : Int,
) -> RunStep {
  let started_ms = @async.now()
  let deadline = started_ms + timeout_seconds.max(1).to_int64() * 1_000L
  let mut error_since : Int64 = -1L
  let mut attempt = 0
  while true {
    let status = run_status_of(state, run_id)
    if status != @contracts.RUN_STATUS_RUNNING &&
      status != @contracts.RUN_STATUS_VERIFYING {
      return Recovered("run is no longer active (status=" + status + ")")
    }
    let poll = provider.durable_poll(handle)
    if poll.error != "" {
      if error_since < 0L {
        error_since = @async.now()
      } else if @async.now() - error_since >= unverifiable_ms() {
        recovery_event(state, run_id, "run.unverifiable", poll.error)
        let _ = transition_run(
          state,
          run_id,
          @contracts.RUN_STATUS_LOST,
          stop_reason=@contracts.STOP_REASON_UNVERIFIABLE,
          error_text="cannot observe the run: " + poll.error,
        )
        apply_stop_policy(
          state,
          run_id,
          @contracts.STOP_REASON_UNVERIFIABLE,
          "host could not observe the run: " + poll.error,
        )
        return Recovered("unverifiable")
      }
    } else {
      error_since = -1L
    }
    if poll.exited {
      let output = truncate_output(poll.output, RUN_OUTPUT_CAP)
      let _ = write_run_artifact(
        state,
        run_id,
        "run-output.log",
        output,
        "run_output",
        "text/plain",
      )
      if poll.exit_code == 0 {
        let _ = transition_run(
          state,
          run_id,
          @contracts.RUN_STATUS_RUNNING,
          summary="exit 0",
        )
        return Completed("exit 0")
      }
      let detail = "command exited with code " +
        poll.exit_code.to_string() + ": " + truncate_output(output, 500)
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason=@contracts.STOP_REASON_EXITED,
        error_text=detail,
      )
      apply_stop_policy(
        state,
        run_id,
        @contracts.STOP_REASON_EXITED,
        detail,
      )
      return Recovered("exited")
    }
    if !poll.alive && poll.error == "" {
      // The session is gone and there is no exit marker: the exit code is
      // unknowable. Mark lost and apply the retry policy.
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_LOST,
        stop_reason=@contracts.STOP_REASON_LOST,
        error_text="durable session disappeared without an exit marker",
      )
      recovery_event(state, run_id, "run.lost", "exit marker absent")
      apply_stop_policy(
        state,
        run_id,
        @contracts.STOP_REASON_LOST,
        "tmux session " + handle.session + " is gone and no exit marker exists",
      )
      return Recovered("lost")
    }
    if @async.now() > deadline {
      provider.durable_stop(handle)
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason="timeout",
        error_text="run timed out after " + timeout_seconds.to_string() + "s",
      )
      apply_stop_policy(
        state,
        run_id,
        "timeout",
        "run exceeded its timeout",
      )
      return Recovered("timeout")
    }
    attempt = attempt + 1
    let backoff = poll_base_ms() + (attempt / 10) * 80
    @async.sleep(backoff.min(2_000))
  }
  Recovered("unreachable")
}

///|
/// Command-mode main step: durable tmux launch on local or SSH, with a
/// synchronous fallback when tmux is unavailable. The fallback is honest
/// about being unrecoverable (`durable=direct`).
async fn execute_command_run(
  state : HostState,
  run : @contracts.RunRecord,
  cwd : String,
) -> Result[RunStep, String] {
  if run.command.trim() == "" {
    return Err("run has no command")
  }
  let workspace = match state.load_workspace(run.workspace_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let provider = match open_provider(state, workspace.machine_id, workspace.root) {
    Ok(value) => value
    Err(error) => return Err(error.message)
  }
  let short = run.id.substring(start=(run.id.length() - 12).max(0))
  let session = "monexus-run-" + short
  let handle = match
    provider.durable_start(
      session~,
      command=run.command,
      cwd~,
      local_dir=state.state_dir + "/runs/" + run.id,
    ) {
    Ok(value) => value
    Err(error) =>
      return Err("cannot start a durable run: " + error.to_string())
  }
  let _ = persist_durable_handle(state, run.id, handle)
  if !handle.durable {
    // tmux is not installed; degrade to the M5 synchronous path. Recovery
    // records such a Run as unverifiable if the host restarts mid-flight.
    let existing = match state.load_run(run.id) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    let step = run_command_step(state, existing, cwd)
    match step {
      Ok((_kind, detail)) => Ok(Completed(detail))
      Err(message) => {
        // Synchronous mode observes the exit directly, so this is an
        // `exited` stop (not unverifiable) and the retry-once policy applies.
        let _ = transition_run(
          state,
          run.id,
          @contracts.RUN_STATUS_FAILED,
          stop_reason=@contracts.STOP_REASON_EXITED,
          error_text=message,
        )
        apply_stop_policy(
          state,
          run.id,
          @contracts.STOP_REASON_EXITED,
          message,
        )
        Ok(Recovered("exited"))
      }
    }
  } else {
    recovery_event(state, run.id, "run.durable", "tmux session " + session)
    let step = monitor_durable_run(
      state,
      run.id,
      cwd,
      provider,
      handle,
      RUN_DEFAULT_TIMEOUT_S,
    )
    Ok(step)
  }
}

// ---------------------------------------------------------------------------
// Startup reconcile
// ---------------------------------------------------------------------------

///|
/// Startup scan of every active Run. Runs that are still observable are
/// reattached; unobservable ones become `lost`/`unverifiable` and go through
/// the retry/Decision policy before the host serves clients.
pub async fn reconcile_runs(state : HostState) -> Unit {
  state.mutex.acquire()
  let active = match state.store.list_runs("", "") {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      println("monexus-host: cannot list runs for recovery: " + message)
      return
    }
  }
  state.mutex.release()
  for run in active {
    let status = run.status
    if status == @contracts.RUN_STATUS_SUCCEEDED ||
      status == @contracts.RUN_STATUS_FAILED ||
      status == @contracts.RUN_STATUS_CANCELLED {
      continue
    }
    if status == @contracts.RUN_STATUS_QUEUED {
      continue
    }
    if status == @contracts.RUN_STATUS_WAITING_APPROVAL ||
      status == @contracts.RUN_STATUS_WAITING_INPUT {
      // A pending approval/verify decision survives a restart for Runs (it
      // is not tied to a dead ACP pipe). Re-create it if the crash happened
      // between the state change and the decision insert.
      if !has_pending_decision(state, run.id, "") {
        if run.stop_reason == "verify_failed" {
          request_verify_decision(state, run.id, 1)
        } else if run.stop_reason == "policy_approval" {
          request_approval_decision(
            state,
            run.id,
            @contracts.POLICY_ASK,
            "",
          )
        }
      }
      continue
    }
    if status == @contracts.RUN_STATUS_LOST {
      if !has_pending_decision(state, run.id, @contracts.DECISION_KIND_RECOVERY) {
        apply_stop_policy(
          state,
          run.id,
          if run.stop_reason == "" { @contracts.STOP_REASON_LOST } else { run.stop_reason },
          "run was lost before this host start",
        )
      }
      continue
    }
    if status == @contracts.RUN_STATUS_VERIFYING {
      // Evidence rows may be partially written; re-running the gate could
      // duplicate side effects, so this is never auto-retried.
      let _ = transition_run(
        state,
        run.id,
        @contracts.RUN_STATUS_LOST,
        stop_reason=@contracts.STOP_REASON_UNVERIFIABLE,
        error_text="host restarted while the evidence gate was running",
      )
      recovery_event(
        state,
        run.id,
        "run.unverifiable",
        "host restarted during verification",
      )
      apply_stop_policy(
        state,
        run.id,
        @contracts.STOP_REASON_UNVERIFIABLE,
        "host restarted during the evidence gate; evidence may be partial",
      )
      continue
    }
    if status != @contracts.RUN_STATUS_RUNNING {
      continue
    }
    // Running: try to reattach to the durable session.
    let handle = match run_handle(run) {
      Some(value) => value
      None => {
        let _ = transition_run(
          state,
          run.id,
          @contracts.RUN_STATUS_LOST,
          stop_reason=@contracts.STOP_REASON_UNVERIFIABLE,
          error_text="run has no durable handle; the host cannot observe it",
        )
        recovery_event(
          state,
          run.id,
          "run.unverifiable",
          "no durable handle survived the host restart",
        )
        apply_stop_policy(
          state,
          run.id,
          @contracts.STOP_REASON_UNVERIFIABLE,
          "the run was not tmux-backed, so its exit cannot be verified",
        )
        continue
      }
    }
    let cwd = match run_worktree_path(state, run) {
      Ok(value) => value
      Err(message) => {
        let _ = transition_run(
          state,
          run.id,
          @contracts.RUN_STATUS_LOST,
          stop_reason=@contracts.STOP_REASON_UNVERIFIABLE,
          error_text="cannot resolve the run worktree: " + message,
        )
        apply_stop_policy(
          state,
          run.id,
          @contracts.STOP_REASON_UNVERIFIABLE,
          "worktree missing after restart: " + message,
        )
        continue
      }
    }
    let provider = match open_provider(state, run.machine_id, cwd) {
      Ok(value) => value
      Err(error) => {
        let _ = transition_run(
          state,
          run.id,
          @contracts.RUN_STATUS_LOST,
          stop_reason=@contracts.STOP_REASON_UNVERIFIABLE,
          error_text="cannot open the transport: " + error.message,
        )
        apply_stop_policy(
          state,
          run.id,
          @contracts.STOP_REASON_UNVERIFIABLE,
          "transport unavailable after restart: " + error.message,
        )
        continue
      }
    }
    let first = provider.durable_poll(handle)
    if first.error != "" {
      // Cannot observe at startup. Short drops end here for a crash restart:
      // the process may well be alive, so never auto-retry.
      let _ = transition_run(
        state,
        run.id,
        @contracts.RUN_STATUS_LOST,
        stop_reason=@contracts.STOP_REASON_UNVERIFIABLE,
        error_text="cannot observe the run at startup: " + first.error,
      )
      recovery_event(state, run.id, "run.unverifiable", first.error)
      apply_stop_policy(
        state,
        run.id,
        @contracts.STOP_REASON_UNVERIFIABLE,
        "host restarted and the transport is unavailable: " + first.error,
      )
      continue
    }
    if first.exited {
      if first.exit_code == 0 {
        recovery_event(
          state,
          run.id,
          "run.reconcile.reconnect",
          "session finished with exit 0 while the host was down",
        )
        audit(
          state,
          "recovery.reconnect",
          "host",
          "run/" + run.id,
          "exit_0",
          target=run.task_id,
          policy="resume_verification",
          detail="tmux session " + handle.session + " had already exited 0",
          run_id=run.id,
        )
        let _ = write_run_artifact(
          state,
          run.id,
          "run-output.log",
          truncate_output(first.output, RUN_OUTPUT_CAP),
          "run_output",
          "text/plain",
        )
        run_verification(state, run.id, cwd)
      } else {
        let detail = "command exited with code " + first.exit_code.to_string() +
          " while the host was down"
        let _ = transition_run(
          state,
          run.id,
          @contracts.RUN_STATUS_FAILED,
          stop_reason=@contracts.STOP_REASON_EXITED,
          error_text=detail,
        )
        apply_stop_policy(
          state,
          run.id,
          @contracts.STOP_REASON_EXITED,
          detail,
        )
      }
      continue
    }
    if !first.alive {
      let _ = transition_run(
        state,
        run.id,
        @contracts.RUN_STATUS_LOST,
        stop_reason=@contracts.STOP_REASON_LOST,
        error_text="durable session " + handle.session + " is gone",
      )
      recovery_event(state, run.id, "run.lost", handle.session + " missing")
      apply_stop_policy(
        state,
        run.id,
        @contracts.STOP_REASON_LOST,
        "tmux session " + handle.session + " is gone and no exit marker exists",
      )
      continue
    }
    recovery_event(
      state,
      run.id,
      "run.reconcile.reconnect",
      "reattached to tmux session " + handle.session,
    )
    audit(
      state,
      "recovery.reconnect",
      "host",
      "run/" + run.id,
      "running",
      target=run.task_id,
      policy="reattach",
      detail="tmux session " + handle.session + " is still alive",
      run_id=run.id,
    )
    match state.group.val {
      Some(group) =>
        group.spawn_bg(
          allow_failure=true,
          () => {
            let step = monitor_durable_run(
              state,
              run.id,
              cwd,
              provider,
              handle,
              RUN_DEFAULT_TIMEOUT_S,
            )
            match step {
              Completed(_) => run_verification(state, run.id, cwd)
              Recovered(_) => ()
            }
          },
        )
      None => ()
    }
  }
  dispatch_queued(state)
}

// ---------------------------------------------------------------------------
// Owner answers: approval and recovery Decisions
// ---------------------------------------------------------------------------

///|
/// Policy approval Decision for a high-risk command. The Run is created in
/// `waiting_approval`; approving returns it to the queue, denying fails it.
async fn request_approval_decision(
  state : HostState,
  run_id : String,
  risk : String,
  reason : String,
) -> Unit {
  if has_pending_decision(state, run_id, @contracts.DECISION_KIND_APPROVAL) {
    return
  }
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  let task_title = match state.load_task(run.task_id) {
    Ok(task) => task.title
    Err(_) => run.task_id
  }
  let options : Array[@contracts.DecisionOption] = [
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_APPROVE,
      name="Approve once",
      kind="allow_once",
    ),
    @contracts.DecisionOption::new(
      option_id=@contracts.DECISION_OPTION_DENY,
      name="Deny",
      kind="reject_once",
    ),
  ]
  let record = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", @async.now()),
    kind=@contracts.DECISION_KIND_APPROVAL,
    title="Approval needed: " + task_title,
    detail="Risk: " + risk + "\n" + reason + "\nCommand:\n" +
    @contracts.redact_secrets(run.command) + "\nRun: " + run_id,
    session_id="",
    agent_id=run.agent_id,
    options~,
    created_at=@contracts.format_rfc3339(@async.now()),
    run_id~,
  )
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    record.id,
    @contracts.decision_payload(record),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot persist approval decision: " + message)
  }
  audit(
    state,
    "policy.approval",
    "host",
    "run/" + run_id,
    "ask",
    target=run.task_id,
    policy=@contracts.POLICY_ASK,
    risk~,
    detail="decision " + record.id + ": " + reason,
    decision_id=record.id,
    run_id~,
  )
}

///|
async fn handle_approval_decision_respond(
  state : HostState,
  run_id : String,
  option_id : String,
  answered_by : String,
) -> Unit {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  let risk = @contracts.evaluate_command_policy(run.command).risk
  if option_id == @contracts.DECISION_OPTION_APPROVE {
    match
      transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_QUEUED,
        summary="owner approved the command",
      ) {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot queue approved run: " + message)
    }
    audit(
      state,
      "policy.approve",
      answered_by,
      "run/" + run_id,
      "approved",
      target=run.task_id,
      policy=@contracts.POLICY_ASK,
      risk~,
      detail="owner approved the high-risk command",
      run_id~,
    )
    dispatch_queued(state)
  } else {
    let _ = transition_run(
      state,
      run_id,
      @contracts.RUN_STATUS_FAILED,
      stop_reason=@contracts.STOP_REASON_APPROVAL_DENIED,
      summary="owner denied the high-risk command",
    )
    audit(
      state,
      "policy.deny",
      answered_by,
      "run/" + run_id,
      "denied",
      target=run.task_id,
      policy=@contracts.POLICY_ASK,
      risk~,
      detail="owner denied the high-risk command",
      run_id~,
    )
    update_task_rollup_for_run(state, run_id)
  }
}

///|
async fn handle_recovery_decision_respond(
  state : HostState,
  run_id : String,
  option_id : String,
  answered_by : String,
) -> Unit {
  let run = match state.load_run(run_id) {
    Ok(value) => value
    Err(_) => return
  }
  if option_id == @contracts.DECISION_OPTION_RETRY {
    match create_retry_run(state, run, answered_by, true) {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot create owner retry run: " + message)
    }
  } else {
    if !@contracts.run_status_is_terminal(run.status) {
      let _ = transition_run(
        state,
        run_id,
        @contracts.RUN_STATUS_FAILED,
        stop_reason="recovery_failed",
        summary="owner failed the run after recovery",
      )
    }
    update_task_rollup_for_run(state, run_id)
  }
  dispatch_queued(state)
}

// ---------------------------------------------------------------------------
// Audit listing
// ---------------------------------------------------------------------------

///|
/// `audit.list`: newest audit records first, optionally filtered to one Run.
/// Secrets were redacted when the record was written; the listing re-checks
/// as a defence in depth.
pub async fn handle_audit_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let run_filter = @contracts.string_field_or(request.params, "run_id", "")
  let limit = match @contracts.int_field(request.params, "limit") {
    Some(value) => value.max(1).min(500)
    None => 200
  }
  state.mutex.acquire()
  let events = match state.store.load_events_since(0L, 2_000) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot list audit events: " + message),
      )
      return
    }
  }
  state.mutex.release()
  let records : Array[@contracts.AuditRecord] = []
  for event in events {
    if event.event_type != @contracts.EVENT_AUDIT_RECORDED {
      continue
    }
    match @contracts.audit_from_json(event.payload) {
      Some(record) =>
        if run_filter == "" || record.run_id == run_filter {
          records.push(record)
        }
      None => ()
    }
  }
  let out : Array[@contracts.AuditRecord] = []
  let mut index = records.length() - 1
  while index >= 0 && out.length() < limit {
    out.push(records[index])
    index = index - 1
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.audit_list_result(out),
  )
}
