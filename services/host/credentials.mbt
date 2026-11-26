///|
/// Managed account credential RPCs (A5.0, ADR-0016 as amended for V0.2).
///
/// Local credentials: the platform store (`CredentialStore`) owns the secret,
/// SQLite owns metadata, and a per-session loopback proxy hands the Agent a
/// short-lived `mxp_` token instead of the real key.
///
/// Remote credentials: the node registers and stores the secret on itself. The
/// primary stores only `(machine, agent, profile)`, fingerprint, version and
/// status. Lease and revoke are metadata/control signals; neither carries a
/// secret. `credential.enroll` for a non-local machine is refused, so the
/// primary cannot become a key custodian for a remote Agent.
///
/// With `credential.enabled=false` every `credential.*` method answers
/// `unsupported` and appends no credential event, preserving V0.1 behavior.

///|
/// Backstop lifetime of a local proxy capability token. The proxy is normally
/// stopped with its Agent session; expiry bounds a leaked token if a session
/// is orphaned.
const CREDENTIAL_PROXY_SESSION_TTL_MS : Int64 = 3_600_000L

///|
fn credential_rpc_error(
  reason : String,
  detail~ : String = "",
) -> @contracts.RpcError {
  let message = if detail == "" { reason } else { reason + ": " + detail }
  @contracts.RpcError::new(@contracts.ERR_HOST, message)
}

///|
fn credential_unsupported_error() -> @contracts.RpcError {
  credential_rpc_error(
    @contracts.CREDENTIAL_REASON_DISABLED,
    detail="managed credentials are disabled; start the host with --credential-enabled true",
  )
}

///|
fn credential_failure_error(
  failure : @credentials.CredentialFailure,
) -> @contracts.RpcError {
  credential_rpc_error(failure.reason, detail=failure.detail)
}

///|
fn credential_valid_kind(kind : String) -> Bool {
  kind == @contracts.CREDENTIAL_KIND_API_KEY ||
  kind == @contracts.CREDENTIAL_KIND_BEARER_TOKEN
}

///|
/// The fixed reason a binding's state implies. Empty means "usable".
fn credential_binding_state_reason(binding_state : String) -> String {
  if binding_state == @contracts.CREDENTIAL_STATE_ACTIVE {
    ""
  } else if binding_state == @contracts.CREDENTIAL_STATE_PENDING_ENROLLMENT {
    @contracts.CREDENTIAL_REASON_DELIVERY_FAILED
  } else if binding_state == @contracts.CREDENTIAL_STATE_REVOKED ||
    binding_state == @contracts.CREDENTIAL_STATE_REVOCATION_PENDING {
    @contracts.CREDENTIAL_REASON_REVOKED
  } else if binding_state == @contracts.CREDENTIAL_STATE_DELETED ||
    binding_state == @contracts.CREDENTIAL_STATE_UNBOUND {
    @contracts.CREDENTIAL_REASON_MISSING
  } else {
    @contracts.CREDENTIAL_REASON_BAD_STATE
  }
}

///|
/// Secret-free event payload. The platform store is the only place a secret
/// exists; neither record below has a secret field.
fn credential_event_payload(
  credential : @contracts.CredentialRecord?,
  binding : @contracts.CredentialBinding?,
  extra : Array[(String, @json.Json)],
) -> @json.Json {
  let fields : Array[(String, @json.Json)] = []
  match credential {
    Some(record) => {
      fields.push(("credential_id", @contracts.json_string(record.id)))
      fields.push(("kind", @contracts.json_string(record.kind)))
      fields.push(("storage", @contracts.json_string(record.storage)))
      fields.push(("owner", @contracts.json_string(record.owner)))
      fields.push(("credential_state", @contracts.json_string(record.state)))
      fields.push(("version", @contracts.json_int(record.version)))
      fields.push(("fingerprint", @contracts.json_string(record.fingerprint)))
    }
    None => ()
  }
  match binding {
    Some(record) => {
      fields.push(("binding_id", @contracts.json_string(record.id)))
      fields.push(("machine_id", @contracts.json_string(record.machine_id)))
      fields.push(("agent_id", @contracts.json_string(record.agent_id)))
      fields.push(("profile", @contracts.json_string(record.profile)))
      fields.push(("binding_state", @contracts.json_string(record.state)))
      fields.push(("binding_version", @contracts.json_int(record.version)))
      fields.push(
        ("binding_fingerprint", @contracts.json_string(record.fingerprint)),
      )
      fields.push(
        ("lease_expires_at", @contracts.json_string(record.lease_expires_at)),
      )
    }
    None => ()
  }
  for field in extra {
    fields.push(field)
  }
  @contracts.json_object(fields)
}

///|
fn credential_profile_named(
  state : HostState,
  name : String,
) -> @contracts.CredentialProfile? {
  match @contracts.CredentialProfile::builtin(name) {
    Some(value) => Some(value)
    None =>
      match state.store.get_credential_profile(name) {
        Ok(Some(value)) => Some(value)
        _ => None
      }
  }
}

///|
/// A host-owned secret may only be bound to the host's own machine: an empty
/// machine id or a `local` machine record. A runtime/SSH machine must enroll on
/// the node itself, and the primary then stores metadata only.
async fn credential_machine_accepts_host_secret(
  state : HostState,
  machine_id : String,
) -> Bool {
  if machine_id == "" {
    return true
  }
  state.mutex.acquire()
  let kind = match state.store.get_machine(machine_id) {
    Ok(Some(record)) => record.kind
    _ => ""
  }
  state.mutex.release()
  kind == @contracts.MACHINE_KIND_LOCAL
}

///|
async fn credential_machine_exists(
  state : HostState,
  machine_id : String,
) -> Result[String, @contracts.RpcError] {
  if machine_id == "" {
    return Ok("")
  }
  state.mutex.acquire()
  let kind = match state.store.get_machine(machine_id) {
    Ok(Some(record)) => record.kind
    _ => ""
  }
  state.mutex.release()
  if kind == "" {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
        detail="machine not found",
      ),
    )
  }
  Ok(kind)
}

///|
fn credential_lease_expired(
  binding : @contracts.CredentialBinding,
  now : Int64,
) -> Bool {
  if binding.lease_expires_at == "" {
    return false
  }
  let parsed = @contracts.parse_rfc3339_ms(binding.lease_expires_at)
  match parsed {
    Some(value) => now > value
    None => true
  }
}

///|
fn credential_lease_deadline(now : Int64, ttl_ms : Int64) -> String {
  let ttl = if ttl_ms > 0L {
    ttl_ms
  } else {
    @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS
  }
  @contracts.format_rfc3339(now + ttl)
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

///|
/// Record one secret-free credential audit event while the caller holds
/// `mutex`. Projection updates are optional.
fn HostState::record_credential_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  credential : @contracts.CredentialRecord?,
  binding : @contracts.CredentialBinding?,
) -> Result[Unit, String] {
  match
    self.append_credential_event(
      event_type, subject, payload, credential, binding,
    ) {
    Ok(_) => Ok(())
    Err(message) => Err(message)
  }
}

///|
/// Proxy audit hook. The proxy only ever sends fixed reason strings or its
/// own event names here; the token and the secret never reach this function.
/// `append_event` is synchronous and does not await, so a single event append
/// is atomic with respect to other cooperative tasks even without `mutex`.
fn record_proxy_audit(
  state : HostState,
  binding_id : String,
  event_type : String,
  reason : String,
) -> Unit {
  let payload = @contracts.json_object([
    ("binding_id", @contracts.json_string(binding_id)),
    ("reason", @contracts.json_string(reason)),
  ])
  ignore(
    state.append_event(event_type, "credential_binding/" + binding_id, payload),
  )
}

// ---------------------------------------------------------------------------
// Readiness + proxy preparation (used by agent.start)
// ---------------------------------------------------------------------------

///|
/// One prepared Agent credential. Local sessions get a started proxy and the
/// two env values to inject; remote sessions carry only the binding tuple the
/// node needs to start its own local proxy.
pub struct PreparedAgentCredential {
  binding : @contracts.CredentialBinding
  proxy : @credentials.CredentialProxy?
  proxy_url : String
  proxy_token : String
  remote : Bool
}

///|
pub fn PreparedAgentCredential::is_remote(
  self : PreparedAgentCredential,
) -> Bool {
  self.remote
}

///|
pub fn PreparedAgentCredential::binding(
  self : PreparedAgentCredential,
) -> @contracts.CredentialBinding {
  self.binding
}

///|
pub fn PreparedAgentCredential::env(
  self : PreparedAgentCredential,
) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  if !self.remote && self.proxy_url != "" {
    env.set(@contracts.CREDENTIAL_ENV_PROXY_URL, self.proxy_url)
    env.set(@contracts.CREDENTIAL_ENV_PROXY_TOKEN, self.proxy_token)
  }
  env
}

///|
/// Fixed-reason readiness failure. Repeated failures for the same binding and
/// reason are deduplicated: a failure inside the cooldown window, or one that
/// matches an already-open readiness Decision for the same tuple, records
/// `credential.readiness.suppressed` instead of creating another Inbox item.
/// A missing key therefore cannot cause a retry storm.
async fn record_credential_readiness_failure(
  state : HostState,
  machine_id : String,
  agent_id : String,
  profile : String,
  reason : String,
) -> Unit {
  let key = machine_id + "|" + agent_id + "|" + profile + "|" + reason
  let now = @async.now()
  let cooldown_active = match state.credential_cooldowns.get(key) {
    Some(last) => now - last < state.credential_cooldown_ms
    None => false
  }
  let detail = "reason=" +
    reason +
    "; profile=" +
    profile +
    "; machine=" +
    machine_id
  state.mutex.acquire()
  let pending = match
    state.store.list_decisions(@contracts.DECISION_STATUS_PENDING, "") {
    Ok(value) => value
    Err(_) => []
  }
  let mut open_for_tuple = false
  for decision in pending {
    if decision.kind == @contracts.DECISION_KIND_READINESS &&
      decision.agent_id == agent_id &&
      decision.detail == detail {
      open_for_tuple = true
    }
  }
  state.mutex.release()
  let payload = @contracts.json_object([
    ("machine_id", @contracts.json_string(machine_id)),
    ("agent_id", @contracts.json_string(agent_id)),
    ("profile", @contracts.json_string(profile)),
    ("reason", @contracts.json_string(reason)),
  ])
  if cooldown_active || open_for_tuple {
    ignore(
      state.append_event(
        @contracts.EVENT_CREDENTIAL_READINESS_SUPPRESSED,
        "agent/" + agent_id,
        payload,
      ),
    )
    return
  }
  state.credential_cooldowns.set(key, now)
  ignore(
    state.append_event(
      @contracts.EVENT_CREDENTIAL_READINESS_FAILED,
      "agent/" + agent_id,
      payload,
    ),
  )
  let decision = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", now),
    kind=@contracts.DECISION_KIND_READINESS,
    title="Agent credential not ready: " + agent_id,
    detail~,
    session_id="",
    agent_id~,
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

///|
/// Resolve, validate and (for a local machine) start the proxy for one Agent
/// start. `profile_name` is the explicit `credential_profile` parameter; empty
/// means "the one active binding for this agent and machine".
///
/// Returns `None` when the Agent has no credential binding, preserving the
/// V0.1 path for agents that do not use managed accounts.
pub async fn prepare_agent_credential(
  state : HostState,
  group : @async.TaskGroup[Unit],
  machine_id : String,
  agent_id : String,
  profile_name : String,
) -> Result[PreparedAgentCredential?, @credentials.CredentialFailure] {
  if !state.credential_enabled {
    return Ok(None)
  }
  state.mutex.acquire()
  let bindings_result = state.store.list_credential_bindings()
  state.mutex.release()
  let bindings = match bindings_result {
    Ok(value) => value
    Err(message) =>
      return Err(
        @credentials.credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot read binding metadata: " + message,
        ),
      )
  }
  let candidates : Array[@contracts.CredentialBinding] = []
  for binding in bindings {
    if binding.agent_id == agent_id && binding.machine_id == machine_id {
      if profile_name == "" || binding.profile == profile_name {
        candidates.push(binding)
      }
    }
  }
  let chosen = if profile_name != "" {
    let mut found : @contracts.CredentialBinding? = None
    for binding in candidates {
      if binding.state == @contracts.CREDENTIAL_STATE_ACTIVE {
        found = Some(binding)
        break
      }
      found = Some(binding)
    }
    found
  } else {
    let active : Array[@contracts.CredentialBinding] = []
    for binding in candidates {
      if binding.state == @contracts.CREDENTIAL_STATE_ACTIVE {
        active.push(binding)
      }
    }
    if active.length() > 1 {
      return Err(
        @credentials.credential_failure(
          @contracts.CREDENTIAL_REASON_BINDING_CONFLICT,
          detail="multiple active credential profiles; pass credential_profile",
        ),
      )
    }
    if active.length() == 1 {
      Some(active[0])
    } else if candidates.length() > 0 {
      Some(candidates[0])
    } else {
      None
    }
  }
  let binding = match chosen {
    Some(value) => value
    None => return Ok(None)
  }
  if binding.state != @contracts.CREDENTIAL_STATE_ACTIVE {
    return Err(
      @credentials.credential_failure(
        credential_binding_state_reason(binding.state),
        detail="binding state=" + binding.state,
      ),
    )
  }
  // Resolve the target machine kind. An empty machine id means the primary's
  // own machine; a runtime machine uses node-local custody; an SSH machine has
  // no credential channel at all and must fail closed.
  let kind = if binding.machine_id == "" {
    @contracts.MACHINE_KIND_LOCAL
  } else {
    state.mutex.acquire()
    let record_result = state.store.get_machine(binding.machine_id)
    state.mutex.release()
    match record_result {
      Ok(Some(record)) => record.kind
      _ => ""
    }
  }
  if kind == "" {
    return Err(
      @credentials.credential_failure(
        @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
        detail="binding machine not found",
      ),
    )
  }
  let remote = kind != @contracts.MACHINE_KIND_LOCAL
  if remote && kind != @contracts.MACHINE_KIND_RUNTIME {
    return Err(
      @credentials.credential_failure(
        @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
        detail="SSH machines have no node-local credential channel",
      ),
    )
  }
  if remote {
    // Node-local custody: renew the lease with the node and verify the
    // mirrored status. No secret ever reaches this host for a remote binding.
    state.mutex.acquire()
    let port = state.credential_ports.get(binding.machine_id)
    state.mutex.release()
    let now = @async.now()
    let port = match port {
      Some(value) => value
      None =>
        // No live channel: the binding is usable only while its lease lasts.
        if credential_lease_expired(binding, now) {
          return Err(
            @credentials.credential_failure(
              @contracts.CREDENTIAL_REASON_LEASE_EXPIRED,
              detail="primary lease for the remote binding has expired",
            ),
          )
        } else {
          return Err(
            @credentials.credential_failure(
              @contracts.CREDENTIAL_REASON_DELIVERY_FAILED,
              detail="no live node channel for the remote binding",
            ),
          )
        }
    }
    let signal = @credentials.RemoteCredentialSignal::new(
      binding_id=binding.id,
      credential_id=binding.credential_id,
      machine_id=binding.machine_id,
      agent_id=binding.agent_id,
      profile=binding.profile,
      version=binding.version,
      fingerprint=binding.fingerprint,
      lease_ttl_ms=state.credential_lease_ttl_ms,
    )
    let delivered = (port.lease)(signal)
    match delivered {
      Err(message) =>
        return Err(
          @credentials.credential_failure(
            @contracts.CREDENTIAL_REASON_DELIVERY_FAILED,
            detail=@contracts.redact_secrets(message),
          ),
        )
      Ok(_) => ()
    }
    let renewed = {
      ..binding,
      last_seen_at: @contracts.format_rfc3339(now),
      lease_expires_at: credential_lease_deadline(
        now,
        state.credential_lease_ttl_ms,
      ),
      updated_at: @contracts.format_rfc3339(now),
    }
    state.mutex.acquire()
    let recorded = state.record_credential_event(
      @contracts.EVENT_CREDENTIAL_DELIVERED,
      "credential_binding/" + binding.id,
      credential_event_payload(None, Some(renewed), [
        ("reason", @contracts.json_string("lease_renewed")),
      ]),
      None,
      Some(renewed),
    )
    state.mutex.release()
    match recorded {
      Err(message) =>
        return Err(
          @credentials.credential_failure(
            @contracts.CREDENTIAL_REASON_LOCKED,
            detail="cannot persist the renewed lease: " + message,
          ),
        )
      Ok(_) => ()
    }
    return Ok(
      Some({
        binding: renewed,
        proxy: None,
        proxy_url: "",
        proxy_token: "",
        remote: true,
      }),
    )
  }
  // Local machine: the secret is in this host's platform store.
  state.mutex.acquire()
  let credential_result = state.store.get_credential(binding.credential_id)
  state.mutex.release()
  let credential = match credential_result {
    Ok(Some(value)) => value
    _ =>
      return Err(
        @credentials.credential_failure(
          @contracts.CREDENTIAL_REASON_MISSING,
          detail="credential metadata not found",
        ),
      )
  }
  if credential.owner != @contracts.CREDENTIAL_OWNER_HOST {
    return Err(
      @credentials.credential_failure(
        @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
        detail="a node-owned credential cannot be used on the primary",
      ),
    )
  }
  if credential.state != @contracts.CREDENTIAL_STATE_ACTIVE {
    return Err(
      @credentials.credential_failure(
        @contracts.CREDENTIAL_REASON_REVOKED,
        detail="credential state=" + credential.state,
      ),
    )
  }
  match state.credential_store.check() {
    Ok(_) => ()
    Err(failure) => return Err(failure)
  }
  let profile = match credential_profile_named(state, binding.profile) {
    Some(value) => value
    None =>
      return Err(
        @credentials.credential_failure(
          @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
          detail="unknown credential profile: " + binding.profile,
        ),
      )
  }
  let token = @contracts.CREDENTIAL_TOKEN_PREFIX + random_token()
  let now = @async.now()
  let session = @credentials.ProxySession::new(
    token~,
    binding_id=binding.id,
    credential_id=binding.credential_id,
    version=binding.version,
    machine_id=binding.machine_id,
    agent_id=binding.agent_id,
    profile=binding.profile,
    expires_at_ms=now + CREDENTIAL_PROXY_SESSION_TTL_MS,
  )
  let callbacks = @credentials.ProxyCallbacks::new(
    authorize=async fn(session) {
      state.mutex.acquire()
      let current_result = state.store.get_credential_binding(
        session.binding_id,
      )
      state.mutex.release()
      match current_result {
        Ok(Some(current)) =>
          if current.state != @contracts.CREDENTIAL_STATE_ACTIVE {
            Err(credential_binding_state_reason(current.state))
          } else if current.version != session.version {
            Err(@contracts.CREDENTIAL_REASON_BAD_STATE)
          } else {
            Ok(())
          }
        _ => Err(@contracts.CREDENTIAL_REASON_MISSING)
      }
    },
    secret=async fn(session) {
      match state.credential_store.get(session.credential_id) {
        Ok(value) => Ok(value)
        Err(failure) => Err(failure.reason)
      }
    },
    audit=fn(event_type, reason) {
      record_proxy_audit(state, binding.id, event_type, reason)
    },
  )
  let proxy = match
    @credentials.start_credential_proxy(group, profile, session, callbacks) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @credentials.credential_failure(
          @contracts.CREDENTIAL_REASON_PROXY_UNAVAILABLE,
          detail=message,
        ),
      )
  }
  ignore(
    state.append_event(
      @contracts.EVENT_CREDENTIAL_PROXY_OPENED,
      "credential_binding/" + binding.id,
      credential_event_payload(Some(credential), Some(binding), [
        ("proxy", @contracts.json_string("loopback")),
      ]),
    ),
  )
  Ok(
    Some({
      binding,
      proxy: Some(proxy),
      proxy_url: proxy.url(),
      proxy_token: token,
      remote: false,
    }),
  )
}

///|
/// Register the metadata-only lease/revoke channel for one paired runtime
/// machine. It carries binding metadata and fixed reasons, never a secret.
/// Registering again replaces the previous channel; a missing channel makes a
/// remote start fail closed (`credential_delivery_failed`).
pub async fn HostState::register_remote_credential_port(
  self : HostState,
  machine_id : String,
  port : @credentials.RemoteCredentialPort,
) -> Unit {
  self.mutex.acquire()
  self.credential_ports.set(machine_id, port)
  self.mutex.release()
}

///|
/// Drop the channel for a machine. A later remote start or revoke records
/// `credential_delivery_failed` instead of pretending delivery happened.
pub async fn HostState::clear_remote_credential_port(
  self : HostState,
  machine_id : String,
) -> Unit {
  self.mutex.acquire()
  self.credential_ports.remove(machine_id)
  self.mutex.release()
}

///|
/// Stop a session's local proxy, if one was started. Called on session
/// finalization, revoke and rotate; stopping is idempotent.
pub fn stop_session_credential_proxy(
  state : HostState,
  session_id : String,
) -> Unit {
  let proxy = state.credential_proxies.get(session_id)
  match proxy {
    Some(value) => {
      state.credential_proxies.remove(session_id)
      value.stop()
      ignore(
        state.append_event(
          @contracts.EVENT_CREDENTIAL_PROXY_CLOSED,
          "credential_binding/" + value.session.binding_id,
          @contracts.json_object([
            ("binding_id", @contracts.json_string(value.session.binding_id)),
            ("reason", @contracts.json_string("session_stopped")),
          ]),
        ),
      )
    }
    None => ()
  }
}

///|
/// Stop every live proxy for one binding or credential. Revoke/rotate must
/// take effect for an in-flight session, not just the next one.
fn stop_binding_proxies(
  state : HostState,
  binding_id : String,
  reason : String,
) -> Unit {
  let session_ids : Array[String] = []
  for session_id, proxy in state.credential_proxies {
    if proxy.session.binding_id == binding_id {
      session_ids.push(session_id)
    }
  }
  for session_id in session_ids {
    let proxy = state.credential_proxies.get(session_id)
    match proxy {
      Some(value) => {
        state.credential_proxies.remove(session_id)
        value.stop()
        ignore(
          state.append_event(
            @contracts.EVENT_CREDENTIAL_PROXY_CLOSED,
            "credential_binding/" + binding_id,
            @contracts.json_object([
              ("binding_id", @contracts.json_string(binding_id)),
              ("reason", @contracts.json_string(reason)),
            ]),
          ),
        )
      }
      None => ()
    }
  }
}

///|
fn stop_credential_proxies(
  state : HostState,
  credential_id : String,
  reason : String,
) -> Unit {
  let binding_ids : Array[String] = []
  for _session_id, proxy in state.credential_proxies {
    if proxy.session.credential_id == credential_id {
      binding_ids.push(proxy.session.binding_id)
    }
  }
  for binding_id in binding_ids {
    stop_binding_proxies(state, binding_id, reason)
  }
}

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

///|
async fn credential_status_document(state : HostState) -> @json.Json {
  let (store_ok, store_detail) = match state.credential_store.check() {
    Ok(_) => (true, state.credential_store.detail)
    Err(failure) => (false, failure.message())
  }
  state.mutex.acquire()
  let credentials_result = state.store.list_credentials()
  let bindings_result = state.store.list_credential_bindings()
  state.mutex.release()
  let credentials = match credentials_result {
    Ok(value) => value
    _ => []
  }
  let bindings = match bindings_result {
    Ok(value) => value
    _ => []
  }
  let reasons : Array[String] = []
  if !store_ok {
    reasons.push(@contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED)
  }
  let now = @async.now()
  for binding in bindings {
    if binding.state == @contracts.CREDENTIAL_STATE_ACTIVE &&
      credential_lease_expired(binding, now) {
      reasons.push(@contracts.CREDENTIAL_REASON_LEASE_EXPIRED)
    }
    if binding.state == @contracts.CREDENTIAL_STATE_REVOCATION_PENDING {
      reasons.push(@contracts.CREDENTIAL_REASON_REVOKED)
    }
  }
  for credential in credentials {
    if credential.state == @contracts.CREDENTIAL_STATE_REVOCATION_PENDING {
      reasons.push(@contracts.CREDENTIAL_REASON_DELIVERY_FAILED)
    }
  }
  let status : @contracts.CredentialStatus = {
    enabled: state.credential_enabled,
    storage: state.credential_store.backend,
    store_ok,
    store_detail,
    credentials,
    bindings,
    reasons,
    checked_at: @contracts.format_rfc3339(now),
  }
  status.to_json()
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

///|
async fn handle_credential_rpc(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.credential_enabled {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      credential_unsupported_error(),
    )
    return
  }
  // Durable idempotency: a retry after a host restart returns the exact prior
  // result, not a second enrollment or a duplicated binding.
  state.mutex.acquire()
  let cached = match state.store.get_credential_request(client_request_id) {
    Ok(Some(value)) => Some(value)
    _ => None
  }
  state.mutex.release()
  match cached {
    Some(text) => {
      let json = @json.parse(text) catch { _ => @contracts.json_null() }
      send_machine_result(state, sink, request, client_request_id, json)
      return
    }
    None => ()
  }
  let result = credential_dispatch(state, request.method, request.params)
  match result {
    Err(error) =>
      send_machine_error(state, sink, request, client_request_id, error)
    Ok(value) => {
      state.mutex.acquire()
      let recorded = state.store.record_credential_request(
        client_request_id,
        request.method,
        value.stringify(),
        @contracts.format_rfc3339(@async.now()),
      )
      state.mutex.release()
      match recorded {
        Ok(_) =>
          send_machine_result(state, sink, request, client_request_id, value)
        Err(message) =>
          send_machine_error(
            state,
            sink,
            request,
            client_request_id,
            credential_rpc_error(
              @contracts.CREDENTIAL_REASON_LOCKED,
              detail="cannot record idempotency result: " + message,
            ),
          )
      }
    }
  }
}

///|
async fn credential_dispatch(
  state : HostState,
  method : String,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  if method == @contracts.METHOD_CREDENTIAL_ENROLL {
    return credential_enroll(state, params)
  }
  if method == @contracts.METHOD_CREDENTIAL_BINDING_CREATE {
    return credential_binding_create(state, params)
  }
  if method == @contracts.METHOD_CREDENTIAL_BINDING_LIST {
    state.mutex.acquire()
    let result = state.store.list_credential_bindings()
    let credential_result = state.store.list_credentials()
    state.mutex.release()
    let bindings = match result {
      Ok(value) => value
      Err(message) =>
        return Err(
          credential_rpc_error(
            @contracts.CREDENTIAL_REASON_LOCKED,
            detail="cannot list bindings: " + message,
          ),
        )
    }
    let credentials = match credential_result {
      Ok(value) => value
      _ => []
    }
    return Ok(
      @contracts.json_object([
        (
          "bindings",
          @contracts.json_array(bindings.map(fn(item) { item.to_json() })),
        ),
        (
          "credentials",
          @contracts.json_array(credentials.map(fn(item) { item.to_json() })),
        ),
      ]),
    )
  }
  if method == @contracts.METHOD_CREDENTIAL_BINDING_UNBIND {
    return credential_binding_unbind(state, params)
  }
  if method == @contracts.METHOD_CREDENTIAL_ROTATE {
    return credential_rotate(state, params)
  }
  if method == @contracts.METHOD_CREDENTIAL_REVOKE {
    return credential_revoke(state, params)
  }
  if method == @contracts.METHOD_CREDENTIAL_DELETE {
    return credential_delete(state, params)
  }
  if method == @contracts.METHOD_CREDENTIAL_STATUS {
    let document = credential_status_document(state)
    return Ok(@contracts.json_object([("status", document)]))
  }
  if method == @contracts.METHOD_CREDENTIAL_DOCTOR {
    return credential_doctor(state)
  }
  Err(@contracts.method_not_found_error(method))
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

///|
async fn credential_enroll(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let kind = @contracts.string_field_or(
    params,
    "kind",
    @contracts.CREDENTIAL_KIND_API_KEY,
  )
  if !credential_valid_kind(kind) {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_SECRET_INVALID,
        detail="unsupported credential kind",
      ),
    )
  }
  let secret = match @contracts.string_field(params, "secret") {
    Some(value) => value
    None =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_SECRET_REQUIRED,
          detail="secret is required",
        ),
      )
  }
  match @credentials.validate_credential_secret(secret) {
    Ok(_) => ()
    Err(failure) => return Err(credential_failure_error(failure))
  }
  let machine_id = @contracts.string_field_or(params, "machine_id", "")
  if !credential_machine_accepts_host_secret(state, machine_id) {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
        detail="the primary never accepts a secret for a remote machine; enroll on the node",
      ),
    )
  }
  let now = @async.now()
  let credential_id = @contracts.new_id("crd", now)
  let fingerprint = @credentials.credential_fingerprint(secret)
  let record = @contracts.CredentialRecord::new(
    id=credential_id,
    kind~,
    storage=state.credential_store.backend,
    owner=@contracts.CREDENTIAL_OWNER_HOST,
    version=1,
    fingerprint~,
    created_at=@contracts.format_rfc3339(now),
  )
  match
    state.credential_store.put(
      credential_id,
      kind,
      secret,
      1,
      record.created_at,
    ) {
    Ok(_) => ()
    Err(failure) => return Err(credential_failure_error(failure))
  }
  state.mutex.acquire()
  let recorded = state.record_credential_event(
    @contracts.EVENT_CREDENTIAL_ENROLLED,
    "credential/" + credential_id,
    credential_event_payload(Some(record), None, []),
    Some(record),
    None,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) => {
      // The secret is destroyed rather than leaving an unreferenced copy.
      ignore(state.credential_store.delete(credential_id))
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot persist credential metadata: " + message,
        ),
      )
    }
  }
  Ok(@contracts.json_object([("credential", record.to_json())]))
}

///|
async fn credential_binding_create(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  // A binding request may never carry secret material. The secret is enrolled
  // separately (host) or registered on the node (remote).
  match @contracts.string_field(params, "secret") {
    Some(_) =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_SECRET_INVALID,
          detail="binding.create never accepts a secret",
        ),
      )
    None => ()
  }
  let machine_id = @contracts.string_field_or(params, "machine_id", "")
  let agent_id = @contracts.string_field_or(params, "agent_id", "")
  let profile_name = @contracts.string_field_or(params, "profile", "")
  let credential_id = @contracts.string_field_or(params, "credential_id", "")
  if agent_id == "" {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_BAD_STATE,
        detail="agent_id is required",
      ),
    )
  }
  if profile_name == "" {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_BAD_STATE,
        detail="profile is required",
      ),
    )
  }
  if credential_id == "" {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_MISSING,
        detail="credential_id is required",
      ),
    )
  }
  let kind = match credential_machine_exists(state, machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let profile = match credential_profile_named(state, profile_name) {
    Some(value) => value
    None =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
          detail="unknown profile: " + profile_name,
        ),
      )
  }
  ignore(profile)
  let now = @async.now()
  state.mutex.acquire()
  let credential_result = state.store.get_credential(credential_id)
  let existing_tuple = state.store.find_credential_binding(
    machine_id, agent_id, profile_name,
  )
  let all_bindings = state.store.list_credential_bindings()
  state.mutex.release()
  let existing = match existing_tuple {
    Ok(Some(value)) =>
      if value.state == @contracts.CREDENTIAL_STATE_ACTIVE {
        true
      } else {
        false
      }
    _ => false
  }
  if existing {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_BINDING_CONFLICT,
        detail="an active binding already exists for this machine, agent and profile",
      ),
    )
  }
  let bindings = match all_bindings {
    Ok(value) => value
    _ => []
  }
  for binding in bindings {
    if binding.state == @contracts.CREDENTIAL_STATE_ACTIVE &&
      binding.credential_id == credential_id {
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_REUSED,
          detail="a credential has exactly one live binding",
        ),
      )
    }
  }
  let remote = machine_id != "" && kind != @contracts.MACHINE_KIND_LOCAL
  if remote && kind != @contracts.MACHINE_KIND_RUNTIME {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
        detail="SSH machines have no node-local credential channel",
      ),
    )
  }
  let node_enrolled = @contracts.bool_field_or(params, "node_enrolled", false)
  let fingerprint = @contracts.string_field_or(params, "fingerprint", "")
  let version = @contracts.int_field_or(params, "version", 0)
  let credential = match credential_result {
    Ok(Some(value)) => Some(value)
    _ => None
  }
  // A remote binding mirrors node-owned metadata. The primary may not invent
  // a secret-bearing host credential for a remote machine.
  let mirror = match credential {
    Some(value) =>
      if remote {
        if value.owner != @contracts.CREDENTIAL_OWNER_NODE {
          return Err(
            credential_rpc_error(
              @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
              detail="host-owned credentials cannot be bound to a remote machine",
            ),
          )
        }
        value
      } else {
        if value.owner != @contracts.CREDENTIAL_OWNER_HOST {
          return Err(
            credential_rpc_error(
              @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
              detail="node-owned credentials cannot be bound to the primary",
            ),
          )
        }
        value
      }
    None =>
      if remote {
        let mirror_state = if node_enrolled && fingerprint != "" && version > 0 {
          @contracts.CREDENTIAL_STATE_ACTIVE
        } else {
          @contracts.CREDENTIAL_STATE_PENDING_ENROLLMENT
        }
        let base = @contracts.CredentialRecord::new(
          id=credential_id,
          kind=@contracts.string_field_or(
            params,
            "kind",
            @contracts.CREDENTIAL_KIND_API_KEY,
          ),
          storage=@contracts.string_field_or(
            params,
            "storage",
            @contracts.CREDENTIAL_STORAGE_FILE,
          ),
          owner=@contracts.CREDENTIAL_OWNER_NODE,
          version=if version > 0 { version } else { 0 },
          fingerprint~,
          created_at=@contracts.format_rfc3339(now),
        )
        { ..base, state: mirror_state, }
      } else {
        return Err(
          credential_rpc_error(
            @contracts.CREDENTIAL_REASON_MISSING,
            detail="credential not found: " + credential_id,
          ),
        )
      }
  }
  let binding_state = if remote && !node_enrolled {
    @contracts.CREDENTIAL_STATE_PENDING_ENROLLMENT
  } else {
    @contracts.CREDENTIAL_STATE_ACTIVE
  }
  let binding_base = @contracts.CredentialBinding::new(
    id=@contracts.new_id("bind", now),
    credential_id~,
    machine_id~,
    agent_id~,
    profile=profile_name,
    version=mirror.version,
    fingerprint=mirror.fingerprint,
    created_at=@contracts.format_rfc3339(now),
  )
  let binding = {
    ..binding_base,
    state: binding_state,
    lease_expires_at: if remote {
      credential_lease_deadline(now, state.credential_lease_ttl_ms)
    } else {
      ""
    },
  }
  state.mutex.acquire()
  let recorded = state.record_credential_event(
    @contracts.EVENT_CREDENTIAL_BOUND,
    "credential_binding/" + binding.id,
    credential_event_payload(Some(mirror), Some(binding), []),
    Some(mirror),
    Some(binding),
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot persist binding: " + message,
        ),
      )
  }
  Ok(@contracts.json_object([("binding", binding.to_json())]))
}

///|
async fn credential_binding_unbind(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let binding_id = @contracts.string_field_or(params, "binding_id", "")
  let machine_id = @contracts.string_field_or(params, "machine_id", "")
  let agent_id = @contracts.string_field_or(params, "agent_id", "")
  let profile_name = @contracts.string_field_or(params, "profile", "")
  state.mutex.acquire()
  let found = if binding_id != "" {
    state.store.get_credential_binding(binding_id)
  } else {
    state.store.find_credential_binding(machine_id, agent_id, profile_name)
  }
  state.mutex.release()
  let binding = match found {
    Ok(Some(value)) => value
    _ =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_NOT_FOUND,
          detail="binding not found",
        ),
      )
  }
  if binding.state == @contracts.CREDENTIAL_STATE_UNBOUND ||
    binding.state == @contracts.CREDENTIAL_STATE_DELETED {
    return Ok(@contracts.json_object([("binding", binding.to_json())]))
  }
  let updated = {
    ..binding,
    state: @contracts.CREDENTIAL_STATE_UNBOUND,
    updated_at: @contracts.format_rfc3339(@async.now()),
  }
  state.mutex.acquire()
  let recorded = state.record_credential_event(
    @contracts.EVENT_CREDENTIAL_UNBOUND,
    "credential_binding/" + updated.id,
    credential_event_payload(None, Some(updated), []),
    None,
    Some(updated),
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot persist unbind: " + message,
        ),
      )
  }
  stop_binding_proxies(state, updated.id, "unbound")
  Ok(@contracts.json_object([("binding", updated.to_json())]))
}

///|
async fn credential_rotate(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let credential_id = @contracts.string_field_or(params, "credential_id", "")
  if credential_id == "" {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_MISSING,
        detail="credential_id is required",
      ),
    )
  }
  state.mutex.acquire()
  let credential_result = state.store.get_credential(credential_id)
  let bindings_result = state.store.list_credential_bindings()
  state.mutex.release()
  let credential = match credential_result {
    Ok(Some(value)) => value
    _ =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_NOT_FOUND,
          detail="credential not found",
        ),
      )
  }
  let bindings = match bindings_result {
    Ok(value) => value
    _ => []
  }
  let now = @async.now()
  if credential.owner == @contracts.CREDENTIAL_OWNER_NODE {
    // Remote rotation is node-local and reported as metadata. Accepting a
    // secret here would make the primary a key courier, so it is refused.
    match @contracts.string_field(params, "secret") {
      Some(_) =>
        return Err(
          credential_rpc_error(
            @contracts.CREDENTIAL_REASON_MACHINE_MISMATCH,
            detail="remote rotation happens on the node; the primary never accepts the secret",
          ),
        )
      None => ()
    }
    let version = @contracts.int_field_or(params, "version", 0)
    let fingerprint = @contracts.string_field_or(params, "fingerprint", "")
    if version <= credential.version || fingerprint == "" {
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_BAD_STATE,
          detail="remote rotation needs a newer version and its fingerprint",
        ),
      )
    }
    let updated = {
      ..credential,
      version,
      fingerprint,
      rotated_at: @contracts.format_rfc3339(now),
      state: @contracts.CREDENTIAL_STATE_ACTIVE,
    }
    state.mutex.acquire()
    let recorded = state.record_credential_event(
      @contracts.EVENT_CREDENTIAL_ROTATED,
      "credential/" + credential_id,
      credential_event_payload(Some(updated), None, []),
      Some(updated),
      None,
    )
    let updated_bindings : Array[@contracts.CredentialBinding] = []
    let recorded_ok = match recorded {
      Ok(_) => true
      Err(_) => false
    }
    if recorded_ok {
      for binding in bindings {
        if binding.credential_id == credential_id {
          let next = {
            ..binding,
            version,
            fingerprint: updated.fingerprint,
            state: @contracts.CREDENTIAL_STATE_ACTIVE,
            updated_at: @contracts.format_rfc3339(now),
          }
          match
            state.record_credential_event(
              @contracts.EVENT_CREDENTIAL_BOUND,
              "credential_binding/" + binding.id,
              credential_event_payload(None, Some(next), [
                ("reason", @contracts.json_string("rotation_synced")),
              ]),
              None,
              Some(next),
            ) {
            Ok(_) => updated_bindings.push(next)
            Err(_) => ()
          }
        }
      }
    }
    state.mutex.release()
    let result = match recorded {
      Ok(_) => {
        let document = @contracts.json_object([
          ("credential", updated.to_json()),
          (
            "bindings",
            @contracts.json_array(
              updated_bindings.map(fn(item) { item.to_json() }),
            ),
          ),
        ])
        Ok(document)
      }
      Err(message) =>
        Err(
          credential_rpc_error(
            @contracts.CREDENTIAL_REASON_LOCKED,
            detail="cannot persist rotation: " + message,
          ),
        )
    }
    return result
  }
  // Host-owned rotation: replace the stored secret and bump the version. Live
  // proxies are stopped so no session keeps using the old key.
  let secret = match @contracts.string_field(params, "secret") {
    Some(value) => value
    None =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_SECRET_REQUIRED,
          detail="secret is required",
        ),
      )
  }
  match @credentials.validate_credential_secret(secret) {
    Ok(_) => ()
    Err(failure) => return Err(credential_failure_error(failure))
  }
  let version = credential.version + 1
  let fingerprint = @credentials.credential_fingerprint(secret)
  match
    state.credential_store.put(
      credential_id,
      credential.kind,
      secret,
      version,
      credential.created_at,
    ) {
    Ok(_) => ()
    Err(failure) => return Err(credential_failure_error(failure))
  }
  let updated = {
    ..credential,
    version,
    fingerprint,
    rotated_at: @contracts.format_rfc3339(now),
  }
  state.mutex.acquire()
  let recorded = state.record_credential_event(
    @contracts.EVENT_CREDENTIAL_ROTATED,
    "credential/" + credential_id,
    credential_event_payload(Some(updated), None, []),
    Some(updated),
    None,
  )
  let updated_bindings : Array[@contracts.CredentialBinding] = []
  let recorded_ok = match recorded {
    Ok(_) => true
    Err(_) => false
  }
  if recorded_ok {
    for binding in bindings {
      if binding.credential_id == credential_id &&
        binding.state == @contracts.CREDENTIAL_STATE_ACTIVE {
        let next = {
          ..binding,
          version,
          fingerprint: updated.fingerprint,
          updated_at: @contracts.format_rfc3339(now),
        }
        match
          state.record_credential_event(
            @contracts.EVENT_CREDENTIAL_BOUND,
            "credential_binding/" + binding.id,
            credential_event_payload(None, Some(next), [
              ("reason", @contracts.json_string("rotated")),
            ]),
            None,
            Some(next),
          ) {
          Ok(_) => updated_bindings.push(next)
          Err(_) => ()
        }
      }
    }
  }
  state.mutex.release()
  stop_credential_proxies(state, credential_id, "rotated")
  match recorded {
    Ok(_) =>
      Ok(
        @contracts.json_object([
          ("credential", updated.to_json()),
          (
            "bindings",
            @contracts.json_array(
              updated_bindings.map(fn(item) { item.to_json() }),
            ),
          ),
        ]),
      )
    Err(message) =>
      Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot persist rotation: " + message,
        ),
      )
  }
}

///|
async fn credential_revoke(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let credential_id = @contracts.string_field_or(params, "credential_id", "")
  let binding_id = @contracts.string_field_or(params, "binding_id", "")
  state.mutex.acquire()
  let credential_result = if credential_id != "" {
    state.store.get_credential(credential_id)
  } else if binding_id != "" {
    match state.store.get_credential_binding(binding_id) {
      Ok(Some(binding)) => state.store.get_credential(binding.credential_id)
      _ => Ok(None)
    }
  } else {
    Ok(None)
  }
  state.mutex.release()
  let credential = match credential_result {
    Ok(Some(value)) => value
    _ =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_NOT_FOUND,
          detail="credential not found",
        ),
      )
  }
  let now = @async.now()
  if credential.owner == @contracts.CREDENTIAL_OWNER_NODE {
    let updated = {
      ..credential,
      state: @contracts.CREDENTIAL_STATE_REVOCATION_PENDING,
    }
    state.mutex.acquire()
    let recorded = state.record_credential_event(
      @contracts.EVENT_CREDENTIAL_REVOKED,
      "credential/" + credential.id,
      credential_event_payload(Some(updated), None, [
        ("reason", @contracts.json_string("revocation_requested")),
      ]),
      Some(updated),
      None,
    )
    let pending_bindings : Array[@contracts.CredentialBinding] = []
    let recorded_ok = match recorded {
      Ok(_) => true
      Err(_) => false
    }
    if recorded_ok {
      let bindings_result = state.store.list_credential_bindings()
      match bindings_result {
        Ok(bindings) =>
          for binding in bindings {
            if binding.credential_id == credential.id &&
              binding.state == @contracts.CREDENTIAL_STATE_ACTIVE {
              let next = {
                ..binding,
                state: @contracts.CREDENTIAL_STATE_REVOCATION_PENDING,
                updated_at: @contracts.format_rfc3339(now),
              }
              match
                state.record_credential_event(
                  @contracts.EVENT_CREDENTIAL_REVOKED,
                  "credential_binding/" + binding.id,
                  credential_event_payload(None, Some(next), [
                    ("reason", @contracts.json_string("revocation_requested")),
                  ]),
                  None,
                  Some(next),
                ) {
                Ok(_) => pending_bindings.push(next)
                Err(_) => ()
              }
            }
          }
        _ => ()
      }
    }
    state.mutex.release()
    match recorded {
      Err(message) =>
        return Err(
          credential_rpc_error(
            @contracts.CREDENTIAL_REASON_LOCKED,
            detail="cannot persist revocation: " + message,
          ),
        )
      Ok(_) => ()
    }
    // Deliver one metadata-only revoke signal per pending binding. The signal
    // never carries secret material; it only asks the node to destroy the copy
    // it registered locally. Without an attached port the binding stays
    // `revocation_pending`, and the node's lease window bounds how long it can
    // still use its local copy while offline.
    let mut delivered_all = true
    for binding in pending_bindings {
      let port = state.credential_ports.get(binding.machine_id)
      let signal = @credentials.RemoteCredentialSignal::new(
        binding_id=binding.id,
        credential_id=credential.id,
        machine_id=binding.machine_id,
        agent_id=binding.agent_id,
        profile=binding.profile,
        version=binding.version,
        fingerprint=binding.fingerprint,
        lease_ttl_ms=0L,
      )
      let delivered = match port {
        Some(value) => (value.revoke)(signal)
        None => Err("no runtime credential port attached")
      }
      match delivered {
        Ok(_) => {
          let next = {
            ..binding,
            state: @contracts.CREDENTIAL_STATE_REVOKED,
            updated_at: @contracts.format_rfc3339(now),
          }
          state.mutex.acquire()
          ignore(
            state.record_credential_event(
              @contracts.EVENT_CREDENTIAL_DELIVERED,
              "credential_binding/" + binding.id,
              credential_event_payload(None, Some(next), [
                ("signal", @contracts.json_string("revoke")),
              ]),
              None,
              Some(next),
            ),
          )
          state.mutex.release()
        }
        Err(reason) => {
          delivered_all = false
          state.mutex.acquire()
          ignore(
            state.record_credential_event(
              @contracts.EVENT_CREDENTIAL_DELIVERY_FAILED,
              "credential_binding/" + binding.id,
              credential_event_payload(None, Some(binding), [
                ("reason", @contracts.json_string(reason)),
              ]),
              None,
              Some(binding),
            ),
          )
          state.mutex.release()
        }
      }
    }
    let final = if delivered_all {
      { ..updated, state: @contracts.CREDENTIAL_STATE_REVOKED, }
    } else {
      updated
    }
    if delivered_all {
      state.mutex.acquire()
      ignore(
        state.record_credential_event(
          @contracts.EVENT_CREDENTIAL_DELIVERED,
          "credential/" + final.id,
          credential_event_payload(Some(final), None, [
            ("signal", @contracts.json_string("revoke")),
          ]),
          Some(final),
          None,
        ),
      )
      state.mutex.release()
    }
    return Ok(@contracts.json_object([("credential", final.to_json())]))
  }
  // Host-owned: destroy the secret first, then record the metadata. A crash
  // between the two leaves the binding unusable (fail closed).
  match state.credential_store.delete(credential.id) {
    Ok(_) => ()
    Err(failure) => return Err(credential_failure_error(failure))
  }
  let updated = { ..credential, state: @contracts.CREDENTIAL_STATE_REVOKED, }
  state.mutex.acquire()
  let recorded = state.record_credential_event(
    @contracts.EVENT_CREDENTIAL_REVOKED,
    "credential/" + credential.id,
    credential_event_payload(Some(updated), None, []),
    Some(updated),
    None,
  )
  let updated_bindings : Array[@contracts.CredentialBinding] = []
  let recorded_ok = match recorded {
    Ok(_) => true
    Err(_) => false
  }
  if recorded_ok {
    match state.store.list_credential_bindings() {
      Ok(bindings) =>
        for binding in bindings {
          if binding.credential_id == credential.id &&
            binding.state == @contracts.CREDENTIAL_STATE_ACTIVE {
            let next = {
              ..binding,
              state: @contracts.CREDENTIAL_STATE_REVOKED,
              updated_at: @contracts.format_rfc3339(now),
            }
            match
              state.record_credential_event(
                @contracts.EVENT_CREDENTIAL_REVOKED,
                "credential_binding/" + binding.id,
                credential_event_payload(None, Some(next), []),
                None,
                Some(next),
              ) {
              Ok(_) => updated_bindings.push(next)
              Err(_) => ()
            }
          }
        }
      _ => ()
    }
  }
  state.mutex.release()
  stop_credential_proxies(state, credential.id, "revoked")
  match recorded {
    Ok(_) =>
      Ok(
        @contracts.json_object([
          ("credential", updated.to_json()),
          (
            "bindings",
            @contracts.json_array(
              updated_bindings.map(fn(item) { item.to_json() }),
            ),
          ),
        ]),
      )
    Err(message) =>
      Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot persist revocation: " + message,
        ),
      )
  }
}

///|
async fn credential_delete(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let credential_id = @contracts.string_field_or(params, "credential_id", "")
  if credential_id == "" {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_MISSING,
        detail="credential_id is required",
      ),
    )
  }
  state.mutex.acquire()
  let credential_result = state.store.get_credential(credential_id)
  let bindings_result = state.store.list_credential_bindings()
  state.mutex.release()
  let credential = match credential_result {
    Ok(Some(value)) => value
    _ =>
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_NOT_FOUND,
          detail="credential not found",
        ),
      )
  }
  let bindings = match bindings_result {
    Ok(value) => value
    _ => []
  }
  for binding in bindings {
    if binding.credential_id == credential_id &&
      (
        binding.state == @contracts.CREDENTIAL_STATE_ACTIVE ||
        binding.state == @contracts.CREDENTIAL_STATE_PENDING_ENROLLMENT
      ) {
      return Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_BAD_STATE,
          detail="unbind or revoke the credential before deleting it",
        ),
      )
    }
  }
  if credential.state != @contracts.CREDENTIAL_STATE_REVOKED &&
    credential.state != @contracts.CREDENTIAL_STATE_DELETED {
    return Err(
      credential_rpc_error(
        @contracts.CREDENTIAL_REASON_BAD_STATE,
        detail="revoke the credential before deleting it",
      ),
    )
  }
  if credential.owner == @contracts.CREDENTIAL_OWNER_HOST {
    match state.credential_store.delete(credential.id) {
      Ok(_) => ()
      Err(failure) => return Err(credential_failure_error(failure))
    }
  }
  let updated = { ..credential, state: @contracts.CREDENTIAL_STATE_DELETED, }
  state.mutex.acquire()
  let recorded = state.record_credential_event(
    @contracts.EVENT_CREDENTIAL_DELETED,
    "credential/" + credential_id,
    credential_event_payload(Some(updated), None, []),
    Some(updated),
    None,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => Ok(@contracts.json_object([("credential", updated.to_json())]))
    Err(message) =>
      Err(
        credential_rpc_error(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot persist deletion: " + message,
        ),
      )
  }
}

///|
async fn credential_doctor(
  state : HostState,
) -> Result[@json.Json, @contracts.RpcError] {
  let checks : Array[@contracts.CredentialCheck] = []
  checks.push(@contracts.CredentialCheck::{
    name: "enabled",
    ok: true,
    detail: "credential.enabled=true",
  })
  match state.credential_store.check() {
    Ok(_) =>
      checks.push(@contracts.CredentialCheck::{
        name: "storage",
        ok: true,
        detail: state.credential_store.backend +
        " (" +
        state.credential_store.detail +
        ")",
      })
    Err(failure) =>
      checks.push(@contracts.CredentialCheck::{
        name: "storage",
        ok: false,
        detail: failure.message(),
      })
  }
  state.mutex.acquire()
  let credentials_result = state.store.list_credentials()
  let bindings_result = state.store.list_credential_bindings()
  state.mutex.release()
  let credentials = match credentials_result {
    Ok(value) => value
    _ => []
  }
  let bindings = match bindings_result {
    Ok(value) => value
    _ => []
  }
  let reasons : Array[String] = []
  for binding in bindings {
    if binding.state == @contracts.CREDENTIAL_STATE_ACTIVE {
      match credential_profile_named(state, binding.profile) {
        Some(_) =>
          checks.push(@contracts.CredentialCheck::{
            name: "binding/" + binding.id,
            ok: true,
            detail: "profile=" +
            binding.profile +
            "; machine=" +
            binding.machine_id +
            "; agent=" +
            binding.agent_id,
          })
        None => {
          reasons.push(@contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED)
          checks.push(@contracts.CredentialCheck::{
            name: "binding/" + binding.id,
            ok: false,
            detail: "unknown profile: " + binding.profile,
          })
        }
      }
      if credential_lease_expired(binding, @async.now()) {
        reasons.push(@contracts.CREDENTIAL_REASON_LEASE_EXPIRED)
      }
    }
  }
  for credential in credentials {
    if credential.state == @contracts.CREDENTIAL_STATE_REVOCATION_PENDING {
      reasons.push(@contracts.CREDENTIAL_REASON_DELIVERY_FAILED)
    }
  }
  let mut checks_ok = true
  for check in checks {
    if !check.ok {
      checks_ok = false
    }
  }
  let ok = reasons.is_empty() && checks_ok
  let report : @contracts.CredentialDoctorReport = {
    ok,
    storage: state.credential_store.backend,
    checks,
    reasons,
    checked_at: @contracts.format_rfc3339(@async.now()),
  }
  Ok(@contracts.json_object([("doctor", report.to_json())]))
}
