///|
/// Skill pack owner RPCs (ADR-0015 §2.3, §7, §11). Every handler is an owner
/// action: import verifies a signed local bundle, allow records the exact
/// quadruple, enable records an exact binding. No method here trusts a name
/// alone and there is no TOFU path.
///
/// Persisted records carry name/version/hash/key ids only; a skill body never
/// enters an event, audit record or the database.

///|
const SKILL_DECISION_WAIT_MS : Int = 300_000

///|
const SKILL_GATEWAY_RATE_WINDOW_MS : Int64 = 60_000L

///|
const SKILL_GATEWAY_RATE_MAX : Int = 120

///|
fn skill_rpc_error(reason : String, message : String) -> @contracts.RpcError {
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
fn skill_fault_error(fault : @skills.SkillFault) -> @contracts.RpcError {
  skill_rpc_error(fault.code, fault.code + ": " + fault.detail)
}

///|
fn skill_disabled_error() -> @contracts.RpcError {
  @contracts.agent_error(
    @contracts.AGENT_ERR_UNSUPPORTED,
    "skill packs are disabled (skill.enabled=false)",
  )
}

///|
async fn skill_send(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  value : @json.Json,
) -> Unit {
  send_machine_result(state, sink, request, client_request_id, value)
}

///|
async fn skill_send_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  error : @contracts.RpcError,
) -> Unit {
  send_machine_error(state, sink, request, client_request_id, error)
}

///|
async fn reload_skill_keys(state : HostState) -> Unit {
  let keys = @skills.SkillKeyStore::empty()
  state.mutex.acquire()
  let rows = match state.store.list_skill_keys() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      println("monexus-host: cannot load skill keys: " + message)
      return
    }
  }
  let mut store = keys
  for row in rows {
    store = store.with_key(row.key_id, row.public_key)
    if row.revoked {
      store = store.revoke(row.key_id)
    }
  }
  state.skill_keys = store
  state.mutex.release()
}

///|
async fn skill_key_snapshot(state : HostState) -> @skills.SkillKeyStore {
  state.mutex.acquire()
  let keys = state.skill_keys
  state.mutex.release()
  keys
}

///|
fn skill_binding_payload(
  scope : String,
  scope_ref : String,
  binding : @contracts.SkillBinding,
) -> @json.Json {
  @contracts.json_object([
    ("scope", @contracts.json_string(scope)),
    ("scope_ref", @contracts.json_string(scope_ref)),
    ("name", @contracts.json_string(binding.name)),
    ("version", @contracts.json_string(binding.version)),
    ("content_hash", @contracts.json_string(binding.content_hash)),
    ("mode", @contracts.json_string(binding.mode)),
  ])
}

///|
fn skill_binding_from_params(
  params : Map[String, @json.Json],
) -> @contracts.SkillBinding? {
  let name = @contracts.string_field_or(params, "name", "")
  let version = @contracts.string_field_or(params, "version", "")
  let content_hash = @contracts.string_field_or(params, "content_hash", "")
  let mode = @contracts.string_field_or(
    params,
    "mode",
    @contracts.SKILL_MODE_LOADED,
  )
  if !@skills.is_valid_skill_name(name) ||
    !@skills.is_valid_skill_version(version) ||
    !@skills.is_valid_skill_content_hash(content_hash) ||
    !@contracts.skill_mode_valid(mode) {
    return None
  }
  Some(@contracts.SkillBinding::new(name~, version~, content_hash~, mode~))
}

///|
fn skill_tuple_payload(
  name : String,
  version : String,
  content_hash : String,
) -> @json.Json {
  @contracts.json_object([
    ("name", @contracts.json_string(name)),
    ("version", @contracts.json_string(version)),
    ("content_hash", @contracts.json_string(content_hash)),
  ])
}

///|
/// Load one stored manifest row. The row must exist and its manifest must be
/// parseable; nothing else is trusted from the row.
fn skill_row_manifest(
  state : HostState,
  row : @machines.SkillRow,
) -> Result[@contracts.SkillManifest, @contracts.RpcError] {
  match @skills.parse_skill_manifest(row.manifest_json) {
    Ok(value) =>
      if value.name == row.name &&
        value.version == row.version &&
        value.content_hash == row.content_hash {
        Ok(value)
      } else {
        Err(skill_rpc_error(
          @contracts.SKILL_ERR_HASH_MISMATCH,
          "stored manifest does not match its index row",
        ))
      }
    Err(fault) => Err(skill_fault_error(fault))
  }
}

///|
fn skill_agent_permissions(
  state : HostState,
  agent_id : String,
) -> Array[String] {
  match state.store.get_agent_skill_permissions(agent_id) {
    Ok(Some(value)) => value
    Ok(None) => @contracts.default_skill_permissions()
    Err(_) => @contracts.default_skill_permissions()
  }
}

///|
/// Binary dependency readiness. Only existence is checked; no version probe
/// and no download (ADR-0015 §9).
async fn skill_binary_present(name : String) -> Bool {
  if name == "" || name.length() > 128 {
    return false
  }
  let result = @process.collect_output(
    "which",
    [name],
    inherit_env=true,
  ) catch {
    _ => return false
  }
  let (code, _stdout, _stderr) = result
  code == 0
}

///|
/// A missing binary dependency is a readiness failure that always leaves a
/// readable Decision (ADR-0015 §13 item 7). No session is started and nothing
/// is downloaded or auto-enabled.
async fn skill_dependency_readiness_decision(
  state : HostState,
  agent_id : String,
  session_id : String,
  name : String,
  version : String,
  content_hash : String,
  binary : String,
) -> Unit {
  let now = @async.now()
  let record = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", now),
    kind=@contracts.DECISION_KIND_READINESS,
    title="Skill dependency is missing",
    detail="Skill " +
    name +
    "@" +
    version +
    " requires an executable on the machine's PATH but it was not found.\n" +
    "Dependency: " +
    binary +
    "\nSkill hash: " +
    content_hash,
    session_id~,
    agent_id~,
    options=[
      @contracts.DecisionOption::new(
        option_id="acknowledge",
        name="Acknowledge",
        kind="allow_once",
      ),
    ],
    created_at=@contracts.format_rfc3339(now),
  )
  state.mutex.acquire()
  let persisted = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    record.id,
    @contracts.decision_payload(record),
    record,
  )
  state.mutex.release()
  match persisted {
    Ok(_) =>
      audit(
        state,
        "skill.dependency",
        "host",
        "skill/" + name + "@" + version,
        "readiness_failed",
        detail="dependency=" + binary,
        policy=@contracts.DECISION_KIND_READINESS,
        decision_id=record.id,
      )
    Err(_) => ()
  }
}

// ---------------------------------------------------------------------------
// Owner handlers
// ---------------------------------------------------------------------------

///|
async fn handle_skill_import(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_disabled_error(),
    )
    return
  }
  if @contracts.string_field_or(request.params, "source", "local_directory") !=
    @contracts.SKILL_SOURCE_LOCAL_DIRECTORY {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(
        @contracts.SKILL_ERR_INVALID_MANIFEST,
        "only local_directory sources are supported",
      ),
    )
    return
  }
  let path = @contracts.string_field_or(request.params, "path", "")
  if path.trim() == "" {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(
        @contracts.SKILL_ERR_INVALID_PATH,
        "path is required",
      ),
    )
    return
  }
  let keys = skill_key_snapshot(state)
  let bundle = match
    @skills.import_skill_bundle(path, keys, state.verifier) {
    Ok(value) => value
    Err(fault) => {
      let payload = @contracts.json_object([
        ("stage", @contracts.json_string("import")),
        ("reason", @contracts.json_string(fault.code)),
        ("source", @contracts.json_string(@contracts.redact_secrets(path))),
      ])
      state.mutex.acquire()
      let _ = state.append_event(
        @contracts.EVENT_SKILL_REFUSED,
        "skill/import",
        payload,
      )
      state.mutex.release()
      audit(
        state,
        "skill.import",
        "owner",
        "skill/import",
        "refused",
        detail="reason=" + fault.code,
        policy="skill",
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
  let stored = match @skills.store_skill_bundle(state.state_dir, bundle) {
    Ok(value) => value
    Err(fault) => {
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
  let manifest = bundle.manifest
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  let existing_state = match
    state.store.get_skill_row(
      manifest.name,
      manifest.version,
      manifest.content_hash,
    ) {
    Ok(Some(row)) => row.state
    _ => @contracts.SKILL_STATUS_PENDING
  }
  let target_state = if existing_state == @contracts.SKILL_STATUS_ALLOWED {
    @contracts.SKILL_STATUS_ALLOWED
  } else {
    @contracts.SKILL_STATUS_PENDING
  }
  let mut total_bytes = 0
  for file in bundle.files {
    total_bytes = total_bytes + file.content.length()
  }
  let row : @machines.SkillRow = {
    id: @contracts.new_id("skl", now),
    name: manifest.name,
    version: manifest.version,
    content_hash: manifest.content_hash,
    key_id: manifest.signature.key_id,
    state: target_state,
    manifest_json: bundle.manifest_text,
    signature: manifest.signature.sig,
    source: path,
    created_at: timestamp,
    updated_at: timestamp,
  }
  let put = state.store.put_skill_row(row)
  match put {
    Ok(_) => ()
    Err(message) => {
      state.mutex.release()
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  let file_count = bundle.files.length()
  let _ = state.append_event(
    @contracts.EVENT_SKILL_IMPORTED,
    "skill/" + manifest.name + "@" + manifest.version,
    @contracts.json_object([
      ("name", @contracts.json_string(manifest.name)),
      ("version", @contracts.json_string(manifest.version)),
      ("content_hash", @contracts.json_string(manifest.content_hash)),
      ("key_id", @contracts.json_string(manifest.signature.key_id)),
      ("source_kind", @contracts.json_string(@contracts.SKILL_SOURCE_LOCAL_DIRECTORY)),
      ("file_count", @contracts.json_int(file_count)),
      ("total_bytes", @contracts.json_int(total_bytes)),
    ]),
  )
  state.mutex.release()
  audit(
    state,
    "skill.import",
    "owner",
    "skill/" + manifest.name + "@" + manifest.version,
    "imported",
    detail="content_hash=" +
    manifest.content_hash +
    " key_id=" +
    manifest.signature.key_id +
    " files=" +
    file_count.to_string(),
    policy="skill",
  )
  let result = @contracts.SkillImportResult::new(
    name=manifest.name,
    version=manifest.version,
    content_hash=manifest.content_hash,
    key_id=manifest.signature.key_id,
    file_count=file_count,
    total_bytes=total_bytes,
    status=target_state,
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("skill", result.to_json())]),
  )
}

///|
async fn handle_skill_key_register(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let key_id = @contracts.string_field_or(request.params, "key_id", "")
  let public_key = @contracts.string_field_or(request.params, "public_key", "")
  if !@skills.valid_skill_public_key(public_key) || key_id == "" ||
    key_id.length() > 128 {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_UNKNOWN_KEY, "invalid public key or key_id"),
    )
    return
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let stored = state.store.put_skill_key(key_id, public_key, timestamp)
  state.mutex.release()
  match stored {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  reload_skill_keys(state)
  audit(
    state,
    "skill.key.register",
    "owner",
    "skill-key/" + key_id,
    "registered",
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("key_id", @contracts.json_string(key_id))]),
  )
}

///|
async fn handle_skill_key_revoke(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let key_id = @contracts.string_field_or(request.params, "key_id", "")
  if key_id == "" {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_UNKNOWN_KEY, "key_id is required"),
    )
    return
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let stored = state.store.revoke_skill_key(key_id, timestamp)
  state.mutex.release()
  match stored {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  reload_skill_keys(state)
  audit(
    state,
    "skill.key.revoke",
    "owner",
    "skill-key/" + key_id,
    "revoked",
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("key_id", @contracts.json_string(key_id))]),
  )
}

///|
async fn handle_skill_allow(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let binding = match skill_binding_from_params(request.params) {
    Some(value) => value
    None => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid exact skill reference"),
      )
      return
    }
  }
  let reason = @contracts.string_field_or(request.params, "reason", "owner")
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  let row = match
    state.store.get_skill_row(
      binding.name,
      binding.version,
      binding.content_hash,
    ) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_NOT_ALLOWLISTED, "import this exact bundle first"),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  if row.state == @contracts.SKILL_STATUS_REVOKED ||
    row.state == @contracts.SKILL_STATUS_PENDING_DELETE {
    state.mutex.release()
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_REVOKED_KEY, "this bundle is revoked"),
    )
    return
  }
  let key_ok = match state.store.list_skill_keys() {
    Ok(keys) => {
      let mut found = false
      for key in keys {
        if key.key_id == row.key_id && !key.revoked {
          found = true
        }
      }
      found
    }
    Err(_) => false
  }
  if !key_ok {
    state.mutex.release()
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_REVOKED_KEY, "signing key is not registered or is revoked"),
    )
    return
  }
  let allow_row : @machines.SkillAllowRow = {
    name: row.name,
    version: row.version,
    content_hash: row.content_hash,
    key_id: row.key_id,
    state: @contracts.SKILL_STATUS_ALLOWED,
    reason,
    added_at: timestamp,
    revoked_at: "",
  }
  let allowed = state.store.allow_skill(allow_row)
  let updated = state.store.set_skill_row_state(
    row.name,
    row.version,
    row.content_hash,
    @contracts.SKILL_STATUS_ALLOWED,
    timestamp,
  )
  let payload = @contracts.json_object([
    ("name", @contracts.json_string(row.name)),
    ("version", @contracts.json_string(row.version)),
    ("content_hash", @contracts.json_string(row.content_hash)),
    ("key_id", @contracts.json_string(row.key_id)),
    ("actor", @contracts.json_string("owner")),
    ("reason", @contracts.json_string(@contracts.redact_secrets(reason))),
  ])
  let append_ok = match allowed {
    Ok(_) => match updated {
      Ok(_) => {
        let _ = state.append_event(
          @contracts.EVENT_SKILL_ALLOWLISTED,
          "skill/" + row.name + "@" + row.version,
          payload,
        )
        true
      }
      Err(_) => false
    }
    Err(_) => false
  }
  state.mutex.release()
  if !append_ok {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error("store_error", "cannot update the skill allowlist"),
    )
    return
  }
  audit(
    state,
    "skill.allow",
    "owner",
    "skill/" + row.name + "@" + row.version,
    "allowed",
    detail="content_hash=" + row.content_hash + " key_id=" + row.key_id,
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("name", @contracts.json_string(row.name)),
      ("version", @contracts.json_string(row.version)),
      ("content_hash", @contracts.json_string(row.content_hash)),
      ("state", @contracts.json_string(@contracts.SKILL_STATUS_ALLOWED)),
    ]),
  )
}

///|
async fn handle_skill_allowlist_revoke(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let binding = match skill_binding_from_params(request.params) {
    Some(value) => value
    None => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid exact skill reference"),
      )
      return
    }
  }
  let reason = @contracts.string_field_or(request.params, "reason", "owner")
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let revoked = state.store.revoke_skill_allow(
    binding.name,
    binding.version,
    binding.content_hash,
    reason,
    timestamp,
  )
  let row_updated = state.store.set_skill_row_state(
    binding.name,
    binding.version,
    binding.content_hash,
    @contracts.SKILL_STATUS_REVOKED,
    timestamp,
  )
  let append_ok = match revoked {
    Ok(_) => match row_updated {
      Ok(_) => {
        let _ = state.append_event(
          @contracts.EVENT_SKILL_ALLOWLIST_REVOKED,
          "skill/" + binding.name + "@" + binding.version,
          @contracts.json_object([
            ("name", @contracts.json_string(binding.name)),
            ("version", @contracts.json_string(binding.version)),
            ("content_hash", @contracts.json_string(binding.content_hash)),
            ("actor", @contracts.json_string("owner")),
            ("reason", @contracts.json_string(@contracts.redact_secrets(reason))),
          ]),
        )
        true
      }
      Err(_) => false
    }
    Err(_) => false
  }
  state.mutex.release()
  if !append_ok {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error("store_error", "cannot revoke the skill allowlist entry"),
    )
    return
  }
  audit(
    state,
    "skill.allowlist.revoke",
    "owner",
    "skill/" + binding.name + "@" + binding.version,
    "revoked",
    detail="content_hash=" + binding.content_hash,
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("name", @contracts.json_string(binding.name)),
      ("version", @contracts.json_string(binding.version)),
      ("content_hash", @contracts.json_string(binding.content_hash)),
      ("state", @contracts.json_string(@contracts.SKILL_STATUS_REVOKED)),
    ]),
  )
}

///|
fn skill_scope_ref_valid(scope : String, scope_ref : String) -> Bool {
  if scope_ref == "" || scope_ref.length() > 128 {
    return false
  }
  if scope == @contracts.SKILL_SCOPE_AGENT {
    return valid_agent_id(scope_ref)
  }
  scope == @contracts.SKILL_SCOPE_TASK || scope == @contracts.SKILL_SCOPE_SESSION
}

///|
/// Exact allowlist and key trust check used by enable/upgrade and by every
/// session resolution. No row means not allowlisted; a revoked row or key
/// means the quadruple is no longer usable.
fn skill_tuple_allowed(
  state : HostState,
  name : String,
  version : String,
  content_hash : String,
) -> Result[Unit, @contracts.RpcError] {
  let row = match state.store.get_skill_row(name, version, content_hash) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        skill_rpc_error(
          @contracts.SKILL_ERR_NOT_ALLOWLISTED,
          "skill bundle is not imported",
        ),
      )
    Err(message) => return Err(skill_rpc_error("store_error", message))
  }
  if row.state == @contracts.SKILL_STATUS_REVOKED ||
    row.state == @contracts.SKILL_STATUS_PENDING_DELETE {
    return Err(
      skill_rpc_error(@contracts.SKILL_ERR_REVOKED_KEY, "skill bundle is revoked"),
    )
  }
  let allow = match state.store.get_skill_allow(name, version, content_hash) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        skill_rpc_error(
          @contracts.SKILL_ERR_NOT_ALLOWLISTED,
          "skill bundle is not in the owner allowlist",
        ),
      )
    Err(message) => return Err(skill_rpc_error("store_error", message))
  }
  if allow.state != @contracts.SKILL_STATUS_ALLOWED {
    return Err(
      skill_rpc_error(
        @contracts.SKILL_ERR_NOT_ALLOWLISTED,
        "skill allowlist entry is revoked",
      ),
    )
  }
  let keys = match state.store.list_skill_keys() {
    Ok(value) => value
    Err(message) => return Err(skill_rpc_error("store_error", message))
  }
  let mut key_ok = false
  for key in keys {
    if key.key_id == row.key_id && !key.revoked {
      key_ok = true
    }
  }
  if !key_ok {
    return Err(
      skill_rpc_error(@contracts.SKILL_ERR_REVOKED_KEY, "signing key is revoked"),
    )
  }
  Ok(())
}

///|
async fn skill_verify_dependencies(
  state : HostState,
  manifest : @contracts.SkillManifest,
  agent_id : String,
  session_id : String,
) -> Result[Unit, @contracts.RpcError] {
  for dependency in manifest.dependencies {
    if dependency.kind == "binary" {
      if !skill_binary_present(dependency.name) {
        skill_dependency_readiness_decision(
          state,
          agent_id,
          session_id,
          manifest.name,
          manifest.version,
          manifest.content_hash,
          dependency.name,
        )
        return Err(
          skill_rpc_error(
            @contracts.SKILL_ERR_DEPENDENCY_MISSING,
            "required binary is not on PATH: " + dependency.name,
          ),
        )
      }
    } else {
      let allowed = match
        skill_tuple_allowed(
          state,
          dependency.name,
          dependency.version,
          dependency.content_hash,
        ) {
        Ok(_) => true
        Err(_) => false
      }
      if !allowed {
        return Err(
          skill_rpc_error(
            @contracts.SKILL_ERR_DEPENDENCY_MISSING,
            "required skill dependency is missing or not allowlisted: " +
            dependency.name +
            "@" +
            dependency.version,
          ),
        )
      }
    }
  }
  Ok(())
}

///|
async fn handle_skill_enable(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let scope = @contracts.string_field_or(request.params, "scope", "")
  let scope_ref = @contracts.string_field_or(request.params, "scope_ref", "")
  if !@contracts.skill_scope_valid(scope) ||
    !skill_scope_ref_valid(scope, scope_ref) {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid scope or scope_ref"),
    )
    return
  }
  let binding = match skill_binding_from_params(request.params) {
    Some(value) => value
    None => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid exact skill reference"),
      )
      return
    }
  }
  state.mutex.acquire()
  let allowed = skill_tuple_allowed(
    state,
    binding.name,
    binding.version,
    binding.content_hash,
  )
  let row = state.store.get_skill_row(
    binding.name,
    binding.version,
    binding.content_hash,
  )
  state.mutex.release()
  match allowed {
    Ok(_) => ()
    Err(error) => {
      skill_send_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let manifest = match row {
    Ok(Some(value)) => match skill_row_manifest(state, value) {
      Ok(manifest) => manifest
      Err(error) => {
        skill_send_error(state, sink, request, client_request_id, error)
        return
      }
    }
    _ => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", "cannot read the skill index row"),
      )
      return
    }
  }
  let ceiling = if scope == @contracts.SKILL_SCOPE_AGENT {
    state.mutex.acquire()
    let permissions = skill_agent_permissions(state, scope_ref)
    state.mutex.release()
    permissions
  } else {
    @contracts.default_skill_permissions()
  }
  if !@skills.skill_permissions_subset(manifest.permissions, ceiling) {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(
        @contracts.SKILL_ERR_PERMISSION_DENIED,
        "skill permissions exceed the agent's skill_permissions ceiling",
      ),
    )
    return
  }
  match skill_verify_dependencies(state, manifest, scope_ref, "") {
    Ok(_) => ()
    Err(error) => {
      skill_send_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let stored = state.store.put_skill_binding({
    scope,
    scope_ref,
    name: binding.name,
    version: binding.version,
    content_hash: binding.content_hash,
    mode: binding.mode,
    enabled_at: timestamp,
  })
  match stored {
    Ok(_) => {
      let _ = state.append_event(
        @contracts.EVENT_SKILL_ENABLED,
        "skill/" + binding.name + "@" + binding.version,
        skill_binding_payload(scope, scope_ref, binding),
      )
    }
    Err(_) => ()
  }
  state.mutex.release()
  match stored {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  audit(
    state,
    "skill.enable",
    "owner",
    "skill/" + binding.name + "@" + binding.version,
    "enabled",
    detail="scope=" +
    scope +
    " scope_ref=" +
    scope_ref +
    " mode=" +
    binding.mode +
    " content_hash=" +
    binding.content_hash,
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("binding", skill_binding_payload(scope, scope_ref, binding))]),
  )
}

///|
async fn handle_skill_disable(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let scope = @contracts.string_field_or(request.params, "scope", "")
  let scope_ref = @contracts.string_field_or(request.params, "scope_ref", "")
  let name = @contracts.string_field_or(request.params, "name", "")
  if !@contracts.skill_scope_valid(scope) ||
    !skill_scope_ref_valid(scope, scope_ref) || name == "" {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid scope, scope_ref or name"),
    )
    return
  }
  state.mutex.acquire()
  let existing = state.store.get_skill_binding(scope, scope_ref, name)
  let removed = state.store.remove_skill_binding(scope, scope_ref, name)
  match removed {
    Ok(_) => {
      let _ = state.append_event(
        @contracts.EVENT_SKILL_DISABLED,
        "skill/" + name,
        @contracts.json_object([
          ("scope", @contracts.json_string(scope)),
          ("scope_ref", @contracts.json_string(scope_ref)),
          ("name", @contracts.json_string(name)),
        ]),
      )
      match existing {
        Ok(Some(value)) => {
          let _ = state.append_event(
            @contracts.EVENT_SKILL_DISABLED,
            "skill/" + name + "@" + value.version,
            @contracts.json_object([
              ("scope", @contracts.json_string(scope)),
              ("scope_ref", @contracts.json_string(scope_ref)),
              ("name", @contracts.json_string(name)),
              ("version", @contracts.json_string(value.version)),
              ("content_hash", @contracts.json_string(value.content_hash)),
              ("mode", @contracts.json_string(value.mode)),
              ("active_sessions_note", @contracts.json_string("already-injected text cannot be recalled; the gateway refuses new calls")),
            ]),
          )
        }
        _ => ()
      }
    }
    Err(_) => ()
  }
  state.mutex.release()
  match removed {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  audit(
    state,
    "skill.disable",
    "owner",
    "skill/" + name,
    "disabled",
    detail="scope=" + scope + " scope_ref=" + scope_ref,
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("scope", @contracts.json_string(scope)),
      ("scope_ref", @contracts.json_string(scope_ref)),
      ("name", @contracts.json_string(name)),
      ("disabled", @contracts.json_bool(true)),
      ("active_sessions_note", @contracts.json_string("already-injected text cannot be recalled; the gateway refuses new calls")),
    ]),
  )
}

///|
async fn handle_skill_upgrade(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let scope = @contracts.string_field_or(request.params, "scope", "")
  let scope_ref = @contracts.string_field_or(request.params, "scope_ref", "")
  if !@contracts.skill_scope_valid(scope) ||
    !skill_scope_ref_valid(scope, scope_ref) {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid scope or scope_ref"),
    )
    return
  }
  let binding = match skill_binding_from_params(request.params) {
    Some(value) => value
    None => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid exact skill reference"),
      )
      return
    }
  }
  state.mutex.acquire()
  let allowed = skill_tuple_allowed(
    state,
    binding.name,
    binding.version,
    binding.content_hash,
  )
  let old = state.store.get_skill_binding(scope, scope_ref, binding.name)
  state.mutex.release()
  match allowed {
    Ok(_) => ()
    Err(error) => {
      skill_send_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let stored = state.store.put_skill_binding({
    scope,
    scope_ref,
    name: binding.name,
    version: binding.version,
    content_hash: binding.content_hash,
    mode: binding.mode,
    enabled_at: timestamp,
  })
  state.mutex.release()
  match stored {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  let old_version = match old {
    Ok(Some(value)) => value.version
    _ => ""
  }
  let old_hash = match old {
    Ok(Some(value)) => value.content_hash
    _ => ""
  }
  state.mutex.acquire()
  let _ = state.append_event(
    @contracts.EVENT_SKILL_UPGRADED,
    "skill/" + binding.name + "@" + binding.version,
    @contracts.json_object([
      ("name", @contracts.json_string(binding.name)),
      ("old_version", @contracts.json_string(old_version)),
      ("old_content_hash", @contracts.json_string(old_hash)),
      ("new_version", @contracts.json_string(binding.version)),
      ("new_content_hash", @contracts.json_string(binding.content_hash)),
      ("scope", @contracts.json_string(scope)),
      ("scope_ref", @contracts.json_string(scope_ref)),
      ("actor", @contracts.json_string("owner")),
    ]),
  )
  state.mutex.release()
  audit(
    state,
    "skill.upgrade",
    "owner",
    "skill/" + binding.name,
    "upgraded",
    detail="scope=" +
    scope +
    " scope_ref=" +
    scope_ref +
    " old=" +
    old_version +
    " new=" +
    binding.version,
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("binding", skill_binding_payload(scope, scope_ref, binding)),
      ("old_version", @contracts.json_string(old_version)),
      ("old_content_hash", @contracts.json_string(old_hash)),
    ]),
  )
}

///|
async fn skill_dir_names(path : String) -> Array[String] {
  let out : Array[String] = []
  let dir = @fs.opendir(path) catch { _ => return out }
  defer dir.close()
  while true {
    let next = dir.next(include_hidden=true) catch { _ => break }
    match next {
      Some(entry) => out.push(entry.name)
      None => break
    }
  }
  out
}

///|
/// Remove `<name>-<version>` copies under every Agent's session skill
/// directory. Only the derived path is touched; agent homes themselves and
/// MEMORY/AGENTS files are never removed.
async fn skill_remove_session_copies(
  state : HostState,
  name : String,
  version : String,
) -> Int {
  let mut removed = 0
  for agent_id in skill_dir_names(state.state_dir + "/agents") {
    let sessions = state.state_dir + "/agents/" + agent_id + "/sessions"
    for session_id in skill_dir_names(sessions) {
      let skills_dir = sessions + "/" + session_id + "/skills"
      for entry in skill_dir_names(skills_dir) {
        if entry == name + "-" + version {
          let target = skills_dir + "/" + entry
          @fs.rmdir(target, recursive=true) catch { _ => () }
          removed = removed + 1
        }
      }
    }
  }
  removed
}

///|
/// Drop capability entries for one exact tuple and count the sessions that
/// referenced it. Caller holds the host mutex.
fn skill_drop_capability_tuple(
  state : HostState,
  name : String,
  version : String,
  content_hash : String,
) -> Int {
  let mut affected = 0
  for token, capability in state.skill_capabilities {
    let kept : Map[String, SkillCapabilityEntry] = Map([])
    for entry_id, entry in capability.entries {
      if entry.name == name && entry.version == version &&
        entry.content_hash == content_hash {
        affected = affected + 1
      } else {
        kept.set(entry_id, entry)
      }
    }
    let updated : SkillCapability = { ..capability, entries: kept }
    state.skill_capabilities.set(token, updated)
  }
  affected
}

///|
async fn handle_skill_uninstall(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let binding = match skill_binding_from_params(request.params) {
    Some(value) => value
    None => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid exact skill reference"),
      )
      return
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let row = state.store.get_skill_row(
    binding.name,
    binding.version,
    binding.content_hash,
  )
  let revoke = state.store.revoke_skill_allow(
    binding.name,
    binding.version,
    binding.content_hash,
    "uninstall",
    timestamp,
  )
  let remove_bindings = state.store.remove_skill_bindings_for(
    binding.name,
    binding.version,
    binding.content_hash,
  )
  let affected = skill_drop_capability_tuple(
    state,
    binding.name,
    binding.version,
    binding.content_hash,
  )
  let mut pending = false
  match row {
    Ok(Some(value)) =>
      if value.state != @contracts.SKILL_STATUS_PENDING_DELETE {
        pending = affected > 0
      }
    _ => ()
  }
  if pending {
    let _ = state.store.set_skill_row_state(
      binding.name,
      binding.version,
      binding.content_hash,
      @contracts.SKILL_STATUS_PENDING_DELETE,
      timestamp,
    )
  }
  state.mutex.release()
  match revoke {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  match remove_bindings {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  let mut deleted = false
  if !pending {
    state.mutex.acquire()
    let _ = state.store.remove_skill_row(
      binding.name,
      binding.version,
      binding.content_hash,
    )
    state.mutex.release()
    let store_path = state.state_dir +
      "/skills/store/" +
      binding.name +
      "/" +
      binding.version +
      "/" +
      binding.content_hash
    @fs.rmdir(store_path, recursive=true) catch { _ => () }
    let _ = skill_remove_session_copies(
      state,
      binding.name,
      binding.version,
    )
    deleted = true
  }
  state.mutex.acquire()
  let _ = state.append_event(
    @contracts.EVENT_SKILL_UNINSTALLED,
    "skill/" + binding.name + "@" + binding.version,
    @contracts.json_object([
      ("name", @contracts.json_string(binding.name)),
      ("version", @contracts.json_string(binding.version)),
      ("content_hash", @contracts.json_string(binding.content_hash)),
      ("affected_sessions", @contracts.json_int(affected)),
      ("deleted", @contracts.json_bool(deleted)),
    ]),
  )
  state.mutex.release()
  audit(
    state,
    "skill.uninstall",
    "owner",
    "skill/" + binding.name + "@" + binding.version,
    if deleted { "deleted" } else { "pending_delete" },
    detail="content_hash=" + binding.content_hash + " sessions=" + affected.to_string(),
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("name", @contracts.json_string(binding.name)),
      ("version", @contracts.json_string(binding.version)),
      ("content_hash", @contracts.json_string(binding.content_hash)),
      ("pending_delete", @contracts.json_bool(!deleted)),
      ("affected_sessions", @contracts.json_int(affected)),
    ]),
  )
}

///|
/// Complete a deferred uninstall once no live capability references it. Called
/// at session finalization and from `skill.doctor`.
async fn skill_gc_pending_uninstalls(state : HostState) -> Unit {
  state.mutex.acquire()
  let rows = match state.store.list_skill_rows() {
    Ok(value) => value
    Err(_) => {
      state.mutex.release()
      return
    }
  }
  let candidates : Array[@machines.SkillRow] = []
  for row in rows {
    if row.state == @contracts.SKILL_STATUS_PENDING_DELETE {
      let mut referenced = false
      for _token, capability in state.skill_capabilities {
        for _entry_id, entry in capability.entries {
          if entry.name == row.name && entry.version == row.version &&
            entry.content_hash == row.content_hash {
            referenced = true
          }
        }
      }
      if !referenced {
        candidates.push(row)
      }
    }
  }
  state.mutex.release()
  for row in candidates {
    state.mutex.acquire()
    let _ = state.store.remove_skill_row(
      row.name,
      row.version,
      row.content_hash,
    )
    state.mutex.release()
    let store_path = state.state_dir +
      "/skills/store/" +
      row.name +
      "/" +
      row.version +
      "/" +
      row.content_hash
    @fs.rmdir(store_path, recursive=true) catch { _ => () }
    let removed = skill_remove_session_copies(state, row.name, row.version)
    state.mutex.acquire()
    let _ = state.append_event(
      @contracts.EVENT_SKILL_UNINSTALLED,
      "skill/" + row.name + "@" + row.version,
      @contracts.json_object([
        ("name", @contracts.json_string(row.name)),
        ("version", @contracts.json_string(row.version)),
        ("content_hash", @contracts.json_string(row.content_hash)),
        ("affected_sessions", @contracts.json_int(0)),
        ("deleted", @contracts.json_bool(true)),
        ("session_copies_removed", @contracts.json_int(removed)),
      ]),
    )
    state.mutex.release()
    audit(
      state,
      "skill.uninstall",
      "host",
      "skill/" + row.name + "@" + row.version,
      "deleted",
      detail="content_hash=" + row.content_hash + " deferred=true",
      policy="skill",
    )
  }
}

///|
fn skill_row_json(row : @machines.SkillRow) -> @json.Json {
  @contracts.json_object([
    ("name", @contracts.json_string(row.name)),
    ("version", @contracts.json_string(row.version)),
    ("content_hash", @contracts.json_string(row.content_hash)),
    ("key_id", @contracts.json_string(row.key_id)),
    ("state", @contracts.json_string(row.state)),
    ("source", @contracts.json_string(@contracts.redact_secrets(row.source))),
    ("updated_at", @contracts.json_string(row.updated_at)),
  ])
}

///|
fn skill_allow_json(row : @machines.SkillAllowRow) -> @json.Json {
  @contracts.json_object([
    ("name", @contracts.json_string(row.name)),
    ("version", @contracts.json_string(row.version)),
    ("content_hash", @contracts.json_string(row.content_hash)),
    ("key_id", @contracts.json_string(row.key_id)),
    ("state", @contracts.json_string(row.state)),
    ("reason", @contracts.json_string(@contracts.redact_secrets(row.reason))),
    ("added_at", @contracts.json_string(row.added_at)),
    ("revoked_at", @contracts.json_string(row.revoked_at)),
  ])
}

///|
fn skill_binding_json(row : @machines.SkillBindingRow) -> @json.Json {
  @contracts.json_object([
    ("scope", @contracts.json_string(row.scope)),
    ("scope_ref", @contracts.json_string(row.scope_ref)),
    ("name", @contracts.json_string(row.name)),
    ("version", @contracts.json_string(row.version)),
    ("content_hash", @contracts.json_string(row.content_hash)),
    ("mode", @contracts.json_string(row.mode)),
    ("enabled_at", @contracts.json_string(row.enabled_at)),
  ])
}

///|
async fn handle_skill_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let scope = @contracts.string_field_or(request.params, "scope", "")
  let scope_ref = @contracts.string_field_or(request.params, "scope_ref", "")
  state.mutex.acquire()
  let rows = state.store.list_skill_rows()
  let allows = state.store.list_skill_allows()
  let bindings = if scope != "" {
    state.store.list_skill_bindings(scope, scope_ref)
  } else {
    state.store.list_all_skill_bindings()
  }
  state.mutex.release()
  let skills_json = match rows {
    Ok(values) => values.map(fn(row) { skill_row_json(row) })
    Err(_) => []
  }
  let allows_json = match allows {
    Ok(values) => values.map(fn(row) { skill_allow_json(row) })
    Err(_) => []
  }
  let bindings_json = match bindings {
    Ok(values) => values.map(fn(row) { skill_binding_json(row) })
    Err(_) => []
  }
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("skills", @contracts.json_array(skills_json)),
      ("allowlist", @contracts.json_array(allows_json)),
      ("bindings", @contracts.json_array(bindings_json)),
    ]),
  )
}

///|
async fn handle_skill_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let name = @contracts.string_field_or(request.params, "name", "")
  let version = @contracts.string_field_or(request.params, "version", "")
  let content_hash = @contracts.string_field_or(request.params, "content_hash", "")
  state.mutex.acquire()
  let row = state.store.get_skill_row(name, version, content_hash)
  state.mutex.release()
  let row_value = match row {
    Ok(Some(value)) => value
    _ => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(@contracts.SKILL_ERR_NOT_ALLOWLISTED, "skill not found"),
      )
      return
    }
  }
  let manifest_json = @json.parse(row_value.manifest_json) catch {
    _ => @contracts.json_object([])
  }
  state.mutex.acquire()
  let allow_row = state.store.get_skill_allow(name, version, content_hash)
  state.mutex.release()
  let allow_state = match allow_row {
    Ok(Some(value)) => value.state
    _ => @contracts.SKILL_STATUS_PENDING
  }
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("skill", skill_row_json(row_value)),
      ("manifest", manifest_json),
      ("allow_state", @contracts.json_string(allow_state)),
    ]),
  )
}

///|
async fn skill_doctor_check(
  state : HostState,
  problems : Array[String],
) -> @json.Json {
  state.mutex.acquire()
  let rows = match state.store.list_skill_rows() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      problems.push("cannot list skills: " + message)
      return @contracts.json_object([])
    }
  }
  let keys = state.store.list_skill_keys()
  state.mutex.release()
  let key_map : Map[String, Bool] = Map([])
  match keys {
    Ok(values) =>
      for key in values {
        key_map.set(key.key_id, key.revoked)
      }
    Err(_) => ()
  }
  let checks : Array[@json.Json] = []
  for row in rows {
    let mut ok = true
    let key_revoked = match key_map.get(row.key_id) {
      Some(revoked) => revoked
      None => true
    }
    if key_revoked {
      ok = false
      problems.push(
        "skill " + row.name + "@" + row.version + " uses a missing or revoked key",
      )
    }
    let store_path = state.state_dir +
      "/skills/store/" +
      row.name +
      "/" +
      row.version +
      "/" +
      row.content_hash
    let keys_snapshot = skill_key_snapshot(state)
    let verified = @skills.load_stored_skill(
      store_path,
      keys_snapshot,
      state.verifier,
    )
    match verified {
      Ok(_) => ()
      Err(fault) => {
        ok = false
        problems.push(
          "skill " +
          row.name +
          "@" +
          row.version +
          " failed re-verification: " +
          fault.code,
        )
      }
    }
    checks.push(
      @contracts.json_object([
        ("name", @contracts.json_string(row.name)),
        ("version", @contracts.json_string(row.version)),
        ("content_hash", @contracts.json_string(row.content_hash)),
        ("state", @contracts.json_string(row.state)),
        ("ok", @contracts.json_bool(ok)),
      ]),
    )
  }
  @contracts.json_array(checks)
}

///|
async fn handle_skill_doctor(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let problems : Array[String] = []
  let checks = skill_doctor_check(state, problems)
  skill_gc_pending_uninstalls(state)
  let ok = problems.is_empty()
  audit(
    state,
    "skill.doctor",
    "owner",
    "skill",
    if ok { "ok" } else { "problems" },
    detail="problems=" + problems.length().to_string(),
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("ok", @contracts.json_bool(ok)),
      ("checks", checks),
      ("problems", @contracts.json_array(problems.map(fn(problem) { @contracts.json_string(problem) }))),
    ]),
  )
}

///|
async fn handle_skill_permissions_set(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let agent_id = @contracts.agent_id_param(request.params)
  if !valid_agent_id(agent_id) {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid agent_id"),
    )
    return
  }
  let permissions = @contracts.string_array_field(request.params, "permissions")
  let clean : Array[String] = []
  for permission in permissions {
    if !@contracts.skill_permission_valid(permission) {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error(
          @contracts.SKILL_ERR_INVALID_PERMISSION,
          "unknown permission: " + permission,
        ),
      )
      return
    }
    let mut duplicate = false
    for existing in clean {
      if existing == permission {
        duplicate = true
      }
    }
    if !duplicate {
      clean.push(permission)
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let stored = state.store.set_agent_skill_permissions(
    agent_id,
    clean,
    timestamp,
  )
  state.mutex.release()
  match stored {
    Ok(_) => ()
    Err(message) => {
      skill_send_error(
        state,
        sink,
        request,
        client_request_id,
        skill_rpc_error("store_error", message),
      )
      return
    }
  }
  audit(
    state,
    "skill.permissions.set",
    "owner",
    "agent/" + agent_id,
    "updated",
    detail="permissions=" + clean.join(","),
    policy="skill",
  )
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("agent_id", @contracts.json_string(agent_id)),
      ("permissions", @contracts.json_string_array(clean)),
    ]),
  )
}

///|
async fn handle_skill_permissions_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.skill_enabled {
    skill_send_error(state, sink, request, client_request_id, skill_disabled_error())
    return
  }
  let agent_id = @contracts.agent_id_param(request.params)
  if !valid_agent_id(agent_id) {
    skill_send_error(
      state,
      sink,
      request,
      client_request_id,
      skill_rpc_error(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid agent_id"),
    )
    return
  }
  state.mutex.acquire()
  let permissions = match state.store.get_agent_skill_permissions(agent_id) {
    Ok(Some(value)) => value
    Ok(None) => @contracts.default_skill_permissions()
    Err(_) => @contracts.default_skill_permissions()
  }
  state.mutex.release()
  skill_send(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([
      ("agent_id", @contracts.json_string(agent_id)),
      ("permissions", @contracts.json_string_array(permissions)),
      ("default", @contracts.json_bool(true)),
    ]),
  )
}
