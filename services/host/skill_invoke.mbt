///|
/// Host-owned `skill.invoke` gateway (ADR-0015 §6.2).
///
/// The Agent can only name an `entry_id`. The host re-resolves the frozen
/// capability, re-verifies the stored bundle, applies the exact manifest argv,
/// intersects permissions with the current agent ceiling, evaluates policy and
/// — for write entries — always waits for an owner Decision on the existing
/// Decision/approval path. No shell, no interpreter first token, no
/// Agent-supplied argv or environment.

///|
fn skill_denied_error(reason : String, message : String) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_HOST,
    message,
    data=@contracts.json_object([
      ("kind", @contracts.json_string("skill")),
      ("reason", @contracts.json_string(reason)),
    ]),
  )
}

///|
fn skill_default_env(home : String) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  env.set("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  env.set("LANG", "C")
  env.set("LC_ALL", "C")
  if home != "" {
    env.set("HOME", home)
  }
  env
}

///|
async fn skill_entry_lookup(
  state : HostState,
  token : String,
  entry_id : String,
) -> (SkillCapability?, SkillCapabilityEntry?) {
  state.mutex.acquire()
  let capability = state.skill_capabilities.get(token)
  let entry = match capability {
    Some(value) => value.entries.get(entry_id)
    None => None
  }
  // The session must still be live; a finalized session loses the gateway.
  let live = match capability {
    Some(value) => state.agent_sessions.get(value.session_id) is Some(_)
    None => false
  }
  state.mutex.release()
  if !live {
    (None, None)
  } else {
    (capability, entry)
  }
}

///|
/// Re-check the binding/allowlist/key state that the snapshot was frozen
/// against. A disabled agent/task binding refuses new invocations while the
/// session keeps its already-injected text.
async fn skill_binding_still_enabled(
  state : HostState,
  capability : SkillCapability,
  entry : SkillCapabilityEntry,
) -> Bool {
  if entry.scope == @contracts.SKILL_SCOPE_SESSION {
    return true
  }
  state.mutex.acquire()
  let row = state.store.get_skill_binding(
    entry.scope,
    entry.scope_ref,
    entry.name,
  )
  state.mutex.release()
  match row {
    Ok(Some(value)) =>
      value.version == entry.version && value.content_hash == entry.content_hash
    _ => false
  }
}

///|
async fn skill_emit_invoke_denied(
  state : HostState,
  session_id : String,
  entry_id : String,
  name : String,
  version : String,
  content_hash : String,
  reason : String,
) -> Unit {
  state.mutex.acquire()
  let _ = state.append_event(
    @contracts.EVENT_SKILL_INVOKE_DENIED,
    "skill-invoke/" + session_id,
    @contracts.json_object([
      ("session_id", @contracts.json_string(session_id)),
      ("entry_id", @contracts.json_string(entry_id)),
      ("name", @contracts.json_string(name)),
      ("version", @contracts.json_string(version)),
      ("content_hash", @contracts.json_string(content_hash)),
      ("reason", @contracts.json_string(reason)),
    ]),
  )
  state.mutex.release()
  audit(
    state,
    "skill.invoke_denied",
    "host",
    "session/" + session_id,
    reason,
    detail="entry_id=" + entry_id + " reason=" + reason,
    policy="skill",
  )
}

///|
async fn skill_record_invocation(
  state : HostState,
  capability : SkillCapability,
  entry : SkillCapabilityEntry,
  entry_id : String,
  client_request_id : String,
  argv_hash : String,
  status : String,
  exit_code : Int,
  decision_id : String,
  output_bytes : Int,
) -> Unit {
  let now = @async.now()
  let row : @machines.SkillInvocationRow = {
    id: @contracts.new_id("ski", now),
    request_id: client_request_id,
    session_id: capability.session_id,
    name: entry.name,
    version: entry.version,
    content_hash: entry.content_hash,
    entry_id,
    argv_hash,
    status,
    exit_code,
    decision_id,
    run_id: "",
    output_bytes,
    created_at: @contracts.format_rfc3339(now),
  }
  state.mutex.acquire()
  let _ = state.store.record_skill_invocation(row)
  state.mutex.release()
}

///|
/// Expire a skill Decision whose waiter timed out. Uses the same persisted
/// decision status as every other Decision; there is no second approval queue.
async fn skill_expire_decision(state : HostState, decision_id : String) -> Unit {
  state.mutex.acquire()
  let record = match state.store.get_decision(decision_id) {
    Ok(Some(value)) => Some(value)
    _ => None
  }
  match record {
    Some(value) =>
      if value.status == @contracts.DECISION_STATUS_PENDING {
        let timestamp = @contracts.format_rfc3339(@async.now())
        let expired = {
          ..value,
          status: @contracts.DECISION_STATUS_EXPIRED,
          answered_at: timestamp,
          answered_by: "host",
          delivery_error: "skill invocation timed out before the owner answered",
        }
        let _ = state.append_decision_event(
          @contracts.EVENT_DECISION_EXPIRED,
          decision_id,
          @contracts.decision_payload(expired),
          expired,
        )
      }
    None => ()
  }
  state.mutex.release()
}

///|
/// Ask the owner through the existing Decision record and wait for the
/// persisted answer. Returns `(approved, decision_id)`.
async fn skill_wait_owner_decision(
  state : HostState,
  capability : SkillCapability,
  entry : SkillCapabilityEntry,
  command : @contracts.SkillCommand,
  risk : String,
) -> (Bool, String) {
  let now = @async.now()
  let decision_id = @contracts.new_id("dec", now)
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
    id=decision_id,
    kind=@contracts.DECISION_KIND_SKILL,
    title="Approve skill command: " + entry.name + "@" + entry.version,
    detail="Session " +
    capability.session_id +
    " requests skill entry `" +
    command.id +
    "` (mode " +
    command.mode +
    ", risk " +
    risk +
    ").\n" +
    "Skill hash: " +
    entry.content_hash +
    "\nExact argv: " +
    command.argv.join(" "),
    session_id=capability.session_id,
    agent_id=capability.agent_id,
    options~,
    created_at=@contracts.format_rfc3339(now),
  )
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  state.mutex.acquire()
  state.skill_waiters.set(decision_id, queue)
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    decision_id,
    @contracts.decision_payload(record),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(_) => {
      state.mutex.acquire()
      state.skill_waiters.remove(decision_id)
      state.mutex.release()
      return (false, decision_id)
    }
  }
  let answer = @async.with_timeout_opt(
    SKILL_DECISION_WAIT_MS,
    async fn() { queue.get() },
  )
  state.mutex.acquire()
  state.skill_waiters.remove(decision_id)
  state.mutex.release()
  match answer {
    Some(option_id) => (option_id == @contracts.DECISION_OPTION_APPROVE, decision_id)
    None => {
      skill_expire_decision(state, decision_id)
      (false, decision_id)
    }
  }
}

///|
async fn handle_skill_tools(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let token = @contracts.string_field_or(request.params, "token", "")
  let (capability, _first) = skill_entry_lookup(state, token, "")
  let capability = match capability {
    Some(value) => value
    None => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error(
          @contracts.SKILL_ERR_GATEWAY_UNAVAILABLE,
          "skill gateway capability is not valid for a live session",
        ),
      )
      return
    }
  }
  let snapshot : Array[@contracts.SkillSnapshotEntry] = []
  for _entry_id, entry in capability.entries {
    let ids : Array[String] = []
    for id in entry.entry_ids {
      ids.push(id)
    }
    let mut duplicate = false
    for existing in snapshot {
      if existing.name == entry.name && existing.version == entry.version {
        duplicate = true
      }
    }
    if !duplicate {
      snapshot.push({
        name: entry.name,
        version: entry.version,
        content_hash: entry.content_hash,
        scope: entry.scope,
        mode: entry.mode,
        entry_sha256: "",
        entry_ids: ids,
      })
    }
  }
  let description = @skills.skill_invoke_tool_description(snapshot)
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("tools", @contracts.json_array([
        @contracts.json_object([
          ("name", @contracts.json_string(@contracts.SKILL_INVOKE_TOOL)),
          ("description", @contracts.json_string(description)),
          ("input_schema", @contracts.json_object([
            ("type", @contracts.json_string("object")),
            ("properties", @contracts.json_object([
              ("entry_id", @contracts.json_object([
                ("type", @contracts.json_string("string")),
              ])),
            ])),
            ("required", @contracts.json_array([
              @contracts.json_string("entry_id"),
            ])),
            ("additionalProperties", @contracts.json_bool(false)),
          ])),
        ]),
      ])),
    ]),
  )
}

///|
async fn handle_skill_invoke(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let token = @contracts.string_field_or(request.params, "token", "")
  let entry_id = @contracts.string_field_or(request.params, "entry_id", "")
  if token == "" || entry_id == "" || entry_id.length() > 64 {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(
        @contracts.SKILL_ERR_INVALID_ENTRY,
        "skill.invoke accepts only token and entry_id",
      ),
    )
    return
  }
  let (capability, entry) = skill_entry_lookup(state, token, entry_id)
  let capability = match capability {
    Some(value) => value
    None => {
      skill_emit_invoke_denied(state, "", entry_id, "", "", "", @contracts.SKILL_ERR_GATEWAY_UNAVAILABLE)
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error(
          @contracts.SKILL_ERR_GATEWAY_UNAVAILABLE,
          "skill gateway capability is not valid for a live session",
        ),
      )
      return
    }
  }
  let entry = match entry {
    Some(value) => value
    None => {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        "",
        "",
        "",
        @contracts.SKILL_ERR_NOT_LOADED,
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error(
          @contracts.SKILL_ERR_NOT_LOADED,
          "entry_id is not loaded in this session snapshot",
        ),
      )
      return
    }
  }
  state.mutex.acquire()
  let rate = match state.skill_rate.get(token) {
    Some(value) => value
    None => @contracts.trigger_rate_bucket_new(@async.now(), SKILL_GATEWAY_RATE_MAX)
  }
  let (updated, allowed) = @contracts.trigger_rate_take(
    rate,
    @async.now(),
    SKILL_GATEWAY_RATE_WINDOW_MS.to_int(),
    SKILL_GATEWAY_RATE_MAX,
  )
  state.skill_rate.set(token, updated)
  state.mutex.release()
  if !allowed {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_LIMIT_EXCEEDED,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "skill gateway rate limit exceeded"),
    )
    return
  }
  if entry.mode != @contracts.SKILL_MODE_LOADED {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_NOT_LOADED,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(@contracts.SKILL_ERR_NOT_LOADED, "skill is available but not loaded"),
    )
    return
  }
  if !skill_binding_still_enabled(state, capability, entry) {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_NOT_LOADED,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(
        @contracts.SKILL_ERR_NOT_LOADED,
        "skill was disabled; the frozen text remains but new invocations are refused",
      ),
    )
    return
  }
  // Re-verify the stored bundle on every invocation: allowlist, key,
  // signature and hash are re-checked rather than trusting the snapshot.
  state.mutex.acquire()
  let tuple = skill_tuple_allowed(
    state,
    entry.name,
    entry.version,
    entry.content_hash,
  )
  let ceiling = match state.store.get_agent_skill_permissions(capability.agent_id) {
    Ok(Some(value)) => value
    Ok(None) => @contracts.default_skill_permissions()
    Err(message) => {
      state.mutex.release()
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        "store_error",
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error("store_error", message),
      )
      return
    }
  }
  state.mutex.release()
  match tuple {
    Ok(_) => ()
    Err(error) => {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        @contracts.SKILL_ERR_NOT_ALLOWLISTED,
      )
      skill_send_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let keys = skill_key_snapshot(state)
  let store_path = state.state_dir +
    "/skills/store/" +
    entry.name +
    "/" +
    entry.version +
    "/" +
    entry.content_hash
  let bundle = match @skills.load_stored_skill(store_path, keys, state.verifier) {
    Ok(value) => value
    Err(fault) => {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        fault.code,
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_fault_error(fault),
      )
      return
    }
  }
  let command = match @skills.find_skill_command(bundle.manifest, entry_id) {
    Some(value) => value
    None => {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        @contracts.SKILL_ERR_INVALID_ENTRY,
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error(@contracts.SKILL_ERR_INVALID_ENTRY, "unknown entry_id"),
      )
      return
    }
  }
  if !@skills.skill_permissions_subset(bundle.manifest.permissions, ceiling) {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_PERMISSION_DENIED,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(
        @contracts.SKILL_ERR_PERMISSION_DENIED,
        "skill permissions exceed the current agent ceiling",
      ),
    )
    return
  }
  if !@skills.skill_argv_safe(command.argv) {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_INTERPRETER_DENIED,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(
        @contracts.SKILL_ERR_INTERPRETER_DENIED,
        "manifest argv contains an interpreter or an unsafe path",
      ),
    )
    return
  }
  let verdict = @skills.classify_skill_command(command.argv)
  if verdict.action == @contracts.POLICY_DENY {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_POLICY_DENIED,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(@contracts.SKILL_ERR_POLICY_DENIED, "policy denies this skill command"),
    )
    return
  }
  if verdict.risk == @contracts.RISK_CRITICAL {
    skill_emit_invoke_denied(
      state,
      capability.session_id,
      entry_id,
      entry.name,
      entry.version,
      entry.content_hash,
      @contracts.SKILL_ERR_CRITICAL,
    )
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_denied_error(@contracts.SKILL_ERR_CRITICAL, "critical commands are never auto-executed"),
    )
    return
  }
  let mut decision_id = ""
  if @skills.skill_verdict_needs_decision(command.mode, verdict) {
    let (approved, id) = skill_wait_owner_decision(
      state,
      capability,
      entry,
      command,
      verdict.risk,
    )
    decision_id = id
    if !approved {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        @contracts.SKILL_ERR_DECISION_DENIED,
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error(
          @contracts.SKILL_ERR_DECISION_DENIED,
          "the owner did not approve this skill invocation",
        ),
      )
      return
    }
  }
  let command_env = skill_default_env(capability.home)
  let collected = @async.with_timeout_opt(
    command.timeout_ms,
    async fn() {
      let triple = @process.collect_output(
        command.argv[0],
        command.argv[1:].to_owned(),
        cwd=capability.cwd,
        inherit_env=false,
        extra_env=command_env,
      ) catch {
        error => return Err(error.to_string())
      }
      Ok(triple)
    },
  )
  let (exit_code, stdout, stderr) = match collected {
    Some(Ok(triple)) => triple
    Some(Err(_)) => {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        "spawn_failed",
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error("spawn_failed", "cannot start the declared command"),
      )
      return
    }
    None => {
      skill_emit_invoke_denied(
        state,
        capability.session_id,
        entry_id,
        entry.name,
        entry.version,
        entry.content_hash,
        @contracts.SKILL_ERR_TIMEOUT,
      )
      skill_record_invocation(
        state,
        capability,
        entry,
        entry_id,
        client_request_id,
        @skills.sha256_file_hex(command.argv.join("\n")),
        "timeout",
        -1,
        decision_id,
        0,
      )
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_denied_error(@contracts.SKILL_ERR_TIMEOUT, "skill command timed out"),
      )
      return
    }
  }
  let stdout_text = stdout.text() catch { _ => "" }
  let stderr_text = stderr.text() catch { _ => "" }
  let merged = if stderr_text == "" {
    stdout_text
  } else if stdout_text == "" {
    stderr_text
  } else {
    stdout_text + "\n" + stderr_text
  }
  let redacted = @contracts.redact_secrets(merged)
  let limit = command.max_output_bytes
  let truncated = redacted.length() > limit
  let output = if truncated {
    redacted[:limit].to_owned() + "\n[output truncated]\n"
  } else {
    redacted
  }
  let argv_hash = @skills.sha256_file_hex(command.argv.join("\n"))
  skill_record_invocation(
    state,
    capability,
    entry,
    entry_id,
    client_request_id,
    argv_hash,
    if truncated { "output_limit" } else { "ok" },
    exit_code.to_int(),
    decision_id,
    output.length(),
  )
  state.mutex.acquire()
  let _ = state.append_event(
    @contracts.EVENT_SKILL_INVOKED,
    "skill-invoke/" + capability.session_id,
    @contracts.json_object([
      ("session_id", @contracts.json_string(capability.session_id)),
      ("name", @contracts.json_string(entry.name)),
      ("version", @contracts.json_string(entry.version)),
      ("content_hash", @contracts.json_string(entry.content_hash)),
      ("entry_id", @contracts.json_string(entry_id)),
      ("argv_hash", @contracts.json_string(argv_hash)),
      ("risk", @contracts.json_string(verdict.risk)),
      ("exit_code", @contracts.json_int(exit_code.to_int())),
      ("decision_id", @contracts.json_string(decision_id)),
      ("run_id", @contracts.json_string("")),
      ("output_bytes", @contracts.json_int(output.length())),
      ("truncated", @contracts.json_bool(truncated)),
    ]),
  )
  state.mutex.release()
  audit(
    state,
    "skill.invoke",
    "host",
    "session/" + capability.session_id,
    "executed",
    detail="entry_id=" +
    entry_id +
    " risk=" +
    verdict.risk +
    " exit=" +
    exit_code.to_string() +
    " decision=" +
    decision_id,
    policy="skill",
    decision_id~,
  )
  let result : @contracts.SkillInvocationResult = {
    name: entry.name,
    version: entry.version,
    content_hash: entry.content_hash,
    entry_id,
    exit_code: exit_code.to_int(),
    output,
    truncated,
    decision_id,
    run_id: "",
  }
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("invocation", result.to_json())]),
  )
}
