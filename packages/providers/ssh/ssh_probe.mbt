///|
/// Machine facts collected by `probe`. Fields mirror `MachineProfile` in
/// architecture §6.1; only what the probe can prove is filled in. M2 adds
/// `hostname`, `has_docker`, `has_gui` and `max_parallel` so the scheduler can
/// treat a machine as a capability set rather than "a host that answers".
pub(all) struct MachineProfile {
  os : String
  arch : String
  kernel : String
  hostname : String
  shell : String
  tools : Map[String, String]
  has_docker : Bool
  has_gui : Bool
  max_parallel : Int
  notes : String
  raw : String
}

///|
pub(all) struct RemoteCommandResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
/// Run one remote command through the system `ssh` client. The host-side
/// timeout is a backstop around `ConnectTimeout` (which only covers
/// connection setup).
async fn run_remote(
  target : SshTarget,
  remote_command : String,
  timeout_seconds : Int,
) -> Result[RemoteCommandResult, @error.ProviderError] {
  if !target.is_configured() {
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::NotConfigured,
        "SSH target has no host",
      ),
    )
  }
  let argv = ssh_argv(target, remote_command)
  let budget_ms = timeout_seconds.max(1) * 1_000
  let collected = @async.with_timeout_opt(budget_ms, async fn() {
    let (exit_code, stdout, stderr) = @process.collect_output(
      argv[0],
      argv[1:].to_owned(),
    ) catch {
      error =>
        return Err(
          @error.ProviderError::new(
            @error.ProviderErrorKind::SpawnFailed,
            "failed to spawn ssh",
          ).with_detail(error.to_string()),
        )
    }
    let stdout_text = stdout.text() catch { _ => "" }
    let stderr_text = stderr.text() catch { _ => "" }
    Ok({ exit_code, stdout: stdout_text, stderr: stderr_text })
  })
  match collected {
    Some(Ok(result)) => Ok(result)
    Some(Err(error)) => Err(error)
    None =>
      Err(
        @error.ProviderError::new(
          @error.ProviderErrorKind::ConnectTimeout,
          "SSH command timed out after " + timeout_seconds.to_string() + "s",
        ),
      )
  }
}

///|
/// Map an `ssh` transport failure (exit 255 or spawn failure) onto the
/// provider's categories. The stderr text is what a user needs to see;
/// classification only decides the label.
pub fn classify_ssh_failure(
  exit_code : Int,
  stderr : String,
) -> @error.ProviderError {
  let lower = stderr.to_lower()
  if lower.contains("host key verification failed") ||
    lower.contains("remote host identification has changed") {
    return @error.ProviderError::new(
      @error.ProviderErrorKind::HostKey,
      "SSH host key was rejected",
    )
    .with_exit(exit_code)
    .with_detail(stderr)
  }
  if lower.contains("permission denied") ||
    lower.contains("authentication failed") ||
    lower.contains("no supported authentication methods") ||
    lower.contains("too many authentication failures") {
    return @error.ProviderError::new(
      @error.ProviderErrorKind::AuthFailed,
      "SSH authentication failed",
    )
    .with_exit(exit_code)
    .with_detail(stderr)
  }
  if lower.contains("could not resolve hostname") ||
    lower.contains("name or service not known") ||
    lower.contains("nodename nor servname") {
    return @error.ProviderError::new(
      @error.ProviderErrorKind::NotFound,
      "SSH host could not be resolved",
    )
    .with_exit(exit_code)
    .with_detail(stderr)
  }
  if lower.contains("connection timed out") ||
    lower.contains("operation timed out") {
    return @error.ProviderError::new(
      @error.ProviderErrorKind::ConnectTimeout,
      "SSH connection timed out",
    )
    .with_exit(exit_code)
    .with_detail(stderr)
  }
  if lower.contains("connection refused") ||
    lower.contains("no route to host") ||
    lower.contains("network is unreachable") ||
    lower.contains("connection closed") ||
    lower.contains("connection reset") ||
    lower.contains("broken pipe") {
    return @error.ProviderError::new(
      @error.ProviderErrorKind::Transport,
      "SSH connection failed",
    )
    .with_exit(exit_code)
    .with_detail(stderr)
  }
  @error.ProviderError::new(
    @error.ProviderErrorKind::AuthFailed,
    "SSH connection or authentication failed",
  )
  .with_exit(exit_code)
  .with_detail(stderr)
}

///|
/// Probe the remote machine: OS/arch/kernel/hostname/shell, CPU count,
/// docker CLI, GUI heuristic and a fixed tool list. This is the read-only half
/// of `MachineProvider.probe` (architecture §6.1); it never mutates the target.
pub async fn probe(
  target : SshTarget,
  timeout_seconds~ : Int = 15,
) -> Result[MachineProfile, @error.ProviderError] {
  let result = match run_remote(target, probe_command(), timeout_seconds) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    // ssh uses 255 for connection/auth failures; report that separately
    // from a remote command that ran and exited non-zero (§8.3).
    if result.exit_code == 255 {
      return Err(classify_ssh_failure(255, result.stderr))
    }
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::RemoteExit,
        "remote probe command failed",
      )
      .with_exit(result.exit_code)
      .with_detail(result.stderr),
    )
  }
  Ok(parse_probe(result.stdout))
}

///|
/// Resolve the effective SSH configuration with `ssh -G` (no network I/O).
/// Only the keys that matter for routing/identity are kept; the full output is
/// intentionally not stored.
pub async fn resolve_effective(
  target : SshTarget,
  timeout_seconds~ : Int = 10,
) -> Result[Map[String, String], @error.ProviderError] {
  if !target.is_configured() {
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::NotConfigured,
        "SSH target has no host",
      ),
    )
  }
  let argv = ssh_g_argv(target)
  let budget_ms = timeout_seconds.max(1) * 1_000
  let collected = @async.with_timeout_opt(budget_ms, async fn() {
    let (exit_code, stdout, stderr) = @process.collect_output(
      argv[0],
      argv[1:].to_owned(),
    ) catch {
      error =>
        return Err(
          @error.ProviderError::new(
            @error.ProviderErrorKind::SpawnFailed,
            "failed to spawn ssh -G",
          ).with_detail(error.to_string()),
        )
    }
    let stdout_text = stdout.text() catch { _ => "" }
    let stderr_text = stderr.text() catch { _ => "" }
    Ok({ exit_code, stdout: stdout_text, stderr: stderr_text })
  })
  let result = match collected {
    Some(Ok(value)) => value
    Some(Err(error)) => return Err(error)
    None =>
      return Err(
        @error.ProviderError::new(
          @error.ProviderErrorKind::ConnectTimeout,
          "ssh -G timed out after " + timeout_seconds.to_string() + "s",
        ),
      )
  }
  if result.exit_code != 0 {
    if result.exit_code == 255 {
      return Err(classify_ssh_failure(255, result.stderr))
    }
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::RemoteExit,
        "ssh -G failed",
      )
      .with_exit(result.exit_code)
      .with_detail(result.stderr),
    )
  }
  Ok(parse_ssh_g(result.stdout))
}

///|
/// Selected `ssh -G` keys. `ssh -G` prints one `key value` pair per line.
/// Repeated keys (e.g. multiple `identityfile`) keep the first value, which is
/// the one ssh tries first.
pub fn parse_ssh_g(raw : String) -> Map[String, String] {
  let effective : Map[String, String] = Map([])
  for line in raw.split("\n") {
    let clean = line.trim_end(chars="\r").to_owned()
    if clean == "" {
      continue
    }
    match clean.split_once(" ") {
      Some((key, value)) => {
        let key = key.to_lower().to_owned()
        if selected_ssh_g_key(key) && !effective.contains(key) {
          effective.set(key, value.trim().to_owned())
        }
      }
      None => ()
    }
  }
  effective
}

///|
fn selected_ssh_g_key(key : String) -> Bool {
  match key {
    "hostname" => true
    "user" => true
    "port" => true
    "identityfile" => true
    "proxyjump" => true
    "proxycommand" => true
    "connecttimeout" => true
    "stricthostkeychecking" => true
    "userknownhostsfile" => true
    _ => false
  }
}

///|
/// Execute `argv` on the remote host with `cwd` as the working directory.
/// `argv` is never joined into a shell string by MoNexus: each element is
/// passed as a positional parameter of a fixed `sh -c` script (see
/// `remote_exec_command`).
pub async fn run(
  target : SshTarget,
  argv : Array[String],
  cwd~ : String = ".",
  timeout_seconds~ : Int = 30,
) -> Result[RemoteCommandResult, @error.ProviderError] {
  if argv.is_empty() {
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::Internal,
        "empty argv",
      ),
    )
  }
  let result = match run_remote(
    target,
    remote_exec_command(cwd, argv),
    timeout_seconds,
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code == 255 {
    return Err(classify_ssh_failure(255, result.stderr))
  }
  Ok(result)
}

///|
/// Parse the fixed `KEY=VALUE` probe output. Exposed so the host and tests can
/// check profile normalization (clamping, docker/gui booleans) without a
/// remote connection.
pub fn parse_probe(raw : String) -> MachineProfile {
  let mut os = ""
  let mut arch = ""
  let mut kernel = ""
  let mut hostname = ""
  let mut shell = ""
  let mut cpus = 0
  let mut gui = false
  let tools : Map[String, String] = Map([])
  let mut docker_path = ""
  for line in raw.split("\n") {
    let clean = line.trim_end(chars="\r").to_owned()
    if clean == "" {
      continue
    }
    guard clean.split_once("=") is Some((key, value)) else { continue }
    let key = key.to_owned()
    let value = value.to_owned()
    match key {
      "OS" => os = value
      "ARCH" => arch = value
      "KERNEL" => kernel = value
      "HOSTNAME" => hostname = value
      "SHELL" => shell = value
      "CPUS" =>
        cpus = @string.parse_int(value) catch { _ => 0 }
      "DOCKER" => docker_path = value
      "GUI" => gui = value.to_lower() == "yes"
      "TOOL" =>
        match value.split_once("=") {
          Some((name, path)) => tools.set(name.to_owned(), path.to_owned())
          None => tools.set(value, "")
        }
      _ => ()
    }
  }
  let has_docker = docker_path != ""
  if has_docker {
    tools.set("docker", docker_path)
  }
  let max_parallel = if cpus > 0 { cpus.min(64) } else { 4 }
  let notes = [
    "probe ran via POSIX login shell (sh -lc)",
    "has_docker means the docker CLI is present (daemon not checked)",
    "has_gui is a session heuristic (DISPLAY/WAYLAND_DISPLAY or /tmp/.X11-unix/X0)",
  ].join("; ")
  {
    os,
    arch,
    kernel,
    hostname,
    shell,
    tools,
    has_docker,
    has_gui: gui,
    max_parallel,
    notes,
    raw,
  }
}

///|
pub fn MachineProfile::render(self : MachineProfile) -> String {
  let lines : Array[String] = [
    "os=" + self.os,
    "arch=" + self.arch,
    "kernel=" + self.kernel,
    "hostname=" + self.hostname,
    "shell=" + self.shell,
    "max_parallel=" + self.max_parallel.to_string(),
    "has_docker=" + self.has_docker.to_string(),
    "has_gui=" + self.has_gui.to_string(),
  ]
  for name in ["git", "gcc", "clang", "cmake", "moon", "node", "bun", "python3"] {
    let path = match self.tools.get(name) {
      Some(value) => value
      None => ""
    }
    lines.push(
      "tool." + name + "=" +
      (if path == "" { "<missing>" } else { path }),
    )
  }
  lines.join("\n")
}
