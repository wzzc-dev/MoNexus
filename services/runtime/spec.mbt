///|
/// One explicit environment variable for a runtime command. The value is
/// passed to the child only; it is never written to an event or log line.
pub(all) struct EnvPair {
  name : String
  value : String
}

///|
pub fn EnvPair::new(name : String, value : String) -> EnvPair {
  { name, value, }
}

///|
/// The runtime execution spec (architecture §6.1). `argv` is an array: there
/// is no whole-shell string field. Callers that need a shell must spell out
/// `sh -c` in argv and declare the matching risk tier.
pub(all) struct CommandSpec {
  argv : Array[String]
  cwd : String
  env : Array[EnvPair]
  inherit_env : Array[String]
  timeout_ms : Int32
  risk : String
  stdin : String?
  max_output_bytes : Int32
}

///|
pub const DEFAULT_TIMEOUT_MS : Int32 = 300_000

///|
pub const MAX_TIMEOUT_MS : Int32 = 86_400_000

///|
pub const DEFAULT_MAX_OUTPUT_BYTES : Int32 = 8_388_608

///|
pub const MAX_OUTPUT_BYTES_LIMIT : Int32 = 67_108_864

///|
pub const DEFAULT_CHUNK_BYTES : Int32 = 65_536

///|
pub const MAX_STDIN_BYTES : Int32 = 32_768

///|
pub fn CommandSpec::new(
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Array[EnvPair] = [],
  inherit_env~ : Array[String] = [],
  timeout_ms~ : Int32 = 0,
  risk~ : String = "",
  stdin~ : String? = None,
  max_output_bytes~ : Int32 = 0,
) -> CommandSpec {
  {
    argv,
    cwd,
    env,
    inherit_env,
    timeout_ms: if timeout_ms <= 0 {
      DEFAULT_TIMEOUT_MS
    } else {
      timeout_ms
    },
    risk,
    stdin,
    max_output_bytes: if max_output_bytes <= 0 {
      DEFAULT_MAX_OUTPUT_BYTES
    } else {
      max_output_bytes
    },
  }
}

///|
fn is_identifier_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 48 && code <= 57) ||
  (code >= 65 && code <= 90) ||
  (code >= 97 && code <= 122) ||
  code == 95
}

///|
/// Resource ids (`run_id`, `client_request_id`) end up in event keys and
/// directory names, so they are restricted to a small alphabet and bounded
/// length. Path separators and `..` can never appear.
pub fn validate_resource_id(
  value : String,
  label : String,
) -> Result[Unit, String] {
  if value == "" {
    return Err(label + " is required")
  }
  if value.length() > 128 {
    return Err(label + " is longer than 128 characters")
  }
  let lowered = value.to_lower()
  if lowered == "." || lowered == ".." {
    return Err(label + " is not a valid identifier")
  }
  for ch in value {
    let code = ch.to_int()
    let allowed = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if !allowed {
      return Err(label + " contains characters outside [A-Za-z0-9._-]")
    }
  }
  Ok(())
}

///|
fn validate_env_name(name : String) -> Result[Unit, String] {
  if name == "" {
    return Err("environment variable name is empty")
  }
  let first = match name.get_char(0) {
    Some(ch) => ch
    None => return Err("environment variable name is empty")
  }
  let first_code = first.to_int()
  let first_ok = (first_code >= 65 && first_code <= 90) ||
    (first_code >= 97 && first_code <= 122) ||
    first_code == 95
  if !first_ok {
    return Err(
      "environment variable name must start with a letter or underscore",
    )
  }
  for ch in name {
    if !is_identifier_char(ch) {
      return Err("environment variable name contains an invalid character")
    }
  }
  Ok(())
}

///|
fn risk_rank(risk : String) -> Int32 {
  match risk {
    @contracts.RISK_LOW => 0
    @contracts.RISK_MEDIUM => 1
    @contracts.RISK_HIGH => 2
    @contracts.RISK_CRITICAL => 3
    _ => -1
  }
}

///|
fn max_risk(left : String, right : String) -> String {
  if risk_rank(right) > risk_rank(left) {
    right
  } else {
    left
  }
}

///|
/// Classify an argv as the policy layer would classify a declared command.
/// The argv is joined for classification only; it is never executed as text.
pub fn classify_argv(argv : Array[String]) -> String {
  @contracts.evaluate_command_policy(argv.join(" ")).risk
}

///|
/// The risk that actually applies: the higher of the caller-declared tier and
/// the classifier's tier. A caller cannot lower the tier by declaring "low".
pub fn CommandSpec::effective_risk(self : CommandSpec) -> String {
  let declared = if self.risk == "" { @contracts.RISK_LOW } else { self.risk }
  max_risk(declared, classify_argv(self.argv))
}

///|
fn looks_like_secret_arg(arg : String, next : String?) -> Bool {
  let lower = arg.to_lower()
  if lower.contains("-----begin") && lower.contains("private key") {
    return true
  }
  match arg.find("=") {
    Some(index) => {
      let name = arg[:index.to_int()].to_string()
      if @contracts.is_secret_key_name(name) {
        return true
      }
    }
    None => ()
  }
  if arg.has_prefix("-") && @contracts.is_secret_key_name(arg) {
    match next {
      Some(_) => return true
      None => ()
    }
  }
  false
}

///|
fn bounded_error(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() <= 512 {
    redacted
  } else {
    redacted[:512].to_string() + "...[truncated]"
  }
}

///|
/// Validate one command spec. Returns a caller-safe message (no env values,
/// no secret argv text) on failure.
pub fn validate_command_spec(spec : CommandSpec) -> Result[Unit, String] {
  if spec.argv.is_empty() {
    return Err("argv is required and may not be empty")
  }
  let program = spec.argv[0].trim()
  if program == "" {
    return Err("argv[0] is required")
  }
  for index, arg in spec.argv {
    if arg == "" && index == 0 {
      return Err("argv[0] is required")
    }
    let next = if index + 1 < spec.argv.length() {
      Some(spec.argv[index + 1])
    } else {
      None
    }
    if looks_like_secret_arg(arg, next) {
      return Err(
        "argv appears to carry a credential; secrets must not travel in argv",
      )
    }
  }
  if spec.timeout_ms <= 0 || spec.timeout_ms > MAX_TIMEOUT_MS {
    return Err("timeout_ms must be between 1 and " + MAX_TIMEOUT_MS.to_string())
  }
  if spec.max_output_bytes <= 0 ||
    spec.max_output_bytes > MAX_OUTPUT_BYTES_LIMIT {
    return Err(
      "max_output_bytes must be between 1 and " +
      MAX_OUTPUT_BYTES_LIMIT.to_string(),
    )
  }
  match spec.stdin {
    Some(text) =>
      if text.length() > MAX_STDIN_BYTES {
        return Err("stdin exceeds " + MAX_STDIN_BYTES.to_string() + " bytes")
      }
    None => ()
  }
  if risk_rank(spec.effective_risk()) < 0 {
    return Err("risk tier is not one of low|medium|high|critical")
  }
  if spec.effective_risk() == @contracts.RISK_CRITICAL {
    return Err("policy denies critical-risk commands at the runtime")
  }
  let seen : Map[String, Bool] = Map([])
  for pair in spec.env {
    match validate_env_name(pair.name) {
      Ok(_) => ()
      Err(message) => return Err(bounded_error(message))
    }
    if seen.get(pair.name) is Some(true) {
      return Err("duplicate environment variable: " + pair.name)
    }
    seen.set(pair.name, true)
    if @contracts.is_secret_key_name(pair.name) && pair.value == "" {
      return Err("secret-named environment variable must not be empty")
    }
  }
  for name in spec.inherit_env {
    match validate_env_name(name) {
      Ok(_) => ()
      Err(message) => return Err(bounded_error(message))
    }
    if @contracts.is_secret_key_name(name) {
      return Err(
        "inherit_env may not name a credential-like variable; pass a scoped explicit value instead",
      )
    }
  }
  match normalize_rooted_path(spec.cwd) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  Ok(())
}

///|
/// The argv shape persisted in events: secret-looking values are redacted,
/// and only the first 32 entries are kept to bound the payload.
pub fn event_argv(argv : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let limit = argv.length().min(32)
  for index in 0..<limit {
    let arg = argv[index]
    let redacted = @contracts.redact_secrets(arg)
    out.push(redacted)
  }
  if argv.length() > limit {
    out.push("...[" + (argv.length() - limit).to_string() + " more]")
  }
  out
}
