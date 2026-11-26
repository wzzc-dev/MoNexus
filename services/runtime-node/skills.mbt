///|
/// Node-side skill mirror, leases and invocation (ADR-0015 A4.2).
///
/// The primary verifies the bundle signature and sends the exact manifest and
/// files. The node re-derives the canonical content hash and the declared-file
/// closure before anything lands in its 0700 state directory, so a truncated
/// or modified transfer is refused. Mirrored bundles live under
/// `state_dir/skills/store/<name>/<version>/<hash>` (immutable, hash-addressed)
/// and are materialised per session under
/// `state_dir/skills/sessions/<session_id>/<name>-<version>`; nothing is ever
/// written into the workspace or to PATH.
///
/// Leases are the fail-closed boundary: `runtime.skill.invoke` refuses a
/// missing or expired lease, and requires a verified policy snapshot. GC
/// removes expired leases, session copies and any mirror no longer referenced.
/// The node never approves anything: a high-risk invocation goes through the
/// same policy/Decision/grant handshake as `exec.start`, with the exact
/// mirrored argv bound into the digest.

///|
pub const NODE_SKILL_LEASES_FILE_NAME : String = "skill_leases.json"

///|
pub const NODE_SKILL_DEFAULT_LEASE_MS : Int64 = 3_600_000L

///|
pub const NODE_SKILL_MAX_LEASE_MS : Int64 = 86_400_000L

///|
pub const MAX_NODE_SKILL_LEASES : Int = 256

///|
pub const MAX_NODE_SKILL_LEASE_FILE_BYTES : Int64 = 524_288L

///|
pub const MAX_NODE_SKILL_FILES : Int = 128

///|
/// Bounded output returned to the primary. The transport frame is 64 KiB, so
/// this leaves room for the result envelope and policy metadata.
pub const NODE_SKILL_MAX_OUTPUT_BYTES : Int = 16_384

///|
/// The node never inherits a credential. `PATH` is fixed so the digest is
/// deterministic across invocations; the session directory is the only HOME.
pub const NODE_SKILL_PATH : String = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

///|
pub(all) struct NodeSkillLease {
  session_id : String
  name : String
  version : String
  content_hash : String
  entry_ids : Array[String]
  mirrored_at_ms : Int64
  expires_at_ms : Int64
}

///|
pub fn NodeSkillLease::to_json(self : NodeSkillLease) -> @json.Json {
  @contracts.json_object([
    ("session_id", @contracts.json_string(self.session_id)),
    ("name", @contracts.json_string(self.name)),
    ("version", @contracts.json_string(self.version)),
    ("content_hash", @contracts.json_string(self.content_hash)),
    ("entry_ids", @contracts.json_string_array(self.entry_ids)),
    ("mirrored_at_ms", @contracts.json_int64(self.mirrored_at_ms)),
    ("expires_at_ms", @contracts.json_int64(self.expires_at_ms)),
  ])
}

///|
pub fn NodeSkillLease::from_json(json : @json.Json) -> NodeSkillLease? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let session_id = match @contracts.string_field(object, "session_id") {
    Some(value) => value
    None => return None
  }
  let name = match @contracts.string_field(object, "name") {
    Some(value) => value
    None => return None
  }
  let version = match @contracts.string_field(object, "version") {
    Some(value) => value
    None => return None
  }
  let content_hash = match @contracts.string_field(object, "content_hash") {
    Some(value) => value
    None => return None
  }
  Some({
    session_id,
    name,
    version,
    content_hash,
    entry_ids: @contracts.string_array_field(object, "entry_ids"),
    mirrored_at_ms: @contracts.int64_field_or(object, "mirrored_at_ms", 0L),
    expires_at_ms: @contracts.int64_field_or(object, "expires_at_ms", 0L),
  })
}

///|
fn node_skill_lease_key(
  session_id : String,
  name : String,
  version : String,
  content_hash : String,
) -> String {
  session_id + "|" + name + "|" + version + "|" + content_hash
}

///|
/// Byte-order comparison, so the persisted lease file is deterministic.
fn node_skill_compare_utf8(left : String, right : String) -> Int32 {
  let left_len = left.length()
  let right_len = right.length()
  let limit = if left_len < right_len { left_len } else { right_len }
  let mut index = 0
  while index < limit {
    let left_char = match left.get_char(index) {
      Some(value) => value.to_int()
      None => 0
    }
    let right_char = match right.get_char(index) {
      Some(value) => value.to_int()
      None => 0
    }
    if left_char != right_char {
      if left_char < right_char {
        return -1
      }
      return 1
    }
    index = index + 1
  }
  if left_len < right_len {
    -1
  } else if left_len > right_len {
    1
  } else {
    0
  }
}

///|
fn node_skill_session_root(state_dir : String, session_id : String) -> String {
  state_dir + "/skills/sessions/" + session_id
}

///|
fn node_skill_store_path(
  state_dir : String,
  name : String,
  version : String,
  content_hash : String,
) -> String {
  state_dir + "/skills/store/" + name + "/" + version + "/" + content_hash
}

///|
fn node_skill_session_copy_path(
  state_dir : String,
  session_id : String,
  name : String,
  version : String,
) -> String {
  node_skill_session_root(state_dir, session_id) + "/" + name + "-" + version
}

///|
fn node_skill_lease_unavailable(reason : String) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @transport.ERR_POLICY_STALE,
    "remote skill invocation fails closed: the session has no live mirror lease",
    data=@contracts.json_object([
      ("kind", @contracts.json_string("skill_unavailable")),
      ("reason", @contracts.json_string(reason)),
    ]),
  )
}

///|
fn node_skill_refused(fault : @skills.SkillFault) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_INVALID_PARAMS,
    "skill bundle refused: " + fault.code + ": " + fault.detail,
    data=@contracts.json_object([
      ("kind", @contracts.json_string("skill_refused")),
      ("reason", @contracts.json_string(fault.code)),
    ]),
  )
}

///|
/// Load the persisted lease file. A missing file is an empty lease set; a
/// malformed, oversized or non-0600 file fails the node open rather than
/// silently extending or forgetting a lease.
pub async fn load_node_skill_leases(
  path : String,
) -> Result[Map[String, NodeSkillLease], String] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(Map([]))
  }
  let stat = match @transport.lstat_path(path) {
    None => return Err("skill lease file is missing")
    Some(value) => value
  }
  match stat.kind {
    @transport.PathKind::Regular =>
      if (stat.mode & 0o777) != 0o600 {
        return Err(
          "skill lease file must be 0600 (found mode " +
          @transport.mode_text(stat.mode) + ")",
        )
      }
    _ => return Err("skill lease file is not a regular file")
  }
  if stat.size > MAX_NODE_SKILL_LEASE_FILE_BYTES {
    return Err("skill lease file exceeds its bound")
  }
  let data = @fs.read_file(path) catch {
    error => return Err("cannot read skill lease file: " + error.to_string())
  }
  let text = data.text() catch {
    error => return Err("cannot decode skill lease file: " + error.to_string())
  }
  let json = @json.parse(text) catch {
    _ => return Err("skill lease file is not valid JSON")
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err("skill lease file must be an object")
  }
  if @contracts.int_field_or(object, "schema", -1) != 1 {
    return Err("unsupported skill lease file schema")
  }
  let items = match object.get("leases") {
    Some(@json.Json::Array(items)) => items
    _ => return Err("skill lease file has no leases array")
  }
  if items.length() > MAX_NODE_SKILL_LEASES {
    return Err("skill lease file has too many leases")
  }
  let leases : Map[String, NodeSkillLease] = Map([])
  for item in items {
    let lease = match NodeSkillLease::from_json(item) {
      Some(value) => value
      None => return Err("skill lease file contains an invalid lease")
    }
    if lease.session_id == "" || lease.expires_at_ms <= 0L {
      return Err("skill lease file contains an invalid lease")
    }
    leases.set(
      node_skill_lease_key(
        lease.session_id,
        lease.name,
        lease.version,
        lease.content_hash,
      ),
      lease,
    )
  }
  Ok(leases)
}

///|
async fn NodeHost::persist_skill_leases(self : NodeHost) -> Result[Unit, String] {
  let sorted : Array[NodeSkillLease] = []
  for _key, lease in self.skill_leases {
    sorted.push(lease)
  }
  sorted.sort_by(fn(left : NodeSkillLease, right : NodeSkillLease) -> Int32 {
    let left_key = node_skill_lease_key(
      left.session_id,
      left.name,
      left.version,
      left.content_hash,
    )
    let right_key = node_skill_lease_key(
      right.session_id,
      right.name,
      right.version,
      right.content_hash,
    )
    node_skill_compare_utf8(left_key, right_key)
  })
  let items : Array[@json.Json] = []
  for lease in sorted {
    items.push(lease.to_json())
  }
  let text = @contracts.json_object([
    ("schema", @contracts.json_int(1)),
    ("leases", @contracts.json_array(items)),
  ]).stringify()
  let bound = MAX_NODE_SKILL_LEASE_FILE_BYTES
  if text.length().to_int64() > bound {
    return Err("skill lease file would exceed its bound")
  }
  save_node_state_file(
    self.state_dir + "/" + NODE_SKILL_LEASES_FILE_NAME,
    text,
    "skill lease file",
  )
}

///|
/// The live lease for one exact tuple, or `None` when absent or expired.
fn NodeHost::live_skill_lease(
  self : NodeHost,
  session_id : String,
  name : String,
  version : String,
  content_hash : String,
  now_ms : Int64,
) -> NodeSkillLease? {
  match
    self.skill_leases.get(
      node_skill_lease_key(session_id, name, version, content_hash),
    ) {
    Some(lease) =>
      if lease.expires_at_ms > now_ms {
        Some(lease)
      } else {
        None
      }
    None => None
  }
}

///|
fn node_skill_tuple(
  params : Map[String, @json.Json],
) -> Result[(String, String, String), @contracts.RpcError] {
  let name = match require_string(params, "name") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@skills.is_valid_skill_name(name) {
    return Err(invalid_params("invalid skill name"))
  }
  let version = match require_string(params, "version") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@skills.is_valid_skill_version(version) {
    return Err(invalid_params("invalid skill version"))
  }
  let content_hash = match require_string(params, "content_hash") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@skills.is_valid_skill_content_hash(content_hash) {
    return Err(invalid_params("invalid skill content_hash"))
  }
  Ok((name, version, content_hash))
}

///|
fn node_skill_files_param(
  params : Map[String, @json.Json],
) -> Result[Array[@skills.SkillBundleFile], @contracts.RpcError] {
  let items = match params.get("files") {
    Some(@json.Json::Array(items)) => items
    _ => return Err(invalid_params("files must be an array"))
  }
  if items.length() > MAX_NODE_SKILL_FILES {
    return Err(invalid_params("files has too many elements"))
  }
  let out : Array[@skills.SkillBundleFile] = []
  for item in items {
    let object = match @contracts.as_object(item) {
      Some(value) => value
      None => return Err(invalid_params("files entries must be objects"))
    }
    let path = match @contracts.string_field(object, "path") {
      Some(value) => value
      None => return Err(invalid_params("files entries require path"))
    }
    let content = match @contracts.string_field(object, "content") {
      Some(value) => value
      None => return Err(invalid_params("files entries require content"))
    }
    out.push(@skills.SkillBundleFile::new(path~, content~))
  }
  Ok(out)
}

///|
/// Environment for one mirrored invocation. Only fixed PATH reaches the
/// child; HOME is the session skill directory so tools cannot read the node
/// operator's home or credentials.
fn node_skill_env(state_dir : String, session_id : String) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  env.set("PATH", NODE_SKILL_PATH)
  env.set("HOME", node_skill_session_root(state_dir, session_id))
  env
}

///|
fn node_skill_env_pairs(
  env : Map[String, String],
) -> (Array[String], Array[(String, String)]) {
  let pairs : Array[(String, String)] = []
  for name, value in env {
    pairs.push((name, value))
  }
  pairs.sort_by(fn(left : (String, String), right : (String, String)) -> Int32 {
    node_skill_compare_utf8(left.0, right.0)
  })
  let names : Array[String] = []
  for pair in pairs {
    names.push(pair.0)
  }
  (names, pairs)
}

///|
/// Resolve the exact execution request for `runtime.skill.invoke` from the
/// verified mirror. The lease gate runs first, so an expired mirror can never
/// be classified as executable; the returned argv is what the policy digest
/// binds and what the invocation executes.
async fn NodeHost::skill_execution_request(
  self : NodeHost,
  params : Map[String, @json.Json],
) -> Result[(@policy.ExecutionRequest, String), @contracts.RpcError] {
  let session_id = match require_safe_id(params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (name, version, content_hash) = match node_skill_tuple(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let entry_id = match require_string(params, "entry_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    self.live_skill_lease(
      session_id,
      name,
      version,
      content_hash,
      @async.now(),
    ) {
    Some(_) => ()
    None => return Err(node_skill_lease_unavailable("lease_expired_or_missing"))
  }
  let (cwd, cwd_rooted) = match
    policy_cwd(self.workspace_root, optional_string(params, "cwd")) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let bundle = match
    @skills.load_stored_skill_hash(
      node_skill_store_path(self.state_dir, name, version, content_hash),
    ) {
    Ok(value) => value
    Err(_) => return Err(node_skill_lease_unavailable("mirror_unverified"))
  }
  if bundle.manifest.name != name || bundle.manifest.version != version ||
    bundle.manifest.content_hash != content_hash {
    return Err(node_skill_lease_unavailable("mirror_tuple_mismatch"))
  }
  let command = match @skills.find_skill_command(bundle.manifest, entry_id) {
    Some(value) => value
    None =>
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_INVALID_PARAMS,
          "entry_id is not declared by the mirrored skill",
          data=@contracts.json_object([
            ("kind", @contracts.json_string("invalid_entry")),
            ("reason", @contracts.json_string(@contracts.SKILL_ERR_INVALID_ENTRY)),
          ]),
        ),
      )
  }
  if !@skills.skill_argv_safe(command.argv) {
    return Err(
      @contracts.RpcError::new(
        @contracts.ERR_INVALID_PARAMS,
        "the declared command is not a safe executable argv",
        data=@contracts.json_object([
          ("kind", @contracts.json_string("invalid_entry")),
          ("reason", @contracts.json_string(@contracts.SKILL_ERR_INTERPRETER_DENIED)),
        ]),
      ),
    )
  }
  let env = node_skill_env(self.state_dir, session_id)
  let (env_names, env_values) = node_skill_env_pairs(env)
  Ok((
    @policy.ExecutionRequest::new(
      operation=@policy.PolicyOperation::Exec,
      argv=command.argv,
      cwd~,
      workspace_root=self.workspace_root,
      env_names~,
      env_values~,
    ),
    cwd_rooted,
  ))
}

///|
/// Mirror one exact bundle for one session. The primary has already verified
/// the signature; this re-derives the canonical hash over the received bytes
/// and refuses anything that does not match the requested tuple.
async fn NodeHost::skill_mirror(
  self : NodeHost,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let session_id = match require_safe_id(params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (name, version, content_hash) = match node_skill_tuple(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let manifest_text = match require_string(params, "manifest") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lease_ms = int64_param_or(params, "lease_ms", NODE_SKILL_DEFAULT_LEASE_MS)
  if lease_ms <= 0L || lease_ms > NODE_SKILL_MAX_LEASE_MS {
    return Err(invalid_params("lease_ms is out of range"))
  }
  let files = match node_skill_files_param(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let bundle = match @skills.verify_skill_bundle_hash_bytes(manifest_text, files) {
    Ok(value) => value
    Err(fault) => return Err(node_skill_refused(fault))
  }
  if bundle.manifest.name != name || bundle.manifest.version != version ||
    bundle.manifest.content_hash != content_hash {
    return Err(
      @contracts.RpcError::new(
        @contracts.ERR_INVALID_PARAMS,
        "the mirrored bundle does not match the requested exact tuple",
        data=@contracts.json_object([
          ("kind", @contracts.json_string("skill_refused")),
          ("reason", @contracts.json_string(@contracts.SKILL_ERR_HASH_MISMATCH)),
        ]),
      ),
    )
  }
  let store_path = node_skill_store_path(self.state_dir, name, version, content_hash)
  let mut existing = false
  let mut store_ready = false
  match @skills.load_stored_skill_hash(store_path) {
    Ok(value) =>
      if value.manifest.content_hash == content_hash {
        store_ready = true
        existing = true
      }
    Err(_) => ()
  }
  if !store_ready {
    match @skills.store_skill_bundle(self.state_dir, bundle) {
      Ok(_) => ()
      Err(fault) => return Err(node_skill_refused(fault))
    }
  }
  match
    @skills.materialize_skill(
      node_skill_session_root(self.state_dir, session_id),
      bundle,
    ) {
    Ok(_) => ()
    Err(fault) => return Err(node_skill_refused(fault))
  }
  let entry_ids : Array[String] = []
  for command in bundle.manifest.commands {
    entry_ids.push(command.id)
  }
  let now = @async.now()
  let lease : NodeSkillLease = {
    session_id,
    name,
    version,
    content_hash,
    entry_ids,
    mirrored_at_ms: now,
    expires_at_ms: now + lease_ms,
  }
  self.skill_leases.set(
    node_skill_lease_key(session_id, name, version, content_hash),
    lease,
  )
  match self.persist_skill_leases() {
    Ok(_) => ()
    Err(message) =>
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_HOST,
          "cannot persist the skill lease: " + message,
        ),
      )
  }
  node_audit(
    self,
    "skill.mirror",
    "ok",
    "session=" +
    session_id +
    " name=" +
    name +
    " version=" +
    version +
    " hash=" +
    content_hash +
    " entries=" + entry_ids.length().to_string(),
  )
  Ok(
    @contracts.json_object([
      ("lease", lease.to_json()),
      ("existing", @contracts.json_bool(existing)),
    ]),
  )
}

///|
/// List mirrored leases without bodies. Expired leases are still reported so
/// the primary can observe a lease running out before GC removes it.
async fn NodeHost::skill_list(
  self : NodeHost,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let session_id = optional_string(params, "session_id")
  if session_id != "" && !@transport.is_safe_id(session_id) {
    return Err(invalid_params("session_id is not a safe runtime id"))
  }
  let now = @async.now()
  let leases : Array[@json.Json] = []
  for _key, lease in self.skill_leases {
    if session_id != "" && lease.session_id != session_id {
      continue
    }
    let object = match @contracts.as_object(lease.to_json()) {
      Some(value) => value
      None => Map([])
    }
    object.set("expired", @contracts.json_bool(lease.expires_at_ms <= now))
    leases.push(@json.Json::object(object))
  }
  Ok(@contracts.json_object([("leases", @contracts.json_array(leases))]))
}

///|
/// Execute one mirrored entry with the exact manifest argv. The policy gate
/// has already classified `/runtime.skill.invoke` as `Exec` and, when needed,
/// a Decision-bound grant was verified and consumed. This function only
/// re-verifies the mirror and runs that exact argv.
async fn NodeHost::skill_invoke(
  self : NodeHost,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let session_id = match require_safe_id(params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (name, version, content_hash) = match node_skill_tuple(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let entry_id = match require_string(params, "entry_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let run_id = match require_safe_id(params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    self.live_skill_lease(
      session_id,
      name,
      version,
      content_hash,
      @async.now(),
    ) {
    Some(_) => ()
    None => {
      node_audit(
        self,
        "skill.invoke_denied",
        "denied",
        "session=" +
        session_id +
        " name=" +
        name +
        " version=" +
        version +
        " reason=lease_expired_or_missing",
      )
      return Err(node_skill_lease_unavailable("lease_expired_or_missing"))
    }
  }
  let bundle = match
    @skills.load_stored_skill_hash(
      node_skill_store_path(self.state_dir, name, version, content_hash),
    ) {
    Ok(value) => value
    Err(_) => {
      node_audit(
        self,
        "skill.invoke_denied",
        "denied",
        "session=" +
        session_id +
        " name=" +
        name +
        " version=" +
        version +
        " reason=mirror_unverified",
      )
      return Err(node_skill_lease_unavailable("mirror_unverified"))
    }
  }
  if bundle.manifest.name != name || bundle.manifest.version != version ||
    bundle.manifest.content_hash != content_hash {
    return Err(node_skill_lease_unavailable("mirror_tuple_mismatch"))
  }
  let command = match @skills.find_skill_command(bundle.manifest, entry_id) {
    Some(value) => value
    None =>
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_INVALID_PARAMS,
          "entry_id is not declared by the mirrored skill",
        ),
      )
  }
  if !@skills.skill_argv_safe(command.argv) {
    return Err(
      @contracts.RpcError::new(
        @contracts.ERR_INVALID_PARAMS,
        "the declared command is not a safe executable argv",
      ),
    )
  }
  let (cwd_abs, _cwd_rooted) = match
    policy_cwd(self.workspace_root, optional_string(params, "cwd")) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let command_env = node_skill_env(self.state_dir, session_id)
  let collected = @async.with_timeout_opt(
    command.timeout_ms,
    async fn() {
      let triple = @process.collect_output(
        command.argv[0],
        command.argv[1:].to_owned(),
        cwd=cwd_abs,
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
      node_audit(
        self,
        "skill.invoke_denied",
        "denied",
        "session=" +
        session_id +
        " name=" +
        name +
        " version=" +
        version +
        " reason=spawn_failed",
      )
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_HOST,
          "cannot start the declared command",
        ),
      )
    }
    None => {
      node_audit(
        self,
        "skill.invoke_denied",
        "denied",
        "session=" +
        session_id +
        " name=" +
        name +
        " version=" +
        version +
        " reason=" +
        @contracts.SKILL_ERR_TIMEOUT,
      )
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_HOST,
          "skill command timed out",
          data=@contracts.json_object([
            ("kind", @contracts.json_string("skill_timeout")),
            ("reason", @contracts.json_string(@contracts.SKILL_ERR_TIMEOUT)),
          ]),
        ),
      )
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
  let limit = command.max_output_bytes.min(NODE_SKILL_MAX_OUTPUT_BYTES)
  let truncated = redacted.length() > limit
  let output = if truncated {
    redacted[:limit].to_owned() + "\n[output truncated]\n"
  } else {
    redacted
  }
  let output_bytes = output.length()
  node_audit(
    self,
    "skill.invoke",
    "ok",
    "session=" +
    session_id +
    " name=" +
    name +
    " version=" +
    version +
    " entry=" +
    entry_id +
    " exit=" +
    exit_code.to_string() +
    " output_bytes=" + output_bytes.to_string(),
  )
  let result = @contracts.SkillInvocationResult::new(
    name~,
    version~,
    content_hash~,
    entry_id~,
    exit_code=exit_code.to_int(),
    output~,
    truncated~,
    decision_id="",
    run_id~,
  )
  Ok(result.to_json())
}

///|
/// Remove expired leases and their materialisation. `force` with a
/// `session_id` drops that session's leases immediately (disable/uninstall);
/// without a session filter it drops every expired lease. A mirror bundle is
/// deleted only after no lease references it.
async fn NodeHost::skill_gc(
  self : NodeHost,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let session_id = optional_string(params, "session_id")
  if session_id != "" && !@transport.is_safe_id(session_id) {
    return Err(invalid_params("session_id is not a safe runtime id"))
  }
  let force = bool_param_or(params, "force", false)
  let now = @async.now()
  let keys : Array[String] = []
  for key, lease in self.skill_leases {
    let matches = session_id == "" || lease.session_id == session_id
    if matches && (force || lease.expires_at_ms <= now) {
      keys.push(key)
    }
  }
  let removed : Array[@json.Json] = []
  for key in keys {
    let lease = match self.skill_leases.get(key) {
      Some(value) => value
      None => continue
    }
    self.skill_leases.remove(key)
    @skills.remove_skill_dir(
      node_skill_session_copy_path(
        self.state_dir,
        lease.session_id,
        lease.name,
        lease.version,
      ),
    )
    let mut referenced = false
    for _other_key, other in self.skill_leases {
      if other.name == lease.name && other.version == lease.version &&
        other.content_hash == lease.content_hash {
        referenced = true
      }
    }
    if !referenced {
      @skills.remove_skill_dir(
        node_skill_store_path(
          self.state_dir,
          lease.name,
          lease.version,
          lease.content_hash,
        ),
      )
    }
    removed.push(
      @contracts.json_object([
        ("session_id", @contracts.json_string(lease.session_id)),
        ("name", @contracts.json_string(lease.name)),
        ("version", @contracts.json_string(lease.version)),
        ("content_hash", @contracts.json_string(lease.content_hash)),
      ]),
    )
  }
  if keys.length() > 0 {
    match self.persist_skill_leases() {
      Ok(_) => ()
      Err(message) =>
        return Err(
          @contracts.RpcError::new(
            @contracts.ERR_HOST,
            "cannot persist the skill lease file: " + message,
          ),
        )
    }
    node_audit(
      self,
      "skill.mirror_gc",
      "ok",
      "session=" +
      (if session_id == "" { "*" } else { session_id }) +
      " removed=" + keys.length().to_string(),
    )
  }
  Ok(
    @contracts.json_object([
      ("removed", @contracts.json_array(removed)),
      ("remaining", @contracts.json_int(self.skill_leases.length())),
    ]),
  )
}
