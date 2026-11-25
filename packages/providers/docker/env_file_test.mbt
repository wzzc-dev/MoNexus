///|
/// Env-file tests: allowlist enforcement, 0600 file inside a 0700 directory,
/// cleanup, and proof that values never appear in summaries or diagnostics.

///|
async fn mode_of(path : String) -> String {
  let has_usr_bin = @fs.exists("/usr/bin/stat") catch { _ => false }
  let tool = if has_usr_bin { "/usr/bin/stat" } else { "/bin/stat" }
  let result = @process.collect_output(tool, ["-c", "%a", path]) catch {
    _ => return "stat-failed"
  }
  let (code, stdout, _stderr) = result
  if code != 0 {
    return "stat-failed"
  }
  let text = stdout.text() catch { _ => "" }
  text.trim().to_owned()
}

///|
fn expect_env_reject(
  result : Result[Array[@docker.EnvironmentVariable], @docker.DockerError],
  reason : String,
) -> Unit raise {
  match result {
    Ok(_) => fail("expected " + reason + " but variables were accepted")
    Err(error) =>
      if error.reason() != reason {
        fail("expected " + reason + " but got " + error.to_string())
      }
  }
}

///|
test "environment variables follow the recipe allowlist order" {
  let recipe = docker_full_recipe()
  let ordered = match @docker.ordered_environment(
    recipe,
    [
      { name: "PATH", value: "/usr/bin:/bin" },
      { name: "HOME", value: "/root" },
    ],
  ) {
    Ok(value) => value
    Err(error) => fail("valid variables rejected: " + error.to_string())
  }
  inspect(ordered.length(), content="2")
  inspect(ordered[0].name, content="HOME")
  inspect(ordered[0].value, content="/root")
  inspect(ordered[1].name, content="PATH")
}

///|
test "unknown, duplicated, malformed and unsafe values are refused" {
  let recipe = docker_full_recipe()
  expect_env_reject(
    @docker.ordered_environment(recipe, [{ name: "SECRET", value: "x" }]),
    "env_name_not_allowed",
  )
  expect_env_reject(
    @docker.ordered_environment(
      recipe,
      [
        { name: "HOME", value: "/a" },
        { name: "HOME", value: "/b" },
      ],
    ),
    "env_name_duplicate",
  )
  expect_env_reject(
    @docker.ordered_environment(recipe, [{ name: "HO-ME", value: "x" }]),
    "invalid_env_name",
  )
  expect_env_reject(
    @docker.ordered_environment(recipe, [{ name: "HOME", value: "/a\nb" }]),
    "env_value_invalid",
  )
  expect_env_reject(
    @docker.ordered_environment(recipe, [{ name: "HOME", value: "/a\rb" }]),
    "env_value_invalid",
  )
  expect_env_reject(
    @docker.ordered_environment(recipe, [{ name: "HOME", value: "/a\u0000b" }]),
    "env_value_invalid",
  )
  let long = StringBuilder()
  for _ in 0..<4_097 {
    long.write_char('a')
  }
  expect_env_reject(
    @docker.ordered_environment(recipe, [{ name: "HOME", value: long.to_string() }]),
    "env_value_invalid",
  )
  let minimal = docker_minimal_recipe()
  expect_env_reject(
    @docker.ordered_environment(minimal, [{ name: "HOME", value: "/root" }]),
    "env_name_not_allowed",
  )
  match @docker.ordered_environment(minimal, []) {
    Ok(value) => inspect(value.length(), content="0")
    Err(error) => fail("an empty variable set should be accepted: " + error.to_string())
  }
}

///|
test "env file content and summaries never expose values" {
  let variables : Array[@docker.EnvironmentVariable] = [
    { name: "HOME", value: "s3cr3t-home" },
    { name: "PATH", value: "/usr/bin" },
  ]
  let content = match @docker.env_file_content(variables) {
    Ok(value) => value
    Err(error) => fail("content failed: " + error.to_string())
  }
  inspect(content, content="HOME=s3cr3t-home\nPATH=/usr/bin\n")
  let summary = @docker.env_file_summary(variables)
  if !summary.contains("HOME") || !summary.contains("PATH") {
    fail("summary lost variable names: " + summary)
  }
  if summary.contains("s3cr3t-home") {
    fail("summary leaked a value")
  }
  // Errors name the variable, never the value.
  match @docker.ordered_environment(
    docker_full_recipe(),
    [{ name: "HOME", value: "s3cr3t\nvalue" }],
  ) {
    Ok(_) => fail("newline value must be refused")
    Err(error) =>
      if error.to_string().contains("s3cr3t") {
        fail("diagnostic leaked a value")
      }
  }
}

///|
async test "env file is 0600 inside a 0700 directory and is removed" {
  let dir = @fs.tmpdir(prefix="docker-env-file") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  inspect(mode_of(dir), content="700")
  let variables : Array[@docker.EnvironmentVariable] = [
    { name: "HOME", value: "/root" },
    { name: "PATH", value: "/usr/bin" },
  ]
  let path = match @docker.write_env_file(dir, variables) {
    Ok(value) => value
    Err(error) => fail("env file write failed: " + error.to_string())
  }
  inspect(mode_of(path), content="600")
  let text = @fs.read_file(path).text() catch {
    _ => fail("cannot read env file")
  }
  inspect(text, content="HOME=/root\nPATH=/usr/bin\n")
  match @docker.remove_env_file(path) {
    Ok(_) => ()
    Err(error) => fail("env file removal failed: " + error.to_string())
  }
  inspect(@fs.exists(path) catch { _ => true }, content="false")
  // Removal is idempotent so cleanup cannot wedge.
  match @docker.remove_env_file(path) {
    Ok(_) => ()
    Err(error) => fail("idempotent removal failed: " + error.to_string())
  }
}

///|
async test "a group-readable env directory is refused" {
  let dir = @fs.tmpdir(prefix="docker-env-insecure") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let insecure = dir + "/shared"
  @fs.mkdir(insecure, permission=0o755) catch {
    _ => fail("cannot create shared dir")
  }
  match @docker.write_env_file(
    insecure,
    [{ name: "HOME", value: "/root" }],
  ) {
    Ok(_) => fail("a 0755 env directory must be refused")
    Err(error) =>
      if error.reason() != "env_file_insecure" {
        fail("expected env_file_insecure, got " + error.to_string())
      }
  }
  match @docker.write_env_file(
    dir + "/missing",
    [{ name: "HOME", value: "/root" }],
  ) {
    Ok(_) => fail("a missing env directory must be refused")
    Err(error) =>
      if error.reason() != "env_file_insecure" {
        fail("expected env_file_insecure, got " + error.to_string())
      }
  }
}
