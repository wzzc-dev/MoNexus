///|
/// Versioned, immutable environment recipe (ADR-0013 §2.1).
///
/// Parsing is strict: every unknown field, out-of-range value, invalid enum and
/// missing required field is refused with a stable `RecipeError` reason code.
/// Nothing is normalised silently, and optional fields keep track of whether
/// they were declared so canonical bytes hash exactly what the author signed.

///|
pub const RECIPE_SCHEMA_VERSION : Int = 1

///|
pub const DEFAULT_WORKDIR : String = "/workspace"

///|
pub const MAX_RECIPE_BYTES : Int = 262_144

///|
pub const MAX_MOUNTS : Int = 8

///|
pub const MAX_ENV_NAMES : Int = 128

///|
pub const MAX_ARGV_ITEMS : Int = 64

///|
pub const MAX_ARGV_ELEMENT_BYTES : Int = 4096

///|
pub const MAX_SCRIPT_BYTES : Int = 65_536

///|
pub const MIN_HOOK_TIMEOUT_S : Int = 1

///|
pub const MAX_HOOK_TIMEOUT_S : Int = 3600

///|
pub const MIN_DOCTOR_TIMEOUT_S : Int = 1

///|
pub const MAX_DOCTOR_TIMEOUT_S : Int = 300

///|
pub const MIN_SOURCE_AUTHOR_BYTES : Int = 1

///|
pub const MAX_SOURCE_AUTHOR_BYTES : Int = 200

///|
pub const MIN_CPU_MILLIS : Int = 100

///|
pub const MAX_CPU_MILLIS : Int = 16_000

///|
pub const DEFAULT_CPU_MILLIS : Int = 1_000

///|
pub const MIN_MEMORY_MB : Int = 128

///|
pub const MAX_MEMORY_MB : Int = 32_768

///|
pub const DEFAULT_MEMORY_MB : Int = 2_048

///|
pub const MIN_PIDS : Int = 16

///|
pub const MAX_PIDS : Int = 8_192

///|
pub const DEFAULT_PIDS : Int = 512

///|
/// A recipe may only bind a registered workspace root or the environment's
/// own scratch directory; arbitrary host paths have no representation.
pub(all) enum MountSource {
  MountWorkspace
  MountScratch
}

///|
pub fn MountSource::label(self : MountSource) -> String {
  match self {
    MountWorkspace => "workspace"
    MountScratch => "scratch"
  }
}

///|
pub(all) enum MountMode {
  MountReadOnly
  MountReadWrite
}

///|
pub fn MountMode::label(self : MountMode) -> String {
  match self {
    MountReadOnly => "ro"
    MountReadWrite => "rw"
  }
}

///|
pub(all) enum NetworkMode {
  NetworkNone
  NetworkBridge
}

///|
pub fn NetworkMode::label(self : NetworkMode) -> String {
  match self {
    NetworkNone => "none"
    NetworkBridge => "bridge"
  }
}

///|
pub(all) struct RecipeImage {
  reference : String
  digest : String
}

///|
pub(all) struct RecipeMount {
  source : MountSource
  target : String
  mode : MountMode
}

///|
/// Declared limits. Absent keys fall back to the defaults in
/// `Recipe::effective_limits`; an absent object is not the same as an object
/// with explicit defaults when hashing, which is why presence is preserved.
pub(all) struct RecipeLimits {
  cpu_millis : Int?
  memory_mb : Int?
  pids : Int?
}

///|
pub(all) struct EffectiveLimits {
  cpu_millis : Int
  memory_mb : Int
  pids : Int
}

///|
pub(all) enum HookCommand {
  HookArgv(Array[String])
  HookScript(String)
}

///|
pub(all) struct LifecycleHook {
  command : HookCommand
  timeout_s : Int
}

///|
pub(all) struct RecipeLifecycle {
  prepare : LifecycleHook
  start : LifecycleHook
  stop : LifecycleHook
}

///|
pub(all) struct RecipeDoctor {
  argv : Array[String]
  timeout_s : Int
}

///|
pub(all) struct RecipeSource {
  kind : String
  path : String
  author : String
  created_at : String
}

///|
/// `alg` is always `ed25519`; `sig` is the base64 (no armour, no whitespace)
/// body of an OpenSSH SSHSIG blob produced by `ssh-keygen -Y sign`.
pub(all) struct RecipeSignature {
  key_id : String
  alg : String
  sig : String
}

///|
pub(all) struct Recipe {
  schema_version : Int
  name : String
  version : String
  image : RecipeImage
  workdir : String?
  user : String?
  mounts : Array[RecipeMount]
  env_allowlist : Array[String]?
  limits : RecipeLimits
  network : NetworkMode?
  lifecycle : RecipeLifecycle
  doctor : RecipeDoctor?
  source : RecipeSource
  signature : RecipeSignature
}

///|
/// Static risk hints for the plan stage. They are derived, never trusted as
/// policy: A2.1 maps them onto the existing Decision flow (ADR-0013 §4.1).
pub(all) struct RecipeRiskFlags {
  root_user : Bool
  bridge_network : Bool
  script_lifecycle : Bool
  workspace_read_only : Bool
}

///|
pub fn Recipe::identity(self : Recipe) -> String {
  self.name + "@" + self.version
}

///|
pub fn Recipe::effective_workdir(self : Recipe) -> String {
  match self.workdir {
    Some(value) => value
    None => DEFAULT_WORKDIR
  }
}

///|
pub fn Recipe::effective_network(self : Recipe) -> NetworkMode {
  match self.network {
    Some(value) => value
    None => NetworkNone
  }
}

///|
pub fn Recipe::effective_limits(self : Recipe) -> EffectiveLimits {
  let limits = self.limits
  let cpu = match limits.cpu_millis {
    Some(value) => value
    None => DEFAULT_CPU_MILLIS
  }
  let memory = match limits.memory_mb {
    Some(value) => value
    None => DEFAULT_MEMORY_MB
  }
  let pids = match limits.pids {
    Some(value) => value
    None => DEFAULT_PIDS
  }
  { cpu_millis: cpu, memory_mb: memory, pids: pids }
}

///|
pub fn Recipe::workspace_mount(self : Recipe) -> RecipeMount? {
  for mount in self.mounts {
    if mount.source is MountWorkspace {
      return Some(mount)
    }
  }
  None
}

///|
pub fn Recipe::scratch_mount(self : Recipe) -> RecipeMount? {
  for mount in self.mounts {
    if mount.source is MountScratch {
      return Some(mount)
    }
  }
  None
}

///|
pub fn Recipe::risk_flags(self : Recipe) -> RecipeRiskFlags {
  let root_user = match self.user {
    Some(value) => value == "root" || value == "0" || value == "0:0" ||
      value.has_prefix("0:")
    None => false
  }
  let script_lifecycle = match self.lifecycle.prepare.command {
    HookScript(_) => true
    HookArgv(_) => match self.lifecycle.start.command {
      HookScript(_) => true
      HookArgv(_) => match self.lifecycle.stop.command {
        HookScript(_) => true
        HookArgv(_) => false
      }
    }
  }
  let workspace_read_only = match self.workspace_mount() {
    Some(mount) => mount.mode is MountReadOnly
    None => false
  }
  {
    root_user,
    bridge_network: self.effective_network() is NetworkBridge,
    script_lifecycle,
    workspace_read_only,
  }
}

// ---------------------------------------------------------------------------
// Strict JSON helpers. All failures carry a field path, never the value.

///|
fn fail(code : RecipeErrorCode, field : String) -> RecipeError {
  RecipeError::new(code).at(field)
}

///|
fn fail_detail(
  code : RecipeErrorCode,
  field : String,
  detail : String,
) -> RecipeError {
  RecipeError::new(code).at(field).with_detail(detail)
}

///|
fn expect_object(
  json : @json.Json,
  path : String,
) -> Result[Map[String, @json.Json], RecipeError] {
  match json {
    @json.Json::Object(object) => Ok(object)
    _ => Err(fail(InvalidType, path + " (object required)"))
  }
}

///|
fn expect_string(
  json : @json.Json,
  path : String,
) -> Result[String, RecipeError] {
  match json {
    @json.Json::String(value) => Ok(value)
    _ => Err(fail(InvalidType, path + " (string required)"))
  }
}

///|
fn expect_array(
  json : @json.Json,
  path : String,
) -> Result[Array[@json.Json], RecipeError] {
  match json {
    @json.Json::Array(items) => Ok(items)
    _ => Err(fail(InvalidType, path + " (array required)"))
  }
}

///|
/// Integral JSON numbers only. Floats such as `1.5`, `1e3` and non-finite
/// numbers are refused rather than truncated.
fn expect_int(
  json : @json.Json,
  path : String,
) -> Result[Int, RecipeError] {
  match json {
    @json.Json::Number(value, ..) => {
      if value.is_nan() || value.is_inf() || value != value.trunc() {
        return Err(fail(InvalidType, path + " (integer required)"))
      }
      if value < -9_007_199_254_740_991.0 || value > 9_007_199_254_740_991.0 {
        return Err(fail(InvalidValue, path + " (out of range)"))
      }
      Ok(value.to_int64().to_int())
    }
    _ => Err(fail(InvalidType, path + " (integer required)"))
  }
}

///|
fn require_field(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[@json.Json, RecipeError] {
  match object.get(key) {
    Some(value) => Ok(value)
    None => Err(fail(MissingField, path))
  }
}

///|
fn required_string(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[String, RecipeError] {
  match require_field(object, key, path) {
    Ok(value) => expect_string(value, path)
    Err(error) => Err(error)
  }
}

///|
fn optional_string(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[String?, RecipeError] {
  match object.get(key) {
    Some(value) => match expect_string(value, path) {
      Ok(text) => Ok(Some(text))
      Err(error) => Err(error)
    }
    None => Ok(None)
  }
}

///|
fn required_object(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[Map[String, @json.Json], RecipeError] {
  match require_field(object, key, path) {
    Ok(value) => expect_object(value, path)
    Err(error) => Err(error)
  }
}

///|
fn optional_object(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[Map[String, @json.Json]?, RecipeError] {
  match object.get(key) {
    Some(value) => match expect_object(value, path) {
      Ok(found) => Ok(Some(found))
      Err(error) => Err(error)
    }
    None => Ok(None)
  }
}

///|
fn required_array(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[Array[@json.Json], RecipeError] {
  match require_field(object, key, path) {
    Ok(value) => expect_array(value, path)
    Err(error) => Err(error)
  }
}

///|
fn optional_array(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[Array[@json.Json]?, RecipeError] {
  match object.get(key) {
    Some(value) => match expect_array(value, path) {
      Ok(found) => Ok(Some(found))
      Err(error) => Err(error)
    }
    None => Ok(None)
  }
}

///|
fn required_int(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[Int, RecipeError] {
  match require_field(object, key, path) {
    Ok(value) => expect_int(value, path)
    Err(error) => Err(error)
  }
}

///|
fn optional_int(
  object : Map[String, @json.Json],
  key : String,
  path : String,
) -> Result[Int?, RecipeError] {
  match object.get(key) {
    Some(value) => match expect_int(value, path) {
      Ok(number) => Ok(Some(number))
      Err(error) => Err(error)
    }
    None => Ok(None)
  }
}

///|
/// Fields that ADR-0013 classifies as unsupported in A2 (host network, port
/// publishing, privileged/capability expansion, devices, quotas). They are not
/// "unknown": they deserve a dedicated reason so an operator can see that the
/// recipe tried to widen the boundary.
fn unsupported_fields() -> Array[String] {
  [
    "privileged", "cap_add", "cap-add", "cap_drop", "devices", "ports",
    "publish", "port_publish", "expose", "host_network", "network_host",
    "pid", "ipc", "userns", "disk", "disk_quota", "quota", "volumes",
    "security_opt", "runtime", "sandbox",
  ]
}

///|
fn reject_unknown_fields(
  object : Map[String, @json.Json],
  allowed : Array[String],
  path : String,
) -> Result[Unit, RecipeError] {
  let unsupported = unsupported_fields()
  for key in object.keys() {
    let mut permitted = false
    for candidate in allowed {
      if key == candidate {
        permitted = true
        break
      }
    }
    if permitted {
      continue
    }
    let mut forbidden = false
    for candidate in unsupported {
      if key == candidate {
        forbidden = true
        break
      }
    }
    if forbidden {
      return Err(
        fail_detail(
          UnsupportedField,
          path + key,
          "field is not supported by A2",
        ),
      )
    }
    return Err(fail(UnknownField, path + key))
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Field validators.

///|
fn validate_string_array(
  items : Array[@json.Json],
  path : String,
  max_items : Int,
  max_item_bytes : Int,
  allow_layout : Bool,
) -> Result[Array[String], RecipeError] {
  if items.length() == 0 || items.length() > max_items {
    return Err(
      fail_detail(ArgvInvalid, path, "argument count is outside the allowed range"),
    )
  }
  let out : Array[String] = []
  let mut index = 0
  for item in items {
    let value = match expect_string(item, path + "[" + index.to_string() + "]") {
      Ok(text) => text
      Err(error) => return Err(error)
    }
    if value.length() == 0 || value.length() > max_item_bytes {
      return Err(
        fail_detail(ArgvInvalid, path, "argument length is outside the allowed range"),
      )
    }
    if has_control_chars(value, allow_layout) {
      return Err(
        fail_detail(ArgvInvalid, path, "argument contains a control character"),
      )
    }
    out.push(value)
    index = index + 1
  }
  Ok(out)
}

///|
fn parse_image(
  object : Map[String, @json.Json],
) -> Result[RecipeImage, RecipeError] {
  match reject_unknown_fields(object, ["ref", "digest"], "image.") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let reference = match required_string(object, "ref", "image.ref") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match image_repository(reference) {
    Some(_) => ()
    None => return Err(fail(ImageRefInvalid, "image.ref"))
  }
  let digest = match required_string(object, "digest", "image.digest") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_image_digest(digest) {
    return Err(
      fail_detail(
        ImageDigestInvalid,
        "image.digest",
        "expected sha256:<64 lowercase hex>",
      ),
    )
  }
  Ok({ reference, digest })
}

///|
fn parse_mount(
  item : @json.Json,
  index : Int,
) -> Result[RecipeMount, RecipeError] {
  let path = "mounts[" + index.to_string() + "]"
  let object = match expect_object(item, path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match reject_unknown_fields(object, ["source", "target", "mode"], path + ".") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let source_text = match required_string(object, "source", path + ".source") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source = if source_text == "workspace" {
    MountWorkspace
  } else if source_text == "scratch" {
    MountScratch
  } else {
    return Err(
      fail_detail(
        MountSourceInvalid,
        path + ".source",
        "allowed sources are workspace and scratch",
      ),
    )
  }
  let target = match required_string(object, "target", path + ".target") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_container_path(target) {
    return Err(
      fail_detail(
        MountTargetInvalid,
        path + ".target",
        "expected an absolute normalised container path",
      ),
    )
  }
  let mode_text = match required_string(object, "mode", path + ".mode") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mode = if mode_text == "rw" {
    MountReadWrite
  } else if mode_text == "ro" {
    MountReadOnly
  } else {
    return Err(
      fail_detail(
        InvalidValue,
        path + ".mode",
        "allowed modes are rw and ro",
      ),
    )
  }
  Ok({ source, target, mode })
}

///|
fn parse_mounts(
  items : Array[@json.Json],
) -> Result[Array[RecipeMount], RecipeError] {
  if items.length() == 0 || items.length() > MAX_MOUNTS {
    return Err(
      fail_detail(MountInvalid, "mounts", "mount count is outside the allowed range"),
    )
  }
  let mounts : Array[RecipeMount] = []
  let mut index = 0
  let mut workspace_count = 0
  let mut scratch_count = 0
  for item in items {
    let mount = match parse_mount(item, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match mount.source {
      MountWorkspace => workspace_count = workspace_count + 1
      MountScratch => scratch_count = scratch_count + 1
    }
    mounts.push(mount)
    index = index + 1
  }
  if workspace_count == 0 {
    return Err(
      fail_detail(
        MountMissingWorkspace,
        "mounts",
        "a recipe must mount the bound workspace root exactly once",
      ),
    )
  }
  if workspace_count > 1 {
    return Err(
      fail_detail(MountDuplicate, "mounts", "workspace may be mounted once"),
    )
  }
  if scratch_count > 1 {
    return Err(
      fail_detail(MountDuplicate, "mounts", "scratch may be mounted once"),
    )
  }
  for left_index in 0..<mounts.length() {
    let next_index = left_index + 1
    for right_index in next_index..<mounts.length() {
      if mounts[left_index].target == mounts[right_index].target {
        return Err(
          fail_detail(
            MountDuplicate,
            "mounts",
            "two mounts share the same target",
          ),
        )
      }
    }
  }
  Ok(mounts)
}

///|
fn path_within(base : String, path : String) -> Bool {
  if path == base {
    return true
  }
  if base.length() >= path.length() {
    return false
  }
  path.has_prefix(base) && path.get_char(base.length()) == Some('/')
}

///|
fn parse_workdir(
  object : Map[String, @json.Json],
  mounts : Array[RecipeMount],
) -> Result[String?, RecipeError] {
  let declared = match optional_string(object, "workdir", "workdir") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let effective = match declared {
    Some(value) => value
    None => DEFAULT_WORKDIR
  }
  if !is_valid_container_path(effective) {
    return Err(
      fail_detail(
        WorkdirInvalid,
        "workdir",
        "expected an absolute normalised container path",
      ),
    )
  }
  let mut inside = false
  for mount in mounts {
    if path_within(mount.target, effective) {
      inside = true
      break
    }
  }
  if !inside {
    return Err(
      fail_detail(
        WorkdirOutsideMount,
        "workdir",
        "workdir must stay inside a declared mount target",
      ),
    )
  }
  Ok(declared)
}

///|
fn parse_user(
  object : Map[String, @json.Json],
) -> Result[String?, RecipeError] {
  let declared = match optional_string(object, "user", "user") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match declared {
    Some(value) =>
      if !is_valid_user(value) {
        return Err(
          fail_detail(
            UserInvalid,
            "user",
            "expected a user name, uid or uid:gid",
          ),
        )
      }
    None => ()
  }
  Ok(declared)
}

///|
fn parse_env_allowlist(
  object : Map[String, @json.Json],
) -> Result[Array[String]?, RecipeError] {
  let items = match optional_array(object, "env_allowlist", "env_allowlist") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  if items.length() > MAX_ENV_NAMES {
    return Err(
      fail_detail(
        EnvNameInvalid,
        "env_allowlist",
        "too many environment names",
      ),
    )
  }
  let names : Array[String] = []
  let mut index = 0
  for item in items {
    let path = "env_allowlist[" + index.to_string() + "]"
    let name = match expect_string(item, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !is_valid_env_name(name) {
      return Err(
        fail_detail(EnvNameInvalid, path, "expected an environment variable name"),
      )
    }
    for existing in names {
      if existing == name {
        return Err(
          fail_detail(EnvNameDuplicate, path, "environment name is duplicated"),
        )
      }
    }
    names.push(name)
    index = index + 1
  }
  Ok(Some(names))
}

///|
fn parse_limits(
  object : Map[String, @json.Json],
) -> Result[RecipeLimits, RecipeError] {
  match reject_unknown_fields(object, ["cpu_millis", "memory_mb", "pids"], "limits.") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let cpu = match optional_int(object, "cpu_millis", "limits.cpu_millis") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let memory = match optional_int(object, "memory_mb", "limits.memory_mb") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let pids = match optional_int(object, "pids", "limits.pids") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match cpu {
    Some(value) =>
      if value < MIN_CPU_MILLIS || value > MAX_CPU_MILLIS {
        return Err(
          fail_detail(
            LimitOutOfRange,
            "limits.cpu_millis",
            "outside the supported range",
          ),
        )
      }
    None => ()
  }
  match memory {
    Some(value) =>
      if value < MIN_MEMORY_MB || value > MAX_MEMORY_MB {
        return Err(
          fail_detail(
            LimitOutOfRange,
            "limits.memory_mb",
            "outside the supported range",
          ),
        )
      }
    None => ()
  }
  match pids {
    Some(value) =>
      if value < MIN_PIDS || value > MAX_PIDS {
        return Err(
          fail_detail(LimitOutOfRange, "limits.pids", "outside the supported range"),
        )
      }
    None => ()
  }
  Ok({ cpu_millis: cpu, memory_mb: memory, pids })
}

///|
fn parse_network(
  object : Map[String, @json.Json],
) -> Result[NetworkMode?, RecipeError] {
  let declared = match optional_string(object, "network", "network") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match declared {
    Some(value) =>
      if value == "none" {
        Ok(Some(NetworkNone))
      } else if value == "bridge" {
        Ok(Some(NetworkBridge))
      } else {
        Err(
          fail_detail(
            NetworkUnsupported,
            "network",
            "only none and bridge are supported in A2",
          ),
        )
      }
    None => Ok(None)
  }
}

///|
fn parse_timeout(
  object : Map[String, @json.Json],
  path : String,
  min_s : Int,
  max_s : Int,
  code~ : RecipeErrorCode = HookTimeoutRange,
) -> Result[Int, RecipeError] {
  let value = match required_int(object, "timeout_s", path + ".timeout_s") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if value < min_s || value > max_s {
    return Err(
      fail_detail(
        code,
        path + ".timeout_s",
        "timeout is outside the supported range",
      ),
    )
  }
  Ok(value)
}

///|
fn parse_hook(
  object : Map[String, @json.Json],
  path : String,
) -> Result[LifecycleHook, RecipeError] {
  match reject_unknown_fields(object, ["argv", "script", "timeout_s"], path + ".") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let has_argv = object.get("argv") is Some(_)
  let has_script = object.get("script") is Some(_)
  if has_argv && has_script {
    return Err(
      fail_detail(
        HookConflict,
        path,
        "argv and script are mutually exclusive",
      ),
    )
  }
  if !has_argv && !has_script {
    return Err(
      fail_detail(
        MissingField,
        path,
        "one of argv or script is required",
      ),
    )
  }
  let timeout_s = match parse_timeout(object, path, MIN_HOOK_TIMEOUT_S, MAX_HOOK_TIMEOUT_S) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let command = if has_argv {
    let items = match required_array(object, "argv", path + ".argv") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let argv = match validate_string_array(
      items,
      path + ".argv",
      MAX_ARGV_ITEMS,
      MAX_ARGV_ELEMENT_BYTES,
      false,
    ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    HookArgv(argv)
  } else {
    let script = match required_string(object, "script", path + ".script") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if script.length() == 0 || script.length() > MAX_SCRIPT_BYTES ||
      has_control_chars(script, true) {
      return Err(
        fail_detail(
          ScriptInvalid,
          path + ".script",
          "script must be bounded text without control characters",
        ),
      )
    }
    HookScript(script)
  }
  Ok({ command, timeout_s })
}

///|
fn parse_lifecycle(
  object : Map[String, @json.Json],
) -> Result[RecipeLifecycle, RecipeError] {
  match reject_unknown_fields(object, ["prepare", "start", "stop"], "lifecycle.") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let hooks : Array[LifecycleHook] = []
  for name in ["prepare", "start", "stop"] {
    let path = "lifecycle." + name
    let hook_object = match required_object(object, name, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let hook = match parse_hook(hook_object, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    hooks.push(hook)
  }
  Ok({ prepare: hooks[0], start: hooks[1], stop: hooks[2] })
}

///|
fn parse_doctor(
  object : Map[String, @json.Json],
) -> Result[RecipeDoctor?, RecipeError] {
  let doctor = match optional_object(object, "doctor", "doctor") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  match reject_unknown_fields(doctor, ["argv", "timeout_s"], "doctor.") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let timeout_s = match parse_timeout(
    doctor,
    "doctor",
    MIN_DOCTOR_TIMEOUT_S,
    MAX_DOCTOR_TIMEOUT_S,
    code=DoctorInvalid,
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let items = match required_array(doctor, "argv", "doctor.argv") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let argv = match validate_string_array(
    items,
    "doctor.argv",
    MAX_ARGV_ITEMS,
    MAX_ARGV_ELEMENT_BYTES,
    false,
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(Some({ argv, timeout_s }))
}

///|
fn parse_source(
  object : Map[String, @json.Json],
) -> Result[RecipeSource, RecipeError] {
  match reject_unknown_fields(object, ["kind", "path", "author", "created_at"], "source.") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let kind = match required_string(object, "kind", "source.kind") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if kind != "local_file" {
    return Err(
      fail_detail(
        SourceInvalid,
        "source.kind",
        "A2 only imports local files",
      ),
    )
  }
  let path = match required_string(object, "path", "source.path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_source_path(path) {
    return Err(
      fail_detail(
        SourceInvalid,
        "source.path",
        "expected an absolute normalised path",
      ),
    )
  }
  let author = match required_string(object, "author", "source.author") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if author.length() < MIN_SOURCE_AUTHOR_BYTES ||
    author.length() > MAX_SOURCE_AUTHOR_BYTES ||
    has_control_chars(author, false) {
    return Err(
      fail_detail(
        SourceInvalid,
        "source.author",
        "author is outside the allowed length or contains control characters",
      ),
    )
  }
  let created_at = match required_string(object, "created_at", "source.created_at") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_timestamp(created_at) {
    return Err(
      fail_detail(
        TimestampInvalid,
        "source.created_at",
        "expected YYYY-MM-DDTHH:MM:SSZ",
      ),
    )
  }
  Ok({ kind, path, author, created_at })
}

///|
pub fn decode_ssh_signature(sig : String) -> Bytes? {
  if sig.length() == 0 || sig.length() > 8192 {
    return None
  }
  if has_control_chars(sig, false) {
    return None
  }
  let bytes = @base64.decode(sig) catch { _ => return None }
  if bytes.length() < 64 || bytes.length() > 4096 {
    return None
  }
  let view = bytes.exact_view()
  if view.length() < 6 {
    return None
  }
  let magic = [0x53, 0x53, 0x48, 0x53, 0x49, 0x47]
  for index in 0..<6 {
    if view[index].to_int() != magic[index] {
      return None
    }
  }
  Some(bytes)
}

///|
fn parse_signature(
  object : Map[String, @json.Json],
) -> Result[RecipeSignature, RecipeError] {
  match reject_unknown_fields(object, ["key_id", "alg", "sig"], "signature.") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let key_id = match required_string(object, "key_id", "signature.key_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_key_id(key_id) {
    return Err(
      fail_detail(
        KeyIdInvalid,
        "signature.key_id",
        "key id contains characters outside the allowed set",
      ),
    )
  }
  let alg = match required_string(object, "alg", "signature.alg") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if alg != "ed25519" {
    return Err(
      fail_detail(
        SignatureAlgUnsupported,
        "signature.alg",
        "only ed25519 is supported",
      ),
    )
  }
  let sig = match required_string(object, "sig", "signature.sig") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match decode_ssh_signature(sig) {
    Some(_) => ()
    None =>
      return Err(
        fail_detail(
          SignatureInvalid,
          "signature.sig",
          "expected the base64 SSHSIG body without whitespace",
        ),
      )
  }
  Ok({ key_id, alg, sig })
}

// ---------------------------------------------------------------------------
// Entry points.

///|
/// Parse and strictly validate a recipe document. The document must be UTF-8
/// text no larger than `MAX_RECIPE_BYTES`; duplicate JSON keys are refused so
/// two readers can never disagree about the same bytes.
pub fn parse_recipe(text : String) -> Result[Recipe, RecipeError] {
  if text.length() == 0 || text.length() > MAX_RECIPE_BYTES {
    return Err(
      fail_detail(InvalidJson, "recipe", "document size is outside the allowed range"),
    )
  }
  let json = @json.parse(text, reject_duplicate_keys=true, max_nesting_depth=64) catch {
    _ => return Err(fail(InvalidJson, "recipe"))
  }
  let object = match expect_object(json, "recipe") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match reject_unknown_fields(
    object,
    [
      "schema_version", "name", "version", "image", "workdir", "user", "mounts",
      "env_allowlist", "limits", "network", "lifecycle", "doctor", "source",
      "signature",
    ],
    "",
  ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let schema_version = match required_int(object, "schema_version", "schema_version") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if schema_version != RECIPE_SCHEMA_VERSION {
    return Err(
      fail_detail(
        SchemaVersionUnsupported,
        "schema_version",
        "only schema_version 1 is supported",
      ),
    )
  }
  let name = match required_string(object, "name", "name") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_recipe_name(name) {
    return Err(
      fail_detail(
        NameInvalid,
        "name",
        "expected [a-z0-9][a-z0-9-]{0,63}",
      ),
    )
  }
  let version = match required_string(object, "version", "version") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_semver(version) {
    return Err(
      fail_detail(VersionInvalid, "version", "expected a SemVer 2.0.0 string"),
    )
  }
  let image_object = match required_object(object, "image", "image") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let image = match parse_image(image_object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mount_items = match required_array(object, "mounts", "mounts") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mounts = match parse_mounts(mount_items) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let workdir = match parse_workdir(object, mounts) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let user = match parse_user(object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let env_allowlist = match parse_env_allowlist(object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let limits = match optional_object(object, "limits", "limits") {
    Ok(Some(value)) =>
      match parse_limits(value) {
        Ok(found) => found
        Err(error) => return Err(error)
      }
    Ok(None) => { cpu_millis: None, memory_mb: None, pids: None }
    Err(error) => return Err(error)
  }
  let network = match parse_network(object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lifecycle_object = match required_object(object, "lifecycle", "lifecycle") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lifecycle = match parse_lifecycle(lifecycle_object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let doctor = match parse_doctor(object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source_object = match required_object(object, "source", "source") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source = match parse_source(source_object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let signature_object = match required_object(object, "signature", "signature") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let signature = match parse_signature(signature_object) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    schema_version,
    name,
    version,
    image,
    workdir,
    user,
    mounts,
    env_allowlist,
    limits,
    network,
    lifecycle,
    doctor,
    source,
    signature,
  })
}

///|
/// Parse an identity reference such as `node-dev@1.2.3`.
pub fn parse_identity(text : String) -> Result[(String, String), RecipeError] {
  match parse_recipe_identity(text) {
    Some(value) => Ok(value)
    None => Err(fail(IdentityInvalid, "recipe_ref"))
  }
}
