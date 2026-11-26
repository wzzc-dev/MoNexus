///|
/// Agent session / Decision RPC handlers (M4).
///
/// The host owns metadata, heartbeat, decisions and transcripts; the provider
/// owns the ACP stdio process. A permission request is never auto-approved:
/// it becomes a pending Decision, the session moves to `waiting_decision`, and
/// the answer is written back on the same stdio pipe.

///|
const AGENT_TRANSCRIPT_CAP : Int = 131_072

///|
const AGENT_STDERR_CAP : Int = 2_048

///|
const AGENT_DIFF_CAP : Int = 65_536

///|
const AGENTS_FILE : String = "AGENTS.md"

///|
const MEMORY_FILE : String = "MEMORY.md"

///|
fn agent_invalid(message : String) -> @contracts.RpcError {
  @contracts.agent_error(@contracts.AGENT_ERR_INVALID, message)
}

///|
fn agent_not_found(message : String) -> @contracts.RpcError {
  @contracts.agent_error(@contracts.AGENT_ERR_NOT_FOUND, message)
}

///|
fn agent_conflict(message : String) -> @contracts.RpcError {
  @contracts.agent_error(@contracts.AGENT_ERR_CONFLICT, message)
}

///|
fn agent_unsupported(message : String) -> @contracts.RpcError {
  @contracts.agent_error(@contracts.AGENT_ERR_UNSUPPORTED, message)
}

///|
fn agent_readiness_error(message : String) -> @contracts.RpcError {
  @contracts.agent_error(@contracts.AGENT_ERR_READINESS, message)
}

///|
fn agent_internal(message : String) -> @contracts.RpcError {
  @contracts.agent_error(@contracts.AGENT_ERR_INTERNAL, message)
}

///|
async fn agent_io_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  error : @contracts.RpcError,
) -> Unit {
  send_machine_error(state, sink, request, client_request_id, error)
}

///|
fn valid_agent_id(agent_id : String) -> Bool {
  if agent_id == "" || agent_id.length() > 64 {
    return false
  }
  for ch in agent_id {
    let code = ch.to_int()
    let ok = (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if !ok {
      return false
    }
  }
  true
}

///|
async fn ensure_agent_home(
  state : HostState,
  agent_id : String,
) -> Result[String, String] {
  if !valid_agent_id(agent_id) {
    return Err(
      "agent_id may contain only letters, digits, '.', '-' and '_' (max 64)",
    )
  }
  let home = state.state_dir + "/agents/" + agent_id
  @fs.mkdir(
    home,
    permission=0o700,
    recursive=true,
    allow_exist=true,
  ) catch {
    error => return Err("cannot create agent home: " + error.to_string())
  }
  @fs.mkdir(
    home + "/artifacts",
    permission=0o700,
    recursive=true,
    allow_exist=true,
  ) catch {
    error => return Err("cannot create artifact dir: " + error.to_string())
  }
  let agents_path = home + "/" + AGENTS_FILE
  let agents_exists = @fs.exists(agents_path) catch { _ => false }
  if !agents_exists {
    let template = "# AGENTS.md\n\n" +
      "This file is the read-only operating contract for this agent.\n" +
      "MoNexus never modifies it from an agent session; MEMORY.md is the\n" +
      "audited writable memory file.\n"
    @fs.write_file(
      agents_path,
      template,
      permission=0o444,
    ) catch {
      error => return Err("cannot write AGENTS.md: " + error.to_string())
    }
  }
  @fs.chmod(agents_path, 0o444) catch { _ => () }
  let memory_path = home + "/" + MEMORY_FILE
  let memory_exists = @fs.exists(memory_path) catch { _ => false }
  if !memory_exists {
    @fs.write_file(memory_path, "", permission=0o644) catch {
      error => return Err("cannot write MEMORY.md: " + error.to_string())
    }
  }
  @fs.chmod(memory_path, 0o644) catch { _ => () }
  Ok(home)
}

///|
async fn read_agent_file(
  state : HostState,
  agent_id : String,
  file : String,
) -> Result[String, String] {
  let home = match ensure_agent_home(state, agent_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let text = @fs.read_file(home + "/" + file).text() catch {
    error => return Err("cannot read " + file + ": " + error.to_string())
  }
  Ok(text)
}

///|
/// Take at most `limit` UTF-16 code units from the head of `text`.
fn cap_text(text : String, limit : Int) -> String {
  if limit <= 0 {
    return ""
  }
  if text.length() <= limit {
    return text
  }
  text[:limit].to_owned()
}

///|
/// Prefix a prompt with the capped AGENTS.md + MEMORY.md summary. Returns the
/// composed text and how many characters of memory were injected.
fn compose_memory_prompt(
  agents : String,
  memory : String,
  prompt : String,
  limit : Int,
) -> (String, Int) {
  let remaining = limit.max(0)
  let agents_part = cap_text(agents, remaining)
  let memory_part = cap_text(memory, remaining - agents_part.length())
  let block = "[MoNexus agent context]\n" +
    "--- AGENTS.md (read-only) ---\n" +
    agents_part +
    "\n--- MEMORY.md ---\n" +
    memory_part +
    "\n[/MoNexus agent context]\n\n"
  (block + prompt, agents_part.length() + memory_part.length())
}

///|
/// Deterministic non-cryptographic content fingerprint. It is only used to
/// show whether a memory snapshot changed and to label artifacts.
fn content_digest(text : String) -> String {
  "fnv-" + text.hash().to_string() + "-" + text.length().to_string()
}

///|
fn memory_diff(before : String, after : String) -> String {
  if before == after {
    return ""
  }
  let lines : Array[String] = [
    "# MEMORY.md snapshot diff",
    "before=" + content_digest(before),
    "after=" + content_digest(after),
    "--- before",
  ]
  for line in before.split("\n") {
    lines.push("- " + line.to_owned())
  }
  lines.push("+++ after")
  for line in after.split("\n") {
    lines.push("+ " + line.to_owned())
  }
  let text = lines.join("\n") + "\n"
  if text.length() > AGENT_DIFF_CAP {
    text[:AGENT_DIFF_CAP].to_owned() +
    "\n... diff truncated at " +
    AGENT_DIFF_CAP.to_string() +
    " bytes\n"
  } else {
    text
  }
}

///|
async fn append_transcript(
  state : HostState,
  runtime : AgentSessionRuntime,
  text : String,
) -> Unit {
  state.mutex.acquire()
  let current = runtime.transcript.val
  let combined = current.text + text
  let overflow = combined.length() - AGENT_TRANSCRIPT_CAP
  if overflow > 0 {
    let dropped = combined[:overflow].to_owned()
    runtime.transcript.val = {
      base: current.base + dropped.length().to_int64(),
      text: combined.substring(start=overflow),
    }
  } else {
    runtime.transcript.val = { base: current.base, text: combined }
  }
  state.mutex.release()
}

///|
async fn append_turn_text(
  state : HostState,
  runtime : AgentSessionRuntime,
  text : String,
) -> Unit {
  state.mutex.acquire()
  runtime.turn_text.val = runtime.turn_text.val + text
  state.mutex.release()
}

///|
/// Write the MEMORY.md snapshot diff for a finished run. The artifact file is
/// written before its event; the returned id is added to the final session
/// record by `finalize_agent_session`.
async fn write_memory_artifact(
  state : HostState,
  runtime : AgentSessionRuntime,
) -> String? {
  let memory_path = runtime.home + "/" + MEMORY_FILE
  let after = @fs.read_file(memory_path).text() catch {
    _ => return None
  }
  let diff = memory_diff(runtime.memory_before, after)
  if diff == "" {
    return None
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let path = runtime.home + "/artifacts/" + runtime.id + "-memory.diff"
  @fs.write_file(path, diff, permission=0o600) catch {
    error => {
      println("monexus-host: cannot write memory artifact: " + error.to_string())
      return None
    }
  }
  let artifact = @contracts.ArtifactRecord::new(
    id=@contracts.new_id("art", now),
    session_id=runtime.id,
    kind=@contracts.ARTIFACT_KIND_MEMORY_DIFF,
    uri=path,
    digest=content_digest(diff),
    size=diff.length(),
    media_type="text/x-diff",
    created_at=timestamp,
  )
  state.mutex.acquire()
  let recorded = state.append_artifact_event(
    @contracts.EVENT_AGENT_ARTIFACT_CREATED,
    artifact.id,
    @contracts.artifact_payload(artifact),
    artifact,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => Some(artifact.id)
    Err(message) => {
      println("monexus-host: cannot persist memory artifact: " + message)
      None
    }
  }
}

///|
fn final_state_for(stop_reason : String) -> String {
  @contracts.agent_terminal_state(stop_reason)
}

///|
fn session_event_for(stop_reason : String) -> String {
  @contracts.agent_session_end_event(stop_reason)
}

///|
/// Mark every still-pending decision of a session expired. Caller holds the
/// host mutex.
fn expire_session_decisions(
  state : HostState,
  session_id : String,
  timestamp : String,
) -> Unit {
  let pending = match
    state.store.list_decisions(@contracts.DECISION_STATUS_PENDING, session_id) {
    Ok(records) => records
    Err(message) => {
      println("monexus-host: cannot list pending decisions: " + message)
      []
    }
  }
  for record in pending {
    let expired = {
      ..record,
      status: @contracts.DECISION_STATUS_EXPIRED,
      answered_at: timestamp,
      answered_by: "host",
      delivery_error: "session ended before the decision was answered",
    }
    let _ = state.append_decision_event(
      @contracts.EVENT_DECISION_EXPIRED,
      expired.id,
      @contracts.decision_payload(expired),
      expired,
    )
    if record.kind == @contracts.DECISION_KIND_SKILL {
      let waiter = state.skill_waiters.get(record.id)
      state.skill_waiters.remove(record.id)
      match waiter {
        Some(queue) => ignore(queue.try_put("expired") catch { _ => false })
        None => ()
      }
    }
  }
}

///|
/// Claim-once session shutdown: interrupt, snapshot memory, expire pending
/// decisions, persist the final record, and remove the runtime.
async fn finalize_agent_session(
  state : HostState,
  runtime : AgentSessionRuntime,
  stop_reason : String,
  last_error : String,
) -> Unit {
  state.mutex.acquire()
  if runtime.finalized.val {
    state.mutex.release()
    return
  }
  runtime.finalized.val = true
  state.mutex.release()
  runtime.process.interrupt()
  let artifact_id = write_memory_artifact(state, runtime)
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  expire_session_decisions(state, runtime.id, timestamp)
  let record = match state.store.get_agent_session(runtime.id) {
    Ok(Some(value)) => value
    _ => @contracts.AgentSessionRecord::new(
      id=runtime.id,
      agent_id=runtime.agent_id,
      mode=@contracts.AGENT_MODE_ACP,
      cwd="",
      started_at=timestamp,
    )
  }
  let artifacts = record.artifacts
  match artifact_id {
    Some(id) => artifacts.push(id)
    None => ()
  }
  let updated = {
    ..record,
    state: final_state_for(stop_reason),
    stop_reason,
    last_error,
    stderr_tail: runtime.stderr_tail.val,
    artifacts,
    ended_at: timestamp,
    updated_at: timestamp,
  }
  let _ = state.append_agent_session_event(
    session_event_for(stop_reason),
    runtime.id,
    @contracts.agent_session_payload(updated),
    updated,
  )
  // Keep the finished transcript so a late agent.read still shows what the
  // session produced. The map is bounded; transcripts are in-memory only and
  // disappear with a host restart (the DB keeps the session record).
  if state.agent_transcripts.size() < 64 {
    state.agent_transcripts.set(runtime.id, runtime.transcript.val)
  }
  let _ = state.store.search_index(
    "session/" + runtime.id,
    "session",
    runtime.id,
    "session " + runtime.agent_id,
    runtime.transcript.val.text,
    timestamp,
  )
  state.agent_sessions.remove(runtime.id)
  state.mutex.release()
  finalize_skill_session(state, runtime.skill_token, runtime.id, runtime.home)
}

// ---------------------------------------------------------------------------
// ACP pump
// ---------------------------------------------------------------------------

///|
fn agent_json_id_key(id : @json.Json) -> String {
  match id {
    @json.Json::String(value) => value
    @json.Json::Number(value, ..) => value.to_string()
    _ => ""
  }
}

///|
fn permission_options(params : Map[String, @json.Json]) -> Array[
  @contracts.DecisionOption,
] {
  let options : Array[@contracts.DecisionOption] = []
  match params.get("options") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        match @contracts.as_object(item) {
          Some(fields) => {
            let option_id = @contracts.string_field_or(fields, "optionId", "")
            if option_id != "" {
              options.push(
                @contracts.DecisionOption::new(
                  option_id~,
                  name=@contracts.string_field_or(fields, "name", option_id),
                  kind=@contracts.string_field_or(fields, "kind", "allow_once"),
                ),
              )
            }
          }
          None => ()
        }
      }
    }
    _ => ()
  }
  options
}

///|
fn decision_title(params : Map[String, @json.Json], agent_id : String) -> String {
  match params.get("toolCall") {
    Some(@json.Json::Object(fields)) =>
      match @contracts.string_field(fields, "title") {
        Some(value) if value != "" => value
        _ => "Permission requested by " + agent_id
      }
    _ => "Permission requested by " + agent_id
  }
}

///|
fn decision_detail(params : Map[String, @json.Json]) -> String {
  match params.get("toolCall") {
    Some(value) => value.stringify()
    None => {
      match params.get("_meta") {
        Some(value) => value.stringify()
        None => ""
      }
    }
  }
}

///|
/// Turn a `session/request_permission` into a pending Decision. No automatic
/// allow/deny: the ACP reply is deferred until `decision.respond`.
async fn record_permission_decision(
  state : HostState,
  runtime : AgentSessionRuntime,
  acp_id : @json.Json,
  params : Map[String, @json.Json],
) -> Unit {
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  if runtime.finalized.val {
    state.mutex.release()
    return
  }
  // Link a Run-owned ACP session to its Run so the Inbox, audit trail and
  // cancellation can find it. Standalone agent sessions keep run_id="".
  let mut run_id = ""
  match state.store.list_runs("", "") {
    Ok(runs) =>
      for run in runs {
        if run_id == "" &&
          run.session_id == runtime.id &&
          !@contracts.run_status_is_terminal(run.status) {
          run_id = run.id
        }
      }
    Err(_) => ()
  }
  let decision = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", now),
    kind=@contracts.DECISION_KIND_PERMISSION,
    title=decision_title(params, runtime.agent_id),
    detail=decision_detail(params),
    session_id=runtime.id,
    agent_id=runtime.agent_id,
    options=permission_options(params),
    created_at=timestamp,
    run_id~,
  )
  let _ = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    decision.id,
    @contracts.decision_payload(decision),
    decision,
  )
  runtime.pending.set(decision.id, { acp_id, })
  match state.store.get_agent_session(runtime.id) {
    Ok(Some(record)) => {
      let updated = {
        ..record,
        state: @contracts.AGENT_STATE_WAITING,
        decisions: record.decisions + 1,
        updated_at: timestamp,
      }
      let _ = state.append_agent_session_event(
        @contracts.EVENT_AGENT_SESSION_UPDATED,
        runtime.id,
        @contracts.agent_session_payload(updated),
        updated,
      )
    }
    _ => ()
  }
  state.mutex.release()
}

///|
fn acp_update_kind(update : Map[String, @json.Json]) -> String {
  @contracts.string_field_or(update, "sessionUpdate", "")
}

///|
fn acp_update_text(update : Map[String, @json.Json]) -> String {
  match update.get("content") {
    Some(value) => @agent.json_content_text(value)
    None => ""
  }
}

///|
/// Handle one notification from the agent while a session is running.
async fn handle_agent_notification(
  state : HostState,
  runtime : AgentSessionRuntime,
  method_name : String,
  params : @json.Json,
) -> Unit {
  let object = match @contracts.as_object(params) {
    Some(value) => value
    None => Map([])
  }
  match method_name {
    "session/update" => {
      let session_id = @contracts.string_field_or(object, "sessionId", "")
      if session_id != "" && session_id != runtime.acp_session_id {
        return
      }
      let update = match object.get("update") {
        Some(@json.Json::Object(fields)) => fields
        _ => return
      }
      let kind = acp_update_kind(update)
      let text = acp_update_text(update)
      match kind {
        "agent_message_chunk" => {
          append_transcript(state, runtime, text)
          append_turn_text(state, runtime, text)
        }
        "agent_thought_chunk" => {
          append_transcript(state, runtime, "\n[thought] " + text + "\n")
          append_turn_text(state, runtime, text)
        }
        _ => ()
      }
    }
    _ => ()
  }
}

///|
/// Answer agent→client requests other than permissions explicitly, so the
/// adapter never hangs on an unsupported client capability.
async fn handle_agent_request(
  state : HostState,
  runtime : AgentSessionRuntime,
  method_name : String,
  id : @json.Json,
  params : @json.Json,
) -> Unit {
  match method_name {
    "session/request_permission" => {
      let object = match @contracts.as_object(params) {
        Some(value) => value
        None => Map([])
      }
      record_permission_decision(state, runtime, id, object)
    }
    _ => {
      ignore(
        runtime.process.write_json(
          @agent.acp_rpc_error(
            id,
            -32601,
            "unsupported ACP client method: " + method_name,
          ),
        ),
      )
    }
  }
}

///|
/// Handle the response to a previously sent `session/prompt`.
async fn handle_agent_response(
  state : HostState,
  runtime : AgentSessionRuntime,
  fields : Map[String, @json.Json],
) -> Unit {
  let id = match fields.get("id") {
    Some(value) => agent_json_id_key(value)
    None => return
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  let turn = match runtime.active_prompts.get(id) {
    Some(value) => value
    None => {
      state.mutex.release()
      return
    }
  }
  runtime.active_prompts.remove(id)
  let turn_text = runtime.turn_text.val
  runtime.turn_text.val = ""
  let error_text = match fields.get("error") {
    Some(value) => value.stringify()
    None => ""
  }
  let stop_reason = if error_text != "" {
    @contracts.AGENT_STOP_ERROR
  } else {
    match fields.get("result") {
      Some(@json.Json::Object(result)) =>
        @contracts.string_field_or(result, "stopReason", @contracts.AGENT_STOP_END_TURN)
      _ => @contracts.AGENT_STOP_END_TURN
    }
  }
  match state.store.get_agent_session(runtime.id) {
    Ok(Some(record)) => {
      let updated = {
        ..record,
        state: @contracts.AGENT_STATE_IDLE,
        stop_reason,
        last_error: error_text,
        updated_at: timestamp,
      }
      let _ = state.append_agent_session_event(
        @contracts.EVENT_AGENT_SESSION_OUTPUT,
        runtime.id,
        @contracts.agent_output_payload(runtime.id, turn, stop_reason, turn_text),
        updated,
      )
    }
    _ => ()
  }
  state.mutex.release()
}

///|
async fn handle_agent_message(
  state : HostState,
  runtime : AgentSessionRuntime,
  value : @json.Json,
) -> Unit {
  let fields = match @contracts.as_object(value) {
    Some(object) => object
    None => return
  }
  match fields.get("method") {
    Some(@json.Json::String(method_name)) => {
      let params = match fields.get("params") {
        Some(value) => value
        None => @contracts.json_object([])
      }
      match fields.get("id") {
        Some(id) =>
          handle_agent_request(state, runtime, method_name, id, params)
        None =>
          handle_agent_notification(state, runtime, method_name, params)
      }
    }
    _ => handle_agent_response(state, runtime, fields)
  }
}

///|
/// Read loop for one agent process. EOF finalizes the session; malformed
/// stdout lines are appended as plain transcript text.
///
/// ADR-0011: a completed turn is settled by its ACP response first, so an EOF
/// with no active prompt keeps the existing clean `exited` state. An EOF while
/// a prompt is still active is not a success: for an SSH launch the host reads
/// the local client's bounded exit status and records `lost` (255, an
/// unobservable status, or a killed local client) or `interrupted` (any other
/// exit of the remote agent). Local launches keep their existing `exited`
/// behavior in this round.
async fn agent_session_pump(
  state : HostState,
  runtime : AgentSessionRuntime,
) -> Unit {
  for ;; {
    match runtime.process.next_message() {
      @agent.RuntimeMessage::Eof => {
        let mut stop_reason = @contracts.AGENT_STOP_EXITED
        let mut last_error = ""
        if runtime.process.is_ssh() {
          state.mutex.acquire()
          let turn_in_flight = runtime.active_prompts.size() > 0
          state.mutex.release()
          if turn_in_flight {
            let exit_status = runtime.process.exit_status()
            stop_reason = @agent.remote_eof_stop_reason(exit_status)
            last_error = @agent.remote_eof_last_error(stop_reason)
          }
        } else if runtime.process.is_runtime() {
          // A1 has no reattach: a gap/dropped/offset error or a missing exit
          // record is always lost, even with no prompt in flight. A clean,
          // node-observed exit with a completed turn stays `exited`; an exit
          // mid-turn is `interrupted` (never success).
          let stream_error = runtime.process.stream_error()
          state.mutex.acquire()
          let turn_in_flight = runtime.active_prompts.size() > 0
          state.mutex.release()
          if stream_error != "" {
            stop_reason = @contracts.AGENT_STOP_LOST
            last_error = @agent.remote_eof_last_error(stop_reason)
          } else if turn_in_flight {
            let exit = runtime.process.remote_exit()
            stop_reason = @agent.runtime_eof_stop_reason(exit)
            last_error = @agent.remote_eof_last_error(stop_reason)
          }
        }
        finalize_agent_session(state, runtime, stop_reason, last_error)
        return
      }
      @agent.RuntimeMessage::Line(text) => {
        append_transcript(state, runtime, text + "\n")
        append_turn_text(state, runtime, text + "\n")
      }
      @agent.RuntimeMessage::JsonMessage(value) =>
        handle_agent_message(state, runtime, value)
    }
  }
}

// ---------------------------------------------------------------------------
// Handlers: probe / start
// ---------------------------------------------------------------------------

///|
fn agent_spec_from_params(
  params : Map[String, @json.Json],
) -> @agent.AgentSpec {
  @agent.AgentSpec::new(
    agent_id=@contracts.agent_id_param(params),
    mode=@contracts.agent_mode_param(params),
    command=@contracts.agent_command_param(params),
    args=@contracts.agent_args_param(params),
    cwd=@contracts.agent_cwd_param(params),
    env=@contracts.agent_env_from_json(params),
  )
}

///|
/// Append a readiness event and, on failure, a pending readiness Decision.
/// Caller holds the host mutex.
fn record_readiness(
  state : HostState,
  readiness : @contracts.AgentReadiness,
) -> Unit {
  let subject = "agent/" + readiness.agent_id
  if readiness.ok {
    let _ = state.append_event(
      @contracts.EVENT_AGENT_READINESS_OK,
      subject,
      @contracts.readiness_payload(readiness),
    )
  } else {
    let _ = state.append_event(
      @contracts.EVENT_AGENT_READINESS_FAILED,
      subject,
      @contracts.readiness_payload(readiness),
    )
    let now = @async.now()
    let decision = @contracts.DecisionRecord::new(
      id=@contracts.new_id("dec", now),
      kind=@contracts.DECISION_KIND_READINESS,
      title="Agent not ready: " + readiness.agent_id,
      detail=readiness.error +
      (if readiness.detail == "" { "" } else { " (" + readiness.detail + ")" }),
      session_id="",
      agent_id=readiness.agent_id,
      options=[],
      created_at=@contracts.format_rfc3339(now),
    )
    let _ = state.append_decision_event(
      @contracts.EVENT_DECISION_REQUESTED,
      decision.id,
      @contracts.decision_payload(decision),
      decision,
    )
  }
}

///|
async fn handle_agent_probe(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let spec = agent_spec_from_params(request.params)
  let readiness = @agent.probe_agent(spec)
  state.mutex.acquire()
  record_readiness(state, readiness)
  state.mutex.release()
  let result = @contracts.json_object([
    ("readiness", readiness.to_json()),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
/// Where one agent process runs and how it is launched. `launcher` is chosen
/// from the workspace/worktree machine: Local for the host's own machine, SSH
/// for a registered non-local one. The SSH choice is gated by
/// `MONEXUS_AGENT_SSH=1` (PoC round 1); without it the M4 local-only error is
/// preserved verbatim. This is the only place the agent runtime learns the
/// transport, and the SSH branch only supplies an `SshTarget` — no ACP.
struct AgentTarget {
  cwd : String
  workspace_id : String
  worktree_id : String
  launcher : @agent.ProcessLauncher
}

///|
///|
/// Register the launcher for one paired runtime machine. Called by the
/// transport attach layer once a primary session exists; tests register the
/// adapter directly. It carries a stdio handle only, never ACP.
pub async fn HostState::register_runtime_agent_launcher(
  self : HostState,
  machine_id : String,
  launcher : @agent.RemoteLauncher,
) -> Unit {
  self.mutex.acquire()
  self.runtime_agent_launchers.set(machine_id, launcher)
  self.mutex.release()
}

///|
async fn agent_launcher_for_machine(
  state : HostState,
  machine_id : String,
) -> Result[@agent.ProcessLauncher, @contracts.RpcError] {
  state.mutex.acquire()
  let record_result = state.store.get_machine(machine_id)
  let runtime_launcher = state.runtime_agent_launchers.get(machine_id)
  state.mutex.release()
  match record_result {
    Ok(Some(record)) =>
      if record.kind == @contracts.MACHINE_KIND_LOCAL {
        Ok(@agent.ProcessLauncher::Local)
      } else if record.kind == @contracts.MACHINE_KIND_RUNTIME {
        // No SSH and no ACP here: only a registered paired transport can
        // carry the agent's stdio. Without one, say so; do not silently fall
        // back to a local or SSH launch.
        match runtime_launcher {
          Some(launcher) => Ok(@agent.ProcessLauncher::Runtime(launcher))
          None =>
            Err(
              agent_unsupported(
                "runtime machine requires a live paired transport session; no runtime channel is attached to this host",
              ),
            )
        }
      } else {
        Ok(@agent.ProcessLauncher::Ssh(machine_target(record)))
      }
    Ok(None) => Err(agent_not_found("machine not found: " + machine_id))
    Err(message) => Err(agent_internal("cannot read machine: " + message))
  }
}

///|
/// The machine kind, or "" when the record disappeared. Used only to choose
/// the launcher; runtime machines are not SSH-gated.
async fn machine_kind_of(state : HostState, machine_id : String) -> String {
  state.mutex.acquire()
  let result = state.store.get_machine(machine_id)
  state.mutex.release()
  match result {
    Ok(Some(record)) => record.kind
    _ => ""
  }
}

///|
/// Resolve which directory the agent should run in and how to launch it.
/// V0.1 keeps remote agents behind `MONEXUS_AGENT_SSH=1`: without the gate an
/// SSH workspace/worktree is rejected rather than pretending a remote cwd is a
/// local one. Remote cwd is the workspace/worktree path on the remote machine.
async fn agent_target_dir(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[AgentTarget, @contracts.RpcError] {
  let explicit_cwd = @contracts.agent_cwd_param(params)
  let workspace_id = @contracts.agent_workspace_param(params)
  let worktree_id = @contracts.agent_worktree_param(params)
  let explicit_machine = @contracts.agent_machine_param(params).trim().to_owned()
  let mut cwd = explicit_cwd.trim().to_owned()
  let mut resolved_workspace = workspace_id
  let mut launcher = @agent.ProcessLauncher::Local
  // A1.5: an explicit machine makes the target unambiguous. Runtime machines
  // have no workspace record (the provider surface only opens local/SSH
  // roots), so the agent path selects them directly and maps the primary-side
  // absolute cwd into the node's rooted workspace. The launcher applies the
  // same mapping again as a no-op for the already-relative value.
  if explicit_machine != "" {
    state.mutex.acquire()
    let record_result = state.store.get_machine(explicit_machine)
    let roots = state.runtime_workspace_roots
    state.mutex.release()
    let record = match record_result {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(agent_not_found("machine not found: " + explicit_machine))
      Err(message) =>
        return Err(agent_internal("cannot read machine: " + message))
    }
    if record.kind == @contracts.MACHINE_KIND_RUNTIME {
      launcher = match agent_launcher_for_machine(state, record.id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if cwd == "" {
        cwd = "."
      } else {
        let mapped = match
          @provider_runtime_agent.runtime_agent_cwd(cwd, roots) {
          Ok(value) => value
          Err(message) => return Err(agent_invalid(message))
        }
        cwd = if mapped == "" { "." } else { mapped }
      }
    } else if record.kind == @contracts.MACHINE_KIND_LOCAL {
      launcher = @agent.ProcessLauncher::Local
    } else {
      if !@agent.agent_ssh_enabled() {
        return Err(
          agent_unsupported(
            "agent sessions currently run only on local worktrees",
          ),
        )
      }
      launcher = match agent_launcher_for_machine(state, record.id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    return Ok({ cwd, workspace_id: resolved_workspace, worktree_id, launcher })
  }
  if worktree_id != "" {
    let record = match lookup_worktree(state, worktree_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !machine_is_local(state, record.machine_id) {
      let kind = machine_kind_of(state, record.machine_id)
      if kind != @contracts.MACHINE_KIND_RUNTIME && !@agent.agent_ssh_enabled() {
        return Err(
          agent_unsupported(
            "agent sessions currently run only on local worktrees",
          ),
        )
      }
      launcher = match
        agent_launcher_for_machine(state, record.machine_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    if cwd == "" {
      cwd = record.path
    }
    if resolved_workspace == "" {
      resolved_workspace = record.workspace_id
    }
  } else if workspace_id != "" {
    let record = match lookup_workspace(state, workspace_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !machine_is_local(state, record.machine_id) {
      let kind = machine_kind_of(state, record.machine_id)
      if kind != @contracts.MACHINE_KIND_RUNTIME && !@agent.agent_ssh_enabled() {
        return Err(
          agent_unsupported(
            "agent sessions currently run only on local workspaces",
          ),
        )
      }
      launcher = match
        agent_launcher_for_machine(state, record.machine_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    if cwd == "" {
      cwd = record.root
    }
  }
  if cwd == "" {
    cwd = match @env.current_dir() {
      Some(value) => value
      None => "."
    }
  }
  Ok({ cwd, workspace_id: resolved_workspace, worktree_id, launcher })
}

///|
/// Create (truncate) the per-session stderr log. The file is separate from the
/// ACP stdout transcript and 0600; the drain callback appends redacted lines.
async fn open_agent_stderr_log(state : HostState, session_id : String) -> Unit {
  @fs.write_file(
    state.state_dir + "/logs/agent-" + session_id + ".stderr.log",
    "",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  ) catch {
    _ => ()
  }
}

///|
/// Record one stderr line. It never enters the ACP transcript: it is kept in a
/// raw window of the most recent `AGENT_STDERR_CAP` bytes, and the whole
/// window is redacted in one `redact_secrets` call so multi-line private-key
/// blocks are recognized. The redacted window is both the session record's
/// `stderr_tail` and the complete contents of
/// `logs/agent-<id>.stderr.log` (rewritten with CreateOrTruncate, so the file
/// cannot grow past the cap). Mode stays 0600.
///
/// Private-key body lines are dropped from the raw window while a block is
/// open, so a body line cannot survive even after the BEGIN line has scrolled
/// out of the bounded window.
async fn record_agent_stderr(
  state : HostState,
  session_id : String,
  raw_tail : Ref[String],
  in_private_key : Ref[Bool],
  stderr_tail : Ref[String],
  line : String,
) -> Unit {
  let lower = line.to_lower()
  let begins = lower.contains("-----begin") && lower.contains("private key")
  let ends = lower.contains("-----end") && lower.contains("private key")
  // Keep the BEGIN and END markers; drop body lines while the block is open.
  let keep = !in_private_key.val || ends
  if begins {
    in_private_key.val = true
  }
  if ends {
    in_private_key.val = false
  }
  if keep {
    let combined = raw_tail.val + line + "\n"
    raw_tail.val = if combined.length() > AGENT_STDERR_CAP {
      combined.substring(start=combined.length() - AGENT_STDERR_CAP)
    } else {
      combined
    }
  }
  let redacted = @contracts.redact_secrets(raw_tail.val)
  let bounded = if redacted.length() > AGENT_STDERR_CAP {
    redacted.substring(start=redacted.length() - AGENT_STDERR_CAP)
  } else {
    redacted
  }
  stderr_tail.val = bounded
  @fs.write_file(
    state.state_dir + "/logs/agent-" + session_id + ".stderr.log",
    bounded,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  ) catch {
    _ => ()
  }
}

///|
fn default_agent_exe(
  mode : String,
  command : String,
  args : Array[String],
) -> (String, Array[String]) {
  if command.trim() == "" && mode == @contracts.AGENT_MODE_ACP {
    (@agent.default_acp_command(), @agent.default_acp_args())
  } else {
    (command, args)
  }
}

///|
async fn handle_agent_start(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let agent_id = @contracts.agent_id_param(request.params)
  if !valid_agent_id(agent_id) {
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_invalid("invalid agent_id"),
    )
    return
  }
  let mode = @contracts.agent_mode_param(request.params)
  if mode != @contracts.AGENT_MODE_ACP && mode != @contracts.AGENT_MODE_STDOUT {
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_unsupported("unsupported agent mode: " + mode),
    )
    return
  }
  let target = match agent_target_dir(state, request.params) {
    Ok(value) => value
    Err(error) => {
      agent_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let cwd = target.cwd
  let workspace_id = target.workspace_id
  let worktree_id = target.worktree_id
  let launcher = target.launcher
  let remote_session = match launcher {
    @agent.ProcessLauncher::Local => false
    _ => true
  }
  let explicit_skills = match @contracts.skill_bindings_param(request.params) {
    Some(value) => value
    None => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_invalid("skills must be an array of exact name/version/content_hash/mode bindings"),
      )
      return
    }
  }
  let task_id = @contracts.agent_task_id_param(request.params)
  if task_id != "" && state.skill_enabled && !skill_scope_ref_valid(@contracts.SKILL_SCOPE_TASK, task_id) {
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_invalid("invalid task_id"),
    )
    return
  }
  let home = match ensure_agent_home(state, agent_id) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  let agents_text = match read_agent_file(state, agent_id, AGENTS_FILE) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  let memory_text = match read_agent_file(state, agent_id, MEMORY_FILE) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  let memory_limit = @contracts.agent_memory_limit_param(request.params)
  let prompt = @contracts.agent_prompt_param(request.params)
  let group = match state.group.val {
    Some(value) => value
    None => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("host task group is not running"),
      )
      return
    }
  }
  // The session id is known before the spawn so the separate stderr log can
  // be named after it. The session record itself is still written only after
  // a successful ACP handshake.
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let session_id = @contracts.new_id("agt", now)
  open_agent_stderr_log(state, session_id)
  let skill_setup = match
    setup_skill_session(
      state,
      agent_id,
      session_id,
      task_id,
      home,
      cwd,
      workspace_id,
      remote_session,
      explicit_skills,
    ) {
    Ok(value) => value
    Err(fault) => {
      finalize_skill_session(state, "", session_id, home)
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        skill_fault_error(fault),
      )
      return
    }
  }
  let (composed, memory_bytes) = @skills.compose_skill_prompt(
    agents_text,
    memory_text,
    Some(skill_setup.injection),
    prompt,
    memory_limit,
  )
  let spec_env = @contracts.agent_env_from_json(request.params)
  if skill_setup.token != "" {
    spec_env.set("MONEXUS_SKILL_TOKEN", skill_setup.token)
  }
  let spec = @agent.AgentSpec::new(
    agent_id~,
    mode~,
    command=@contracts.agent_command_param(request.params),
    args=@contracts.agent_args_param(request.params),
    cwd~,
    env=spec_env,
  )
  let stderr_tail : Ref[String] = Ref("")
  let stderr_raw : Ref[String] = Ref("")
  let stderr_in_key : Ref[Bool] = Ref(false)
  // stderr is drained on its own pipe: never mixed into the ACP stdout
  // transcript, redacted, bounded on the record and in its own log file.
  let process = match
    @agent.spawn_agent(
      group,
      spec,
      async fn(line) {
        record_agent_stderr(
          state,
          session_id,
          stderr_raw,
          stderr_in_key,
          stderr_tail,
          line,
        )
      },
      launcher=launcher,
    ) {
    Ok(value) => value
    Err(message) => {
      let readiness = @contracts.AgentReadiness::new(
        ok=false,
        agent_id~,
        mode~,
        command=@contracts.agent_command_param(request.params),
      )
      let failed = {
        ..readiness,
        error: message,
        auth: "unknown",
        detail: "spawn failed",
        checked_at: @contracts.format_rfc3339(@async.now()),
      }
      state.mutex.acquire()
      record_readiness(state, failed)
      state.mutex.release()
      finalize_skill_session(state, skill_setup.token, session_id, home)
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_readiness_error("cannot start agent: " + message),
      )
      return
    }
  }
  let mut acp_session_id = ""
  let mut agent_name = ""
  let mut acp_version = ""
  let mut load_session = false
  if mode == @contracts.AGENT_MODE_ACP {
    let handshake = @async.with_timeout_opt(
      @agent.agent_timeout_ms(),
      async fn() {
        let info = match @agent.acp_initialize(process) {
          Ok(value) => value
          Err(message) => return Err(message)
        }
        let gateway_servers : Array[@json.Json] = []
        if skill_setup.token != "" {
          let gateway_args : Array[@json.Json] = [
            @contracts.json_string("skill-mcp"),
            @contracts.json_string("--state-dir"),
            @contracts.json_string(state.state_dir),
            @contracts.json_string("--session"),
            @contracts.json_string(session_id),
          ]
          let gateway_env : Array[@json.Json] = [
            @contracts.json_object([
              ("name", @contracts.json_string("MONEXUS_SKILL_TOKEN")),
              ("value", @contracts.json_string(skill_setup.token)),
            ]),
          ]
          gateway_servers.push(
            @contracts.json_object([
              ("name", @contracts.json_string("monexus-skills")),
              ("command", @contracts.json_string(state.host_exe)),
              ("args", @contracts.json_array(gateway_args)),
              ("env", @contracts.json_array(gateway_env)),
            ]),
          )
        }
        let mcp_servers = @contracts.json_array(gateway_servers)
        let session = match @agent.acp_new_session_with(process, cwd, mcp_servers) {
          Ok(value) => value
          Err(message) => return Err(message)
        }
        Ok((info, session))
      },
    )
    match handshake {
      Some(Ok((info, session))) => {
        acp_session_id = session
        agent_name = info.agent_name
        acp_version = info.protocol_version.to_string()
        load_session = info.load_session
      }
      failure => {
        process.interrupt()
        let (detail, auth) = match failure {
          Some(Err(message)) => {
            let classified = @agent.classify_readiness_failure(message)
            (message, classified)
          }
          None => (
            "handshake timed out after " +
            @agent.agent_timeout_ms().to_string() +
            "ms",
            "unknown",
          )
          _ => ("handshake failed", "unknown")
        }
        let readiness = @contracts.AgentReadiness::new(
          ok=false,
          agent_id~,
          mode~,
          command=@contracts.agent_command_param(request.params),
        )
        let failed = {
          ..readiness,
          error: detail,
          auth,
          detail: "ACP initialize/session-new failed",
          checked_at: @contracts.format_rfc3339(@async.now()),
        }
        state.mutex.acquire()
        record_readiness(state, failed)
        state.mutex.release()
        finalize_skill_session(state, skill_setup.token, session_id, home)
        agent_io_error(
          state,
          sink,
          request,
          client_request_id,
          agent_readiness_error("agent readiness failed: " + detail),
        )
        return
      }
    }
  }
  let (display_command, display_args) = default_agent_exe(
    mode,
    @contracts.agent_command_param(request.params),
    @contracts.agent_args_param(request.params),
  )
  let base = @contracts.AgentSessionRecord::new(
    id=session_id,
    agent_id~,
    mode~,
    cwd~,
    started_at=timestamp,
  )
  let record = {
    ..base,
    workspace_id,
    worktree_id,
    command: display_command,
    args: display_args,
    state: if prompt == "" {
      @contracts.AGENT_STATE_IDLE
    } else {
      @contracts.AGENT_STATE_RUNNING
    },
    acp_session_id,
    agent_name,
    acp_version,
    load_session,
    turns: if prompt == "" { 0 } else { 1 },
    memory_injected: memory_bytes > 0,
    memory_bytes,
    skill_snapshot: skill_session_snapshot(skill_setup.entries),
    updated_at: timestamp,
  }
  let runtime : AgentSessionRuntime = {
    id: session_id,
    agent_id: agent_id,
    acp_session_id,
    process,
    transcript: Ref({ base: 0L, text: "" }),
    pending: Map([]),
    active_prompts: Map([]),
    turn_text: Ref(""),
    home,
    memory_before: memory_text,
    stderr_tail,
    finalized: Ref(false),
    skill_token: skill_setup.token,
  }
  let mut prompt_id = ""
  state.mutex.acquire()
  if prompt != "" {
    prompt_id = process.next_id("turn")
    runtime.active_prompts.set(prompt_id, 1)
  }
  let started = state.append_agent_session_event(
    @contracts.EVENT_AGENT_SESSION_STARTED,
    session_id,
    @contracts.agent_session_payload(record),
    record,
  )
  match started {
    Ok(_) => state.agent_sessions.set(session_id, runtime)
    Err(message) => {
      state.mutex.release()
      process.interrupt()
      finalize_skill_session(state, skill_setup.token, session_id, home)
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot persist session: " + message),
      )
      return
    }
  }
  if skill_setup.entries.length() > 0 {
    let skill_entries : Array[@json.Json] = []
    for entry in skill_setup.entries {
      skill_entries.push(
        @contracts.json_object([
          ("name", @contracts.json_string(entry.snapshot.name)),
          ("version", @contracts.json_string(entry.snapshot.version)),
          ("content_hash", @contracts.json_string(entry.snapshot.content_hash)),
          ("scope", @contracts.json_string(entry.snapshot.scope)),
          ("mode", @contracts.json_string(entry.snapshot.mode)),
        ]),
      )
    }
    let _ = state.append_event(
      @contracts.EVENT_SKILL_LOADED,
      "agent-session/" + session_id,
      @contracts.json_object([
        ("session_id", @contracts.json_string(session_id)),
        ("skills", @contracts.json_array(skill_entries)),
        ("bytes", @contracts.json_int(skill_setup.injection.bytes)),
        ("truncated", @contracts.json_bool(skill_setup.injection.truncated)),
        ("invocable", @contracts.json_bool(!remote_session)),
      ]),
    )
    if skill_setup.injection.truncated {
      let _ = state.append_event(
        @contracts.EVENT_SKILL_CONTEXT_TRUNCATED,
        "agent-session/" + session_id,
        @contracts.json_object([
          ("session_id", @contracts.json_string(session_id)),
          ("budget_bytes", @contracts.json_int(@skills.SKILL_CONTEXT_DEFAULT_BYTES)),
          ("bytes", @contracts.json_int(skill_setup.injection.bytes)),
          ("loaded", @contracts.json_int(skill_setup.loaded)),
          ("available", @contracts.json_int(skill_setup.available)),
        ]),
      )
    }
  }
  state.mutex.release()
  if skill_setup.entries.length() > 0 {
    audit(
      state,
      "skill.session.load",
      "host",
      "session/" + session_id,
      if remote_session { "declarative" } else { "injected" },
      detail="loaded=" +
      skill_setup.loaded.to_string() +
      " available=" +
      skill_setup.available.to_string() +
      " bytes=" +
      skill_setup.injection.bytes.to_string() +
      " truncated=" +
      skill_setup.injection.truncated.to_string(),
      policy="skill",
    )
  }
  if prompt != "" {
    let sent = process.write_json(
      @agent.acp_rpc_request(
        prompt_id,
        "session/prompt",
        @agent.acp_prompt_params(acp_session_id, composed),
      ),
    )
    if !sent {
      finalize_agent_session(
        state,
        runtime,
        @contracts.AGENT_STOP_ERROR,
        "cannot write initial prompt",
      )
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot write initial prompt"),
      )
      return
    }
  }
  match state.group.val {
    Some(active) =>
      active.spawn_bg(
        allow_failure=true,
        () => agent_session_pump(state, runtime),
      )
    None => ()
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.agent_session_result(record),
  )
}

// ---------------------------------------------------------------------------
// Handlers: send / read / list / stop / resume
// ---------------------------------------------------------------------------

///|
async fn handle_agent_send(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.agent_session_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  let text = match @contracts.agent_text_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  state.mutex.acquire()
  let runtime = match state.agent_sessions.get(session_id) {
    Some(value) => value
    None => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_not_found("agent session not found or not running"),
      )
      return
    }
  }
  if runtime.pending.size() > 0 || runtime.active_prompts.size() > 0 {
    state.mutex.release()
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_conflict("session is busy; answer the pending decision or wait"),
    )
    return
  }
  let record = match state.store.get_agent_session(session_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_not_found("agent session record not found"),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot read session: " + message),
      )
      return
    }
  }
  if !@contracts.agent_state_is_active(record.state) {
    state.mutex.release()
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_conflict("session is no longer running; resume it first"),
    )
    return
  }
  let turn = record.turns + 1
  let prompt_id = runtime.process.next_id("turn")
  runtime.active_prompts.set(prompt_id, turn)
  runtime.turn_text.val = ""
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let updated = {
    ..record,
    state: @contracts.AGENT_STATE_RUNNING,
    turns: turn,
    last_error: "",
    updated_at: timestamp,
  }
  let persisted = state.append_agent_session_event(
    @contracts.EVENT_AGENT_SESSION_UPDATED,
    session_id,
    @contracts.agent_session_payload(updated),
    updated,
  )
  state.mutex.release()
  match persisted {
    Ok(_) => ()
    Err(message) => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot persist session: " + message),
      )
      return
    }
  }
  let written = runtime.process.write_json(
    @agent.acp_rpc_request(
      prompt_id,
      "session/prompt",
      @agent.acp_prompt_params(record.acp_session_id, text),
    ),
  )
  if !written {
    state.mutex.acquire()
    runtime.active_prompts.remove(prompt_id)
    state.mutex.release()
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_internal("agent process is not running"),
    )
    return
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.agent_ack_result(session_id),
  )
}

///|
async fn handle_agent_read(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.agent_session_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  let requested = @contracts.agent_cursor_param(request.params)
  state.mutex.acquire()
  let record = match state.store.get_agent_session(session_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_not_found("agent session not found"),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot read session: " + message),
      )
      return
    }
  }
  let transcript = match state.agent_sessions.get(session_id) {
    Some(runtime) => runtime.transcript.val
    None => {
      match state.agent_transcripts.get(session_id) {
        Some(value) => value
        None => { base: 0L, text: "" }
      }
    }
  }
  let length = transcript.text.length()
  let start = transcript.base
  let end = start + length.to_int64()
  let cursor = if requested < start {
    start
  } else if requested > end {
    end
  } else {
    requested
  }
  let text = if cursor >= end {
    ""
  } else {
    let offset = (cursor - start).to_int()
    transcript.text.substring(start=offset)
  }
  let pending = match state.store.list_decisions(
    @contracts.DECISION_STATUS_PENDING,
    session_id,
  ) {
    Ok(records) =>
      if records.length() > 0 { records[0].id } else { "" }
    Err(_) => ""
  }
  let runtime_state = match state.agent_sessions.get(session_id) {
    Some(runtime) =>
      if runtime.pending.size() > 0 {
        @contracts.AGENT_STATE_WAITING
      } else if runtime.active_prompts.size() > 0 {
        @contracts.AGENT_STATE_RUNNING
      } else {
        record.state
      }
    None => record.state
  }
  let projected = { ..record, state: runtime_state, }
  let result = @contracts.agent_read_result(
    projected,
    end,
    text,
    pending,
  )
  state.mutex.release()
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_agent_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let agent_id = @contracts.agent_id_param(request.params)
  let filter = match @contracts.string_field(request.params, "agent_id") {
    Some(_) => agent_id
    None => "" // no explicit agent_id: list every session
  }
  state.mutex.acquire()
  let result = match state.store.list_agent_sessions(filter) {
    Ok(records) => Ok(@contracts.agent_sessions_result(records))
    Err(message) => Err(agent_internal("cannot list sessions: " + message))
  }
  state.mutex.release()
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) => agent_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_agent_stop(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.agent_session_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  state.mutex.acquire()
  let runtime = state.agent_sessions.get(session_id)
  state.mutex.release()
  match runtime {
    Some(value) => {
      // ACP cancel first, then close: a local adapter or a remote one behind
      // `ssh -T` both see the notification on the same duplex stdin before
      // `interrupt()` tears the process down. A short grace period lets the
      // adapter flush its own stderr before the pipes close.
      if value.acp_session_id != "" {
        ignore(
          value.process.write_json(
            @agent.acp_cancel_notification(value.acp_session_id),
          ),
        )
        @async.sleep(250)
      }
      finalize_agent_session(
        state,
        value,
        @contracts.AGENT_STOP_CANCELLED,
        "stopped by owner",
      )
    }
    None => {
      // Idempotent for an already-finished session, not-found otherwise.
      state.mutex.acquire()
      let exists = match state.store.get_agent_session(session_id) {
        Ok(Some(_)) => true
        _ => false
      }
      state.mutex.release()
      if !exists {
        agent_io_error(
          state,
          sink,
          request,
          client_request_id,
          agent_not_found("agent session not found"),
        )
        return
      }
    }
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.agent_ack_result(session_id),
  )
}

///|
async fn handle_agent_resume(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.agent_session_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  state.mutex.acquire()
  let runtime_existing = state.agent_sessions.get(session_id)
  let record_result = state.store.get_agent_session(session_id)
  state.mutex.release()
  match runtime_existing {
    Some(runtime) => {
      let record = match record_result {
        Ok(Some(value)) => value
        _ => return
      }
      let projected = {
        ..record,
        state: if runtime.pending.size() > 0 {
          @contracts.AGENT_STATE_WAITING
        } else {
          @contracts.AGENT_STATE_IDLE
        },
      }
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.agent_session_result(projected),
      )
      return
    }
    None => ()
  }
  let record = match record_result {
    Ok(Some(value)) => value
    Ok(None) => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_not_found("agent session not found"),
      )
      return
    }
    Err(message) => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot read session: " + message),
      )
      return
    }
  }
  if record.mode != @contracts.AGENT_MODE_ACP ||
    record.acp_session_id == "" ||
    !record.load_session {
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_unsupported(
        "this session cannot be resumed (adapter did not declare loadSession)",
      ),
    )
    return
  }
  let group = match state.group.val {
    Some(value) => value
    None => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("host task group is not running"),
      )
      return
    }
  }
  let home = match ensure_agent_home(state, record.agent_id) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  let memory_before = match read_agent_file(state, record.agent_id, MEMORY_FILE) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  let spec = @agent.AgentSpec::new(
    agent_id=record.agent_id,
    mode=@contracts.AGENT_MODE_ACP,
    command=record.command,
    args=record.args,
    cwd=record.cwd,
    env=Map([]),
  )
  let stderr_tail : Ref[String] = Ref("")
  let stderr_raw : Ref[String] = Ref("")
  let stderr_in_key : Ref[Bool] = Ref(false)
  // PoC round 1 resumes local sessions only: the session record carries no
  // machine id, so the launcher cannot be reconstructed here. A remote session
  // record whose command is not present locally fails cleanly at spawn.
  let process = match
    @agent.spawn_agent(group, spec, async fn(line) {
      record_agent_stderr(
        state,
        session_id,
        stderr_raw,
        stderr_in_key,
        stderr_tail,
        line,
      )
    }) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_readiness_error("cannot start agent: " + message),
      )
      return
    }
  }
  let loaded = @async.with_timeout_opt(
    @agent.agent_timeout_ms(),
    async fn() {
      match @agent.acp_initialize(process) {
        Ok(_) => ()
        Err(message) => return Err(message)
      }
      @agent.acp_load_session(process, record.acp_session_id, record.cwd)
    },
  )
  match loaded {
    Some(Ok(_)) => ()
    failure => {
      process.interrupt()
      let detail = match failure {
        Some(Err(message)) => message
        None =>
          "session/load timed out after " +
          @agent.agent_timeout_ms().to_string() +
          "ms"
        _ => "session/load failed"
      }
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_unsupported("cannot resume session: " + detail),
      )
      return
    }
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let runtime : AgentSessionRuntime = {
    id: session_id,
    agent_id: record.agent_id,
    acp_session_id: record.acp_session_id,
    process,
    transcript: Ref({ base: 0L, text: "" }),
    pending: Map([]),
    active_prompts: Map([]),
    turn_text: Ref(""),
    home,
    memory_before,
    stderr_tail,
    finalized: Ref(false),
    skill_token: "",
  }
  let resumed = {
    ..record,
    state: @contracts.AGENT_STATE_IDLE,
    stop_reason: "",
    last_error: "",
    updated_at: timestamp,
    ended_at: "",
  }
  state.mutex.acquire()
  // A resumed process starts a new stdout transcript; drop the frozen one from
  // the previous life of this session.
  state.agent_transcripts.remove(session_id)
  let persisted = state.append_agent_session_event(
    @contracts.EVENT_AGENT_SESSION_RESUMED,
    session_id,
    @contracts.agent_session_payload(resumed),
    resumed,
  )
  match persisted {
    Ok(_) => state.agent_sessions.set(session_id, runtime)
    Err(message) => {
      state.mutex.release()
      process.interrupt()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot persist resumed session: " + message),
      )
      return
    }
  }
  state.mutex.release()
  match state.group.val {
    Some(active) =>
      active.spawn_bg(
        allow_failure=true,
        () => agent_session_pump(state, runtime),
      )
    None => ()
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.agent_session_result(resumed),
  )
}

// ---------------------------------------------------------------------------
// Handlers: memory / decisions
// ---------------------------------------------------------------------------

///|
async fn handle_agent_memory_read(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let agent_id = @contracts.agent_id_param(request.params)
  let file = match @contracts.agent_memory_file_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  let content = match read_agent_file(state, agent_id, file) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.agent_memory_read_result(agent_id, file, content),
  )
}

///|
async fn handle_agent_memory_write(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let agent_id = @contracts.agent_id_param(request.params)
  let file = match @contracts.agent_memory_file_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  if file == AGENTS_FILE {
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_unsupported("AGENTS.md is read-only; write MEMORY.md instead"),
    )
    return
  }
  let content = @contracts.agent_memory_content_param(request.params)
  let actor = @contracts.agent_actor_param(request.params)
  let home = match ensure_agent_home(state, agent_id) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_internal(message))
      return
    }
  }
  let path = home + "/" + MEMORY_FILE
  @fs.write_file(path, content, permission=0o644) catch {
    error => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot write MEMORY.md: " + error.to_string()),
      )
      return
    }
  }
  let now = @async.now()
  let digest = content_digest(content)
  let payload = @contracts.json_object([
    ("agent_id", @contracts.json_string(agent_id)),
    ("file", @contracts.json_string(file)),
    ("bytes", @contracts.json_int(content.length())),
    ("digest", @contracts.json_string(digest)),
    ("actor", @contracts.json_string(actor)),
    ("path", @contracts.json_string(path)),
    ("at", @contracts.json_string(@contracts.format_rfc3339(now))),
  ])
  state.mutex.acquire()
  let _ = state.append_event(
    @contracts.EVENT_AGENT_MEMORY_UPDATED,
    "agent/" + agent_id,
    payload,
  )
  state.mutex.release()
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.agent_memory_write_result(
      agent_id,
      file,
      content.length(),
      digest,
    ),
  )
}

///|
async fn handle_decision_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let status = @contracts.decision_status_param(request.params)
  let session_id = @contracts.decision_session_param(request.params)
  let bucket = @contracts.decision_bucket_param(request.params)
  state.mutex.acquire()
  let result = match state.store.list_decisions(status, session_id) {
    Ok(records) => {
      // Inbox placement is computed by the host from one shared rule:
      // pending -> Needs you, an answered retry/approval whose Run is still
      // active -> waiting, anything else -> handled.
      let enriched : Array[@contracts.DecisionRecord] = []
      for record in records {
        let run_status = if record.run_id == "" {
          ""
        } else {
          match state.store.get_run(record.run_id) {
            Ok(Some(run)) => {
              let mut effective = run.status
              // An owner retry answers the Decision on the *old* Run; the
              // Inbox should follow the retry attempt, not the lost original.
              if record.option_id == "retry" {
                match state.store.list_runs(run.task_id, "") {
                  Ok(runs) =>
                    for attempt_run in runs {
                      if attempt_run.retried_from == record.run_id {
                        effective = attempt_run.status
                      }
                    }
                  Err(_) => ()
                }
              }
              effective
            }
            _ => ""
          }
        }
        let item = {
          ..record,
          inbox: @contracts.decision_inbox_bucket(
            record.status,
            record.kind,
            record.option_id,
            run_status,
          ),
          run_status: run_status,
        }
        if bucket == "" || item.inbox == bucket {
          enriched.push(item)
        }
      }
      Ok(@contracts.decision_list_result(enriched))
    }
    Err(message) => Err(agent_internal("cannot list decisions: " + message))
  }
  state.mutex.release()
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) => agent_io_error(state, sink, request, client_request_id, error)
  }
}

///|
///|
/// A runtime approval Decision is answered through the decision store that the
/// runtime wait loop polls; it has no ACP session to deliver to. Telling it
/// apart from an agent permission Decision keeps `decision.respond` honest.
fn is_runtime_approval_decision(record : @contracts.DecisionRecord) -> Bool {
  record.machine_id != "" && record.action.has_prefix("runtime.")
}

///|
async fn handle_decision_respond(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let decision_id = match @contracts.decision_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      agent_io_error(state, sink, request, client_request_id, agent_invalid(message))
      return
    }
  }
  let option_id = @contracts.decision_option_param(request.params)
  let answer_text = @contracts.decision_text_param(request.params)
  let answered_by = @contracts.decision_answered_by_param(request.params)
  state.mutex.acquire()
  let record = match state.store.get_decision(decision_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_not_found("decision not found"),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot read decision: " + message),
      )
      return
    }
  }
  if record.status != @contracts.DECISION_STATUS_PENDING {
    state.mutex.release()
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_conflict("decision is already " + record.status),
    )
    return
  }
  if record.kind == @contracts.DECISION_KIND_VERIFY {
    state.mutex.release()
    handle_verify_decision_respond(
      state,
      sink,
      request,
      client_request_id,
      record,
      option_id,
      answer_text,
      answered_by,
    )
    return
  }
  if record.kind == @contracts.DECISION_KIND_PERMISSION && option_id == "" {
    state.mutex.release()
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      agent_invalid("permission decisions require option_id"),
    )
    return
  }
  if option_id != "" {
    let mut known = false
    for option in record.options {
      if option.option_id == option_id {
        known = true
      }
    }
    if !known {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_invalid("unknown option_id: " + option_id),
      )
      return
    }
  }
  // Claim the pending entry first so a double answer cannot be delivered
  // twice; the ACP reply is written after the mutex is released.
  let runtime = state.agent_sessions.get(record.session_id)
  let pending = match runtime {
    Some(value) => {
      let found = value.pending.get(decision_id)
      value.pending.remove(decision_id)
      found
    }
    None => None
  }
  state.mutex.release()
  let mut delivery_error = ""
  let mut delivered = false
  // Runtime approval Decisions belong to the node transport, not to an ACP
  // session: the host's runtime wait loop polls the decision store, so an
  // answer recorded here is delivered by construction. Reporting an ACP
  // delivery failure for them would mislabel a successful approval.
  let runtime_approval = is_runtime_approval_decision(record)
  match pending {
    Some(value) => {
      let reply = if option_id != "" {
        @agent.acp_permission_result(option_id)
      } else {
        @agent.acp_cancelled_result()
      }
      let written = match runtime {
        Some(rt) => rt.process.write_json(
          @agent.acp_rpc_result(value.acp_id, reply),
        )
        None => false
      }
      if written {
        delivered = true
      } else {
        delivery_error = "could not write the answer to the agent process"
      }
    }
    None =>
      if runtime_approval {
        delivered = true
      } else if record.kind == @contracts.DECISION_KIND_PERMISSION {
        delivery_error = "agent session is no longer running; ACP reply not delivered"
      }
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  let answered = {
    ..record,
    status: @contracts.DECISION_STATUS_ANSWERED,
    option_id,
    answer_text,
    answered_by,
    delivery_error,
    answered_at: timestamp,
  }
  let persisted = state.append_decision_event(
    @contracts.EVENT_DECISION_RESPONDED,
    decision_id,
    @contracts.decision_payload(answered),
    answered,
  )
  // The agent continues the same prompt after a permission answer.
  match runtime {
    Some(rt) =>
      match state.store.get_agent_session(rt.id) {
        Ok(Some(session)) =>
          if @contracts.agent_state_is_active(session.state) &&
            rt.pending.size() == 0 {
            let updated = {
              ..session,
              state: if rt.active_prompts.size() > 0 {
                @contracts.AGENT_STATE_RUNNING
              } else {
                @contracts.AGENT_STATE_IDLE
              },
              updated_at: timestamp,
            }
            let _ = state.append_agent_session_event(
              @contracts.EVENT_AGENT_SESSION_UPDATED,
              rt.id,
              @contracts.agent_session_payload(updated),
              updated,
            )
          }
        _ => ()
      }
    None => ()
  }
  state.mutex.release()
  match persisted {
    Ok(_) => {
      // Every answer is auditable, including permission and readiness
      // answers that do not own a Run.
      audit(
        state,
        "decision.respond",
        if answered_by == "" { "owner" } else { answered_by },
        "decision/" + decision_id,
        "answered",
        target=record.run_id,
        policy=record.kind,
        detail="option " + option_id + "\n" + answer_text,
        decision_id~,
        run_id=record.run_id,
      )
      if record.kind == @contracts.DECISION_KIND_SKILL {
        state.mutex.acquire()
        let waiter = state.skill_waiters.get(decision_id)
        state.skill_waiters.remove(decision_id)
        state.mutex.release()
        match waiter {
          Some(queue) => ignore(queue.try_put(option_id) catch { _ => false })
          None => ()
        }
      }
      if record.kind == @contracts.DECISION_KIND_APPROVAL {
        handle_approval_decision_respond(
          state,
          record.run_id,
          option_id,
          if answered_by == "" { "owner" } else { answered_by },
        )
      } else if record.kind == @contracts.DECISION_KIND_RECOVERY {
        handle_recovery_decision_respond(
          state,
          record.run_id,
          option_id,
          if answered_by == "" { "owner" } else { answered_by },
        )
      }
      if delivered || record.kind != @contracts.DECISION_KIND_PERMISSION {
        send_machine_result(
          state,
          sink,
          request,
          client_request_id,
          @contracts.decision_result(answered),
        )
      } else {
        agent_io_error(
          state,
          sink,
          request,
          client_request_id,
          agent_internal("answer recorded but not delivered: " + delivery_error),
        )
      }
    }
    Err(message) =>
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        agent_internal("cannot persist decision answer: " + message),
      )
  }
}

// ---------------------------------------------------------------------------
// Startup reconcile
// ---------------------------------------------------------------------------

///|
/// A host restart kills ACP processes (M0 found no durable process), so live
/// sessions are closed as `host_restarted` and every pending decision expires.
pub async fn reconcile_agent_sessions(
  state : HostState,
) -> Result[Unit, String] {
  state.mutex.acquire()
  let sessions = match state.store.list_agent_sessions("") {
    Ok(records) => records
    Err(message) => {
      state.mutex.release()
      return Err("cannot list agent sessions: " + message)
    }
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  for record in sessions {
    if @contracts.agent_state_is_active(record.state) {
      let updated = {
        ..record,
        state: @contracts.AGENT_STATE_EXITED,
        stop_reason: @contracts.AGENT_STOP_HOST_RESTART,
        last_error: "monexus-host restarted before the session ended",
        ended_at: timestamp,
        updated_at: timestamp,
      }
      let _ = state.append_agent_session_event(
        @contracts.EVENT_AGENT_SESSION_EXITED,
        record.id,
        @contracts.agent_session_payload(updated),
        updated,
      )
      expire_session_decisions(state, record.id, timestamp)
    }
  }
  let p = match state.store.list_decisions(
    @contracts.DECISION_STATUS_PENDING,
    "",
  ) {
    Ok(records) => records
    Err(message) => {
      state.mutex.release()
      return Err("cannot list pending decisions: " + message)
    }
  }
  for record in p {
    let expired = {
      ..record,
      status: @contracts.DECISION_STATUS_EXPIRED,
      answered_at: timestamp,
      answered_by: "host",
      delivery_error: "host restarted before the decision was answered",
    }
    let _ = state.append_decision_event(
      @contracts.EVENT_DECISION_EXPIRED,
      expired.id,
      @contracts.decision_payload(expired),
      expired,
    )
  }
  state.mutex.release()
  Ok(())
}
