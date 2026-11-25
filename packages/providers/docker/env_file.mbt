///|
/// Environment-value hand-off for `docker create` (ADR-0013 §3.3).
///
/// Values are carried only by a `0600` file inside an owner-only `0700`
/// directory; the argv carries just the file path. No value is ever placed in
/// an argv element, a label, a log line or an error: `env_file_summary` names
/// variables only, and `ordered_environment` refuses names outside the
/// recipe's allowlist. The file is removed by the caller after `create`
/// (`remove_env_file`).

///|
pub const MAX_ENV_VALUE_BYTES : Int = 4_096

///|
pub const MAX_ENV_FILE_BYTES : Int = 65_536

///|
pub(all) struct EnvironmentVariable {
  name : String
  value : String
}

///|
pub fn is_valid_env_value(value : String) -> Bool {
  if value.length() > MAX_ENV_VALUE_BYTES {
    return false
  }
  for index in 0..<value.length() {
    let ch = match value.get_char(index) {
      Some(found) => found
      None => return false
    }
    let code = ch.to_int()
    if code == 0 || code == 10 || code == 13 {
      return false
    }
    if code < 32 && code != 9 {
      return false
    }
    if code == 127 {
      return false
    }
  }
  true
}

///|
/// Return the allowlisted variables in recipe order. Unknown, duplicated,
/// malformed or unsafe values are refused; no partial file is ever produced.
pub fn ordered_environment(
  recipe : @recipes.Recipe,
  values : Array[EnvironmentVariable],
) -> Result[Array[EnvironmentVariable], DockerError] {
  if values.length() > 128 {
    return Err(
      DockerError::new(EnvFileInvalid).with_detail("too many variables"),
    )
  }
  let allowlist = match recipe.env_allowlist {
    Some(names) => names
    None =>
      if values.length() == 0 {
        return Ok([])
      } else {
        return Err(
          DockerError::new(EnvNameNotAllowed).with_detail(
            "the recipe declares no env_allowlist",
          ),
        )
      }
  }
  let provided : Map[String, String] = Map([])
  for variable in values {
    if !@recipes.is_valid_env_name(variable.name) {
      return Err(
        DockerError::new(InvalidEnvName).with_detail(
          "variable name is outside the allowed grammar",
        ),
      )
    }
    if provided.contains(variable.name) {
      return Err(
        DockerError::new(EnvNameDuplicate).at(variable.name).with_detail(
          "variable is supplied twice",
        ),
      )
    }
    let mut allowed = false
    for name in allowlist {
      if name == variable.name {
        allowed = true
      }
    }
    if !allowed {
      return Err(
        DockerError::new(EnvNameNotAllowed).at(variable.name).with_detail(
          "variable is not in the recipe env_allowlist",
        ),
      )
    }
    if !is_valid_env_value(variable.value) {
      return Err(
        DockerError::new(EnvValueInvalid).at(variable.name).with_detail(
          "value contains a newline, NUL or control character, or is too long",
        ),
      )
    }
    provided.set(variable.name, variable.value)
  }
  let ordered : Array[EnvironmentVariable] = []
  for name in allowlist {
    match provided.get(name) {
      Some(value) => ordered.push({ name, value })
      None => ()
    }
  }
  Ok(ordered)
}

///|
/// `NAME=value` lines, allowlist order, trailing newline. An empty set yields
/// an empty file; A2.2 omits `--env-file` in that case.
pub fn env_file_content(
  variables : Array[EnvironmentVariable],
) -> Result[String, DockerError] {
  let out = StringBuilder()
  for variable in variables {
    out.write_string(variable.name)
    out.write_char('=')
    out.write_string(variable.value)
    out.write_char('\n')
  }
  let content = out.to_string()
  if content.length() > MAX_ENV_FILE_BYTES {
    return Err(
      DockerError::new(EnvFileInvalid).with_detail("env file is too large"),
    )
  }
  Ok(content)
}

///|
/// Names only — safe to log. Values never appear in a summary.
pub fn env_file_summary(variables : Array[EnvironmentVariable]) -> String {
  let out = StringBuilder()
  out.write_string("env-file variables (")
  out.write_string(variables.length().to_string())
  out.write_string(")")
  if variables.length() > 0 {
    out.write_string(": ")
    let mut first = true
    for variable in variables {
      if !first {
        out.write_string(", ")
      }
      first = false
      out.write_string(variable.name)
    }
  }
  out.to_string()
}

///|
async fn stat_tool() -> String? {
  for candidate in ["/usr/bin/stat", "/bin/stat"] {
    let executable = @fs.can_execute(candidate) catch { _ => false }
    if executable {
      return Some(candidate)
    }
  }
  None
}

///|
async fn file_mode(path : String) -> Result[String, DockerError] {
  let tool = match stat_tool() {
    Some(value) => value
    None =>
      return Err(
        DockerError::new(EnvFileInsecure).with_detail(
          "stat tool is not available",
        ),
      )
  }
  let collected = @async.with_timeout_opt(2_000, async fn() {
    let result = @process.collect_output(tool, ["-c", "%a", path]) catch {
      _ => return None
    }
    Some(result)
  })
  let (code, stdout, _stderr) = match collected {
    None =>
      return Err(
        DockerError::new(EnvFileInsecure).with_detail("stat timed out"),
      )
    Some(None) =>
      return Err(
        DockerError::new(EnvFileInsecure).with_detail(
          "stat could not be spawned",
        ),
      )
    Some(Some(value)) => value
  }
  if code != 0 {
    return Err(
      DockerError::new(EnvFileInsecure).with_detail("stat failed"),
    )
  }
  let text = stdout.text() catch {
    _ =>
      return Err(
        DockerError::new(EnvFileInsecure).with_detail(
          "stat output was not readable",
        ),
      )
  }
  Ok(text.trim().to_owned())
}

///|
/// Write the env file as `<dir>/env` with mode `0600` inside a `0700`
/// directory. The directory mode is verified before anything is written, and
/// the file mode is verified after the write; a mismatch removes the file and
/// fails closed.
pub async fn write_env_file(
  dir : String,
  variables : Array[EnvironmentVariable],
) -> Result[String, DockerError] {
  if !@recipes.is_valid_host_path(dir) {
    return Err(
      DockerError::new(EnvFileInvalid).at("dir").with_detail(
        "expected an absolute normalised host path",
      ),
    )
  }
  let content = match env_file_content(variables) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dir_mode = match file_mode(dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if dir_mode != "700" {
    return Err(
      DockerError::new(EnvFileInsecure).at("dir").with_detail(
        "env directory must be owner-only (0700)",
      ),
    )
  }
  let path = dir + "/env"
  @fs.write_file(path, content, permission=0o600) catch {
    _ =>
      return Err(
        DockerError::new(EnvFileWriteFailed).with_detail(
          "cannot write env file",
        ),
      )
  }
  let mode = match file_mode(path) {
    Ok(value) => value
    Err(error) => {
      ignore(remove_env_file(path))
      return Err(error)
    }
  }
  if mode != "600" {
    ignore(remove_env_file(path))
    return Err(
      DockerError::new(EnvFileInsecure).at("env").with_detail(
        "env file mode is not 0600",
      ),
    )
  }
  Ok(path)
}

///|
/// Remove the env file. Already-absent is success (idempotent cleanup).
pub async fn remove_env_file(path : String) -> Result[Unit, DockerError] {
  if path == "" || !@recipes.is_valid_host_path(path) {
    return Err(
      DockerError::new(EnvFileInvalid).at("path").with_detail(
        "expected an absolute normalised host path",
      ),
    )
  }
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(())
  }
  @fs.remove(path) catch {
    _ =>
      return Err(
        DockerError::new(EnvFileRemoveFailed).with_detail(
          "cannot remove env file",
        ),
      )
  }
  Ok(())
}
