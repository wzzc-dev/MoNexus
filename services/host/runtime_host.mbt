///|
/// Paired-runtime host wiring (A1.5).
///
/// This file is the production entry point the A1.4 review asked for: it opens
/// the pinned TLS `PrimaryServer`, attaches a `RuntimeMachine` for every
/// `kind=runtime` record with a live channel, registers the runtime agent
/// launcher with a Decision-backed `ApprovalContext`, and exposes the small
/// operator surface the two-machine harness drives.
///
/// It does not add policy logic. Every mutating call goes through the A1.3b
/// provider (`process_start_approved`, `fs_write_approved`), which asks the
/// node's real policy gate and mints a one-time grant only after the owner
/// answers a Decision. Reads use the plain provider methods.

// ---------------------------------------------------------------------------
// Audit and approval plumbing
// ---------------------------------------------------------------------------

///|
fn runtime_error(
  kind : String,
  message : String,
  detail~ : String = "",
) -> @contracts.RpcError {
  @contracts.machine_error(kind, message, detail=detail)
}

///|
fn runtime_failure_kind(
  failure : @provider_runtime.ApprovalFailure,
) -> String {
  match failure {
    Denied(_) | Expired(_) | Rejected(_, _) | Rpc(_) => @contracts.MACHINE_ERR_REMOTE
    Pending(_) | Unavailable(_) => @contracts.MACHINE_ERR_UNREACHABLE
  }
}

///|
fn runtime_failure_message(
  failure : @provider_runtime.ApprovalFailure,
) -> String {
  failure.error_text()
}

///|
/// Append a permission Decision bound to this exact runtime operation. The
/// grant itself is minted by the provider after the owner answers; this record
/// is only the owner-facing question. `nonce` stays empty here: it is minted
/// by the provider and must never be shown to the owner.
async fn runtime_create_approval_decision(
  state : HostState,
  machine_id : String,
  request : @provider_runtime.ApprovalRequest,
) -> Result[String, String] {
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
  let full_detail = request.detail()
  let detail = if full_detail.length() > 8_192 {
    full_detail[:8_192].to_owned() + "\n... detail truncated"
  } else {
    full_detail
  }
  let record : @contracts.DecisionRecord = {
    ..@contracts.DecisionRecord::new(
      id=@contracts.new_id("dec", @async.now()),
      kind=@contracts.DECISION_KIND_PERMISSION,
      title="Runtime approval needed: " + request.rpc_method,
      detail~,
      session_id="",
      agent_id="",
      options~,
      created_at=@contracts.format_rfc3339(@async.now()),
      run_id=request.run_id,
    ),
    action: request.rpc_method,
    plan_digest: request.digest,
    machine_id,
    expires_at: @contracts.format_rfc3339(request.expires_at_ms),
  }
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    record.id,
    @contracts.decision_payload(record),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => Ok(record.id)
    Err(message) => Err("cannot persist runtime approval decision: " + message)
  }
}

///|
fn runtime_decision_binding_matches(
  record : @contracts.DecisionRecord,
  machine_id : String,
  request : @provider_runtime.ApprovalRequest,
) -> Bool {
  record.machine_id == machine_id &&
  record.action == request.rpc_method &&
  record.plan_digest == request.digest &&
  record.run_id == request.run_id
}

///|
async fn runtime_expire_approval_decision(
  state : HostState,
  decision_id : String,
) -> Unit {
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let loaded = state.store.get_decision(decision_id)
  match loaded {
    Ok(Some(record)) =>
      if record.status == @contracts.DECISION_STATUS_PENDING {
        let expired = {
          ..record,
          status: @contracts.DECISION_STATUS_EXPIRED,
          answered_at: timestamp,
          answered_by: "host",
          delivery_error: "runtime approval expired before the owner answered",
        }
        let _ = state.append_decision_event(
          @contracts.EVENT_DECISION_EXPIRED,
          decision_id,
          @contracts.decision_payload(expired),
          expired,
        )
      }
    _ => ()
  }
  state.mutex.release()
}

///|
/// Wait for the owner to answer the bound Decision. This blocks the calling
/// provider operation, but holds no host mutex while sleeping. An unanswered
/// request expires as `Expired`, never as an offline allow.
async fn runtime_wait_for_approval(
  state : HostState,
  machine_id : String,
  request : @provider_runtime.ApprovalRequest,
  decision_id : String,
) -> @provider_runtime.ApprovalOutcome {
  let mut id = decision_id
  if id == "" {
    match runtime_create_approval_decision(state, machine_id, request) {
      Ok(value) => id = value
      Err(message) => return @provider_runtime.ApprovalOutcome::Unavailable(message)
    }
  }
  let now = @async.now()
  let deadline = if request.expires_at_ms > now {
    request.expires_at_ms
  } else {
    now
  }
  let mut binding_checked = false
  while true {
    state.mutex.acquire()
    let loaded = state.store.get_decision(id)
    state.mutex.release()
    match loaded {
      Ok(Some(record)) => {
        if !binding_checked {
          if !runtime_decision_binding_matches(record, machine_id, request) {
            let message =
              "runtime approval decision is not bound to this operation"
            return @provider_runtime.ApprovalOutcome::Unavailable(message)
          }
          binding_checked = true
        }
        if record.status == @contracts.DECISION_STATUS_ANSWERED {
          match record.option_id {
            @contracts.DECISION_OPTION_APPROVE =>
              return @provider_runtime.ApprovalOutcome::Approved(record.id)
            @contracts.DECISION_OPTION_DENY =>
              return @provider_runtime.ApprovalOutcome::Denied(record.id)
            _ => {
              let message = "runtime approval has an unknown answer"
              return @provider_runtime.ApprovalOutcome::Unavailable(message)
            }
          }
        }
        if record.status == @contracts.DECISION_STATUS_EXPIRED {
          return @provider_runtime.ApprovalOutcome::Expired(record.id)
        }
      }
      Ok(None) => {
        let message = "runtime approval decision disappeared"
        return @provider_runtime.ApprovalOutcome::Unavailable(message)
      }
      Err(message) => {
        let text = "cannot read runtime approval decision: " + message
        return @provider_runtime.ApprovalOutcome::Unavailable(text)
      }
    }
    if @async.now() >= deadline {
      runtime_expire_approval_decision(state, id)
      return @provider_runtime.ApprovalOutcome::Expired(id)
    }
    @async.sleep(100)
  }
  @provider_runtime.ApprovalOutcome::Unavailable("runtime approval wait ended")
}

///|
fn runtime_approval_port(
  state : HostState,
  machine_id : String,
) -> @provider_runtime.ApprovalPort {
  let port : @provider_runtime.ApprovalPort = async fn(request) {
    runtime_wait_for_approval(state, machine_id, request, request.decision_id)
  }
  port
}

///|
fn runtime_approval_context(
  state : HostState,
  machine_id : String,
) -> @provider_runtime.ApprovalContext {
  @provider_runtime.ApprovalContext::new(
    port=runtime_approval_port(state, machine_id),
    ttl_ms=state.runtime_approval_ttl_ms,
    wait_ms=state.runtime_wait_ms,
  )
}

// ---------------------------------------------------------------------------
// Transport open / attach
// ---------------------------------------------------------------------------

///|
fn runtime_primary_state(
  state : HostState,
) -> Result[@transport.PrimaryState, String] {
  match state.runtime_primary.val {
    Some(value) => Ok(value)
    None =>
      Err(
        "runtime listener is disabled; start the host with --runtime-listen, --runtime-cert and --runtime-key",
      )
  }
}

///|
/// Open the pinned TLS primary when configured. There is no plaintext
/// fallback: a missing certificate, key or policy decode error refuses to
/// start the runtime listener rather than accepting unverifiable traffic.
async fn open_runtime_host(
  state : HostState,
  options : HostOptions,
) -> Result[Unit, String] {
  if options.runtime_listen.trim() == "" {
    return Ok(())
  }
  if options.runtime_cert == "" || options.runtime_key == "" {
    return Err(
      "--runtime-listen requires --runtime-cert and --runtime-key (TLS only)",
    )
  }
  let (host, port) = match runtime_address(options.runtime_listen) {
    Ok(value) => value
    Err(message) => return Err("invalid --runtime-listen: " + message)
  }
  let store_dir = if options.runtime_state_dir != "" {
    options.runtime_state_dir
  } else {
    options.state_dir + "/runtime"
  }
  let store = match @transport.StateStore::open(store_dir) {
    Ok(value) => value
    Err(message) => return Err("cannot open runtime state store: " + message)
  }
  let tls = @transport.TlsServerConfig::new(
    bind_host=host,
    bind_port=port,
    certificate_file=options.runtime_cert,
    private_key_file=options.runtime_key,
  )
  let config = @transport.ServerConfig::new(
    tls~,
    policy=@transport.CredentialPolicy::until_revoked(),
    heartbeat_interval_ms=5_000L,
    heartbeat_max_missed=3,
    hello_timeout_ms=10_000L,
  )
  let server = match
    @transport.PrimaryServer::open(
      config,
      store,
      @transport.HandlerRegistry::new(),
    ) {
    Ok(value) => value
    Err(message) => return Err("cannot open runtime primary: " + message)
  }
  if options.runtime_policy != "" {
    let text = @fs.read_file(options.runtime_policy).text() catch {
      error => {
        server.close()
        return Err(
          "cannot read --runtime-policy " + options.runtime_policy + ": " +
          error.to_string(),
        )
      }
    }
    let snapshot = match @policy.PolicySnapshot::decode(text) {
      Ok(value) => value
      Err(message) => {
        server.close()
        return Err("invalid --runtime-policy snapshot: " + message)
      }
    }
    state.runtime_policy_snapshot.val = Some(snapshot)
    match server.primary_state().publish_policy(snapshot) {
      Ok(_) => ()
      Err(message) => {
        server.close()
        return Err("cannot publish --runtime-policy: " + message)
      }
    }
  }
  let actual_port = server.port()
  state.mutex.acquire()
  state.runtime_primary.val = Some(server.primary_state())
  state.runtime_server.val = Some(server)
  state.mutex.release()
  println(
    "monexus-host: runtime primary listening on tls://" +
    host + ":" + actual_port.to_int().to_string(),
  )
  Ok(())
}

///|
async fn close_runtime_host(state : HostState) -> Unit {
  state.mutex.acquire()
  let server = state.runtime_server.val
  state.runtime_server.val = None
  state.runtime_primary.val = None
  state.mutex.release()
  match server {
    Some(value) => value.close()
    None => ()
  }
}

///|
fn runtime_audit(
  primary : @transport.PrimaryState,
  action : String,
  runtime_id : String,
  outcome : String,
  detail : String,
) -> Unit {
  primary.record_audit(action, runtime_id, outcome, detail)
}

///|
/// Reconcile attached runtime machines with live channels. This is the only
/// production registration point for `runtime_agent_launchers`; the A1.4
/// launcher is not useful until a live channel exists.
async fn runtime_attach_once(state : HostState) -> Unit {
  let primary = match state.runtime_primary.val {
    Some(value) => value
    None => return
  }
  let records = match state.store.list_machines() {
    Ok(value) => value
    Err(_) => return
  }
  let live : Map[String, String] = Map([])
  for record in records {
    if record.kind == @contracts.MACHINE_KIND_RUNTIME {
      match primary.channel_for(record.host) {
        Some(_) => live.set(record.id, record.host)
        None => ()
      }
    }
  }
  let attached : Array[String] = []
  let detached : Array[String] = []
  state.mutex.acquire()
  let existing : Array[String] = []
  for machine_id, _ in state.runtime_machines {
    existing.push(machine_id)
  }
  for machine_id in existing {
    if !live.contains(machine_id) {
      state.runtime_machines.remove(machine_id)
      state.runtime_agent_launchers.remove(machine_id)
      detached.push(machine_id)
    }
  }
  let already : Array[String] = []
  for machine_id, _ in state.runtime_machines {
    already.push(machine_id)
  }
  for machine_id, runtime_id in live {
    if !already.contains(machine_id) {
      let machine = @provider_runtime.RuntimeMachine::new(primary, runtime_id)
      let context = runtime_approval_context(state, machine_id)
      let launcher = @provider_runtime_agent.runtime_agent_launcher(
        machine,
        approval=Some(context),
        workspace_roots=state.runtime_workspace_roots,
      )
      state.runtime_machines.set(machine_id, machine)
      state.runtime_agent_launchers.set(machine_id, launcher)
      attached.push(machine_id)
    }
  }
  state.mutex.release()
  // A channel only receives a policy that was published while it existed, so
  // re-announce the snapshot when a node attaches (including after a node
  // restart). Without this the node would stay fail-closed forever.
  if attached.length() > 0 {
    match state.runtime_policy_snapshot.val {
      Some(snapshot) =>
        match primary.publish_policy(snapshot) {
          Ok(_) => ()
          Err(_) =>
            runtime_audit(
              primary,
              "runtime.policy_republish_failed",
              "",
              "error",
              "reason=publish_failed",
            )
        }
      None => ()
    }
  }
  for machine_id in attached {
    runtime_audit(
      primary,
      "runtime.attached",
      machine_id,
      "ok",
      "machine_id=" + machine_id,
    )
  }
  for machine_id in detached {
    runtime_audit(
      primary,
      "runtime.detached",
      machine_id,
      "ok",
      "machine_id=" + machine_id,
    )
  }
}

///|
async fn runtime_attach_loop(state : HostState) -> Unit {
  while true {
    runtime_attach_once(state)
    @async.sleep(500)
  }
}

///|
async fn runtime_machine_for(
  state : HostState,
  machine_id : String,
) -> Result[@provider_runtime.RuntimeMachine, String] {
  state.mutex.acquire()
  let machine = state.runtime_machines.get(machine_id)
  state.mutex.release()
  match machine {
    Some(value) => Ok(value)
    None =>
      Err(
        "runtime machine requires a live paired transport session; no runtime channel is attached to this host",
      )
  }
}

///|
async fn runtime_machine_probe(
  state : HostState,
  machine_id : String,
  timeout_seconds : Int,
) -> Result[@provider_runtime.RuntimeProbe, @contracts.RpcError] {
  let machine = match runtime_machine_for(state, machine_id) {
    Ok(value) => value
    Err(message) =>
      return Err(
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
  }
  let timeout_ms = if timeout_seconds < 1 {
    1_000
  } else {
    timeout_seconds * 1_000
  }
  let attempt = @async.with_timeout_opt(
    timeout_ms,
    async fn() {
      machine.probe()
    },
  )
  match attempt {
    None =>
      Err(
        runtime_error(
          @contracts.MACHINE_ERR_TIMEOUT,
          "runtime probe timed out after " + timeout_seconds.to_string() + "s",
        ),
      )
    Some(Ok(value)) => Ok(value)
    Some(Err(error)) =>
      Err(
        runtime_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          error.message,
          detail="code=" + error.code.to_string(),
        ),
      )
  }
}

///|
async fn handle_runtime_machine_probe(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  machine_id : String,
  timeout_seconds : Int,
) -> Unit {
  let probed = runtime_machine_probe(state, machine_id, timeout_seconds)
  let ts = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let current = match live_machine(state, machine_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          @contracts.MACHINE_ERR_NOT_FOUND,
          "machine was removed while probing: " + machine_id,
        ),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot read machine: " + message,
        ),
      )
      return
    }
  }
  match probed {
    Ok(probe) => {
      let contract = probe.machine_profile()
      let status = if contract.is_complete() {
        @contracts.MACHINE_STATUS_ONLINE
      } else {
        @contracts.MACHINE_STATUS_DEGRADED
      }
      let updated : @contracts.MachineRecord = {
        ..current,
        status,
        profile: Some(contract),
        ssh_effective: Map([]),
        ssh_effective_error: "",
        last_seen: ts,
        last_error: "",
        updated_at: ts,
      }
      let payload = @contracts.machine_event_payload(updated)
      if !current.is_reachable() {
        let connected = state.append_machine_event(
          @contracts.EVENT_MACHINE_CONNECTED,
          "machine/" + updated.id,
          payload,
          Some(updated),
          None,
        )
        match connected {
          Ok(_) => ()
          Err(message) => {
            state.mutex.release()
            send_machine_error(
              state,
              sink,
              request,
              client_request_id,
              runtime_error(
                @contracts.MACHINE_ERR_INTERNAL,
                "cannot persist machine state: " + message,
              ),
            )
            return
          }
        }
      }
      match
        state.append_machine_event(
          @contracts.EVENT_MACHINE_PROBED,
          "machine/" + updated.id,
          payload,
          Some(updated),
          None,
        ) {
        Ok(_) => ()
        Err(message) => {
          state.mutex.release()
          send_machine_error(
            state,
            sink,
            request,
            client_request_id,
            runtime_error(
              @contracts.MACHINE_ERR_INTERNAL,
              "cannot persist probe result: " + message,
            ),
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
        @contracts.machine_probe_result(updated, contract),
      )
    }
    Err(error) => {
      let updated : @contracts.MachineRecord = {
        ..current,
        status: @contracts.MACHINE_STATUS_OFFLINE,
        last_error: error.message,
        updated_at: ts,
      }
      let payload = @contracts.machine_event_payload(updated)
      let _ = state.append_machine_event(
        @contracts.EVENT_MACHINE_DISCONNECTED,
        "machine/" + updated.id,
        payload,
        Some(updated),
        None,
      )
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        error,
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Runtime operator RPCs
// ---------------------------------------------------------------------------

///|
async fn handle_runtime_pairing_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let primary = match state.runtime_primary.val {
    Some(value) => value
    None => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "runtime listener is disabled",
        ),
      )
      return
    }
  }
  let secret = match primary.create_pairing_code() {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_INTERNAL, message),
      )
      return
    }
  }
  let result = @contracts.json_object([
    ("code", @contracts.json_string(secret.code)),
    ("code_id", @contracts.json_string(secret.code_id)),
    ("expires_at_ms", @contracts.json_int64(secret.expires_at_ms)),
    ("expires_at", @contracts.json_string(@contracts.format_rfc3339(secret.expires_at_ms))),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_runtime_revoke(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let primary = match state.runtime_primary.val {
    Some(value) => value
    None => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "runtime listener is disabled",
        ),
      )
      return
    }
  }
  let runtime_id = @contracts.string_field_or(
    request.params,
    "runtime_id",
    "",
  ).trim().to_owned()
  if runtime_id == "" {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(
        @contracts.MACHINE_ERR_INVALID,
        "missing runtime_id",
      ),
    )
    return
  }
  let reason = @contracts.string_field_or(
    request.params,
    "reason",
    "owner_revoked",
  )
  let revoked = match primary.revoke(runtime_id, reason) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_INTERNAL, message),
      )
      return
    }
  }
  // Detach immediately; the channel has already been dropped by revoke.
  let records = match state.store.list_machines() {
    Ok(value) => value
    Err(_) => []
  }
  for record in records {
    if record.kind == @contracts.MACHINE_KIND_RUNTIME &&
      record.host == runtime_id {
      state.mutex.acquire()
      state.runtime_machines.remove(record.id)
      state.runtime_agent_launchers.remove(record.id)
      state.mutex.release()
      runtime_audit(
        primary,
        "runtime.detached",
        record.id,
        "revoked",
        "reason=" + reason,
      )
    }
  }
  let result = @contracts.json_object([
    ("runtime_id", @contracts.json_string(runtime_id)),
    ("revoked", @contracts.json_int(revoked)),
    ("reason", @contracts.json_string(reason)),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_runtime_drain(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let primary = match state.runtime_primary.val {
    Some(value) => value
    None => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "runtime listener is disabled",
        ),
      )
      return
    }
  }
  primary.request_drain()
  let result = @contracts.json_object([
    ("draining", @contracts.json_bool(true)),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_runtime_status(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  let primary = state.runtime_primary.val
  let server = state.runtime_server.val
  let attached : Array[@json.Json] = []
  for machine_id, machine in state.runtime_machines {
    attached.push(
      @contracts.json_object([
        ("machine_id", @contracts.json_string(machine_id)),
        ("runtime_id", @contracts.json_string(machine.runtime_id)),
        ("connected", @contracts.json_bool(machine.is_connected())),
        ("ack_cursor", @contracts.json_int64(machine.ack_cursor())),
      ]),
    )
  }
  let port = match server {
    Some(value) => value.port().to_int()
    None => 0
  }
  state.mutex.release()
  let (draining, channels, sessions, credentials, pairings, installed) =
    match primary {
      Some(value) =>
        (
          value.is_draining(),
          value.channel_count(),
          value.session_count(),
          value.credential_count(),
          value.pairing_count(),
          value.installed_policy_count(),
        )
      None => (false, 0, 0, 0, 0, 0)
    }
  let result = @contracts.json_object([
    ("enabled", @contracts.json_bool(primary is Some(_))),
    ("port", @contracts.json_int(port)),
    ("draining", @contracts.json_bool(draining)),
    ("channels", @contracts.json_int(channels)),
    ("sessions", @contracts.json_int(sessions)),
    ("credentials", @contracts.json_int(credentials)),
    ("pairings", @contracts.json_int(pairings)),
    ("installed_policies", @contracts.json_int(installed)),
    ("attached", @contracts.json_array(attached)),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_runtime_audit(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let primary = match state.runtime_primary.val {
    Some(value) => value
    None => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "runtime listener is disabled",
        ),
      )
      return
    }
  }
  let result = @contracts.json_object([
    ("events", @contracts.json_array(primary.audit_events())),
    ("audit_text", @contracts.json_string(primary.audit_text())),
    ("logs", @contracts.json_string_array(primary.logs())),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

// ---------------------------------------------------------------------------
// Machine execution surface
// ---------------------------------------------------------------------------

///|
fn runtime_optional_int64(
  params : Map[String, @json.Json],
  key : String,
) -> Int64 {
  @contracts.int64_field_or(params, key, 0L)
}

///|
fn runtime_run_id(
  params : Map[String, @json.Json],
) -> String {
  let supplied = @contracts.string_field_or(params, "run_id", "").trim().to_owned()
  if supplied != "" {
    return supplied
  }
  @contracts.new_id("run", @async.now())
}

///|
fn runtime_cwd_for(
  state : HostState,
  requested : String,
) -> Result[String, String] {
  @provider_runtime_agent.runtime_agent_cwd(
    requested,
    state.runtime_workspace_roots,
  )
}

///|
fn json_int_or_null(value : Int?) -> @json.Json {
  match value {
    Some(found) => @contracts.json_int(found)
    None => @contracts.json_null()
  }
}

///|
async fn runtime_read_stream(
  machine : @provider_runtime.RuntimeMachine,
  run_id : String,
  stream : String,
) -> Result[String, String] {
  let mut offset = 0L
  let bytes : Array[Byte] = []
  let mut eof = false
  let mut chunks = 0
  while !eof && chunks < 4_096 {
    let chunk = if stream == "stdout" {
      machine.process_stdout(run_id, offset)
    } else {
      machine.process_stderr(run_id, offset)
    }
    let chunk = match chunk {
      Ok(value) => value
      Err(error) => return Err(error.message)
    }
    let decoded = @base64.decode(chunk.data_b64) catch {
      _ =>
        return Err("runtime " + stream + " chunk is not valid base64")
    }
    for byte in decoded {
      bytes.push(byte)
    }
    eof = chunk.eof
    if chunk.next_offset > offset {
      offset = chunk.next_offset
    } else {
      break
    }
    chunks = chunks + 1
  }
  Ok(
    @utf8.decode_lossy(Bytes::from_array(bytes[:])[:], ignore_bom=false),
  )
}

///|
async fn runtime_wait_process(
  machine : @provider_runtime.RuntimeMachine,
  run_id : String,
  timeout_ms : Int64,
) -> Result[@provider_runtime.ProcessSnapshot, String] {
  let wait_ms = if timeout_ms > 0L {
    timeout_ms + 10_000L
  } else {
    60_000L
  }
  let deadline = @async.now() + wait_ms
  while true {
    let result = machine.process_exit(run_id)
    match result {
      Ok(Some(snapshot)) =>
        if snapshot.is_terminal() {
          return Ok(snapshot)
        }
      Ok(None) =>
        return Err(
          "runtime process is not known to the node (status=lost)",
        )
      Err(error) => {
        if error.message.contains("unknown process") {
          return Err(
            "runtime process is not known to the node (status=lost): " +
            error.message,
          )
        }
        return Err(
          "runtime session was interrupted before the run was settled: " +
          error.message,
        )
      }
    }
    if !machine.is_connected() {
      return Err(
        "runtime session was interrupted before the run was settled; not reporting success",
      )
    }
    if @async.now() >= deadline {
      return Err("runtime process did not finish within the observation window")
    }
    @async.sleep(50)
  }
  Err("runtime process observation ended")
}

///|
async fn handle_machine_exec(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = @contracts.string_field_or(
    request.params,
    "machine_id",
    "",
  ).trim().to_owned()
  if machine_id == "" {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(@contracts.MACHINE_ERR_INVALID, "missing machine_id"),
    )
    return
  }
  let argv = @contracts.string_array_field(request.params, "argv")
  if argv.is_empty() {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(@contracts.MACHINE_ERR_INVALID, "missing argv"),
    )
    return
  }
  let cwd = match runtime_cwd_for(
    state,
    @contracts.string_field_or(request.params, "cwd", ""),
  ) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_INVALID, message),
      )
      return
    }
  }
  let machine = match runtime_machine_for(state, machine_id) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let run_id = runtime_run_id(request.params)
  let timeout_ms = runtime_optional_int64(request.params, "timeout_ms")
  let max_output = runtime_optional_int64(
    request.params,
    "max_output_bytes",
  )
  let approval = runtime_approval_context(state, machine_id)
  let started = machine.process_start_approved(
    run_id~,
    client_request_id~,
    argv~,
    cwd~,
    timeout_ms~,
    max_output_bytes=if max_output > 0L { max_output } else { 1_048_576L },
    approval~,
  )
  let (process, existing) = match started {
    Ok(value) => value
    Err(failure) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(
          runtime_failure_kind(failure),
          runtime_failure_message(failure),
        ),
      )
      return
    }
  }
  let settled = if process.is_terminal() {
    Ok(process)
  } else {
    runtime_wait_process(machine, run_id, timeout_ms)
  }
  let snapshot = match settled {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let stdout = match runtime_read_stream(machine, run_id, "stdout") {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let stderr = match runtime_read_stream(machine, run_id, "stderr") {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let result = @contracts.json_object([
    ("run_id", @contracts.json_string(snapshot.run_id)),
    ("client_request_id", @contracts.json_string(snapshot.client_request_id)),
    ("status", @contracts.json_string(snapshot.status)),
    ("success", @contracts.json_bool(snapshot.success)),
    ("exit_code", json_int_or_null(snapshot.exit_code)),
    ("signal", json_int_or_null(snapshot.signal)),
    ("stop_reason", @contracts.json_string(snapshot.stop_reason)),
    ("risk", @contracts.json_string(snapshot.risk)),
    ("pid", @contracts.json_int(snapshot.pid)),
    ("cwd", @contracts.json_string(snapshot.cwd)),
    ("started_at", @contracts.json_string(snapshot.started_at)),
    ("ended_at", @contracts.json_string(snapshot.ended_at)),
    ("timed_out", @contracts.json_bool(snapshot.timed_out)),
    ("stdout", @contracts.json_string(stdout)),
    ("stderr", @contracts.json_string(stderr)),
    ("stdout_bytes", @contracts.json_int64(snapshot.stdout_bytes)),
    ("stderr_bytes", @contracts.json_int64(snapshot.stderr_bytes)),
    ("stdout_dropped", @contracts.json_bool(snapshot.stdout_dropped)),
    ("stderr_dropped", @contracts.json_bool(snapshot.stderr_dropped)),
    ("existing", @contracts.json_bool(existing)),
  ])
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_machine_exec_status(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = @contracts.string_field_or(
    request.params,
    "machine_id",
    "",
  ).trim().to_owned()
  let run_id = @contracts.string_field_or(
    request.params,
    "run_id",
    "",
  ).trim().to_owned()
  if machine_id == "" || run_id == "" {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(
        @contracts.MACHINE_ERR_INVALID,
        "missing machine_id or run_id",
      ),
    )
    return
  }
  let machine = match runtime_machine_for(state, machine_id) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let found = machine.process_exit(run_id)
  let result = match found {
    Ok(Some(snapshot)) =>
      @contracts.json_object([
        ("run_id", @contracts.json_string(snapshot.run_id)),
        ("status", @contracts.json_string(snapshot.status)),
        ("success", @contracts.json_bool(snapshot.success)),
        ("exit_code", json_int_or_null(snapshot.exit_code)),
        ("signal", json_int_or_null(snapshot.signal)),
        ("stop_reason", @contracts.json_string(snapshot.stop_reason)),
        ("timed_out", @contracts.json_bool(snapshot.timed_out)),
        ("stdout_bytes", @contracts.json_int64(snapshot.stdout_bytes)),
        ("stderr_bytes", @contracts.json_int64(snapshot.stderr_bytes)),
      ])
    Ok(None) =>
      @contracts.json_object([
        ("run_id", @contracts.json_string(run_id)),
        ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
        ("success", @contracts.json_bool(false)),
      ])
    Err(error) => {
      if error.message.contains("unknown process") {
        @contracts.json_object([
          ("run_id", @contracts.json_string(run_id)),
          ("status", @contracts.json_string(@contracts.RUN_STATUS_LOST)),
          ("success", @contracts.json_bool(false)),
          ("detail", @contracts.json_string(error.message)),
        ])
      } else {
        send_machine_error(
          state,
          sink,
          request,
          client_request_id,
          runtime_error(
            @contracts.MACHINE_ERR_UNREACHABLE,
            "cannot read runtime process: " + error.message,
          ),
        )
        return
      }
    }
  }
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_machine_fs(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = @contracts.string_field_or(
    request.params,
    "machine_id",
    "",
  ).trim().to_owned()
  if machine_id == "" {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(@contracts.MACHINE_ERR_INVALID, "missing machine_id"),
    )
    return
  }
  let machine = match runtime_machine_for(state, machine_id) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let op = @contracts.string_field_or(request.params, "op", "")
  let path = @contracts.string_field_or(request.params, "path", "")
  let result = match op {
    "read" => {
      let max_bytes = @contracts.int_field_or(
        request.params,
        "max_bytes",
        0,
      )
      machine.fs_read(path~, max_bytes~)
    }
    "stat" => machine.fs_stat(path~)
    "list" => machine.fs_list(path~)
    "write" => {
      let content = @contracts.string_field_or(
        request.params,
        "content",
        "",
      )
      let approval = runtime_approval_context(state, machine_id)
      let written = machine.fs_write_approved(
        path~,
        content~,
        client_request_id~,
        approval~,
      )
      match written {
        Ok(value) => Ok(value)
        Err(failure) => Err(
          runtime_error(
            runtime_failure_kind(failure),
            runtime_failure_message(failure),
          ),
        )
      }
    }
    _ =>
      Err(
        runtime_error(
          @contracts.MACHINE_ERR_INVALID,
          "unsupported fs op: " + op,
        ),
      )
  }
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      send_machine_error(state, sink, request, client_request_id, error)
  }
}

///|
fn pty_snapshot_json(
  snapshot : @provider_runtime.PtySnapshot,
) -> @json.Json {
  @contracts.json_object([
    ("session_id", @contracts.json_string(snapshot.session_id)),
    ("status", @contracts.json_string(snapshot.status)),
    ("running", @contracts.json_bool(snapshot.running)),
    ("success", @contracts.json_bool(snapshot.success)),
    ("exit_code", json_int_or_null(snapshot.exit_code)),
    ("output_seq", @contracts.json_int64(snapshot.output_seq)),
    ("output_dropped", @contracts.json_bool(snapshot.output_dropped)),
    ("log_bytes", @contracts.json_int64(snapshot.log_bytes)),
    ("pid", @contracts.json_int(snapshot.pid)),
    ("rows", @contracts.json_int(snapshot.rows)),
    ("cols", @contracts.json_int(snapshot.cols)),
  ])
}

///|
async fn handle_machine_pty(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = @contracts.string_field_or(
    request.params,
    "machine_id",
    "",
  ).trim().to_owned()
  if machine_id == "" {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(@contracts.MACHINE_ERR_INVALID, "missing machine_id"),
    )
    return
  }
  let machine = match runtime_machine_for(state, machine_id) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let op = @contracts.string_field_or(request.params, "op", "")
  let session_id = @contracts.string_field_or(
    request.params,
    "session_id",
    "",
  ).trim().to_owned()
  let result = match op {
    "open" => {
      let id = if session_id != "" {
        session_id
      } else {
        @contracts.new_id("pty", @async.now())
      }
      let argv = @contracts.string_array_field(request.params, "argv")
      let cwd = match runtime_cwd_for(
        state,
        @contracts.string_field_or(request.params, "cwd", ""),
      ) {
        Ok(value) => value
        Err(message) => {
          send_machine_error(
            state,
            sink,
            request,
            client_request_id,
            runtime_error(@contracts.MACHINE_ERR_INVALID, message),
          )
          return
        }
      }
      let rows = @contracts.int_field_or(request.params, "rows", 24)
      let cols = @contracts.int_field_or(request.params, "cols", 80)
      match
        machine.pty_open(
          session_id=id,
          client_request_id~,
          argv~,
          cwd~,
          rows~,
          cols~,
        ) {
        Ok((snapshot, existing)) =>
          Ok(
            @contracts.json_object([
              ("session", pty_snapshot_json(snapshot)),
              ("existing", @contracts.json_bool(existing)),
            ]),
          )
        Err(error) => Err(error)
      }
    }
    "input" => {
      let data = @contracts.string_field_or(request.params, "data", "")
      machine.pty_input(session_id~, data~, client_request_id~)
    }
    "resize" => {
      let rows = @contracts.int_field_or(request.params, "rows", 24)
      let cols = @contracts.int_field_or(request.params, "cols", 80)
      machine.pty_resize(session_id~, rows~, cols~, client_request_id~)
    }
    "close" =>
      match machine.pty_close(session_id, client_request_id~) {
        Ok(snapshot) =>
          Ok(
            @contracts.json_object([
              ("session", pty_snapshot_json(snapshot)),
            ]),
          )
        Err(error) => Err(error)
      }
    "status" =>
      match machine.pty_status(session_id) {
        Ok(snapshot) =>
          Ok(
            @contracts.json_object([
              ("session", pty_snapshot_json(snapshot)),
            ]),
          )
        Err(error) => Err(error)
      }
    _ =>
      Err(
        runtime_error(
          @contracts.MACHINE_ERR_INVALID,
          "unsupported pty op: " + op,
        ),
      )
  }
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      send_machine_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_machine_git(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = @contracts.string_field_or(
    request.params,
    "machine_id",
    "",
  ).trim().to_owned()
  if machine_id == "" {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      runtime_error(@contracts.MACHINE_ERR_INVALID, "missing machine_id"),
    )
    return
  }
  let machine = match runtime_machine_for(state, machine_id) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        runtime_error(@contracts.MACHINE_ERR_UNREACHABLE, message),
      )
      return
    }
  }
  let op = @contracts.string_field_or(request.params, "op", "")
  let result = match op {
    "status" => machine.git_status()
    "diff" =>
      machine.git_diff(
        path=@contracts.string_field_or(request.params, "path", ""),
        cached=@contracts.bool_field_or(request.params, "cached", false),
        range=@contracts.string_field_or(request.params, "range", ""),
      )
    "log" =>
      machine.git_log(
        rev=@contracts.string_field_or(request.params, "rev", ""),
        max_count=@contracts.int_field_or(request.params, "max_count", 0),
        path=@contracts.string_field_or(request.params, "path", ""),
      )
    "show" =>
      machine.git_show(
        rev=@contracts.string_field_or(request.params, "rev", "HEAD"),
        path=@contracts.string_field_or(request.params, "path", ""),
      )
    "branches" => machine.git_branches()
    "worktrees" => machine.git_worktrees()
    "read_output" =>
      machine.git_read_output(
        op_id=@contracts.string_field_or(request.params, "op_id", ""),
        stream=@contracts.string_field_or(
          request.params,
          "stream",
          "stdout",
        ),
        offset=@contracts.int64_field_or(request.params, "offset", 0L),
        max_bytes=@contracts.int_field_or(request.params, "max_bytes", 0),
      )
    _ =>
      Err(
        runtime_error(
          @contracts.MACHINE_ERR_INVALID,
          "unsupported git op: " + op,
        ),
      )
  }
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      send_machine_error(state, sink, request, client_request_id, error)
  }
}
