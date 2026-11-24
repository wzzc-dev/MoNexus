///|
/// Machine facts collected by `probe`. Fields mirror `MachineProfile` in
/// architecture §6.1; only what the probe can prove is filled in.
pub(all) struct MachineProfile {
  os : String
  arch : String
  kernel : String
  shell : String
  tools : Map[String, String]
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
/// Probe the remote machine: OS/arch/kernel/shell and a fixed tool list.
/// This is the read-only half of `MachineProvider.probe` (architecture
/// §6.1); it never mutates the target.
pub async fn probe(
  target : SshTarget,
  timeout_seconds~ : Int = 15,
) -> Result[MachineProfile, @error.ProviderError] {
  let result = match run_remote(target, probe_script(), timeout_seconds) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    // ssh uses 255 for connection/auth failures; report that separately
    // from a remote command that ran and exited non-zero (§8.3).
    if result.exit_code == 255 {
      return Err(
        @error.ProviderError::new(
          @error.ProviderErrorKind::AuthFailed,
          "SSH authentication or connection failed",
        )
        .with_exit(255)
        .with_detail(result.stderr),
      )
    }
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::RemoteExit,
        "remote probe failed",
      )
      .with_exit(result.exit_code)
      .with_detail(result.stderr),
    )
  }
  Ok(parse_probe(result.stdout))
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
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::AuthFailed,
        "SSH authentication or connection failed",
      )
      .with_exit(255)
      .with_detail(result.stderr),
    )
  }
  Ok(result)
}

///|
fn parse_probe(raw : String) -> MachineProfile {
  let mut os = ""
  let mut arch = ""
  let mut kernel = ""
  let mut shell = ""
  let tools : Map[String, String] = Map([])
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
      "SHELL" => shell = value
      "TOOL" =>
        match value.split_once("=") {
          Some((name, path)) => tools.set(name.to_owned(), path.to_owned())
          None => tools.set(value, "")
        }
      _ => ()
    }
  }
  { os, arch, kernel, shell, tools, raw, }
}

///|
pub fn MachineProfile::render(self : MachineProfile) -> String {
  let lines : Array[String] = [
    "os=" + self.os,
    "arch=" + self.arch,
    "kernel=" + self.kernel,
    "shell=" + self.shell,
  ]
  for name in ["git", "gcc", "clang", "cmake", "moon"] {
    let path = match self.tools.get(name) {
      Some(value) => value
      None => ""
    }
    lines.push(
      "tool." + name + "=" + (if path == "" { "<missing>" } else { path }),
    )
  }
  lines.join("\n")
}
