///|
/// Node-local credential custody (A5.2, ADR-0016 as amended).
///
/// The secret is registered on the node itself, under the node's login, and
/// never crosses the transport. The primary stores only binding metadata,
/// fingerprints, versions and status. This module owns:
///
/// - a 0700 secret directory with 0600 files (`packages/credentials` file
///   backend) or the macOS Keychain under the node login;
/// - a 0600 metadata file mapping profile → credential id, version,
///   fingerprint, state and the last lease;
/// - lease/revoke signals: metadata-only control frames from the primary;
/// - the per-process loopback proxy that swaps the node-local secret in.
///
/// The metadata file never contains a secret. A lease is a freshness promise:
/// a process proxy stops authorizing once the primary has been unreachable for
/// longer than the lease window, so offline custody fails closed.

///|
pub const NODE_CREDENTIAL_METADATA_FILE : String = "profiles.json"

///|
pub const NODE_CREDENTIAL_STORE_DIR : String = "credentials"

///|
pub const NODE_CREDENTIAL_METADATA_VERSION : Int32 = 1

///|
pub const NODE_CREDENTIAL_MAX_PROFILES : Int32 = 64

///|
pub const NODE_CREDENTIAL_MAX_PROFILE_NAME : Int32 = 64

///|
pub const NODE_CREDENTIAL_MAX_FINGERPRINT : Int32 = 128

///|
/// One node-local credential profile. No field is a secret.
pub(all) struct NodeCredentialEntry {
  profile : String
  credential_id : String
  kind : String
  version : Int32
  fingerprint : String
  state : String
  created_at : String
  updated_at : String
  binding_id : String
  agent_id : String
  lease_expires_at : String
  last_lease_at : String
}

///|
pub fn NodeCredentialEntry::to_json(self : NodeCredentialEntry) -> @json.Json {
  @contracts.json_object([
    ("profile", @contracts.json_string(self.profile)),
    ("credential_id", @contracts.json_string(self.credential_id)),
    ("kind", @contracts.json_string(self.kind)),
    ("version", @contracts.json_int(self.version)),
    ("fingerprint", @contracts.json_string(self.fingerprint)),
    ("state", @contracts.json_string(self.state)),
    ("created_at", @contracts.json_string(self.created_at)),
    ("updated_at", @contracts.json_string(self.updated_at)),
    ("binding_id", @contracts.json_string(self.binding_id)),
    ("agent_id", @contracts.json_string(self.agent_id)),
    ("lease_expires_at", @contracts.json_string(self.lease_expires_at)),
    ("last_lease_at", @contracts.json_string(self.last_lease_at)),
  ])
}

///|
pub fn node_credential_entry_from_json(
  value : @json.Json,
) -> NodeCredentialEntry? {
  let object = match @contracts.as_object(value) {
    Some(value) => value
    None => return None
  }
  let profile = @contracts.string_field_or(object, "profile", "")
  if !valid_node_credential_profile(profile) {
    return None
  }
  let version = @contracts.int_field_or(object, "version", 0)
  if version <= 0 {
    return None
  }
  Some({
    profile,
    credential_id: @contracts.string_field_or(object, "credential_id", ""),
    kind: @contracts.string_field_or(
      object,
      "kind",
      @contracts.CREDENTIAL_KIND_API_KEY,
    ),
    version,
    fingerprint: @contracts.string_field_or(object, "fingerprint", ""),
    state: @contracts.string_field_or(
      object,
      "state",
      @contracts.CREDENTIAL_STATE_ACTIVE,
    ),
    created_at: @contracts.string_field_or(object, "created_at", ""),
    updated_at: @contracts.string_field_or(object, "updated_at", ""),
    binding_id: @contracts.string_field_or(object, "binding_id", ""),
    agent_id: @contracts.string_field_or(object, "agent_id", ""),
    lease_expires_at: @contracts.string_field_or(object, "lease_expires_at", ""),
    last_lease_at: @contracts.string_field_or(object, "last_lease_at", ""),
  })
}

///|
/// Profile names end up in metadata and are matched by the transport, so they
/// use the same conservative alphabet as resource ids.
pub fn valid_node_credential_profile(name : String) -> Bool {
  if name == "" || name.length() > NODE_CREDENTIAL_MAX_PROFILE_NAME {
    return false
  }
  for ch in name {
    let code = ch.to_int()
    let allowed = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if !allowed {
      return false
    }
  }
  true
}

///|
pub fn node_credential_failure_message(
  reason : String,
  detail : String,
) -> String {
  if detail == "" {
    reason
  } else {
    reason + ": " + detail
  }
}

///|
/// The node's credential vault. `open` does no I/O; every operation validates
/// the 0700 directory and 0600 files before use.
pub struct NodeCredentialVault {
  root : String
  storage : String
  store : @credentials.CredentialStore
}

///|
pub fn NodeCredentialVault::open(
  root : String,
  storage~ : String = "",
) -> NodeCredentialVault {
  {
    root,
    storage,
    store: @credentials.CredentialStore::open(root, requested=storage),
  }
}

///|
pub fn NodeCredentialVault::root(self : NodeCredentialVault) -> String {
  self.root
}

///|
pub fn NodeCredentialVault::backend(self : NodeCredentialVault) -> String {
  self.store.backend
}

///|
pub fn NodeCredentialVault::detail(self : NodeCredentialVault) -> String {
  self.store.detail
}

///|
fn NodeCredentialVault::node_credential_metadata_path(
  self : NodeCredentialVault,
) -> String {
  self.root + "/" + NODE_CREDENTIAL_METADATA_FILE
}

///|
async fn NodeCredentialVault::ensure_root(
  self : NodeCredentialVault,
) -> Result[Unit, String] {
  @fs.mkdir(self.root, permission=0o700, recursive=true, allow_exist=true) catch {
    error =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_LOCKED,
          "cannot create the node credential directory: " + error.to_string(),
        ),
      )
  }
  match @transport.validate_private_dir(self.root, "node credential dir") {
    Ok(_) => Ok(())
    Err(message) =>
      Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          @contracts.redact_secrets(message),
        ),
      )
  }
}

///|
async fn NodeCredentialVault::read_metadata(
  self : NodeCredentialVault,
) -> Result[Array[NodeCredentialEntry], String] {
  let path = self.node_credential_metadata_path()
  let present = @fs.exists(path) catch { _ => false }
  if !present {
    return Ok([])
  }
  match @transport.validate_secret_file(path, "node credential metadata") {
    Ok(_) => ()
    Err(message) =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          @contracts.redact_secrets(message),
        ),
      )
  }
  let text = @fs.read_file(path).text() catch {
    _ =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_LOCKED,
          "cannot read node credential metadata",
        ),
      )
  }
  let parsed = @json.parse(text) catch {
    _ =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_BAD_STATE,
          "node credential metadata is not valid JSON",
        ),
      )
  }
  let object = match @contracts.as_object(parsed) {
    Some(value) => value
    None =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_BAD_STATE,
          "node credential metadata is not an object",
        ),
      )
  }
  if @contracts.int_field_or(object, "version", 0) !=
    NODE_CREDENTIAL_METADATA_VERSION {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_BAD_STATE,
        "unsupported node credential metadata version",
      ),
    )
  }
  let entries : Array[NodeCredentialEntry] = []
  match object.get("profiles") {
    Some(@json.Json::Array(items)) =>
      for item in items {
        let entry = match node_credential_entry_from_json(item) {
          Some(value) => value
          None =>
            return Err(
              node_credential_failure_message(
                @contracts.CREDENTIAL_REASON_BAD_STATE,
                "node credential metadata contains an invalid entry",
              ),
            )
        }
        entries.push(entry)
      }
    Some(_) =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_BAD_STATE,
          "node credential profiles are not an array",
        ),
      )
    None => ()
  }
  if entries.length() > NODE_CREDENTIAL_MAX_PROFILES {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_BAD_STATE,
        "too many node credential profiles",
      ),
    )
  }
  Ok(entries)
}

///|
async fn NodeCredentialVault::write_metadata(
  self : NodeCredentialVault,
  entries : Array[NodeCredentialEntry],
) -> Result[Unit, String] {
  match self.ensure_root() {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let document = @contracts.json_object([
    ("version", @contracts.json_int(NODE_CREDENTIAL_METADATA_VERSION)),
    (
      "profiles",
      @contracts.json_array(entries.map(fn(item) { item.to_json() })),
    ),
  ])
  match
    save_node_state_file(
      self.node_credential_metadata_path(),
      document.stringify(),
      "node credential metadata",
    ) {
    Ok(_) => Ok(())
    Err(_) =>
      Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_LOCKED,
          "cannot write node credential metadata",
        ),
      )
  }
}

///|
fn find_node_credential(
  entries : Array[NodeCredentialEntry],
  profile : String,
) -> NodeCredentialEntry? {
  for entry in entries {
    if entry.profile == profile {
      return Some(entry)
    }
  }
  None
}

///|
pub async fn NodeCredentialVault::enroll(
  self : NodeCredentialVault,
  profile : String,
  secret : String,
  kind~ : String = @contracts.CREDENTIAL_KIND_API_KEY,
) -> Result[NodeCredentialEntry, String] {
  if !valid_node_credential_profile(profile) {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_SECRET_INVALID,
        "invalid credential profile name",
      ),
    )
  }
  if kind != @contracts.CREDENTIAL_KIND_API_KEY &&
    kind != @contracts.CREDENTIAL_KIND_BEARER_TOKEN {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_SECRET_INVALID,
        "unsupported credential kind",
      ),
    )
  }
  match @credentials.validate_credential_secret(secret) {
    Ok(_) => ()
    Err(failure) =>
      return Err(
        node_credential_failure_message(failure.reason, failure.detail),
      )
  }
  match self.ensure_root() {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let entries = match self.read_metadata() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let existing = find_node_credential(entries, profile)
  let version = match existing {
    Some(value) =>
      if value.state == @contracts.CREDENTIAL_STATE_ACTIVE {
        value.version + 1
      } else {
        value.version + 1
      }
    None => 1
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let credential_id = @contracts.new_id("crd", now)
  let fingerprint = @credentials.credential_fingerprint(secret)
  let created_at = match existing {
    Some(value) => value.created_at
    None => timestamp
  }
  match self.store.put(credential_id, kind, secret, version, created_at) {
    Ok(_) => ()
    Err(failure) =>
      return Err(
        node_credential_failure_message(failure.reason, failure.detail),
      )
  }
  let entry : NodeCredentialEntry = {
    profile,
    credential_id,
    kind,
    version,
    fingerprint,
    state: @contracts.CREDENTIAL_STATE_ACTIVE,
    created_at,
    updated_at: timestamp,
    binding_id: "",
    agent_id: "",
    lease_expires_at: "",
    last_lease_at: "",
  }
  let next : Array[NodeCredentialEntry] = []
  let mut old_credential_id = ""
  for item in entries {
    if item.profile == profile {
      old_credential_id = item.credential_id
    } else {
      next.push(item)
    }
  }
  next.push(entry)
  let saved = self.write_metadata(next)
  match saved {
    Ok(_) => ()
    Err(message) => {
      // The metadata never referenced the new secret; remove it so a failed
      // enrollment cannot leave an unaccounted 0600 secret behind.
      ignore(self.store.delete(credential_id))
      return Err(message)
    }
  }
  if old_credential_id != "" && old_credential_id != credential_id {
    // The metadata already points at the new version. A failed delete leaves
    // an unreferenced old secret; doctor reports any such orphan.
    ignore(self.store.delete(old_credential_id))
  }
  Ok(entry)
}

///|
async fn NodeCredentialVault::set_state(
  self : NodeCredentialVault,
  profile : String,
  state : String,
) -> Result[NodeCredentialEntry, String] {
  let entries = match self.read_metadata() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let existing = match find_node_credential(entries, profile) {
    Some(value) => value
    None =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_NOT_FOUND,
          "no node credential for profile " + profile,
        ),
      )
  }
  let now = @async.now()
  let updated = {
    ..existing,
    state,
    updated_at: @contracts.format_rfc3339(now),
    binding_id: "",
    agent_id: "",
    lease_expires_at: "",
    last_lease_at: "",
  }
  let next = entries.map(fn(item) {
    if item.profile == profile {
      updated
    } else {
      item
    }
  })
  match self.write_metadata(next) {
    Ok(_) => Ok(updated)
    Err(message) => Err(message)
  }
}

///|
/// Destroy the local secret first, then record the revocation. A failed delete
/// keeps the profile active and reports an error: revocation is fail-closed.
pub async fn NodeCredentialVault::revoke(
  self : NodeCredentialVault,
  profile : String,
) -> Result[NodeCredentialEntry, String] {
  if !valid_node_credential_profile(profile) {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_SECRET_INVALID,
        "invalid credential profile name",
      ),
    )
  }
  let entries = match self.read_metadata() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let existing = match find_node_credential(entries, profile) {
    Some(value) => value
    None =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_NOT_FOUND,
          "no node credential for profile " + profile,
        ),
      )
  }
  if existing.state == @contracts.CREDENTIAL_STATE_REVOKED {
    return Ok(existing)
  }
  match self.store.delete(existing.credential_id) {
    Ok(_) => ()
    Err(failure) =>
      return Err(
        node_credential_failure_message(failure.reason, failure.detail),
      )
  }
  self.set_state(profile, @contracts.CREDENTIAL_STATE_REVOKED)
}

///|
fn node_lease_expired(entry : NodeCredentialEntry, now : Int64) -> Bool {
  if entry.lease_expires_at == "" {
    return true
  }
  match @contracts.parse_rfc3339_ms(entry.lease_expires_at) {
    Some(value) => now > value
    None => true
  }
}

///|
/// Verify the non-secret marker against the node's own enrollment. A revoked,
/// rotated, unknown or never-leased profile fails closed.
async fn NodeCredentialVault::for_binding(
  self : NodeCredentialVault,
  binding : NodeCredentialBinding,
) -> Result[NodeCredentialEntry, String] {
  let entries = match self.read_metadata() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let entry = match find_node_credential(entries, binding.profile) {
    Some(value) => value
    None =>
      return Err(
        node_credential_failure_message(
          @contracts.CREDENTIAL_REASON_MISSING,
          "profile is not enrolled on this node",
        ),
      )
  }
  if entry.state != @contracts.CREDENTIAL_STATE_ACTIVE {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_REVOKED,
        "node credential state=" + entry.state,
      ),
    )
  }
  if entry.version != binding.version ||
    entry.fingerprint != binding.fingerprint {
    return Err(
      node_credential_failure_message(
        @contracts.CREDENTIAL_REASON_BAD_STATE,
        "node credential version/fingerprint mismatch",
      ),
    )
  }
  Ok(entry)
}

///|
/// Lease renewal from the primary: metadata only. The node records the binding
/// and a fresh deadline, and refuses when its local copy has been rotated or
/// revoked.
async fn NodeCredentialVault::lease(
  self : NodeCredentialVault,
  binding : NodeCredentialBinding,
  lease_ttl_ms : Int64,
) -> Result[NodeCredentialEntry, String] {
  let entry = match self.for_binding(binding) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let ttl = if lease_ttl_ms > 0L {
    lease_ttl_ms
  } else {
    @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS
  }
  let now = @async.now()
  let updated = {
    ..entry,
    binding_id: binding.binding_id,
    agent_id: binding.agent_id,
    lease_expires_at: @contracts.format_rfc3339(now + ttl),
    last_lease_at: @contracts.format_rfc3339(now),
    updated_at: @contracts.format_rfc3339(now),
  }
  let entries = match self.read_metadata() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let next = entries.map(fn(item) {
    if item.profile == entry.profile {
      updated
    } else {
      item
    }
  })
  match self.write_metadata(next) {
    Ok(_) => Ok(updated)
    Err(message) => Err(message)
  }
}

///|
async fn NodeCredentialVault::secret_for(
  self : NodeCredentialVault,
  credential_id : String,
) -> Result[String, String] {
  match self.store.get(credential_id) {
    Ok(value) => Ok(value)
    Err(failure) =>
      Err(node_credential_failure_message(failure.reason, failure.detail))
  }
}

///|
/// Secret-free status document. Fingerprints and versions are metadata and
/// are safe to report; no secret or session token is included.
pub async fn NodeCredentialVault::status_json(
  self : NodeCredentialVault,
) -> @json.Json {
  let (store_ok, store_detail) = match self.store.check() {
    Ok(_) => (true, self.store.detail)
    Err(failure) => (false, failure.message())
  }
  let entries = match self.read_metadata() {
    Ok(value) => value
    _ => []
  }
  let reasons : Array[String] = []
  if !store_ok {
    reasons.push(@contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED)
  }
  let now = @async.now()
  for entry in entries {
    if entry.state == @contracts.CREDENTIAL_STATE_ACTIVE &&
      node_lease_expired(entry, now) {
      reasons.push(@contracts.CREDENTIAL_REASON_LEASE_EXPIRED)
    }
  }
  @contracts.json_object([
    ("enabled", @contracts.json_bool(true)),
    ("storage", @contracts.json_string(self.store.backend)),
    ("store_ok", @contracts.json_bool(store_ok)),
    ("store_detail", @contracts.json_string(store_detail)),
    (
      "profiles",
      @contracts.json_array(entries.map(fn(item) { item.to_json() })),
    ),
    ("reasons", @contracts.json_string_array(reasons)),
    ("checked_at", @contracts.json_string(@contracts.format_rfc3339(now))),
  ])
}

///|
pub fn node_random_token() -> String {
  let rand = @random.Rand::chacha8()
  let bytes : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  for index in 0..<32 {
    bytes.set(index, rand.int(limit=256).to_byte())
  }
  @hex.encode(Bytes::from_fixedarray(bytes).exact_view())
}

///|
/// Non-secret identity sent by the primary in `runtime.process.start`. The
/// secret never crosses the transport; only these fields bind the node's local
/// copy to the primary's binding.
pub(all) struct NodeCredentialBinding {
  binding_id : String
  credential_id : String
  machine_id : String
  agent_id : String
  profile : String
  version : Int32
  fingerprint : String
}

///|
fn node_credential_binding_from_params(
  params : Map[String, @json.Json],
) -> Result[NodeCredentialBinding?, @contracts.RpcError] {
  let value = match params.get("credential") {
    Some(value) => value
    None => return Ok(None)
  }
  let object = match @contracts.as_object(value) {
    Some(value) => value
    None => return Err(invalid_params("credential must be an object"))
  }
  let binding_id = @contracts.string_field_or(object, "binding_id", "")
  let credential_id = @contracts.string_field_or(object, "credential_id", "")
  let machine_id = @contracts.string_field_or(object, "machine_id", "")
  let agent_id = @contracts.string_field_or(object, "agent_id", "")
  let profile = @contracts.string_field_or(object, "profile", "")
  let version = @contracts.int_field_or(object, "version", 0)
  let fingerprint = @contracts.string_field_or(object, "fingerprint", "")
  if binding_id == "" ||
    machine_id == "" ||
    agent_id == "" ||
    !valid_node_credential_profile(profile) ||
    version <= 0 ||
    fingerprint == "" ||
    fingerprint.length() > NODE_CREDENTIAL_MAX_FINGERPRINT {
    return Err(invalid_params("credential marker is incomplete or invalid"))
  }
  Ok(
    Some({
      binding_id,
      credential_id,
      machine_id,
      agent_id,
      profile,
      version,
      fingerprint,
    }),
  )
}

///|
fn node_credential_rpc_error(
  reason : String,
  detail : String,
) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_HOST,
    node_credential_failure_message(reason, @contracts.redact_secrets(detail)),
    data=@contracts.json_object([("reason", @contracts.json_string(reason))]),
  )
}
