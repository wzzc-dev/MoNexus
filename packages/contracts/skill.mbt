///|
/// Skill packs (ADR-0015). These types are the wire and storage shape shared
/// by the host, the runtime node and the CLI. Skill bodies never travel in
/// events; records carry only names, versions, hashes and bounded metadata.
pub const SKILL_SCHEMA_VERSION : Int = 1

///|
pub const SKILL_MODE_AVAILABLE : String = "available"

///|
pub const SKILL_MODE_LOADED : String = "loaded"

///|
pub const SKILL_SCOPE_AGENT : String = "agent"

///|
pub const SKILL_SCOPE_TASK : String = "task"

///|
pub const SKILL_SCOPE_SESSION : String = "session"

///|
pub const SKILL_PERMISSION_WORKSPACE_READ : String = "workspace.read"

///|
pub const SKILL_PERMISSION_WORKSPACE_WRITE : String = "workspace.write"

///|
pub const SKILL_PERMISSION_GIT_READ : String = "git.read"

///|
pub const SKILL_PERMISSION_GIT_WRITE : String = "git.write"

///|
pub const SKILL_PERMISSION_EXEC_READONLY : String = "exec.readonly"

///|
pub const SKILL_PERMISSION_EXEC_WORKSPACE : String = "exec.workspace"

///|
pub const SKILL_ENTRY_MODE_READ_ONLY : String = "read_only"

///|
pub const SKILL_ENTRY_MODE_WRITE : String = "write"

///|
pub const SKILL_SOURCE_LOCAL_DIRECTORY : String = "local_directory"

///|
pub const SKILL_STATUS_PENDING : String = "pending"

///|
pub const SKILL_STATUS_ALLOWED : String = "allowed"

///|
pub const SKILL_STATUS_REVOKED : String = "revoked"

///|
pub const SKILL_STATUS_PENDING_DELETE : String = "pending_delete"

///|
pub const SKILL_SIGNATURE_ALG_ED25519 : String = "ed25519"

///|
pub const SKILL_INVOKE_TOOL : String = "skill.invoke"

///|
/// Fixed refusal/diagnostic reason codes. Nothing in an event may echo argv
/// values, skill bodies or command output.
pub const SKILL_ERR_DISABLED : String = "skill_disabled"

///|
pub const SKILL_ERR_INVALID_MANIFEST : String = "invalid_manifest"

///|
pub const SKILL_ERR_UNKNOWN_FIELD : String = "unknown_field"

///|
pub const SKILL_ERR_DUPLICATE_COMMAND : String = "duplicate_command_id"

///|
pub const SKILL_ERR_INVALID_NAME : String = "invalid_name"

///|
pub const SKILL_ERR_INVALID_VERSION : String = "invalid_version"

///|
pub const SKILL_ERR_INVALID_PERMISSION : String = "invalid_permission"

///|
pub const SKILL_ERR_INVALID_PATH : String = "invalid_path"

///|
pub const SKILL_ERR_UNSIGNED : String = "unsigned"

///|
pub const SKILL_ERR_UNKNOWN_KEY : String = "unknown_key"

///|
pub const SKILL_ERR_REVOKED_KEY : String = "revoked_key"

///|
pub const SKILL_ERR_BAD_SIGNATURE : String = "bad_signature"

///|
pub const SKILL_ERR_HASH_MISMATCH : String = "hash_mismatch"

///|
pub const SKILL_ERR_NOT_ALLOWLISTED : String = "not_allowlisted"

///|
pub const SKILL_ERR_PERMISSION_DENIED : String = "permission_denied"

///|
pub const SKILL_ERR_DEPENDENCY_MISSING : String = "dependency_missing"

///|
pub const SKILL_ERR_CONFLICT : String = "skill_conflict"

///|
pub const SKILL_ERR_LIMIT_EXCEEDED : String = "limit_exceeded"

///|
pub const SKILL_ERR_NOT_LOADED : String = "not_loaded"

///|
pub const SKILL_ERR_INVALID_ENTRY : String = "invalid_entry"

///|
pub const SKILL_ERR_PATH_ESCAPE : String = "path_escape"

///|
pub const SKILL_ERR_INTERPRETER_DENIED : String = "interpreter_denied"

///|
pub const SKILL_ERR_POLICY_DENIED : String = "policy_denied"

///|
pub const SKILL_ERR_CRITICAL : String = "critical_command"

///|
pub const SKILL_ERR_DECISION_DENIED : String = "decision_denied"

///|
pub const SKILL_ERR_TIMEOUT : String = "timeout"

///|
pub const SKILL_ERR_OUTPUT_LIMIT : String = "output_limit"

///|
pub const SKILL_ERR_GATEWAY_UNAVAILABLE : String = "gateway_unavailable"

///|
pub const METHOD_SKILL_IMPORT : String = "skill.import"

///|
pub const METHOD_SKILL_KEY_REGISTER : String = "skill.key.register"

///|
pub const METHOD_SKILL_KEY_REVOKE : String = "skill.key.revoke"

///|
pub const METHOD_SKILL_ALLOW : String = "skill.allow"

///|
pub const METHOD_SKILL_ALLOWLIST_REVOKE : String = "skill.allowlist.revoke"

///|
pub const METHOD_SKILL_ENABLE : String = "skill.enable"

///|
pub const METHOD_SKILL_DISABLE : String = "skill.disable"

///|
pub const METHOD_SKILL_UPGRADE : String = "skill.upgrade"

///|
pub const METHOD_SKILL_UNINSTALL : String = "skill.uninstall"

///|
pub const METHOD_SKILL_LIST : String = "skill.list"

///|
pub const METHOD_SKILL_GET : String = "skill.get"

///|
pub const METHOD_SKILL_DOCTOR : String = "skill.doctor"

///|
pub const METHOD_SKILL_PERMISSIONS_SET : String = "skill.permissions.set"

///|
pub const METHOD_SKILL_PERMISSIONS_GET : String = "skill.permissions.get"

///|
/// Gateway capability calls. `skill.invoke` is reached only by the host-owned
/// stdio MCP gateway with a session capability token; it is not an owner RPC
/// and is not listed with the owner methods above.
pub const METHOD_SKILL_INVOKE : String = "skill.invoke"

///|
pub const METHOD_SKILL_TOOLS : String = "skill.tools"

///|
/// Node-facing mirrored-skill transport methods (A4.2).
pub const METHOD_RUNTIME_SKILL_MIRROR : String = "runtime.skill.mirror"

///|
pub const METHOD_RUNTIME_SKILL_LIST : String = "runtime.skill.list"

///|
pub const METHOD_RUNTIME_SKILL_INVOKE : String = "runtime.skill.invoke"

///|
pub const METHOD_RUNTIME_SKILL_GC : String = "runtime.skill.gc"

///|
pub const EVENT_SKILL_IMPORTED : String = "skill.imported"

///|
pub const EVENT_SKILL_REFUSED : String = "skill.refused"

///|
pub const EVENT_SKILL_ALLOWLISTED : String = "skill.allowlisted"

///|
pub const EVENT_SKILL_ALLOWLIST_REVOKED : String = "skill.allowlist_revoked"

///|
pub const EVENT_SKILL_ENABLED : String = "skill.enabled"

///|
pub const EVENT_SKILL_DISABLED : String = "skill.disabled"

///|
pub const EVENT_SKILL_UPGRADED : String = "skill.upgraded"

///|
pub const EVENT_SKILL_LOADED : String = "skill.loaded"

///|
pub const EVENT_SKILL_INVOKED : String = "skill.invoked"

///|
pub const EVENT_SKILL_INVOKE_DENIED : String = "skill.invoke_denied"

///|
pub const EVENT_SKILL_UNINSTALLED : String = "skill.uninstalled"

///|
pub const EVENT_SKILL_CONTEXT_TRUNCATED : String = "skill.context_truncated"

///|
pub const EVENT_SKILL_MIRRORED : String = "skill.mirrored"

///|
pub const EVENT_SKILL_MIRROR_GC : String = "skill.mirror_gc"

///|
pub const DECISION_KIND_SKILL : String = "skill"

///|
/// Conservative default `agent.skill_permissions` (ADR-0015 §5.1).
pub fn default_skill_permissions() -> Array[String] {
  [
    SKILL_PERMISSION_WORKSPACE_READ,
    SKILL_PERMISSION_GIT_READ,
    SKILL_PERMISSION_EXEC_READONLY,
  ]
}

///|
pub fn skill_permission_valid(value : String) -> Bool {
  value == SKILL_PERMISSION_WORKSPACE_READ ||
  value == SKILL_PERMISSION_WORKSPACE_WRITE ||
  value == SKILL_PERMISSION_GIT_READ ||
  value == SKILL_PERMISSION_GIT_WRITE ||
  value == SKILL_PERMISSION_EXEC_READONLY ||
  value == SKILL_PERMISSION_EXEC_WORKSPACE
}

///|
pub fn skill_mode_valid(value : String) -> Bool {
  value == SKILL_MODE_AVAILABLE || value == SKILL_MODE_LOADED
}

///|
pub fn skill_scope_valid(value : String) -> Bool {
  value == SKILL_SCOPE_AGENT ||
  value == SKILL_SCOPE_TASK ||
  value == SKILL_SCOPE_SESSION
}

///|
pub fn skill_entry_mode_valid(value : String) -> Bool {
  value == SKILL_ENTRY_MODE_READ_ONLY || value == SKILL_ENTRY_MODE_WRITE
}

///|
/// Exact reference to one immutable skill bundle. No ranges or `latest`.
pub(all) struct SkillRef {
  name : String
  version : String
  content_hash : String
}

///|
pub fn SkillRef::new(
  name~ : String,
  version~ : String,
  content_hash~ : String,
) -> SkillRef {
  { name, version, content_hash }
}

///|
pub fn SkillRef::to_json(self : SkillRef) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("version", json_string(self.version)),
    ("content_hash", json_string(self.content_hash)),
  ])
}

///|
pub fn skill_ref_from_json(json : @json.Json) -> SkillRef? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let name = match string_field(object, "name") {
    Some(value) => value
    None => return None
  }
  let version = match string_field(object, "version") {
    Some(value) => value
    None => return None
  }
  let content_hash = match string_field(object, "content_hash") {
    Some(value) => value
    None => return None
  }
  Some({ name, version, content_hash })
}

///|
pub(all) struct SkillBinding {
  name : String
  version : String
  content_hash : String
  mode : String
}

///|
pub fn SkillBinding::new(
  name~ : String,
  version~ : String,
  content_hash~ : String,
  mode~ : String = SKILL_MODE_LOADED,
) -> SkillBinding {
  { name, version, content_hash, mode }
}

///|
pub fn SkillBinding::to_json(self : SkillBinding) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("version", json_string(self.version)),
    ("content_hash", json_string(self.content_hash)),
    ("mode", json_string(self.mode)),
  ])
}

///|
pub fn skill_binding_from_json(json : @json.Json) -> SkillBinding? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let name = match string_field(object, "name") {
    Some(value) => value
    None => return None
  }
  let version = match string_field(object, "version") {
    Some(value) => value
    None => return None
  }
  let content_hash = match string_field(object, "content_hash") {
    Some(value) => value
    None => return None
  }
  let mode = string_field_or(object, "mode", SKILL_MODE_LOADED)
  Some({ name, version, content_hash, mode })
}

///|
pub fn skill_bindings_from_json(json : @json.Json) -> Array[SkillBinding] {
  let out : Array[SkillBinding] = []
  match json {
    @json.Json::Array(items) =>
      for item in items {
        match skill_binding_from_json(item) {
          Some(value) => out.push(value)
          None => ()
        }
      }
    _ => ()
  }
  out
}

///|
pub(all) struct SkillResource {
  path : String
  description : String
}

///|
pub(all) struct SkillCommand {
  id : String
  argv : Array[String]
  mode : String
  timeout_ms : Int
  max_output_bytes : Int
}

///|
pub(all) struct SkillDependency {
  kind : String
  name : String
  version : String
  content_hash : String
}

///|
pub(all) struct SkillSource {
  kind : String
  path : String
  author : String
  created_at : String
}

///|
pub(all) struct SkillSignature {
  key_id : String
  alg : String
  sig : String
}

///|
pub(all) struct SkillLimits {
  max_runtime_ms : Int
  max_output_bytes : Int
}

///|
pub(all) struct SkillManifest {
  schema_version : Int
  name : String
  version : String
  description : String
  permissions : Array[String]
  entry_path : String
  entry_max_bytes : Int
  resources : Array[SkillResource]
  commands : Array[SkillCommand]
  dependencies : Array[SkillDependency]
  source : SkillSource
  content_hash : String
  signature : SkillSignature
  limits : SkillLimits
}

///|
/// One entry in a frozen per-session snapshot. Only metadata and an entry
/// hash are persisted; the entry body is materialised on disk for the session.
pub(all) struct SkillSnapshotEntry {
  name : String
  version : String
  content_hash : String
  scope : String
  mode : String
  entry_sha256 : String
  entry_ids : Array[String]
}

///|
pub fn SkillSnapshotEntry::to_json(self : SkillSnapshotEntry) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("version", json_string(self.version)),
    ("content_hash", json_string(self.content_hash)),
    ("scope", json_string(self.scope)),
    ("mode", json_string(self.mode)),
    ("entry_sha256", json_string(self.entry_sha256)),
    ("entry_ids", json_string_array(self.entry_ids)),
  ])
}

///|
pub fn skill_snapshot_entry_from_json(json : @json.Json) -> SkillSnapshotEntry? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let name = match string_field(object, "name") {
    Some(value) => value
    None => return None
  }
  let version = match string_field(object, "version") {
    Some(value) => value
    None => return None
  }
  let content_hash = match string_field(object, "content_hash") {
    Some(value) => value
    None => return None
  }
  Some({
    name,
    version,
    content_hash,
    scope: string_field_or(object, "scope", SKILL_SCOPE_SESSION),
    mode: string_field_or(object, "mode", SKILL_MODE_LOADED),
    entry_sha256: string_field_or(object, "entry_sha256", ""),
    entry_ids: string_array_field(object, "entry_ids"),
  })
}

///|
pub fn skill_snapshot_from_json(json : @json.Json) -> Array[SkillSnapshotEntry] {
  let out : Array[SkillSnapshotEntry] = []
  match json {
    @json.Json::Array(items) =>
      for item in items {
        match skill_snapshot_entry_from_json(item) {
          Some(value) => out.push(value)
          None => ()
        }
      }
    _ => ()
  }
  out
}

///|
pub fn skill_snapshot_to_json(
  entries : Array[SkillSnapshotEntry],
) -> @json.Json {
  json_array(entries.map(fn(entry) { entry.to_json() }))
}

///|
pub(all) struct SkillImportResult {
  name : String
  version : String
  content_hash : String
  key_id : String
  file_count : Int
  total_bytes : Int
  status : String
}

///|
pub fn SkillImportResult::new(
  name~ : String,
  version~ : String,
  content_hash~ : String,
  key_id~ : String,
  file_count~ : Int,
  total_bytes~ : Int,
  status~ : String,
) -> SkillImportResult {
  { name, version, content_hash, key_id, file_count, total_bytes, status }
}

///|
pub fn SkillImportResult::to_json(self : SkillImportResult) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("version", json_string(self.version)),
    ("content_hash", json_string(self.content_hash)),
    ("key_id", json_string(self.key_id)),
    ("file_count", json_int(self.file_count)),
    ("total_bytes", json_int(self.total_bytes)),
    ("status", json_string(self.status)),
  ])
}

///|
pub(all) struct SkillInvocationResult {
  name : String
  version : String
  content_hash : String
  entry_id : String
  exit_code : Int
  output : String
  truncated : Bool
  decision_id : String
  run_id : String
}

///|
pub fn SkillInvocationResult::new(
  name~ : String,
  version~ : String,
  content_hash~ : String,
  entry_id~ : String,
  exit_code~ : Int,
  output~ : String,
  truncated~ : Bool,
  decision_id~ : String,
  run_id~ : String,
) -> SkillInvocationResult {
  {
    name,
    version,
    content_hash,
    entry_id,
    exit_code,
    output,
    truncated,
    decision_id,
    run_id,
  }
}

///|
pub fn SkillInvocationResult::to_json(
  self : SkillInvocationResult,
) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("version", json_string(self.version)),
    ("content_hash", json_string(self.content_hash)),
    ("entry_id", json_string(self.entry_id)),
    ("exit_code", json_int(self.exit_code)),
    ("output", json_string(self.output)),
    ("truncated", json_bool(self.truncated)),
    ("decision_id", json_string(self.decision_id)),
    ("run_id", json_string(self.run_id)),
  ])
}

// ---------------------------------------------------------------------------
// RPC parameter helpers
// ---------------------------------------------------------------------------

///|
/// Strictly parse an optional `skills` array. Returns `None` when the field is
/// present but not an array of complete exact bindings, so the caller can
/// refuse the whole request instead of silently dropping a binding.
pub fn skill_bindings_param(
  params : Map[String, @json.Json],
) -> Array[SkillBinding]? {
  match params.get("skills") {
    None => Some([])
    Some(@json.Json::Array(items)) => {
      let out : Array[SkillBinding] = []
      if items.length() > 64 {
        return None
      }
      for item in items {
        let binding = match skill_binding_from_json(item) {
          Some(value) => value
          None => return None
        }
        if !skill_name_valid(binding.name) ||
          !skill_version_valid(binding.version) ||
          !skill_content_hash_valid(binding.content_hash) ||
          !skill_mode_valid(binding.mode) {
          return None
        }
        out.push(binding)
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn skill_name_valid(value : String) -> Bool {
  if value.length() == 0 || value.length() > 64 {
    return false
  }
  for index in 0..<value.length() {
    let ch = match value.get_char(index) {
      Some(found) => found
      None => return false
    }
    let code = ch.to_int()
    let allowed = (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 45 ||
      code == 95 ||
      code == 46
    if !allowed {
      return false
    }
  }
  true
}

///|
fn skill_version_valid(value : String) -> Bool {
  if value.length() == 0 || value.length() > 64 {
    return false
  }
  for index in 0..<value.length() {
    let ch = match value.get_char(index) {
      Some(found) => found
      None => return false
    }
    let code = ch.to_int()
    let allowed = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 43
    if !allowed {
      return false
    }
  }
  true
}

///|
fn skill_content_hash_valid(value : String) -> Bool {
  if value.length() != 71 || !value.has_prefix("sha256:") {
    return false
  }
  for ch in value[7:].to_owned() {
    let code = ch.to_int()
    let hex = (code >= 48 && code <= 57) || (code >= 97 && code <= 102)
    if !hex {
      return false
    }
  }
  true
}

///|
pub fn skill_import_params(
  client_request_id : String,
  path : String,
  source~ : String = "local_directory",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("path", json_string(path)),
    ("source", json_string(source)),
  ])
}

///|
pub fn skill_key_register_params(
  client_request_id : String,
  key_id : String,
  public_key : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("key_id", json_string(key_id)),
    ("public_key", json_string(public_key)),
  ])
}

///|
pub fn skill_key_revoke_params(
  client_request_id : String,
  key_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("key_id", json_string(key_id)),
  ])
}

///|
pub fn skill_ref_params(
  client_request_id : String,
  name : String,
  version : String,
  content_hash : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("name", json_string(name)),
    ("version", json_string(version)),
    ("content_hash", json_string(content_hash)),
  ])
}

///|
pub fn skill_enable_params(
  client_request_id : String,
  scope : String,
  scope_ref : String,
  binding : SkillBinding,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("scope", json_string(scope)),
    ("scope_ref", json_string(scope_ref)),
    ("name", json_string(binding.name)),
    ("version", json_string(binding.version)),
    ("content_hash", json_string(binding.content_hash)),
    ("mode", json_string(binding.mode)),
  ])
}

///|
pub fn skill_list_params(
  client_request_id : String,
  scope~ : String = "",
  scope_ref~ : String = "",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("scope", json_string(scope)),
    ("scope_ref", json_string(scope_ref)),
  ])
}

///|
/// The skill gateway accepts only the session capability and the entry id; the
/// session id and any command/argv fields are never client-supplied.
pub fn skill_invoke_params(
  token : String,
  entry_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("token", json_string(token)),
    ("entry_id", json_string(entry_id)),
  ])
}

///|
pub fn skill_tools_params(token : String) -> Map[String, @json.Json] {
  Map([("token", json_string(token))])
}

///|
pub fn skill_permissions_set_params(
  client_request_id : String,
  agent_id : String,
  permissions : Array[String],
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
    ("permissions", json_string_array(permissions)),
  ])
}

///|
pub fn skill_permissions_get_params(
  client_request_id : String,
  agent_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
  ])
}
