///|
/// Strict skill manifest parsing (ADR-0015 §2.1).
///
/// Every unknown field, missing required field, invalid enum, duplicate command
/// id, unsafe path and out-of-range limit is refused with a fixed reason code.
/// There is no "best effort" mode and no silent normalisation other than the
/// documented permission dedupe+sort.
pub(all) struct SkillFault {
  code : String
  detail : String
}

///|
pub fn SkillFault::new(code : String, detail : String) -> SkillFault {
  { code, detail }
}

///|
fn skill_fail(code : String, detail : String) -> SkillFault {
  SkillFault::new(code, detail)
}

///|
pub const MAX_SKILL_ENTRY_BYTES : Int = 32_768

///|
pub const MAX_SKILL_RESOURCE_BYTES : Int = 262_144

///|
pub const MAX_SKILL_BUNDLE_BYTES : Int = 4_194_304

///|
pub const MAX_SKILL_COMMANDS : Int = 32

///|
pub const MAX_SKILL_RESOURCES : Int = 64

///|
pub const MAX_SKILL_ARGV_ITEMS : Int = 64

///|
pub const MAX_SKILL_ARGV_BYTES : Int = 4096

///|
pub const MAX_SKILL_TIMEOUT_MS : Int = 600_000

///|
pub const MAX_SKILL_OUTPUT_BYTES : Int = 1_048_576

///|
pub const SKILL_MANIFEST_FILE : String = "skill.json"

///|
fn skill_string_field(
  object : Map[String, @json.Json],
  key : String,
) -> Result[String, SkillFault] {
  match object.get(key) {
    Some(@json.Json::String(value)) => Ok(value)
    Some(_) =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, key + " must be a string"))
    None =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "missing " + key))
  }
}

///|
fn skill_optional_string(
  object : Map[String, @json.Json],
  key : String,
) -> Result[String, SkillFault] {
  match object.get(key) {
    Some(@json.Json::String(value)) => Ok(value)
    Some(_) =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, key + " must be a string"))
    None => Ok("")
  }
}

///|
fn skill_int_field(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Int, SkillFault] {
  match object.get(key) {
    Some(value) =>
      match @contracts.as_int(value) {
        Some(number) => Ok(number)
        None =>
          Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, key + " must be an integer"))
      }
    None =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "missing " + key))
  }
}

///|
fn skill_object_field(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Map[String, @json.Json], SkillFault] {
  match object.get(key) {
    Some(@json.Json::Object(value)) => Ok(value)
    Some(_) =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, key + " must be an object"))
    None =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "missing " + key))
  }
}

///|
fn skill_array_field(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Array[@json.Json], SkillFault] {
  match object.get(key) {
    Some(@json.Json::Array(value)) => Ok(value)
    Some(_) =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, key + " must be an array"))
    None =>
      Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "missing " + key))
  }
}

///|
fn reject_skill_unknown_fields(
  object : Map[String, @json.Json],
  allowed : Array[String],
) -> Result[Unit, SkillFault] {
  for key in object.keys() {
    let mut permitted = false
    for candidate in allowed {
      if key == candidate {
        permitted = true
        break
      }
    }
    if !permitted {
      return Err(
        skill_fail(@contracts.SKILL_ERR_UNKNOWN_FIELD, "unknown field: " + key),
      )
    }
  }
  Ok(())
}

///|
/// `[a-z0-9][a-z0-9-]{0,63}`; same grammar as recipe names.
pub fn is_valid_skill_name(text : String) -> Bool {
  @recipes.is_valid_recipe_name(text)
}

///|
/// Strict semver, exact string matching at use sites.
pub fn is_valid_skill_version(text : String) -> Bool {
  @recipes.is_valid_semver(text)
}

///|
/// Package-internal relative path: no absolute/`~` start, no `..`, empty or
/// backslash segments, no control characters/NUL, length ≤256.
pub fn is_valid_skill_path(text : String) -> Bool {
  if text.length() == 0 || text.length() > 256 {
    return false
  }
  if text.get_char(0) == Some('/') || text.get_char(0) == Some('~') {
    return false
  }
  if text.get_char(text.length() - 1) == Some('/') {
    return false
  }
  let mut segment_empty = true
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let code = ch.to_int()
    if code < 32 || code == 127 {
      return false
    }
    if ch == '\\' {
      return false
    }
    if ch == '/' {
      if segment_empty {
        return false
      }
      segment_empty = true
    } else {
      segment_empty = false
    }
  }
  if segment_empty {
    return false
  }
  // `..` as a whole segment is a traversal escape.
  let parts = text.split("/")
  for part in parts {
    if part == ".." || part == "." {
      return false
    }
  }
  true
}

///|
pub fn is_valid_skill_content_hash(text : String) -> Bool {
  if !text.has_prefix("sha256:") || text.length() != 71 {
    return false
  }
  for index in 7..<71 {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
    if !ok {
      return false
    }
  }
  true
}

///|
fn valid_skill_text(text : String, allow_layout : Bool, max_bytes : Int) -> Bool {
  if text.length() > max_bytes {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let code = ch.to_int()
    if code < 32 {
      if !(allow_layout && (ch == '\n' || ch == '\r' || ch == '\t')) {
        return false
      }
    } else if code == 127 {
      return false
    }
  }
  true
}

///|
fn valid_skill_command_id(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '-' ||
      ch == '_' ||
      ch == '.'
    if !ok {
      return false
    }
  }
  true
}

///|
fn validate_skill_permissions(
  values : Array[@json.Json],
) -> Result[Array[String], SkillFault] {
  let seen : Array[String] = []
  for value in values {
    let permission = match value {
      @json.Json::String(found) => found
      _ =>
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_INVALID_PERMISSION,
            "permission must be a string",
          ),
        )
    }
    if !@contracts.skill_permission_valid(permission) {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_INVALID_PERMISSION,
          "unknown permission: " + permission,
        ),
      )
    }
    let mut duplicate = false
    for existing in seen {
      if existing == permission {
        duplicate = true
        break
      }
    }
    if !duplicate {
      seen.push(permission)
    }
  }
  let out : Array[String] = []
  for value in seen {
    out.push(value)
  }
  out.sort_by(fn(left : String, right : String) -> Int32 {
    @recipes.compare_utf8(left, right)
  })
  Ok(out)
}

///|
fn parse_skill_entry(
  object : Map[String, @json.Json],
) -> Result[(String, Int), SkillFault] {
  let allowed = ["path", "max_bytes"]
  match reject_skill_unknown_fields(object, allowed) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = match skill_string_field(object, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let max_bytes = match skill_int_field(object, "max_bytes") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_valid_skill_path(path) {
    return Err(skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "invalid entry path"))
  }
  if max_bytes <= 0 || max_bytes > MAX_SKILL_ENTRY_BYTES {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_LIMIT_EXCEEDED,
        "entry max_bytes is out of range",
      ),
    )
  }
  Ok((path, max_bytes))
}

///|
fn parse_skill_resources(
  values : Array[@json.Json],
) -> Result[Array[@contracts.SkillResource], SkillFault] {
  if values.length() > MAX_SKILL_RESOURCES {
    return Err(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "too many resources"),
    )
  }
  let out : Array[@contracts.SkillResource] = []
  let paths : Array[String] = []
  for value in values {
    let object = match value {
      @json.Json::Object(found) => found
      _ =>
        return Err(
          skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "resource must be an object"),
        )
    }
    let allowed = ["path", "description"]
    match reject_skill_unknown_fields(object, allowed) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let path = match skill_string_field(object, "path") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    let description = match skill_string_field(object, "description") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if !is_valid_skill_path(path) {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "invalid resource path"),
      )
    }
    if !valid_skill_text(description, true, 512) {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "resource description is invalid"),
      )
    }
    for existing in paths {
      if existing == path {
        return Err(
          skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "duplicate resource path"),
        )
      }
    }
    paths.push(path)
    out.push({ path, description })
  }
  Ok(out)
}

///|
pub type SkillCommandList = Array[@contracts.SkillCommand]

///|
fn parse_skill_commands(
  values : Array[@json.Json],
) -> Result[SkillCommandList, SkillFault] {
  if values.length() > MAX_SKILL_COMMANDS {
    return Err(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "too many commands"),
    )
  }
  let out : Array[@contracts.SkillCommand] = []
  let ids : Array[String] = []
  for value in values {
    let object = match value {
      @json.Json::Object(found) => found
      _ =>
        return Err(
          skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "command must be an object"),
        )
    }
    let allowed = ["id", "argv", "mode", "timeout_ms", "max_output_bytes"]
    match reject_skill_unknown_fields(object, allowed) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let id = match skill_string_field(object, "id") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if !valid_skill_command_id(id) {
      return Err(skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid command id"))
    }
    for existing in ids {
      if existing == id {
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_DUPLICATE_COMMAND,
            "duplicate command id: " + id,
          ),
        )
      }
    }
    ids.push(id)
    let argv_values = match skill_array_field(object, "argv") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if argv_values.length() == 0 || argv_values.length() > MAX_SKILL_ARGV_ITEMS {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid argv length"),
      )
    }
    let argv : Array[String] = []
    for argument in argv_values {
      let text = match argument {
        @json.Json::String(found) => found
        _ =>
          return Err(
            skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "argv must be strings"),
          )
      }
      if !valid_skill_text(text, false, MAX_SKILL_ARGV_BYTES) {
        return Err(
          skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "argv value is invalid"),
        )
      }
      argv.push(text)
    }
    let mode = match skill_string_field(object, "mode") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if !@contracts.skill_entry_mode_valid(mode) {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid command mode"),
      )
    }
    let timeout_ms = match skill_int_field(object, "timeout_ms") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if timeout_ms <= 0 || timeout_ms > MAX_SKILL_TIMEOUT_MS {
      return Err(
        skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "timeout_ms is out of range"),
      )
    }
    let max_output_bytes = match skill_int_field(object, "max_output_bytes") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if max_output_bytes <= 0 || max_output_bytes > MAX_SKILL_OUTPUT_BYTES {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_LIMIT_EXCEEDED,
          "max_output_bytes is out of range",
        ),
      )
    }
    out.push({ id, argv, mode, timeout_ms, max_output_bytes })
  }
  Ok(out)
}

///|
fn parse_skill_dependencies(
  values : Array[@json.Json],
) -> Result[Array[@contracts.SkillDependency], SkillFault] {
  if values.length() > 64 {
    return Err(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "too many dependencies"),
    )
  }
  let out : Array[@contracts.SkillDependency] = []
  for value in values {
    let object = match value {
      @json.Json::Object(found) => found
      _ =>
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_INVALID_MANIFEST,
            "dependency must be an object",
          ),
        )
    }
    let allowed = ["kind", "name", "version", "content_hash"]
    match reject_skill_unknown_fields(object, allowed) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let kind = match skill_string_field(object, "kind") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if kind != "binary" && kind != "skill" {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid dependency kind"),
      )
    }
    let name = match skill_string_field(object, "name") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if !valid_skill_text(name, false, 128) || name == "" {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid dependency name"),
      )
    }
    let version = match skill_optional_string(object, "version") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    let content_hash = match skill_optional_string(object, "content_hash") {
      Ok(found) => found
      Err(error) => return Err(error)
    }
    if version != "" && !is_valid_skill_version(version) {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_VERSION, "invalid dependency version"),
      )
    }
    if content_hash != "" && !is_valid_skill_content_hash(content_hash) {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid dependency hash"),
      )
    }
    if kind == "skill" && (version == "" || content_hash == "") {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_INVALID_MANIFEST,
          "skill dependencies require an exact version and content_hash",
        ),
      )
    }
    out.push({ kind, name, version, content_hash })
  }
  Ok(out)
}

///|
fn parse_skill_source(
  object : Map[String, @json.Json],
) -> SkillSourceResult {
  let allowed = ["kind", "path", "author", "created_at"]
  match reject_skill_unknown_fields(object, allowed) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let kind = match skill_string_field(object, "kind") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if kind != @contracts.SKILL_SOURCE_LOCAL_DIRECTORY {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_MANIFEST,
        "source.kind must be local_directory",
      ),
    )
  }
  let path = match skill_string_field(object, "path") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !valid_skill_text(path, false, 1024) || path == "" {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid source.path"),
    )
  }
  let author = match skill_string_field(object, "author") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !valid_skill_text(author, false, 128) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid source.author"),
    )
  }
  let created_at = match skill_string_field(object, "created_at") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !@recipes.is_valid_timestamp(created_at) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid source.created_at"),
    )
  }
  Ok({ kind, path, author, created_at })
}

///|
fn parse_skill_signature(
  object : Map[String, @json.Json],
) -> SkillSignatureResult {
  let allowed = ["key_id", "alg", "sig"]
  match reject_skill_unknown_fields(object, allowed) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let key_id = match skill_string_field(object, "key_id") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !@recipes.is_valid_key_id(key_id) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid signature key_id"),
    )
  }
  let alg = match skill_string_field(object, "alg") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if alg != @contracts.SKILL_SIGNATURE_ALG_ED25519 {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_MANIFEST,
        "signature.alg must be ed25519",
      ),
    )
  }
  let sig = match skill_string_field(object, "sig") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if sig == "" {
    return Err(skill_fail(@contracts.SKILL_ERR_UNSIGNED, "signature is empty"))
  }
  Ok({ key_id, alg, sig })
}

///|
fn parse_skill_limits(
  object : Map[String, @json.Json],
) -> SkillLimitsResult {
  let allowed = ["max_runtime_ms", "max_output_bytes"]
  match reject_skill_unknown_fields(object, allowed) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let max_runtime_ms = match object.get("max_runtime_ms") {
    Some(value) =>
      match @contracts.as_int(value) {
        Some(found) => found
        None =>
          return Err(
            skill_fail(
              @contracts.SKILL_ERR_INVALID_MANIFEST,
              "limits.max_runtime_ms must be an integer",
            ),
          )
      }
    None => 0
  }
  let max_output_bytes = match object.get("max_output_bytes") {
    Some(value) =>
      match @contracts.as_int(value) {
        Some(found) => found
        None =>
          return Err(
            skill_fail(
              @contracts.SKILL_ERR_INVALID_MANIFEST,
              "limits.max_output_bytes must be an integer",
            ),
          )
      }
    None => 0
  }
  if max_runtime_ms < 0 || max_runtime_ms > MAX_SKILL_TIMEOUT_MS {
    return Err(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "max_runtime_ms is out of range"),
    )
  }
  if max_output_bytes < 0 || max_output_bytes > MAX_SKILL_OUTPUT_BYTES {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_LIMIT_EXCEEDED,
        "max_output_bytes is out of range",
      ),
    )
  }
  Ok({ max_runtime_ms, max_output_bytes })
}

///|
/// Parse the manifest document. The `content_hash` value is carried through
/// unchanged; bundle import recomputes and compares it.
pub fn parse_skill_manifest(text : String) -> SkillManifestResult {
  if text.length() == 0 {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "manifest is empty"),
    )
  }
  if text.length() > 262_144 {
    return Err(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "manifest is too large"),
    )
  }
  let json = @json.parse(
    text,
    reject_duplicate_keys=true,
    max_nesting_depth=16,
  ) catch {
    _ =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "manifest is not valid JSON"),
      )
  }
  let object = match json {
    @json.Json::Object(found) => found
    _ =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "manifest must be an object"),
      )
  }
  let allowed = [
    "schema_version",
    "name",
    "version",
    "description",
    "permissions",
    "entry",
    "resources",
    "commands",
    "dependencies",
    "source",
    "content_hash",
    "signature",
    "limits",
  ]
  match reject_skill_unknown_fields(object, allowed) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let schema_version = match skill_int_field(object, "schema_version") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if schema_version != @contracts.SKILL_SCHEMA_VERSION {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_MANIFEST,
        "unsupported schema_version",
      ),
    )
  }
  let name = match skill_string_field(object, "name") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !is_valid_skill_name(name) {
    return Err(skill_fail(@contracts.SKILL_ERR_INVALID_NAME, "invalid skill name"))
  }
  let version = match skill_string_field(object, "version") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !is_valid_skill_version(version) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_VERSION, "invalid skill version"),
    )
  }
  let description = match skill_string_field(object, "description") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !valid_skill_text(description, true, 512) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid description"),
    )
  }
  let permissions_values = match skill_array_field(object, "permissions") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let permissions = match validate_skill_permissions(permissions_values) {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let entry_object = match skill_object_field(object, "entry") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let (entry_path, entry_max_bytes) = match parse_skill_entry(entry_object) {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let resources = match object.get("resources") {
    Some(@json.Json::Array(items)) =>
      match parse_skill_resources(items) {
        Ok(found) => found
        Err(error) => return Err(error)
      }
    Some(_) =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "resources must be an array"),
      )
    None => []
  }
  let commands = match object.get("commands") {
    Some(@json.Json::Array(items)) =>
      match parse_skill_commands(items) {
        Ok(found) => found
        Err(error) => return Err(error)
      }
    Some(_) =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "commands must be an array"),
      )
    None => []
  }
  let dependencies = match object.get("dependencies") {
    Some(@json.Json::Array(items)) =>
      match parse_skill_dependencies(items) {
        Ok(found) => found
        Err(error) => return Err(error)
      }
    Some(_) =>
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_INVALID_MANIFEST,
          "dependencies must be an array",
        ),
      )
    None => []
  }
  let source_object = match skill_object_field(object, "source") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let source = match parse_skill_source(source_object) {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let content_hash = match skill_string_field(object, "content_hash") {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  if !is_valid_skill_content_hash(content_hash) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "invalid content_hash"),
    )
  }
  let signature_object = match object.get("signature") {
    Some(@json.Json::Object(found)) => found
    Some(_) =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "signature must be an object"),
      )
    None => return Err(skill_fail(@contracts.SKILL_ERR_UNSIGNED, "missing signature"))
  }
  let signature = match parse_skill_signature(signature_object) {
    Ok(found) => found
    Err(error) => return Err(error)
  }
  let limits = match object.get("limits") {
    Some(@json.Json::Object(found)) =>
      match parse_skill_limits(found) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    Some(_) =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, "limits must be an object"),
      )
    None => { max_runtime_ms: 0, max_output_bytes: 0 }
  }
  // Entry/resource paths must be distinct: a duplicate would materialise one
  // file under two declared roles.
  for resource in resources {
    if resource.path == entry_path {
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "entry path is also a resource"),
      )
    }
  }
  // Entry mode and permissions must agree (ADR-0015 §5.1).
  for command in commands {
    if command.mode == @contracts.SKILL_ENTRY_MODE_WRITE {
      let has_write = permissions.contains(@contracts.SKILL_PERMISSION_WORKSPACE_WRITE) ||
        permissions.contains(@contracts.SKILL_PERMISSION_GIT_WRITE) ||
        permissions.contains(@contracts.SKILL_PERMISSION_EXEC_WORKSPACE)
      if !has_write {
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_PERMISSION_DENIED,
            "write command requires a write permission",
          ),
        )
      }
    } else {
      let allowed_read = permissions.contains(
        @contracts.SKILL_PERMISSION_EXEC_READONLY,
      ) ||
        permissions.contains(@contracts.SKILL_PERMISSION_WORKSPACE_READ) ||
        permissions.contains(@contracts.SKILL_PERMISSION_GIT_READ)
      if !allowed_read {
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_PERMISSION_DENIED,
            "read_only command requires a read permission",
          ),
        )
      }
    }
  }
  Ok({
    schema_version,
    name,
    version,
    description,
    permissions,
    entry_path,
    entry_max_bytes,
    resources,
    commands,
    dependencies,
    source,
    content_hash,
    signature,
    limits,
  })
}
