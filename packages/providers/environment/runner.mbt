///|
/// Machine-side Docker execution for environment lifecycle (ADR-0013 §3).
///
/// `DockerRunner` is the only seam between the lifecycle engine and a
/// machine: docker argv execution plus the four private-filesystem
/// operations needed for the env-file hand-off and temp directory. Local and
/// SSH runners are constructed by `local_runner` / `ssh_runner`; tests inject
/// deterministic fakes and never need a daemon.

///|
pub const DOCKER_OUTPUT_CAP : Int = 1_048_576

///|
pub const DEFAULT_DOCKER_TIMEOUT_S : Int = 600

///|
pub(all) struct DockerOutput {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
pub type DockerInvoke = async (Array[String], Int) -> Result[
  DockerOutput,
  EnvFailure,
]

///|
pub type PathOp = async (String) -> Result[Unit, EnvFailure]

///|
pub type WriteSecretOp = async (
  String,
  Array[@docker.EnvironmentVariable],
) -> Result[Unit, EnvFailure]

///|
/// Container terminal transport for a paired runtime node. The argv excludes
/// the `docker` program name, matching `DockerInvoke`; the runtime node
/// resolves and streams it through `runtime.pty.*`.
pub type RuntimeTerminalOp = async (
  Array[String],
  Int32,
  Int32,
  @aqueue.Queue[@workspace.TerminalInput],
  @aqueue.Queue[@workspace.TerminalEvent],
) -> Unit

///|
pub(all) struct DockerRunner {
  machine_id : String
  remote : Bool
  home : String
  target : @ssh.SshTarget?
  invoke : DockerInvoke
  make_dir : PathOp
  write_secret : WriteSecretOp
  remove_file : PathOp
  remove_dir : PathOp
  /// True when this runner executes on a paired runtime node (A2.2). Docker
  /// argv and the environment filesystem go through `runtime.exec.*` and
  /// `runtime.fs.*`; the local/SSH behavior is unchanged.
  runtime : Bool
  /// The A2.1 environment-approval Decision bound to this lifecycle
  /// operation, when one exists. Empty means the primary authorizes the
  /// operation directly. The runtime adapter mints one-time A1.3b grants from
  /// this value; it never creates a second approval path.
  authorization : Ref[String]?
  /// PTY transport for runtime terminals. `None` on local/SSH runners, which
  /// use the existing PTY/SSH paths.
  terminal : RuntimeTerminalOp?
}

///|
pub(all) struct EnvFailure {
  code : String
  message : String
  detail : String
}

///|
fn bounded_detail(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() <= 1_024 {
    redacted
  } else {
    redacted[:1_024].to_owned() + "...[truncated]"
  }
}

///|
pub fn EnvFailure::new(code : String, message : String) -> EnvFailure {
  { code, message, detail: "", }
}

///|
pub fn EnvFailure::with_detail(
  self : EnvFailure,
  detail : String,
) -> EnvFailure {
  { ..self, detail: bounded_detail(detail), }
}

///|
pub fn EnvFailure::to_string(self : EnvFailure) -> String {
  let mut text = self.code + ": " + self.message
  if self.detail != "" {
    text = text + ": " + self.detail
  }
  text
}

///|
/// Bind this runner's runtime authorizations to the A2.1 environment Decision
/// that already authorized the plan. A no-op for local/SSH runners.
pub fn DockerRunner::set_approval_decision(
  self : DockerRunner,
  decision_id : String,
) -> Unit {
  match self.authorization {
    Some(value) => value.val = decision_id
    None => ()
  }
}

///|
pub fn DockerRunner::is_runtime(self : DockerRunner) -> Bool {
  self.runtime
}

///|
pub fn env_failure_from_docker(error : @docker.DockerError) -> EnvFailure {
  let mut failure = EnvFailure::new(
    @contracts.ENVIRONMENT_ERR_INVALID,
    error.reason(),
  )
  match error.field {
    Some(field) if field != "" => failure = failure.with_detail(field)
    _ => ()
  }
  match error.detail {
    Some(detail) if detail != "" => failure = failure.with_detail(detail)
    _ => ()
  }
  failure
}

///|
fn spawn_failure(message : String, detail : String) -> EnvFailure {
  EnvFailure::new(@contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE, message)
  .with_detail(detail)
}

///|
fn timeout_failure(seconds : Int, stderr : String) -> EnvFailure {
  let failure = EnvFailure::new(
    @contracts.ENVIRONMENT_ERR_TIMEOUT,
    "docker command timed out after " + seconds.to_string() + "s",
  )
  if stderr == "" {
    failure
  } else {
    failure.with_detail(stderr)
  }
}

///|
async fn pump_reader(
  reader : @process.ReadFromProcess,
  sink : Ref[String],
) -> Unit {
  for ;; {
    let chunk = reader.read_some() catch { _ => break }
    match chunk {
      Some(bytes) => {
        if sink.val.length() < DOCKER_OUTPUT_CAP {
          let text = @utf8.decode_lossy(bytes[:], ignore_bom=false)
          sink.val = sink.val + text
        }
      }
      None => break
    }
  }
  reader.close()
}

///|
/// Run a local docker argv with a hard timeout. On timeout the child is
/// cancelled (terminate, then kill after a short grace period in the process
/// library), and the call returns `timeout`; it can never report success.
///|
/// Resolve a bare program name against PATH before spawning. `@process.spawn`
/// does not perform the PATH search itself, and environment execution must not
/// fall back to a shell just to find `docker`.
async fn resolve_local_program(name : String) -> String {
  if name.contains("/") || name == "" {
    return name
  }
  match @env.get_env_var("PATH") {
    Some(value) => {
      for dir in value.split(":") {
        let candidate = dir + "/" + name
        let exists = @fs.exists(candidate) catch { _ => false }
        if exists {
          return candidate.to_owned()
        }
      }
    }
    None => ()
  }
  name
}

///|
async fn run_local_docker(
  argv : Array[String],
  timeout_s : Int,
) -> Result[DockerOutput, EnvFailure] {
  if argv.is_empty() {
    return Err(EnvFailure::new(
      @contracts.ENVIRONMENT_ERR_INTERNAL,
      "docker argv is empty",
    ))
  }
  let program = resolve_local_program("docker")
  let seconds = if timeout_s < 1 { 1 } else { timeout_s }
  let stdout : Ref[String] = Ref("")
  let stderr : Ref[String] = Ref("")
  let exit_code : Ref[Int] = Ref(0)
  let timed_out : Ref[Bool] = Ref(false)
  let spawn_error : Ref[String] = Ref("")
  let args : Array[String] = argv
  @async.with_task_group(async fn(group) {
    let (out_r, out_w) = @process.read_from_process() catch {
      error => {
        spawn_error.val = error.to_string()
        return
      }
    }
    let (err_r, err_w) = @process.read_from_process() catch {
      error => {
        spawn_error.val = error.to_string()
        return
      }
    }
    let proc = @process.spawn(
      group,
      program,
      args,
      stdout=out_w,
      stderr=err_w,
      cancel_handler=@process.hard_cancel(),
    ) catch {
      error => {
        spawn_error.val = error.to_string()
        return
      }
    }
    group.spawn_bg(() => pump_reader(out_r, stdout))
    group.spawn_bg(() => pump_reader(err_r, stderr))
    match
      @async.with_timeout_opt(seconds * 1_000, async fn() -> Int32 {
        proc.wait()
      }) {
      Some(code) => exit_code.val = code.to_int()
      None => {
        timed_out.val = true
        proc.cancel()
        let _ = @async.with_timeout_opt(5_000, async fn() -> Int32 {
          proc.wait()
        })
        group.return_immediately(())
      }
    }
  })
  if spawn_error.val != "" {
    return Err(
      spawn_failure("cannot spawn docker", spawn_error.val),
    )
  }
  let output = {
    exit_code: exit_code.val,
    stdout: stdout.val,
    stderr: stderr.val,
  }
  if timed_out.val {
    return Err(timeout_failure(seconds, output.stderr))
  }
  Ok(output)
}

///|
async fn local_make_dir(path : String) -> Result[Unit, EnvFailure] {
  @fs.mkdir(path, permission=0o700, recursive=true, allow_exist=true) catch {
    error =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot create environment directory",
        ).with_detail(error.to_string()),
      )
  }
  @fs.chmod(path, 0o700) catch { _ => () }
  Ok(())
}

///|
async fn local_remove_file(path : String) -> Result[Unit, EnvFailure] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(())
  }
  @fs.remove(path) catch {
    error =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
          "cannot remove env file",
        ).with_detail(error.to_string()),
      )
  }
  // A removal that leaves the secret file behind is a cleanup failure, never
  // a clean outcome. Reconcile relies on this to set `cleanup_ok` truthfully.
  let remains = @fs.exists(path) catch { _ => true }
  if remains {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
        "env file still exists after removal",
      ).with_detail(path),
    )
  }
  Ok(())
}

///|
async fn local_remove_dir(path : String) -> Result[Unit, EnvFailure] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(())
  }
  @fs.rmdir(path, recursive=true) catch {
    error =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
          "cannot remove environment directory",
        ).with_detail(error.to_string()),
      )
  }
  Ok(())
}

///|
pub async fn local_runner(
  machine_id~ : String,
  home~ : String,
) -> DockerRunner {
  let home_value = home
  {
    machine_id,
    remote: false,
    home: home_value,
    target: None,
    invoke: async fn(argv, timeout_s) { run_local_docker(argv, timeout_s) },
    make_dir: async fn(path) { local_make_dir(path) },
    write_secret: async fn(dir, variables) {
      match @docker.write_env_file(dir, variables) {
        Ok(_) => Ok(())
        Err(error) => Err(env_failure_from_docker(error))
      }
    },
    remove_file: async fn(path) {
      let result = local_remove_file(path)
      result
    },
    remove_dir: async fn(path) { local_remove_dir(path) },
    runtime: false,
    authorization: None,
    terminal: None,
  }
}

// ---------------------------------------------------------------------------
// SSH runner
// ---------------------------------------------------------------------------

///|
fn remote_script_failure(action : String, result : @ssh.RemoteCommandResult) -> EnvFailure {
  EnvFailure::new(
    @contracts.ENVIRONMENT_ERR_UNREACHABLE,
    "remote " + action + " failed",
  ).with_detail(result.stderr)
}

///|
async fn resolve_remote_home(
  target : @ssh.SshTarget,
) -> Result[String, EnvFailure] {
  let script = "printf '%s' \"$HOME\""
  let result = match
    @ssh.run(target, ["sh", "-c", script], cwd=".", timeout_seconds=15) {
    Ok(value) => value
    Err(error) =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_UNREACHABLE,
          "cannot resolve the remote home directory",
        ).with_detail(error.to_string()),
      )
  }
  if result.exit_code != 0 {
    return Err(remote_script_failure("home lookup", result))
  }
  let home = result.stdout.trim().to_owned()
  if home == "" || !@recipes.is_valid_host_path(home) {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "remote home directory is not an absolute normalised path",
      ),
    )
  }
  Ok(home)
}

///|
/// Post-write verification for the SSH env-file (ADR-0013 §3.3). The local
/// writer verifies 0700/0600 before use; the remote path must verify the same
/// properties (plus ownership by the executing user) after the write, and
/// remove the secret on any mismatch. Exit 1 is a refused hand-off.
fn ssh_env_file_verify_script() -> String {
  // GNU `stat -c` on Linux, BSD `stat -f` on macOS; an empty result (both
  // forms failed) mismatches and is refused.
  "mode() { stat -c %a -- \"$1\" 2>/dev/null || stat -f %Lp -- \"$1\" 2>/dev/null; }; " +
  "owner() { stat -c %u -- \"$1\" 2>/dev/null || stat -f %u -- \"$1\" 2>/dev/null; }; " +
  "uid=$(id -u); " +
  "if [ \"$(mode \"$1\")\" != \"700\" ] || " +
  "[ \"$(owner \"$1\")\" != \"$uid\" ] || " +
  "[ \"$(mode \"$1/env\")\" != \"600\" ] || " +
  "[ \"$(owner \"$1/env\")\" != \"$uid\" ]; then " +
  "rm -f -- \"$1/env\"; " +
  "echo \"env file mode or ownership verification failed\" >&2; exit 1; fi"
}

///|
pub async fn ssh_runner(
  machine_id~ : String,
  target : @ssh.SshTarget,
) -> Result[DockerRunner, EnvFailure] {
  let home = match resolve_remote_home(target) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let invoke : DockerInvoke = async fn(argv, timeout_s) {
    let seconds = if timeout_s < 1 { 1 } else { timeout_s }
    let remote_argv : Array[String] = ["docker"]
    for item in argv {
      remote_argv.push(item)
    }
    let result = match @ssh.run(
      target,
      remote_argv,
      cwd=".",
      timeout_seconds=seconds,
    ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          spawn_failure("cannot run docker over SSH", error.to_string()),
        )
    }
    let output = {
      exit_code: result.exit_code,
      stdout: result.stdout,
      stderr: result.stderr,
    }
    Ok(output)
  }
  let make_dir : PathOp = async fn(path) {
    let script = "umask 077; mkdir -p -- \"$1\" && chmod 700 -- \"$1\""
    let result = match @ssh.run(
      target,
      ["sh", "-c", script, "monexus-env-dir", path],
      cwd=".",
      timeout_seconds=30,
    ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_UNREACHABLE,
            "cannot create the remote environment directory",
          ).with_detail(error.to_string()),
        )
    }
    if result.exit_code == 0 {
      Ok(())
    } else {
      Err(remote_script_failure("environment directory creation", result))
    }
  }
  let write_secret : WriteSecretOp = async fn(dir, variables) {
    let script = "umask 077; mkdir -p -- \"$1\" && chmod 700 -- \"$1\" && " +
      "cat > \"$1/env\" && chmod 600 -- \"$1/env\""
    let content = match @docker.env_file_content(variables) {
      Ok(value) => value
      Err(error) => return Err(env_failure_from_docker(error))
    }
    let result = match @ssh.run_with_input(
      target,
      ["sh", "-c", script, "monexus-env-file", dir],
      cwd=".",
      input=content,
      timeout_seconds=30,
    ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_UNREACHABLE,
            "cannot write the remote env file",
          ).with_detail(error.to_string()),
        )
    }
    if result.exit_code != 0 {
      return Err(remote_script_failure("env file write", result))
    }
    // Verify the remote mode and ownership after writing; the verify script
    // removes the secret on any mismatch, so a failed check never leaves the
    // env-file behind.
    let verified = match @ssh.run(
      target,
      [
        "sh", "-c", ssh_env_file_verify_script(), "monexus-env-verify", dir,
      ],
      cwd=".",
      timeout_seconds=30,
    ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_UNREACHABLE,
            "cannot verify the remote env file",
          ).with_detail(error.to_string()),
        )
    }
    if verified.exit_code == 0 {
      Ok(())
    } else {
      Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_SECRET_REJECTED,
          "remote env file mode or ownership is not owner-only",
        ).with_detail(verified.stderr),
      )
    }
  }
  let remove_file : PathOp = async fn(path) {
    let script = "rm -f -- \"$1\" && [ ! -e \"$1\" ] && [ ! -L \"$1\" ]"
    let result = match @ssh.run(
      target,
      ["sh", "-c", script, "monexus-env-rm", path],
      cwd=".",
      timeout_seconds=30,
    ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
            "cannot remove the remote env file",
          ).with_detail(error.to_string()),
        )
    }
    if result.exit_code == 0 {
      Ok(())
    } else {
      Err(remote_script_failure("env file removal", result))
    }
  }
  let remove_dir : PathOp = async fn(path) {
    let script = "rm -rf -- \"$1\""
    let result = match @ssh.run(
      target,
      ["sh", "-c", script, "monexus-env-rmdir", path],
      cwd=".",
      timeout_seconds=30,
    ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
            "cannot remove the remote environment directory",
          ).with_detail(error.to_string()),
        )
    }
    if result.exit_code == 0 {
      Ok(())
    } else {
      Err(remote_script_failure("environment directory removal", result))
    }
  }
  Ok({
    machine_id,
    remote: true,
    home,
    target: Some(target),
    invoke,
    make_dir,
    write_secret,
    remove_file,
    remove_dir,
    runtime: false,
    authorization: None,
    terminal: None,
  })
}
