///|
/// Managed account credentials (A5, ADR-0016).
///
/// The contract is deliberately metadata-first: a `CredentialRecord` carries a
/// fingerprint, version and state, never the secret. The secret itself lives
/// only in the platform `CredentialStore` on the machine that owns the
/// account. For a remote Agent the owning machine is the runtime node, which
/// registers and stores the secret locally; the primary keeps metadata only
/// and never receives, forwards or persists model keys.
///
/// The proxy hand-off is a short-lived capability token (`mxp_...`): the Agent
/// child gets `MONEXUS_CREDENTIAL_PROXY_URL` plus that token, never the
/// upstream credential. The token is the only credential-shaped value that
/// reaches an Agent process, and it expires with the Agent session.

// ---------------------------------------------------------------------------
// RPC methods
// ---------------------------------------------------------------------------

///|
pub const METHOD_CREDENTIAL_ENROLL : String = "credential.enroll"

///|
pub const METHOD_CREDENTIAL_BINDING_CREATE : String = "credential.binding.create"

///|
pub const METHOD_CREDENTIAL_BINDING_LIST : String = "credential.binding.list"

///|
pub const METHOD_CREDENTIAL_BINDING_UNBIND : String = "credential.binding.unbind"

///|
pub const METHOD_CREDENTIAL_ROTATE : String = "credential.rotate"

///|
pub const METHOD_CREDENTIAL_REVOKE : String = "credential.revoke"

///|
pub const METHOD_CREDENTIAL_DELETE : String = "credential.delete"

///|
pub const METHOD_CREDENTIAL_STATUS : String = "credential.status"

///|
pub const METHOD_CREDENTIAL_DOCTOR : String = "credential.doctor"

///|
pub fn credential_methods() -> Array[String] {
  [
    METHOD_CREDENTIAL_ENROLL,
    METHOD_CREDENTIAL_BINDING_CREATE,
    METHOD_CREDENTIAL_BINDING_LIST,
    METHOD_CREDENTIAL_BINDING_UNBIND,
    METHOD_CREDENTIAL_ROTATE,
    METHOD_CREDENTIAL_REVOKE,
    METHOD_CREDENTIAL_DELETE,
    METHOD_CREDENTIAL_STATUS,
    METHOD_CREDENTIAL_DOCTOR,
  ]
}

// ---------------------------------------------------------------------------
// Node-local runtime methods (metadata and control only, never a secret)
// ---------------------------------------------------------------------------

///|
pub const METHOD_RUNTIME_CREDENTIAL_STATUS : String = "runtime.credential.status"

///|
pub const METHOD_RUNTIME_CREDENTIAL_ENROLL : String = "runtime.credential.enroll"

///|
pub const METHOD_RUNTIME_CREDENTIAL_LEASE : String = "runtime.credential.lease"

///|
pub const METHOD_RUNTIME_CREDENTIAL_REVOKE : String = "runtime.credential.revoke"

///|
pub fn runtime_credential_methods() -> Array[String] {
  [
    METHOD_RUNTIME_CREDENTIAL_STATUS,
    METHOD_RUNTIME_CREDENTIAL_ENROLL,
    METHOD_RUNTIME_CREDENTIAL_LEASE,
    METHOD_RUNTIME_CREDENTIAL_REVOKE,
  ]
}

///|
/// The subset the primary may call over the paired transport. `enroll` is
/// deliberately absent: node-local registration happens on the node itself
/// (CLI or node-local API) and the primary never sends a secret. Status,
/// lease and revoke are metadata/control signals only.
pub fn runtime_credential_control_methods() -> Array[String] {
  [
    METHOD_RUNTIME_CREDENTIAL_STATUS,
    METHOD_RUNTIME_CREDENTIAL_LEASE,
    METHOD_RUNTIME_CREDENTIAL_REVOKE,
  ]
}

// ---------------------------------------------------------------------------
// Events and audit
// ---------------------------------------------------------------------------

///|
pub const EVENT_CREDENTIAL_ENROLLED : String = "credential.enrolled"

///|
pub const EVENT_CREDENTIAL_BOUND : String = "credential.bound"

///|
pub const EVENT_CREDENTIAL_UNBOUND : String = "credential.unbound"

///|
pub const EVENT_CREDENTIAL_ROTATED : String = "credential.rotated"

///|
pub const EVENT_CREDENTIAL_REVOKED : String = "credential.revoked"

///|
pub const EVENT_CREDENTIAL_DELETED : String = "credential.deleted"

///|
pub const EVENT_CREDENTIAL_DELIVERED : String = "credential.delivered"

///|
pub const EVENT_CREDENTIAL_DELIVERY_FAILED : String = "credential.delivery_failed"

///|
pub const EVENT_CREDENTIAL_PROXY_OPENED : String = "credential.proxy.opened"

///|
pub const EVENT_CREDENTIAL_PROXY_CLOSED : String = "credential.proxy.closed"

///|
pub const EVENT_CREDENTIAL_PROXY_DENIED : String = "credential.proxy.denied"

///|
pub const EVENT_CREDENTIAL_READINESS_FAILED : String = "credential.readiness.failed"

///|
pub const EVENT_CREDENTIAL_READINESS_SUPPRESSED : String = "credential.readiness.suppressed"

///|
pub const EVENT_CREDENTIAL_LEASE_EXPIRED : String = "credential.lease.expired"

// ---------------------------------------------------------------------------
// Kinds, states, storage backends
// ---------------------------------------------------------------------------

///|
pub const CREDENTIAL_KIND_API_KEY : String = "api_key"

///|
pub const CREDENTIAL_KIND_BEARER_TOKEN : String = "bearer_token"

///|
pub const CREDENTIAL_STATE_ACTIVE : String = "active"

///|
pub const CREDENTIAL_STATE_PENDING_ENROLLMENT : String = "pending_enrollment"

///|
pub const CREDENTIAL_STATE_REVOKED : String = "revoked"

///|
pub const CREDENTIAL_STATE_REVOCATION_PENDING : String = "revocation_pending"

///|
pub const CREDENTIAL_STATE_DELETED : String = "deleted"

///|
/// A binding that the owner removed. The credential itself stays enrolled.
pub const CREDENTIAL_STATE_UNBOUND : String = "unbound"

///|
pub const CREDENTIAL_STORAGE_KEYCHAIN : String = "keychain"

///|
pub const CREDENTIAL_STORAGE_FILE : String = "file"

///|
pub const CREDENTIAL_STORAGE_UNSUPPORTED : String = "unsupported"

///|
pub const CREDENTIAL_OWNER_HOST : String = "host"

///|
pub const CREDENTIAL_OWNER_NODE : String = "node"

// ---------------------------------------------------------------------------
// Fixed readiness/error reasons (ADR-0016 §6)
// ---------------------------------------------------------------------------

///|
pub const CREDENTIAL_REASON_MISSING : String = "credential_missing"

///|
pub const CREDENTIAL_REASON_REVOKED : String = "credential_revoked"

///|
pub const CREDENTIAL_REASON_LOCKED : String = "credential_locked"

///|
pub const CREDENTIAL_REASON_STORE_PERMISSIONS : String = "credential_store_bad_permissions"

///|
pub const CREDENTIAL_REASON_PROXY_UNAVAILABLE : String = "credential_proxy_unavailable"

///|
pub const CREDENTIAL_REASON_PROXY_UNSUPPORTED : String = "credential_proxy_unsupported"

///|
pub const CREDENTIAL_REASON_DELIVERY_FAILED : String = "credential_delivery_failed"

///|
pub const CREDENTIAL_REASON_LEASE_EXPIRED : String = "credential_lease_expired"

///|
pub const CREDENTIAL_REASON_REUSED : String = "credential_reused"

///|
pub const CREDENTIAL_REASON_DISABLED : String = "credential_disabled"

///|
pub const CREDENTIAL_REASON_NOT_FOUND : String = "credential_not_found"

///|
pub const CREDENTIAL_REASON_BINDING_CONFLICT : String = "credential_binding_conflict"

///|
pub const CREDENTIAL_REASON_MACHINE_MISMATCH : String = "credential_machine_mismatch"

///|
pub const CREDENTIAL_REASON_SECRET_REQUIRED : String = "credential_secret_required"

///|
pub const CREDENTIAL_REASON_SECRET_INVALID : String = "credential_secret_invalid"

///|
pub const CREDENTIAL_REASON_BAD_STATE : String = "credential_bad_state"

// ---------------------------------------------------------------------------
// Environment hand-off
// ---------------------------------------------------------------------------

///|
pub const CREDENTIAL_ENV_PROXY_URL : String = "MONEXUS_CREDENTIAL_PROXY_URL"

///|
pub const CREDENTIAL_ENV_PROXY_TOKEN : String = "MONEXUS_CREDENTIAL_PROXY_TOKEN"

///|
/// Short-lived proxy capability token prefix.
pub const CREDENTIAL_TOKEN_PREFIX : String = "mxp_"

///|
/// Node-local machine session prefix; reserved for node-side lease tokens so a
/// leaked host token and a leaked node token are distinguishable in tests.
pub const CREDENTIAL_NODE_TOKEN_PREFIX : String = "mxs_"

///|
/// Config keys. `credential.enabled` defaults to false: V0.1 behavior is
/// untouched until an owner opts in.
pub const CREDENTIAL_CONFIG_ENABLED : String = "credential.enabled"

///|
pub const CREDENTIAL_CONFIG_STORAGE : String = "credential.storage"

///|
pub const CREDENTIAL_CONFIG_LEASE_TTL_MS : String = "credential.lease_ttl_ms"

///|
pub const CREDENTIAL_CONFIG_COOLDOWN_MS : String = "credential.cooldown_ms"

///|
pub const CREDENTIAL_DEFAULT_LEASE_TTL_MS : Int64 = 900_000L

///|
pub const CREDENTIAL_DEFAULT_COOLDOWN_MS : Int64 = 600_000L

///|
pub const CREDENTIAL_FINGERPRINT_DOMAIN : String = "monexus.credential.fingerprint.v1\n"

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

///|
/// How to reach the fixed upstream and how to authenticate to it. The profile
/// is metadata: host, path prefix, header name and scheme, no secret. The
/// proxy refuses any request whose target host/path does not match the
/// profile, so an Agent cannot turn the proxy into an open relay.
pub(all) struct CredentialProfile {
  name : String
  upstream_scheme : String
  upstream_host : String
  upstream_base_path : String
  auth_header : String
  auth_scheme : String
  env_url : String
  env_token : String
}

///|
pub fn CredentialProfile::new(
  name~ : String,
  upstream_scheme~ : String = "https",
  upstream_host~ : String,
  upstream_base_path~ : String = "",
  auth_header~ : String = "authorization",
  auth_scheme~ : String = "Bearer",
  env_url~ : String = CREDENTIAL_ENV_PROXY_URL,
  env_token~ : String = CREDENTIAL_ENV_PROXY_TOKEN,
) -> CredentialProfile {
  {
    name,
    upstream_scheme,
    upstream_host,
    upstream_base_path,
    auth_header,
    auth_scheme,
    env_url,
    env_token,
  }
}

///|
/// Built-in profiles keep the proxy fixed without per-deployment config.
/// `custom` requires an explicit profile created through `credential.profile.*`
/// (A5.3 extension); A5.1 ships `anthropic` and `openai`.
pub fn CredentialProfile::builtin(name : String) -> CredentialProfile? {
  if name == "anthropic" {
    return Some(
      CredentialProfile::new(
        name~,
        upstream_host="api.anthropic.com",
        upstream_base_path="/v1",
        auth_header="x-api-key",
        auth_scheme="",
      ),
    )
  }
  if name == "openai" {
    return Some(
      CredentialProfile::new(
        name~,
        upstream_host="api.openai.com",
        upstream_base_path="/v1",
        auth_header="authorization",
        auth_scheme="Bearer",
      ),
    )
  }
  if name == "openrouter" {
    return Some(
      CredentialProfile::new(
        name~,
        upstream_host="openrouter.ai",
        upstream_base_path="/api/v1",
        auth_header="authorization",
        auth_scheme="Bearer",
      ),
    )
  }
  None
}

///|
pub fn CredentialProfile::to_json(self : CredentialProfile) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("upstream_scheme", json_string(self.upstream_scheme)),
    ("upstream_host", json_string(self.upstream_host)),
    ("upstream_base_path", json_string(self.upstream_base_path)),
    ("auth_header", json_string(self.auth_header)),
    ("auth_scheme", json_string(self.auth_scheme)),
    ("env_url", json_string(self.env_url)),
    ("env_token", json_string(self.env_token)),
  ])
}

///|
pub fn credential_profile_from_json(json : @json.Json) -> CredentialProfile? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let name = string_field_or(object, "name", "")
  if name == "" {
    return None
  }
  Some({
    name,
    upstream_scheme: string_field_or(object, "upstream_scheme", "https"),
    upstream_host: string_field_or(object, "upstream_host", ""),
    upstream_base_path: string_field_or(object, "upstream_base_path", ""),
    auth_header: string_field_or(object, "auth_header", "authorization"),
    auth_scheme: string_field_or(object, "auth_scheme", "Bearer"),
    env_url: string_field_or(object, "env_url", CREDENTIAL_ENV_PROXY_URL),
    env_token: string_field_or(object, "env_token", CREDENTIAL_ENV_PROXY_TOKEN),
  })
}

///|
/// Metadata for one managed credential. `fingerprint` is a domain-separated
/// SHA-256 of the secret; it is not reversible and is safe to persist.
pub(all) struct CredentialRecord {
  id : String
  kind : String
  storage : String
  owner : String
  state : String
  version : Int32
  fingerprint : String
  created_at : String
  rotated_at : String
}

///|
pub fn CredentialRecord::new(
  id~ : String,
  kind~ : String,
  storage~ : String,
  owner~ : String,
  version~ : Int32,
  fingerprint~ : String,
  created_at~ : String,
) -> CredentialRecord {
  {
    id,
    kind,
    storage,
    owner,
    state: CREDENTIAL_STATE_ACTIVE,
    version,
    fingerprint,
    created_at,
    rotated_at: "",
  }
}

///|
pub fn CredentialRecord::to_json(self : CredentialRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("kind", json_string(self.kind)),
    ("storage", json_string(self.storage)),
    ("owner", json_string(self.owner)),
    ("state", json_string(self.state)),
    ("version", json_int(self.version)),
    ("fingerprint", json_string(self.fingerprint)),
    ("created_at", json_string(self.created_at)),
    ("rotated_at", json_string(self.rotated_at)),
  ])
}

///|
pub fn credential_record_from_json(json : @json.Json) -> CredentialRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) if value != "" => value
    _ => return None
  }
  Some({
    id,
    kind: string_field_or(object, "kind", CREDENTIAL_KIND_API_KEY),
    storage: string_field_or(object, "storage", CREDENTIAL_STORAGE_FILE),
    owner: string_field_or(object, "owner", CREDENTIAL_OWNER_HOST),
    state: string_field_or(object, "state", CREDENTIAL_STATE_ACTIVE),
    version: int_field_or(object, "version", 1),
    fingerprint: string_field_or(object, "fingerprint", ""),
    created_at: string_field_or(object, "created_at", ""),
    rotated_at: string_field_or(object, "rotated_at", ""),
  })
}

///|
/// One `(machine, agent, profile)` binding. For a remote binding the primary
/// row is a metadata mirror: `fingerprint` and `version` are reported by the
/// node, and `last_seen_at`/`lease_expires_at` come from the lease renewal.
/// The secret is never part of this record and never reaches the primary.
pub(all) struct CredentialBinding {
  id : String
  credential_id : String
  machine_id : String
  agent_id : String
  profile : String
  state : String
  version : Int32
  fingerprint : String
  created_at : String
  updated_at : String
  last_seen_at : String
  lease_expires_at : String
}

///|
pub fn CredentialBinding::new(
  id~ : String,
  credential_id~ : String,
  machine_id~ : String,
  agent_id~ : String,
  profile~ : String,
  version~ : Int32,
  fingerprint~ : String,
  created_at~ : String,
) -> CredentialBinding {
  {
    id,
    credential_id,
    machine_id,
    agent_id,
    profile,
    state: CREDENTIAL_STATE_ACTIVE,
    version,
    fingerprint,
    created_at,
    updated_at: created_at,
    last_seen_at: created_at,
    lease_expires_at: "",
  }
}

///|
pub fn CredentialBinding::to_json(self : CredentialBinding) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("credential_id", json_string(self.credential_id)),
    ("machine_id", json_string(self.machine_id)),
    ("agent_id", json_string(self.agent_id)),
    ("profile", json_string(self.profile)),
    ("state", json_string(self.state)),
    ("version", json_int(self.version)),
    ("fingerprint", json_string(self.fingerprint)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
    ("last_seen_at", json_string(self.last_seen_at)),
    ("lease_expires_at", json_string(self.lease_expires_at)),
  ])
}

///|
pub fn credential_binding_from_json(json : @json.Json) -> CredentialBinding? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) if value != "" => Some(value)
    _ => None
  }
  let binding_id = match id {
    Some(value) => value
    None =>
      match string_field(object, "binding_id") {
        Some(value) if value != "" => value
        _ => return None
      }
  }
  Some({
    id: binding_id,
    credential_id: string_field_or(object, "credential_id", ""),
    machine_id: string_field_or(object, "machine_id", ""),
    agent_id: string_field_or(object, "agent_id", ""),
    profile: string_field_or(object, "profile", ""),
    state: string_field_or(object, "state", CREDENTIAL_STATE_ACTIVE),
    version: int_field_or(object, "version", 0),
    fingerprint: string_field_or(object, "fingerprint", ""),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    last_seen_at: string_field_or(object, "last_seen_at", ""),
    lease_expires_at: string_field_or(object, "lease_expires_at", ""),
  })
}

///|
/// A single doctor check. `detail` is a fixed, secret-free explanation.
pub(all) struct CredentialCheck {
  name : String
  ok : Bool
  detail : String
}

///|
pub fn CredentialCheck::to_json(self : CredentialCheck) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("ok", json_bool(self.ok)),
    ("detail", json_string(self.detail)),
  ])
}

///|
pub fn CredentialStatus::to_json(self : CredentialStatus) -> @json.Json {
  let credentials = json_array(
    self.credentials.map(fn(item) { item.to_json() }),
  )
  let bindings = json_array(self.bindings.map(fn(item) { item.to_json() }))
  json_object([
    ("enabled", json_bool(self.enabled)),
    ("storage", json_string(self.storage)),
    ("store_ok", json_bool(self.store_ok)),
    ("store_detail", json_string(self.store_detail)),
    ("credentials", credentials),
    ("bindings", bindings),
    ("reasons", json_string_array(self.reasons)),
    ("checked_at", json_string(self.checked_at)),
  ])
}

///|
/// Secret-free status of the credential subsystem. This is what
/// `credential.status` returns and what a remote binding mirror exposes.
pub(all) struct CredentialStatus {
  enabled : Bool
  storage : String
  store_ok : Bool
  store_detail : String
  credentials : Array[CredentialRecord]
  bindings : Array[CredentialBinding]
  reasons : Array[String]
  checked_at : String
}

///|
pub fn CredentialDoctorReport::to_json(
  self : CredentialDoctorReport,
) -> @json.Json {
  let checks = json_array(self.checks.map(fn(item) { item.to_json() }))
  json_object([
    ("ok", json_bool(self.ok)),
    ("storage", json_string(self.storage)),
    ("checks", checks),
    ("reasons", json_string_array(self.reasons)),
    ("checked_at", json_string(self.checked_at)),
  ])
}

///|
pub(all) struct CredentialDoctorReport {
  ok : Bool
  storage : String
  checks : Array[CredentialCheck]
  reasons : Array[String]
  checked_at : String
}

///|
/// `agent.start` names one credential profile explicitly. Empty means "the one
/// active binding for this machine and agent" (see host credential prep).
pub fn credential_profile_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "credential_profile", "").trim().to_owned()
}

///|
/// Node-local enrollment names the profile and reads the secret from a 0600
/// file path given by the operator; the secret itself is never argv.
pub fn credential_secret_file_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "secret_file", "").trim().to_owned()
}
