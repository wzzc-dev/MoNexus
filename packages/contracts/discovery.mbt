///|
/// Contents of `~/.monexus/host.json` (architecture §7.3). The file is
/// written atomically with mode 0600; the token is the bearer credential for
/// the loopback WebSocket endpoint.
pub const DISCOVERY_SCHEMA_VERSION : Int = 1

///|
pub(all) struct HostInfo {
  schema_version : Int
  host_id : String
  version : String
  pid : Int
  port : Int
  token : String
  ws_url : String
  started_at : String
  state_dir : String
}

///|
pub fn HostInfo::new(
  schema_version~ : Int,
  host_id~ : String,
  version~ : String,
  pid~ : Int,
  port~ : Int,
  token~ : String,
  ws_url~ : String,
  started_at~ : String,
  state_dir~ : String,
) -> HostInfo {
  {
    schema_version,
    host_id,
    version,
    pid,
    port,
    token,
    ws_url,
    started_at,
    state_dir,
  }
}

///|
pub fn HostInfo::to_json(self : HostInfo) -> @json.Json {
  json_object([
    ("schema_version", json_int(self.schema_version)),
    ("host_id", json_string(self.host_id)),
    ("version", json_string(self.version)),
    ("pid", json_int(self.pid)),
    ("port", json_int(self.port)),
    ("token", json_string(self.token)),
    ("ws_url", json_string(self.ws_url)),
    ("started_at", json_string(self.started_at)),
    ("state_dir", json_string(self.state_dir)),
  ])
}

///|
pub fn HostInfo::from_json(json : @json.Json) -> HostInfo? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let host_id = match string_field(object, "host_id") {
    Some(value) => value
    None => return None
  }
  let token = match string_field(object, "token") {
    Some(value) => value
    None => return None
  }
  let ws_url = match string_field(object, "ws_url") {
    Some(value) => value
    None => return None
  }
  Some({
    schema_version: int_field_or(object, "schema_version", 1),
    host_id,
    version: string_field_or(object, "version", ""),
    pid: int_field_or(object, "pid", 0),
    port: int_field_or(object, "port", 0),
    token,
    ws_url,
    started_at: string_field_or(object, "started_at", ""),
    state_dir: string_field_or(object, "state_dir", ""),
  })
}

///|
pub fn host_info_path(state_dir : String) -> String {
  state_dir + "/host.json"
}

///|
pub fn host_lock_path(state_dir : String) -> String {
  state_dir + "/host.lock"
}
