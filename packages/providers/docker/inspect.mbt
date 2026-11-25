///|
/// `docker inspect --type container` parsing (ADR-0013 §3.4).
///
/// Only a bounded JSON document for exactly one container named
/// `monexus-env-<id>` is accepted. `Config.Env` entries are split at the first
/// `=` and **only the name is retained**; values are dropped at parse time so
/// they cannot leak through summaries, diagnostics or later storage.

///|
pub const MAX_INSPECT_BYTES : Int = 1_048_576

///|
pub const MAX_INSPECT_ENV_NAMES : Int = 256

///|
pub const MAX_INSPECT_MOUNTS : Int = 64

///|
pub(all) struct InspectMount {
  kind : String
  source : String
  destination : String
  read_only : Bool
}

///|
pub(all) struct ContainerInspect {
  name : String
  image : String
  status : String
  running : Bool
  env_names : Array[String]
  labels : Array[(String, String)]
  network_mode : String
  init : Bool
  restart_policy : String
  user : String
  memory_bytes : Int64?
  nano_cpus : Int64?
  pids_limit : Int64?
  mounts : Array[InspectMount]
}

///|
fn inspect_error(field : String, detail : String) -> DockerError {
  DockerError::new(InspectInvalid).at(field).with_detail(detail)
}

///|
fn inspect_bounded(
  value : String,
  field : String,
  max : Int,
) -> Result[String, DockerError] {
  if value.length() > max || has_control(value, false) {
    return Err(inspect_error(field, "value is outside the allowed range"))
  }
  Ok(value)
}

///|
fn required_string(
  object : Map[String, @json.Json],
  key : String,
  field : String,
) -> Result[String, DockerError] {
  match object.get(key) {
    Some(@json.Json::String(value)) => inspect_bounded(value, field, 1_024)
    Some(_) => Err(inspect_error(field, "string required"))
    None => Err(inspect_error(field, "field is missing"))
  }
}

///|
fn optional_string(
  object : Map[String, @json.Json],
  key : String,
  field : String,
) -> Result[String, DockerError] {
  match object.get(key) {
    Some(@json.Json::String(value)) => inspect_bounded(value, field, 1_024)
    Some(@json.Json::Null) => Ok("")
    Some(_) => Err(inspect_error(field, "string required"))
    None => Ok("")
  }
}

///|
fn required_bool(
  object : Map[String, @json.Json],
  key : String,
  field : String,
) -> Result[Bool, DockerError] {
  match object.get(key) {
    Some(@json.Json::True) => Ok(true)
    Some(@json.Json::False) => Ok(false)
    Some(_) => Err(inspect_error(field, "boolean required"))
    None => Err(inspect_error(field, "field is missing"))
  }
}

///|
fn optional_bool(
  object : Map[String, @json.Json],
  key : String,
  field : String,
) -> Result[Bool, DockerError] {
  match object.get(key) {
    Some(@json.Json::True) => Ok(true)
    Some(@json.Json::False) => Ok(false)
    Some(@json.Json::Null) => Ok(false)
    Some(_) => Err(inspect_error(field, "boolean required"))
    None => Ok(false)
  }
}

///|
fn optional_int(
  object : Map[String, @json.Json],
  key : String,
  field : String,
) -> Result[Int64?, DockerError] {
  match object.get(key) {
    Some(@json.Json::Number(value, ..)) => {
      if value.is_nan() || value.is_inf() || value != value.trunc() ||
        value < 0.0 || value > 9_007_199_254_740_991.0 {
        return Err(inspect_error(field, "non-negative integer required"))
      }
      Ok(Some(value.to_int64()))
    }
    Some(@json.Json::Null) => Ok(None)
    Some(_) => Err(inspect_error(field, "number required"))
    None => Ok(None)
  }
}

///|
fn as_object(
  json : @json.Json,
  field : String,
) -> Result[Map[String, @json.Json], DockerError] {
  match json {
    @json.Json::Object(value) => Ok(value)
    _ => Err(inspect_error(field, "object required"))
  }
}

///|
fn optional_object(
  object : Map[String, @json.Json],
  key : String,
  field : String,
) -> Result[Map[String, @json.Json], DockerError] {
  match object.get(key) {
    Some(@json.Json::Null) => Ok(Map([]))
    Some(value) => as_object(value, field)
    None => Ok(Map([]))
  }
}

///|
fn parse_env_names(
  config : Map[String, @json.Json],
) -> Result[Array[String], DockerError] {
  let items = match config.get("Env") {
    Some(@json.Json::Array(value)) => value
    Some(@json.Json::Null) => return Ok([])
    Some(_) => return Err(inspect_error("Config.Env", "array required"))
    None => return Ok([])
  }
  if items.length() > MAX_INSPECT_ENV_NAMES {
    return Err(inspect_error("Config.Env", "too many entries"))
  }
  let names : Array[String] = []
  for item in items {
    let entry = match item {
      @json.Json::String(value) => value
      _ => return Err(inspect_error("Config.Env", "string entries required"))
    }
    let name = match entry.find("=") {
      Some(index) => entry[:index].to_owned()
      None => entry
    }
    if !@recipes.is_valid_env_name(name) {
      return Err(
        inspect_error(
          "Config.Env",
          "variable name is outside the allowed grammar",
        ),
      )
    }
    names.push(name)
  }
  Ok(names)
}

///|
fn parse_labels(
  config : Map[String, @json.Json],
) -> Result[Array[(String, String)], DockerError] {
  let labels = match config.get("Labels") {
    Some(@json.Json::Object(value)) => value
    Some(@json.Json::Null) => return Ok([])
    Some(_) => return Err(inspect_error("Config.Labels", "object required"))
    None => return Ok([])
  }
  let keys : Array[String] = []
  for key in labels.keys() {
    keys.push(key)
  }
  if keys.length() > 64 {
    return Err(inspect_error("Config.Labels", "too many entries"))
  }
  let pairs : Array[(String, String)] = []
  for key in keys {
    if key.length() > 128 || has_control(key, false) {
      return Err(inspect_error("Config.Labels", "label key is too long"))
    }
    let value = match labels.get(key) {
      Some(@json.Json::String(found)) => found
      _ =>
        return Err(
          inspect_error("Config.Labels", "string label values required"),
        )
    }
    let bounded = match inspect_bounded(value, "Config.Labels", 512) {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    pairs.push((key, bounded))
  }
  pairs.sort_by(fn(left : (String, String),
    right : (String, String)) -> Int32 {
    @recipes.compare_utf8(left.0, right.0)
  })
  Ok(pairs)
}

///|
fn parse_mounts(
  object : Map[String, @json.Json],
) -> Result[Array[InspectMount], DockerError] {
  let items = match object.get("Mounts") {
    Some(@json.Json::Array(value)) => value
    Some(@json.Json::Null) => return Ok([])
    Some(_) => return Err(inspect_error("Mounts", "array required"))
    None => return Ok([])
  }
  if items.length() > MAX_INSPECT_MOUNTS {
    return Err(inspect_error("Mounts", "too many mounts"))
  }
  let mounts : Array[InspectMount] = []
  for item in items {
    let mount = match as_object(item, "Mounts[]") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let kind = match required_string(mount, "Type", "Mounts[].Type") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let source = match optional_string(mount, "Source", "Mounts[].Source") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let destination = match required_string(
      mount,
      "Destination",
      "Mounts[].Destination",
    ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let read_only = match mount.get("RW") {
      Some(@json.Json::True) => false
      Some(@json.Json::False) => true
      Some(_) => return Err(inspect_error("Mounts[].RW", "boolean required"))
      None =>
        // Absence is treated as read-only rather than assuming write access.
        true
    }
    let kind = match inspect_bounded(kind, "Mounts[].Type", 32) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let destination = match inspect_bounded(
      destination,
      "Mounts[].Destination",
      1_024,
    ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    mounts.push({ kind, source, destination, read_only })
  }
  Ok(mounts)
}

///|
/// Parse one `docker inspect` result. `expected_name` is the deterministic
/// container name (`monexus-env-...`); a different container is
/// `inspect_mismatch`, never adopted.
pub fn parse_inspect(
  text : String,
  expected_name : String,
) -> Result[ContainerInspect, DockerError] {
  if expected_name == "" || expected_name.length() > 256 {
    return Err(inspect_error("expected_name", "container name is invalid"))
  }
  if text.length() == 0 || text.length() > MAX_INSPECT_BYTES {
    return Err(
      inspect_error("inspect", "document size is outside the allowed range"),
    )
  }
  let json = @json.parse(text, reject_duplicate_keys=true, max_nesting_depth=32) catch {
    _ => return Err(inspect_error("inspect", "invalid JSON"))
  }
  let items = match json {
    @json.Json::Array(value) => value
    _ => return Err(inspect_error("inspect", "array required"))
  }
  if items.length() != 1 {
    return Err(inspect_error("inspect", "exactly one container is required"))
  }
  let object = match as_object(items[0], "inspect[0]") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let raw_name = match required_string(object, "Name", "Name") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let name = if raw_name.has_prefix("/") {
    raw_name[1:].to_owned()
  } else {
    raw_name
  }
  if name != expected_name {
    return Err(
      DockerError::new(InspectMismatch).at("Name").with_detail(
        "container name does not match the managed environment",
      ),
    )
  }
  let state = match optional_object(object, "State", "State") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = match required_string(state, "Status", "State.Status") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let running = match required_bool(state, "Running", "State.Running") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let config = match optional_object(object, "Config", "Config") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let image = match optional_string(config, "Image", "Config.Image") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let user = match optional_string(config, "User", "Config.User") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let env_names = match parse_env_names(config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let labels = match parse_labels(config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let host = match optional_object(object, "HostConfig", "HostConfig") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let network_mode = match optional_string(
    host,
    "NetworkMode",
    "HostConfig.NetworkMode",
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let init = match optional_bool(host, "Init", "HostConfig.Init") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let restart_policy = match host.get("RestartPolicy") {
    Some(@json.Json::Object(policy)) =>
      match optional_string(policy, "Name", "HostConfig.RestartPolicy.Name") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    Some(@json.Json::Null) => ""
    Some(_) => return Err(inspect_error("HostConfig.RestartPolicy", "object required"))
    None => ""
  }
  let memory_bytes = match optional_int(host, "Memory", "HostConfig.Memory") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let nano_cpus = match optional_int(host, "NanoCpus", "HostConfig.NanoCpus") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let pids_limit = match optional_int(host, "PidsLimit", "HostConfig.PidsLimit") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mounts = match parse_mounts(object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    name,
    image,
    status,
    running,
    env_names,
    labels,
    network_mode,
    init,
    restart_policy,
    user,
    memory_bytes,
    nano_cpus,
    pids_limit,
    mounts,
  })
}

///|
pub fn label_value(inspect : ContainerInspect, key : String) -> String? {
  for pair in inspect.labels {
    if pair.0 == key {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Every managed label must match the identity exactly; anything else is not
/// ours to adopt.
pub fn inspect_matches_identity(
  inspect : ContainerInspect,
  identity : EnvironmentIdentity,
) -> Bool {
  for expected in managed_labels(identity) {
    let found = match label_value(inspect, expected.0) {
      Some(value) => value
      None => return false
    }
    if found != expected.1 {
      return false
    }
  }
  true
}

///|
/// Names only. No `Config.Env` value is ever stored, let alone summarised.
pub fn inspect_summary(inspect : ContainerInspect) -> String {
  let out = StringBuilder()
  out.write_string("name=")
  out.write_string(inspect.name)
  out.write_string(" status=")
  out.write_string(inspect.status)
  out.write_string(" running=")
  out.write_string(if inspect.running { "true" } else { "false" })
  out.write_string(" network=")
  out.write_string(inspect.network_mode)
  out.write_string(" env_names=[")
  let mut first = true
  for name in inspect.env_names {
    if !first {
      out.write_string(",")
    }
    first = false
    out.write_string(name)
  }
  out.write_string("] mounts=")
  out.write_string(inspect.mounts.length().to_string())
  out.to_string()
}
