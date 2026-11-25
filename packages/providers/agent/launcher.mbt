///|
/// ProcessLauncher: where an AgentRuntime process starts, and how its stdio
/// reaches it (PoC round 1 for remote agents).
///
/// The launcher is transport-only. It knows how to obtain a duplex process
/// handle (stdin/stdout/stderr pipes plus a local pid) for a command line,
/// either in-process or through `ssh -T`. It has no ACP or session semantics:
/// the ACP protocol code above it cannot tell which transport it got, and the
/// MachineProvider/ssh layer never returns an "agent connection".
///
/// The SSH variant reuses `SshTarget` and the `ssh_argv` rules (BatchMode,
/// ConnectTimeout, identity, dedicated known_hosts, host-key policy). The
/// remote program is a fixed POSIX `sh -c` script with positional parameters,
/// so cwd/command/args never become shell text (ADR-0008, architecture §8).
pub(all) enum ProcessLauncher {
  Local
  Ssh(@ssh.SshTarget)
}

///|
/// Explicit gate for the remote-agent PoC. V0.1 keeps agents local by default;
/// when this is not `1`, an SSH-backed `agent.start` returns the existing
/// local-only error instead of silently launching over SSH.
pub const AGENT_SSH_GATE_ENV : String = "MONEXUS_AGENT_SSH"

///|
pub fn agent_ssh_enabled() -> Bool {
  match @env.get_env_var(AGENT_SSH_GATE_ENV) {
    Some(value) => value.trim() == "1"
    None => false
  }
}

///|
/// Configured program and argv before local PATH resolution, with the V0.1
/// ACP defaults applied. The local launcher resolves the program against the
/// host PATH; the SSH launcher sends it as-is because the remote machine
/// resolves it with its own login/runtime.
pub fn effective_agent_command(
  mode : String,
  command : String,
  args : Array[String],
) -> Result[(String, Array[String]), String] {
  let configured = if command.trim() == "" {
    if mode == @contracts.AGENT_MODE_ACP {
      default_acp_command()
    } else {
      ""
    }
  } else {
    command.trim().to_owned()
  }
  if configured == "" {
    return Err("command is required for " + mode + " mode")
  }
  let effective_args = if command.trim() == "" &&
    mode == @contracts.AGENT_MODE_ACP &&
    args.is_empty() {
    default_acp_args()
  } else {
    args
  }
  Ok((configured, effective_args))
}

///|
/// Remote program for one agent process. The script contains no user text:
/// `cwd`, `command` and every argument travel as positional parameters of a
/// fixed `sh -c` script, quoted with `shell_quote`. The script changes to the
/// workspace directory and `exec`s the agent with `CLAUDECODE` stripped, the
/// same rule the local launcher applies (M0: the adapter refuses a nested
/// invocation). The remote machine's own login/runtime supplies model
/// credentials; the host never copies them.
pub fn remote_agent_command(
  cwd : String,
  command : String,
  args : Array[String],
) -> String {
  let dir = if cwd.trim() == "" { "." } else { cwd }
  let argv : Array[String] = ["env", "-u", "CLAUDECODE", command]
  for arg in args {
    argv.push(arg)
  }
  @ssh.remote_exec_command(dir, argv)
}

///|
/// The argv a local spawn should use for one agent process, and the directory
/// it should run in. Local launch keeps the existing rule: resolve the program
/// against PATH and wrap it with an absolute `env -u CLAUDECODE` when present.
pub async fn local_agent_argv(
  mode : String,
  command : String,
  args : Array[String],
) -> Result[(String, Array[String]), String] {
  let (configured, effective_args) = match
    effective_agent_command(mode, command, args) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let resolved = match resolve_command(configured) {
    Some(value) => value
    None => return Err("executable not found: " + configured)
  }
  // Prefer an absolute env(1) so the wrapper works even from a GUI launch
  // with a reduced PATH.
  let has_usr_env = @fs.exists("/usr/bin/env") catch { _ => false }
  let has_bin_env = @fs.exists("/bin/env") catch { _ => false }
  let env_path = if has_usr_env {
    Some("/usr/bin/env")
  } else if has_bin_env {
    Some("/bin/env")
  } else {
    None
  }
  match env_path {
    Some(wrapper) => {
      let argv : Array[String] = ["-u", "CLAUDECODE", resolved]
      for arg in effective_args {
        argv.push(arg)
      }
      Ok((wrapper, argv))
    }
    None => Ok((resolved, effective_args))
  }
}

///|
/// The argv for the remote SSH client, or the local argv pair. Transport only:
/// returns (program, argv, local_cwd); the cwd is empty for SSH because the
/// remote script changes directory itself.
pub async fn launch_argv(
  launcher : ProcessLauncher,
  mode : String,
  command : String,
  args : Array[String],
  cwd : String,
) -> Result[(String, Array[String], String), String] {
  match launcher {
    ProcessLauncher::Local => {
      let (program, argv) = match local_agent_argv(mode, command, args) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      Ok((program, argv, cwd.trim().to_owned()))
    }
    ProcessLauncher::Ssh(target) => {
      if !target.is_configured() {
        return Err("SSH target has no host")
      }
      let (program, effective_args) = match
        effective_agent_command(mode, command, args) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      let remote = remote_agent_command(cwd, program, effective_args)
      let argv = @ssh.ssh_stdio_argv(target, remote)
      Ok((argv[0], argv[1:].to_owned(), ""))
    }
  }
}
