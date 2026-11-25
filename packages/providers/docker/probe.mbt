///|
/// Docker capability probe (ADR-0013 §3.1).
///
/// The probe runs `docker info --format '{{json .}}'` with a bounded timeout.
/// Any failure means "not schedulable": there is no host-execution fallback.
/// The result reports the facts A2.1 needs (server version, rootless, cgroup
/// version, required flag availability); the approval/risk policy itself is
/// not decided here.

///|
pub const MIN_DOCKER_SERVER_VERSION : String = "20.10.0"

///|
pub const MAX_DOCKER_INFO_BYTES : Int = 65_536

///|
pub const DEFAULT_DOCKER_PROBE_TIMEOUT_MS : Int = 5_000

///|
pub(all) struct DockerServerVersion {
  major : Int
  minor : Int
  patch : Int
  raw : String
}

///|
pub fn DockerServerVersion::parse(text : String) -> DockerServerVersion? {
  if text.length() < 5 || text.length() > 64 {
    return None
  }
  let major = match version_part(text, 0) {
    Some(value) => value
    None => return None
  }
  let mut cursor = major.1
  if text.get_char(cursor) != Some('.') {
    return None
  }
  cursor = cursor + 1
  let minor = match version_part(text, cursor) {
    Some(value) => value
    None => return None
  }
  cursor = minor.1
  if text.get_char(cursor) != Some('.') {
    return None
  }
  cursor = cursor + 1
  let patch = match version_part(text, cursor) {
    Some(value) => value
    None => return None
  }
  cursor = patch.1
  if cursor < text.length() {
    // Custom builds may append `+azure-1` or `-ce`; accept a bounded printable
    // suffix but never let it hide a malformed numeric core.
    let marker = match text.get_char(cursor) {
      Some(value) => value
      None => return None
    }
    if marker != '+' && marker != '-' {
      return None
    }
    let suffix_length = text.length() - cursor
    if suffix_length > 32 {
      return None
    }
  }
  Some({ major: major.0, minor: minor.0, patch: patch.0, raw: text })
}

///|
fn version_part(text : String, start : Int) -> (Int, Int)? {
  let mut cursor = start
  let mut value = 0
  let mut digits = 0
  while cursor < text.length() {
    let ch = match text.get_char(cursor) {
      Some(found) => found
      None => break
    }
    if ch < '0' || ch > '9' {
      break
    }
    if digits >= 4 {
      return None
    }
    value = value * 10 + (ch.to_int() - 48)
    digits = digits + 1
    cursor = cursor + 1
  }
  if digits == 0 {
    return None
  }
  if digits > 2 {
    if text.get_char(start) == Some('0') {
      return None
    }
  }
  // Docker zero-pads two-digit minor versions in its own releases
  // (`17.06`, `19.03`, `20.10`), so a two-character part may start with `0`.
  // Three-or-more-digit zero-padded parts (`20.010`) remain rejected.
  Some((value, cursor))
}

///|
pub fn DockerServerVersion::at_least(
  self : DockerServerVersion,
  major : Int,
  minor : Int,
  patch : Int,
) -> Bool {
  if self.major != major {
    return self.major > major
  }
  if self.minor != minor {
    return self.minor > minor
  }
  self.patch >= patch
}

///|
pub fn DockerServerVersion::text(self : DockerServerVersion) -> String {
  self.major.to_string() + "." + self.minor.to_string() + "." +
  self.patch.to_string()
}

///|
pub(all) enum DockerRequiredFlag {
  FlagEnvFile
  FlagInit
  FlagPidsLimit
  FlagCpus
  FlagMountBind
  FlagRestartNo
  FlagNetwork
  FlagUser
  FlagWorkdir
  FlagLabel
}

///|
pub fn DockerRequiredFlag::label(self : DockerRequiredFlag) -> String {
  match self {
    FlagEnvFile => "env_file"
    FlagInit => "init"
    FlagPidsLimit => "pids_limit"
    FlagCpus => "cpus"
    FlagMountBind => "mount_bind"
    FlagRestartNo => "restart_no"
    FlagNetwork => "network"
    FlagUser => "user"
    FlagWorkdir => "workdir"
    FlagLabel => "label"
  }
}

///|
pub fn DockerRequiredFlag::min_version(self : DockerRequiredFlag) -> String {
  match self {
    FlagEnvFile => "1.9.0"
    FlagInit => "1.13.0"
    FlagPidsLimit => "1.10.0"
    FlagCpus => "1.13.0"
    FlagMountBind => "17.06.0"
    FlagRestartNo => "1.0.0"
    FlagNetwork => "1.0.0"
    FlagUser => "1.0.0"
    FlagWorkdir => "1.0.0"
    FlagLabel => "1.0.0"
  }
}

///|
pub fn all_required_flags() -> Array[DockerRequiredFlag] {
  [
    FlagEnvFile, FlagInit, FlagPidsLimit, FlagCpus, FlagMountBind, FlagRestartNo,
    FlagNetwork, FlagUser, FlagWorkdir, FlagLabel,
  ]
}

///|
pub fn missing_required_flags(
  version : DockerServerVersion,
) -> Array[DockerRequiredFlag] {
  let missing : Array[DockerRequiredFlag] = []
  for flag in all_required_flags() {
    let parsed = match DockerServerVersion::parse(flag.min_version()) {
      Some(value) => value
      None => {
        // Every minimum above is a valid literal; treat a bad table entry as a
        // missing flag rather than silently assuming support.
        missing.push(flag)
        continue
      }
    }
    if !version.at_least(parsed.major, parsed.minor, parsed.patch) {
      missing.push(flag)
    }
  }
  missing
}

///|
pub(all) struct DockerCapabilities {
  server_version : DockerServerVersion
  rootless : Bool
  cgroup_v2 : Bool
  cgroup_driver : String
  security_options : Array[String]
  architecture : String
  os_type : String
}

///|
pub(all) struct DockerProbe {
  tool : String
  available : Bool
  schedulable : Bool
  capabilities : DockerCapabilities?
  failure : DockerError?
  detail : String
}

///|
pub fn DockerProbe::reason(self : DockerProbe) -> String? {
  match self.failure {
    Some(error) => Some(error.reason())
    None => None
  }
}

///|
pub fn DockerProbe::is_usable(self : DockerProbe) -> Bool {
  self.available && self.schedulable
}

///|
fn probe_failure(
  tool : String,
  code : DockerErrorCode,
  detail : String,
  field : String?,
) -> DockerProbe {
  let error = match field {
    Some(value) => DockerError::new(code).at(value).with_detail(detail)
    None => DockerError::new(code).with_detail(detail)
  }
  {
    tool,
    available: false,
    schedulable: false,
    capabilities: None,
    failure: Some(error),
    detail,
  }
}

///|
/// Parse the JSON object emitted by `docker info --format '{{json .}}'`.
/// Unknown fields are ignored (Docker adds fields between releases); the
/// fields this provider depends on are validated strictly.
pub fn parse_docker_info(text : String) -> Result[DockerCapabilities, DockerError] {
  if text.length() == 0 || text.length() > MAX_DOCKER_INFO_BYTES {
    return Err(
      DockerError::new(DockerInfoInvalid).with_detail(
        "docker info output is outside the allowed size",
      ),
    )
  }
  let json = @json.parse(text, reject_duplicate_keys=true, max_nesting_depth=32) catch {
    _ =>
      return Err(
        DockerError::new(DockerInfoInvalid).with_detail("invalid JSON"),
      )
  }
  let object = match json {
    @json.Json::Object(value) => value
    _ =>
      return Err(
        DockerError::new(DockerInfoInvalid).with_detail("object required"),
      )
  }
  let server_text = match object.get("ServerVersion") {
    Some(@json.Json::String(value)) => value
    Some(_) =>
      return Err(
        DockerError::new(DockerInfoInvalid).at("ServerVersion").with_detail(
          "string required",
        ),
      )
    None =>
      return Err(
        DockerError::new(DockerInfoInvalid).at("ServerVersion").with_detail(
          "field is missing (is the daemon running?)",
        ),
      )
  }
  let server_version = match DockerServerVersion::parse(server_text.trim().to_owned()) {
    Some(value) => value
    None =>
      return Err(
        DockerError::new(DockerInfoInvalid).at("ServerVersion").with_detail(
          "expected a major.minor.patch version",
        ),
      )
  }
  let cgroup_version = match optional_info_string(object, "CgroupVersion") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let cgroup_v2 = match cgroup_version {
    Some(value) =>
      if value == "2" {
        true
      } else if value == "1" {
        false
      } else {
        return Err(
          DockerError::new(DockerInfoInvalid).at("CgroupVersion").with_detail(
            "expected 1 or 2",
          ),
        )
      }
    None => false
  }
  let cgroup_driver = match optional_info_string(object, "CgroupDriver") {
    Ok(value) =>
      match value {
        Some(found) => found
        None => ""
      }
    Err(error) => return Err(error)
  }
  let architecture = match optional_info_string(object, "Architecture") {
    Ok(value) =>
      match value {
        Some(found) => found
        None => ""
      }
    Err(error) => return Err(error)
  }
  let os_type = match optional_info_string(object, "OSType") {
    Ok(value) =>
      match value {
        Some(found) => found
        None => ""
      }
    Err(error) => return Err(error)
  }
  let security_options = match object.get("SecurityOptions") {
    Some(@json.Json::Array(items)) => {
      if items.length() > 32 {
        return Err(
          DockerError::new(DockerInfoInvalid).at("SecurityOptions").with_detail(
            "too many entries",
          ),
        )
      }
      let collected : Array[String] = []
      for item in items {
        let value = match item {
          @json.Json::String(found) => found
          _ =>
            return Err(
              DockerError::new(DockerInfoInvalid).at("SecurityOptions").with_detail(
                "string entries required",
              ),
            )
        }
        if value.length() > 128 || has_control(value, false) {
          return Err(
            DockerError::new(DockerInfoInvalid).at("SecurityOptions").with_detail(
              "entry is outside the allowed range",
            ),
          )
        }
        collected.push(value)
      }
      collected
    }
    Some(_) =>
      return Err(
        DockerError::new(DockerInfoInvalid).at("SecurityOptions").with_detail(
          "array required",
        ),
      )
    None => []
  }
  let mut rootless = false
  for option in security_options {
    if option == "name=rootless" || option == "rootless" {
      rootless = true
    }
  }
  Ok({
    server_version,
    rootless,
    cgroup_v2,
    cgroup_driver,
    security_options,
    architecture,
    os_type,
  })
}

///|
fn optional_info_string(
  object : Map[String, @json.Json],
  key : String,
) -> Result[String?, DockerError] {
  match object.get(key) {
    Some(@json.Json::String(value)) => {
      if value.length() > 128 || has_control(value, false) {
        return Err(
          DockerError::new(DockerInfoInvalid).at(key).with_detail(
            "value is outside the allowed range",
          ),
        )
      }
      Ok(Some(value))
    }
    Some(_) =>
      Err(
        DockerError::new(DockerInfoInvalid).at(key).with_detail(
          "string required",
        ),
      )
    None => Ok(None)
  }
}

///|
fn has_control(text : String, allow_layout : Bool) -> Bool {
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => continue
    }
    let code = ch.to_int()
    if code < 32 {
      let allowed = allow_layout && (code == 9 || code == 10 || code == 13)
      if !allowed {
        return true
      }
    }
    if code == 127 {
      return true
    }
  }
  false
}

///|
/// Probe the Docker daemon through `tool` (default `docker`). The argv is a
/// single-element format string; there is no shell and no recipe text.
pub async fn probe_docker(
  tool~ : String = "docker",
  timeout_ms~ : Int = DEFAULT_DOCKER_PROBE_TIMEOUT_MS,
) -> DockerProbe {
  probe_docker_argv(tool, ["info", "--format", "{{json .}}"], timeout_ms)
}

///|
/// Internal probe entry point with the docker argv injectable. Whitebox tests
/// use `/bin/sh -c` so every outcome is driven by a deterministic runner and
/// never depends on a host `docker` installation or an executable temp file.
/// Production goes through `probe_docker`, which fixes the argv above.
async fn probe_docker_argv(
  tool : String,
  info_argv : Array[String],
  timeout_ms : Int,
) -> DockerProbe {
  if tool == "" {
    return probe_failure(
      tool,
      DockerMissing,
      "docker executable path is empty",
      None,
    )
  }
  let budget = if timeout_ms < 50 { 50 } else { timeout_ms }
  let collected = @async.with_timeout_opt(budget, async fn() {
    let result = @process.collect_output(tool, info_argv) catch {
      _ => return None
    }
    Some(result)
  })
  let (code, stdout, _stderr) = match collected {
    None =>
      return probe_failure(
        tool,
        DockerProbeTimeout,
        "docker info timed out",
        Some("docker"),
      )
    Some(None) =>
      return probe_failure(
        tool,
        DockerMissing,
        "docker executable was not found or could not be spawned",
        Some("docker"),
      )
    Some(Some(value)) => value
  }
  if code != 0 {
    // stderr is deliberately not echoed: it may contain host paths.
    return probe_failure(
      tool,
      DockerUnavailable,
      "docker info exited non-zero (daemon unreachable or permission denied)",
      Some("docker"),
    )
  }
  let text = stdout.text() catch {
    _ =>
      return probe_failure(
        tool,
        DockerInfoInvalid,
        "docker info output could not be decoded",
        Some("docker"),
      )
  }
  let capabilities = match parse_docker_info(text) {
    Ok(value) => value
    Err(error) => {
      return {
        tool,
        available: true,
        schedulable: false,
        capabilities: None,
        failure: Some(error),
        detail: error.to_string(),
      }
    }
  }
  let missing = missing_required_flags(capabilities.server_version)
  if !capabilities.server_version.at_least(20, 10, 0) {
    return {
      tool,
      available: true,
      schedulable: false,
      capabilities: Some(capabilities),
      failure: Some(
        DockerError::new(DockerVersionUnsupported).at("ServerVersion").with_detail(
          "Docker 20.10.0 or newer is required",
        ),
      ),
      detail: "docker server version is below the minimum",
    }
  }
  if missing.length() > 0 {
    let names = StringBuilder()
    let mut first = true
    for flag in missing {
      if !first {
        names.write_string(", ")
      }
      first = false
      names.write_string(flag.label())
    }
    return {
      tool,
      available: true,
      schedulable: false,
      capabilities: Some(capabilities),
      failure: Some(
        DockerError::new(DockerFlagUnsupported).with_detail(
          "missing required flags: " + names.to_string(),
        ),
      ),
      detail: "docker does not support every required flag",
    }
  }
  {
    tool,
    available: true,
    schedulable: true,
    capabilities: Some(capabilities),
    failure: None,
    detail: "docker daemon is reachable and supports the required flags",
  }
}
