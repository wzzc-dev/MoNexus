///|
/// Machine RPC and event contracts (M2).
///
/// A machine is a registered SSH target plus the last observed profile. The
/// host owns the record (SQLite), probes it through the system `ssh` client and
/// publishes `machine.*` events. The desktop only renders this projection.

///|
pub const METHOD_MACHINE_ADD : String = "machine.add"

///|
pub const METHOD_MACHINE_PROBE : String = "machine.probe"

///|
pub const METHOD_MACHINE_REMOVE : String = "machine.remove"

///|
pub const METHOD_MACHINE_LIST : String = "machine.list"

///|
pub const EVENT_MACHINE_REGISTERED : String = "machine.registered"

///|
pub const EVENT_MACHINE_PROBED : String = "machine.probed"

///|
pub const EVENT_MACHINE_CONNECTED : String = "machine.connected"

///|
pub const EVENT_MACHINE_DISCONNECTED : String = "machine.disconnected"

///|
/// Tombstone event for `machine.remove` (architecture R4: no physical
/// cascade delete; replay uses this event to drop the machine from the
/// projection).
pub const EVENT_MACHINE_REMOVED : String = "machine.removed"

///|
pub const MACHINE_KIND_SSH : String = "ssh"

///|
pub const MACHINE_STATUS_UNKNOWN : String = "unknown"

///|
pub const MACHINE_STATUS_ONLINE : String = "online"

///|
pub const MACHINE_STATUS_OFFLINE : String = "offline"

///|
pub const MACHINE_STATUS_DEGRADED : String = "degraded"

///|
/// Host-key verification policies accepted by `machine.add`.
pub const MACHINE_HOST_KEY_POLICY_ACCEPT_NEW : String = "accept-new"

///|
pub const MACHINE_HOST_KEY_POLICY_STRICT : String = "yes"

///|
pub const MACHINE_HOST_KEY_POLICY_INSECURE : String = "no"

///|
pub const MACHINE_HOST_KEY_POLICY_CONFIG : String = "config"

///|
/// Readable machine error categories. The host maps provider failures onto
/// these so the desktop can show `Unauthorized`, `Timeout`, `NotFound`, ...,
/// instead of a raw ssh exit code.
pub const MACHINE_ERR_UNAUTHORIZED : String = "unauthorized"

///|
pub const MACHINE_ERR_TIMEOUT : String = "timeout"

///|
pub const MACHINE_ERR_NOT_FOUND : String = "not_found"

///|
pub const MACHINE_ERR_UNREACHABLE : String = "unreachable"

///|
pub const MACHINE_ERR_HOST_KEY : String = "host_key"

///|
pub const MACHINE_ERR_REMOTE : String = "remote"

///|
pub const MACHINE_ERR_INVALID : String = "invalid"

///|
pub const MACHINE_ERR_INTERNAL : String = "internal"

///|
pub fn machine_error_label(kind : String) -> String {
  match kind {
    "unauthorized" => "Unauthorized"
    "timeout" => "Timeout"
    "not_found" => "NotFound"
    "unreachable" => "Unreachable"
    "host_key" => "HostKeyRejected"
    "remote" => "RemoteError"
    "invalid" => "InvalidRequest"
    _ => "Internal"
  }
}

///|
/// Build the JSON-RPC error for a machine operation. `message` stays short and
/// human-readable; `detail` carries provider stderr or the database failure.
pub fn machine_error(
  kind : String,
  message : String,
  detail? : String,
) -> RpcError {
  let entries : Array[(String, @json.Json)] = [
    ("kind", json_string(kind)),
    ("reason", json_string(message)),
  ]
  match detail {
    Some(value) =>
      if value.trim() != "" {
        entries.push(("detail", json_string(value)))
      }
    None => ()
  }
  RpcError::new(
    ERR_HOST,
    machine_error_label(kind) + ": " + message,
    data=json_object(entries),
  )
}

///|
/// Readable one-line text for a machine RPC error: the label + reason, plus
/// the first line of provider detail when the host supplied one. UIs and the
/// CLI show this instead of a raw ssh exit code or stderr dump.
pub fn machine_error_text(error : RpcError) -> String {
  let base = error.message
  let detail = match error.data {
    Some(@json.Json::Object(object)) =>
      match string_field(object, "detail") {
        Some(value) => value
        None => ""
      }
    _ => ""
  }
  if detail.trim() == "" {
    return base
  }
  let first_line = match detail.split_once("\n") {
    Some((line, _)) => line.to_owned()
    None => detail
  }
  base + " (" + first_line.trim().to_owned() + ")"
}

///|
/// A machine profile as declared by architecture §6.1. `probe` fills every
/// field it can prove; anything it cannot observe stays empty/false.
pub(all) struct MachineProfile {
  arch : String
  os : String
  hostname : String
  shell : String
  toolchains : Map[String, String]
  has_docker : Bool
  has_gui : Bool
  max_parallel : Int
  notes : String
}

///|
pub fn MachineProfile::new(
  arch~ : String = "",
  os~ : String = "",
  hostname~ : String = "",
  shell~ : String = "",
  toolchains~ : Map[String, String] = Map([]),
  has_docker~ : Bool = false,
  has_gui~ : Bool = false,
  max_parallel~ : Int = 4,
  notes~ : String = "",
) -> MachineProfile {
  {
    arch,
    os,
    hostname,
    shell,
    toolchains,
    has_docker,
    has_gui,
    max_parallel,
    notes,
  }
}

///|
pub fn MachineProfile::to_json(self : MachineProfile) -> @json.Json {
  let tools : Array[(String, @json.Json)] = []
  for name, path in self.toolchains {
    tools.push((name, json_string(path)))
  }
  json_object([
    ("arch", json_string(self.arch)),
    ("os", json_string(self.os)),
    ("hostname", json_string(self.hostname)),
    ("shell", json_string(self.shell)),
    ("toolchains", json_object(tools)),
    ("has_docker", json_bool(self.has_docker)),
    ("has_gui", json_bool(self.has_gui)),
    ("max_parallel", json_int(self.max_parallel)),
    ("notes", json_string(self.notes)),
  ])
}

///|
pub fn MachineProfile::from_json(json : @json.Json) -> MachineProfile? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let tools : Map[String, String] = Map([])
  match object.get("toolchains") {
    Some(value) =>
      match as_object(value) {
        Some(entries) =>
          for name, path in entries {
            match as_string(path) {
              Some(text) => tools.set(name, text)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  Some({
    arch: string_field_or(object, "arch", ""),
    os: string_field_or(object, "os", ""),
    hostname: string_field_or(object, "hostname", ""),
    shell: string_field_or(object, "shell", ""),
    toolchains: tools,
    has_docker: bool_field_or(object, "has_docker", false),
    has_gui: bool_field_or(object, "has_gui", false),
    max_parallel: int_field_or(object, "max_parallel", 4),
    notes: string_field_or(object, "notes", ""),
  })
}

///|
/// True when the probe returned the fields the scheduler will rely on.
pub fn MachineProfile::is_complete(self : MachineProfile) -> Bool {
  self.os.trim() != "" && self.arch.trim() != "" && self.hostname.trim() != ""
}

///|
/// Human-readable reasons a profile is not complete.
pub fn MachineProfile::missing_fields(self : MachineProfile) -> String {
  let missing : Array[String] = []
  if self.os.trim() == "" {
    missing.push("os")
  }
  if self.arch.trim() == "" {
    missing.push("arch")
  }
  if self.hostname.trim() == "" {
    missing.push("hostname")
  }
  missing.join(", ")
}

///|
/// One registered machine. `host/port/user/identity` are the explicit target
/// stored in SQLite; `ssh_effective` is the resolved `ssh -G` view (which may
/// include values inherited from `~/.ssh/config`).
pub(all) struct MachineRecord {
  id : String
  kind : String
  name : String
  host : String
  port : Int
  user : String
  identity : String
  use_ssh_config : Bool
  host_key_policy : String
  known_hosts_file : String
  status : String
  profile : MachineProfile?
  ssh_effective : Map[String, String]
  ssh_effective_error : String
  last_seen : String
  last_error : String
  created_at : String
  updated_at : String
}

///|
pub fn MachineRecord::to_json(self : MachineRecord) -> @json.Json {
  let effective : Array[(String, @json.Json)] = []
  for key, value in self.ssh_effective {
    effective.push((key, json_string(value)))
  }
  let profile = match self.profile {
    Some(value) => value.to_json()
    None => @json.Json::null()
  }
  json_object([
    ("id", json_string(self.id)),
    ("kind", json_string(self.kind)),
    ("name", json_string(self.name)),
    ("host", json_string(self.host)),
    ("port", json_int(self.port)),
    ("user", json_string(self.user)),
    ("identity", json_string(self.identity)),
    ("use_ssh_config", json_bool(self.use_ssh_config)),
    ("host_key_policy", json_string(self.host_key_policy)),
    ("known_hosts_file", json_string(self.known_hosts_file)),
    ("status", json_string(self.status)),
    ("profile", profile),
    ("ssh_effective", json_object(effective)),
    ("ssh_effective_error", json_string(self.ssh_effective_error)),
    ("last_seen", json_string(self.last_seen)),
    ("last_error", json_string(self.last_error)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
  ])
}

///|
pub fn MachineRecord::from_json(json : @json.Json) -> MachineRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let host = match string_field(object, "host") {
    Some(value) => value
    None => return None
  }
  let effective : Map[String, String] = Map([])
  match object.get("ssh_effective") {
    Some(value) =>
      match as_object(value) {
        Some(entries) =>
          for key, item in entries {
            match as_string(item) {
              Some(text) => effective.set(key, text)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  let profile = match object.get("profile") {
    Some(value) => MachineProfile::from_json(value)
    None => None
  }
  Some({
    id,
    kind: string_field_or(object, "kind", MACHINE_KIND_SSH),
    name: string_field_or(object, "name", host),
    host,
    port: int_field_or(object, "port", 22),
    user: string_field_or(object, "user", ""),
    identity: string_field_or(object, "identity", ""),
    use_ssh_config: bool_field_or(object, "use_ssh_config", true),
    host_key_policy: string_field_or(
      object,
      "host_key_policy",
      MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    ),
    known_hosts_file: string_field_or(object, "known_hosts_file", ""),
    status: string_field_or(object, "status", MACHINE_STATUS_UNKNOWN),
    profile,
    ssh_effective: effective,
    ssh_effective_error: string_field_or(object, "ssh_effective_error", ""),
    last_seen: string_field_or(object, "last_seen", ""),
    last_error: string_field_or(object, "last_error", ""),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
  })
}

///|
/// `user@host` or `host`, for display only. Never shell text.
pub fn MachineRecord::target_label(self : MachineRecord) -> String {
  if self.user != "" {
    self.user + "@" + self.host
  } else {
    self.host
  }
}

///|
pub fn MachineRecord::is_reachable(self : MachineRecord) -> Bool {
  self.status == MACHINE_STATUS_ONLINE || self.status == MACHINE_STATUS_DEGRADED
}

///|
/// Parsed `machine.add` parameters. Validation happens before any database
/// write; a host must not be able to smuggle ssh options.
pub(all) struct MachineAddSpec {
  name : String
  host : String
  port : Int
  user : String
  identity : String
  use_ssh_config : Bool
  host_key_policy : String
  known_hosts_file : String
}

///|
fn is_valid_host(host : String) -> Bool {
  if host == "" || host.length() > 255 {
    return false
  }
  if host.has_prefix("-") {
    return false
  }
  for index = 0; index < host.length(); index = index + 1 {
    let ch = match host.get_char(index) {
      Some(value) => value
      None => return false
    }
    let allowed = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '.' ||
      ch == '-' ||
      ch == '_' ||
      ch == ':' ||
      ch == '[' ||
      ch == ']'
    if !allowed {
      return false
    }
  }
  true
}

///|
fn is_valid_user(user : String) -> Bool {
  if user == "" {
    return true
  }
  if user.has_prefix("-") || user.length() > 128 {
    return false
  }
  for index = 0; index < user.length(); index = index + 1 {
    let ch = match user.get_char(index) {
      Some(value) => value
      None => return false
    }
    let allowed = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '.' ||
      ch == '-' ||
      ch == '_'
    if !allowed {
      return false
    }
  }
  true
}

///|
pub fn is_valid_host_key_policy(policy : String) -> Bool {
  policy == MACHINE_HOST_KEY_POLICY_ACCEPT_NEW ||
  policy == MACHINE_HOST_KEY_POLICY_STRICT ||
  policy == MACHINE_HOST_KEY_POLICY_INSECURE ||
  policy == MACHINE_HOST_KEY_POLICY_CONFIG
}

///|
pub fn parse_machine_add(
  params : Map[String, @json.Json],
) -> Result[MachineAddSpec, String] {
  let host = match string_field(params, "host") {
    Some(value) => value.trim().to_owned()
    None => return Err("missing host")
  }
  if !is_valid_host(host) {
    return Err(
      "invalid host: expected a hostname or address without spaces or shell metacharacters",
    )
  }
  let port = int_field_or(params, "port", 22)
  if port <= 0 || port > 65_535 {
    return Err("invalid port: expected 1-65535")
  }
  let user = string_field_or(params, "user", "")
  if !is_valid_user(user) {
    return Err("invalid user: unexpected characters")
  }
  let identity = string_field_or(params, "identity", "")
  let use_ssh_config = bool_field_or(params, "use_ssh_config", true)
  let host_key_policy = string_field_or(
    params,
    "host_key_policy",
    MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
  )
  if !is_valid_host_key_policy(host_key_policy) {
    return Err(
      "invalid host_key_policy: expected accept-new, yes, no or config",
    )
  }
  let known_hosts_file = string_field_or(params, "known_hosts_file", "")
  let name = match string_field(params, "name") {
    Some(value) => value.trim().to_owned()
    None => ""
  }
  Ok({
    name: if name == "" { host } else { name },
    host,
    port,
    user,
    identity,
    use_ssh_config,
    host_key_policy,
    known_hosts_file,
  })
}

///|
pub fn machine_add_params(
  client_request_id : String,
  name~ : String,
  host~ : String,
  port~ : Int = 22,
  user~ : String = "",
  identity~ : String = "",
  use_ssh_config~ : Bool = true,
  host_key_policy~ : String = MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
  known_hosts_file~ : String = "",
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([
    ("client_request_id", json_string(client_request_id)),
    ("name", json_string(name)),
    ("host", json_string(host)),
    ("port", json_int(port)),
    ("user", json_string(user)),
    ("identity", json_string(identity)),
    ("use_ssh_config", json_bool(use_ssh_config)),
    ("host_key_policy", json_string(host_key_policy)),
    ("known_hosts_file", json_string(known_hosts_file)),
  ])
  params
}

///|
pub fn machine_probe_params(
  client_request_id : String,
  machine_id : String,
  timeout_seconds~ : Int = 10,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("machine_id", json_string(machine_id)),
    ("timeout_seconds", json_int(timeout_seconds)),
  ])
}

///|
pub fn machine_remove_params(
  client_request_id : String,
  machine_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("machine_id", json_string(machine_id)),
  ])
}

///|
pub fn machine_list_params(
  client_request_id : String,
) -> Map[String, @json.Json] {
  Map([("client_request_id", json_string(client_request_id))])
}

///|
pub fn machine_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "machine_id") {
    Some(value) =>
      if value.trim() == "" {
        Err("missing machine_id")
      } else {
        Ok(value)
      }
    None => Err("missing machine_id")
  }
}

///|
pub fn machine_probe_timeout(
  params : Map[String, @json.Json],
  default : Int,
) -> Int {
  int_field_or(params, "timeout_seconds", default).max(1).min(120)
}

///|
pub fn machine_list_result(
  machines : Array[MachineRecord],
) -> @json.Json {
  let items : Array[@json.Json] = []
  for machine in machines {
    items.push(machine.to_json())
  }
  json_object([("machines", json_array(items))])
}

///|
pub fn machine_list_from_json(
  json : @json.Json,
) -> Result[Array[MachineRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("machine.list result is not an object")
  }
  let items = match object.get("machines") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("machine.list result has no machines array")
  }
  let machines : Array[MachineRecord] = []
  for item in items {
    match MachineRecord::from_json(item) {
      Some(record) => machines.push(record)
      None => return Err("machine.list result contains a malformed machine")
    }
  }
  Ok(machines)
}

///|
pub fn machine_record_result(record : MachineRecord) -> @json.Json {
  record.to_json()
}

///|
pub fn machine_record_from_json(
  json : @json.Json,
) -> Result[MachineRecord, String] {
  match MachineRecord::from_json(json) {
    Some(record) => Ok(record)
    None => Err("malformed machine record")
  }
}

///|
pub fn machine_probe_result(
  record : MachineRecord,
  profile : MachineProfile,
) -> @json.Json {
  json_object([
    ("machine", record.to_json()),
    ("profile", profile.to_json()),
  ])
}

///|
/// `{machine, profile}` as returned by `machine.probe`.
pub(all) struct MachineProbeView {
  machine : MachineRecord
  profile : MachineProfile
}

///|
pub fn machine_probe_from_json(
  json : @json.Json,
) -> Result[MachineProbeView, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("machine.probe result is not an object")
  }
  let machine = match object.get("machine") {
    Some(value) =>
      match machine_record_from_json(value) {
        Ok(record) => record
        Err(message) => return Err(message)
      }
    None => return Err("machine.probe result has no machine")
  }
  let profile = match object.get("profile") {
    Some(value) =>
      match MachineProfile::from_json(value) {
        Some(found) => found
        None => return Err("machine.probe result has a malformed profile")
      }
    None => return Err("machine.probe result has no profile")
  }
  Ok({ machine, profile })
}

///|
pub fn machine_remove_result(machine_id : String) -> @json.Json {
  json_object([
    ("removed", json_bool(true)),
    ("machine_id", json_string(machine_id)),
  ])
}

///|
/// Payload carried by every `machine.*` event. The full record snapshot makes
/// replay independent of any projection state; `machine.removed` carries only
/// the tombstone id.
pub fn machine_event_payload(record : MachineRecord) -> @json.Json {
  json_object([
    ("machine_id", json_string(record.id)),
    ("status", json_string(record.status)),
    ("machine", record.to_json()),
  ])
}

///|
pub fn machine_removed_payload(machine_id : String) -> @json.Json {
  json_object([
    ("machine_id", json_string(machine_id)),
    ("status", json_string(MACHINE_STATUS_OFFLINE)),
    ("removed", json_bool(true)),
  ])
}

///|
/// Machine id carried by `machine.removed` (the tombstone event has no record
/// snapshot). Returns `None` for every other event.
pub fn machine_event_removed_id(
  event : EventEnvelope,
) -> String? {
  if event.event_type != EVENT_MACHINE_REMOVED {
    return None
  }
  match event.payload {
    @json.Json::Object(object) =>
      match object.get("machine_id") {
        Some(@json.Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
pub fn machine_event_record(
  event : EventEnvelope,
) -> MachineRecord? {
  match event.payload {
    @json.Json::Object(object) =>
      match object.get("machine") {
        Some(value) => MachineRecord::from_json(value)
        None => None
      }
    _ => None
  }
}
