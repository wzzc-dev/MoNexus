///|
/// Validation for one open request. The normalized request is what the
/// session stores and what idempotency compares; env order is normalized by
/// name so a retry that reorders the allowlist still maps to the same
/// session.

///|
priv struct NormalizedOpen {
  request : PtyOpenRequest
  cwd : String
  sensitive : Array[(String, String)]
  redact_hold : Int
}

///|
fn pty_utf8_len(value : String) -> Int {
  @utf8.encode(value).length()
}

///|
fn pty_sensitive_name(name : String) -> Bool {
  let upper = name.to_upper()
  upper.contains("TOKEN") || upper.contains("SECRET") ||
  upper.contains("PASSWORD") || upper.contains("PASSWD") ||
  upper.contains("CREDENTIAL") || upper.contains("PRIVATE") ||
  upper.contains("AUTH") || upper.has_suffix("_KEY") || upper == "KEY" ||
  upper.has_prefix("KEY_")
}

///|
fn pty_normalize_env(
  env : Array[(String, String)],
) -> Result[Array[(String, String)], PtyError] {
  let seen : Map[String, Bool] = Map([])
  let normalized : Array[(String, String)] = []
  let mut total = 0
  for pair in env {
    let (name, value) = pair
    if !pty_valid_env_name(name) {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "environment variable names must be [A-Za-z_][A-Za-z0-9_]*",
        ),
      )
    }
    if pty_denied_env_name(name) {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "environment variable " + name +
          " is not allowed (SSH agent and loader variables are denied)",
        ),
      )
    }
    if pty_has_nul(value) || pty_has_control(value) {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "environment values must not contain NUL or control characters",
        ),
      )
    }
    let value_bytes = pty_utf8_len(value)
    if value_bytes > 8_192 {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "environment values are limited to 8192 bytes",
        ),
      )
    }
    total = total + name.length() + value_bytes
    if total > 65_536 {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "environment is limited to 65536 bytes",
        ),
      )
    }
    if seen.contains(name) {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "environment variable " + name + " is duplicated",
        ),
      )
    }
    seen[name] = true
    normalized.push((name, value))
  }
  normalized.sort_by(fn(a, b) { a.0.compare(b.0) })
  Ok(normalized)
}

///|
fn pty_sensitive_values(
  env : Array[(String, String)],
) -> Array[(String, String)] {
  let values : Array[(String, String)] = []
  for pair in env {
    let (name, value) = pair
    if value != "" && pty_sensitive_name(name) {
      values.push(pair)
    }
  }
  // Longest value first so a secret which contains another secret still
  // redacts as a whole.
  values.sort_by(fn(a, b) { b.1.length() - a.1.length() })
  values
}

///|
fn pty_redact_hold(values : Array[(String, String)]) -> Int {
  let mut hold = 0
  for pair in values {
    let length = pair.1.length()
    if length > hold {
      hold = length
    }
  }
  if hold <= 1 {
    0
  } else {
    hold - 1
  }
}

///|
async fn pty_validate_open(
  request : PtyOpenRequest,
) -> Result[NormalizedOpen, PtyError] {
  if !pty_valid_session_id(request.session_id) {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "session_id must be a 1..64 character identifier starting alphanumerically",
      ),
    )
  }
  if !pty_valid_client_request_id(request.client_request_id) {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "client_request_id must be at most 128 bytes without control characters",
      ),
    )
  }
  if request.rows <= 0 || request.rows > 10_000 || request.cols <= 0 ||
    request.cols > 10_000 {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "rows and cols must be between 1 and 10000",
      ),
    )
  }
  if pty_has_nul(request.cwd) || !pty_valid_cwd(request.cwd) {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "cwd must be an absolute path without NUL or control characters",
      ),
    )
  }
  if request.argv.length() == 0 || request.argv.length() > 128 {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "argv must contain between 1 and 128 arguments",
      ),
    )
  }
  if request.argv[0] == "" || pty_has_nul(request.argv[0]) {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "argv[0] must be a non-empty program name without NUL",
      ),
    )
  }
  let mut argv_bytes = 0
  for arg in request.argv {
    if pty_has_nul(arg) {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "argv values must not contain NUL",
        ),
      )
    }
    let length = pty_utf8_len(arg)
    if length > 8_192 {
      return Err(
        pty_error(
          PtyErrorKind::InvalidArgument,
          "argv values are limited to 8192 bytes",
        ),
      )
    }
    argv_bytes = argv_bytes + length
  }
  if argv_bytes > 65_536 {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "argv is limited to 65536 bytes",
      ),
    )
  }
  let cwd = @fs.realpath(request.cwd) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::InvalidArgument, "cwd does not exist"),
      )
  }
  let kind = @fs.kind(cwd) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::InvalidArgument, "cwd is not readable"),
      )
  }
  if !(kind is @fs.FileKind::Directory) {
    return Err(
      pty_error(PtyErrorKind::InvalidArgument, "cwd is not a directory"),
    )
  }
  if pty_has_ssh_component(cwd) {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "cwd must not be inside a .ssh directory",
      ),
    )
  }
  let env = match pty_normalize_env(request.env) {
    Ok(value) => value
    Err(error) =>
      return Err(
        error
        .with_session(request.session_id)
        .with_seq(0L),
      )
  }
  let sensitive = pty_sensitive_values(env)
  let redact_hold = pty_redact_hold(sensitive)
  let normalized_request = {
    session_id: request.session_id,
    argv: request.argv,
    cwd,
    env,
    rows: request.rows,
    cols: request.cols,
    client_request_id: request.client_request_id,
  }
  Ok({ request: normalized_request, cwd, sensitive, redact_hold })
}

///|
fn pty_same_request(a : PtyOpenRequest, b : PtyOpenRequest) -> Bool {
  if a.session_id != b.session_id ||
    a.client_request_id != b.client_request_id || a.cwd != b.cwd ||
    a.rows != b.rows || a.cols != b.cols || a.argv.length() != b.argv.length() ||
    a.env.length() != b.env.length() {
    return false
  }
  for index in 0..<a.argv.length() {
    if a.argv[index] != b.argv[index] {
      return false
    }
  }
  for index in 0..<a.env.length() {
    if a.env[index].0 != b.env[index].0 || a.env[index].1 != b.env[index].1 {
      return false
    }
  }
  true
}
