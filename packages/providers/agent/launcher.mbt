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
  /// An AgentRuntime process launched on a paired runtime node through
  /// `runtime.process.*`. The handle is stdio only; the machine/provider axis
  /// never returns an ACP connection (ADR-0003, ADR-0012 §6).
  Runtime(RemoteLauncher)
}

///|
/// What the host asks a runtime node to start: an argv-only agent process in a
/// node-rooted workspace directory. There is deliberately no `env` field: the
/// node uses its own environment allowlist and login credentials, and the host
/// never ships model keys, private keys or `~/.ssh` (Goal 3).
pub(all) struct RemoteStartSpec {
  argv : Array[String]
  cwd : String
  risk : String
}

///|
pub fn RemoteStartSpec::new(
  argv~ : Array[String],
  cwd~ : String = "",
  risk~ : String = "",
) -> RemoteStartSpec {
  { argv, cwd, risk, }
}

///|
/// The stable identity of a started remote process. `run_id` survives a
/// reconnect; the node's `client_request_id` makes the start idempotent.
pub(all) struct RemoteStarted {
  run_id : String
  pid : Int
  api : RemoteApi
}

///|
pub fn RemoteStarted::new(
  run_id : String,
  pid : Int,
  api : RemoteApi,
) -> RemoteStarted {
  { run_id, pid, api, }
}

///|
/// One bounded stdout/stderr chunk, already base64-decoded. Offsets are
/// absolute within the stream. `gap` means the node's ring evicted bytes the
/// primary had not read yet: the protocol stream is unrecoverable in A1 (no
/// reattach), so the ACP session must end `lost`, never fake success.
pub(all) struct RemoteChunk {
  offset : Int64
  next_offset : Int64
  data : Bytes
  eof : Bool
  gap : Bool
  dropped : Bool
  total_bytes : Int64
}

///|
/// Terminal observation of a remote process. `status` is a runtime run status
/// (`succeeded`, `failed`, `cancelled`, `lost`); `None` means the node had no
/// live record for the run id (host restart, unknown run).
pub(all) struct RemoteExit {
  status : String
  exit_code : Int?
  signal : Int?
  stop_reason : String
  success : Bool
}

///|
/// The stdio/control surface of one remote process. Everything is async and
/// bounded by the node; the agent layer polls `read_*` by absolute offset and
/// never retries a read as if it were a write.
pub(all) struct RemoteApi {
  write_stdin : async (Bytes) -> Result[Unit, String]
  read_stdout : async (Int64) -> Result[RemoteChunk, String]
  read_stderr : async (Int64) -> Result[RemoteChunk, String]
  exit : async () -> Result[RemoteExit?, String]
  cancel : async () -> Result[Unit, String]
}

///|
pub fn RemoteApi::new(
  write_stdin~ : async (Bytes) -> Result[Unit, String],
  read_stdout~ : async (Int64) -> Result[RemoteChunk, String],
  read_stderr~ : async (Int64) -> Result[RemoteChunk, String],
  exit~ : async () -> Result[RemoteExit?, String],
  cancel~ : async () -> Result[Unit, String],
) -> RemoteApi {
  { write_stdin, read_stdout, read_stderr, exit, cancel, }
}

///|
/// Adapter seam from the primary's `RuntimeMachine` (`runtime.process.*`) to
/// the transport-only launcher the AgentRuntime consumes. It is constructed by
/// the host (or a test) and registered per machine id; it carries no ACP.
pub(all) struct RemoteLauncher {
  start : async (RemoteStartSpec) -> Result[RemoteStarted, String]
}

///|
pub fn RemoteLauncher::new(
  start~ : async (RemoteStartSpec) -> Result[RemoteStarted, String],
) -> RemoteLauncher {
  { start, }
}

///|
/// ADR-0011 classification for a runtime-node process. A missing exit record
/// or a `lost` node status means the transport/node could not observe the
/// process: `lost`, never success. Any other terminal status is the agent
/// exiting mid-turn: `interrupted`.
pub fn runtime_eof_stop_reason(exit : RemoteExit?) -> String {
  match exit {
    None => @contracts.AGENT_STOP_LOST
    Some(value) =>
      if value.status == @contracts.RUN_STATUS_LOST ||
        value.stop_reason == @contracts.AGENT_STOP_LOST {
        @contracts.AGENT_STOP_LOST
      } else {
        @contracts.AGENT_STOP_INTERRUPTED
      }
  }
}

///|
/// ADR-0011 remote EOF semantics for a turn that is still in flight. The
/// observed code comes from the local `ssh` client, not from the remote
/// program: 255 is ssh's own connection failure, `None` means the status could
/// not be observed, and a negative code is a signal death of the local client
/// (for example the owner/network killing it). All three mean the transport
/// was lost. Any other exit is the remote agent exiting mid-turn.
pub fn remote_eof_stop_reason(exit_status : Int?) -> String {
  match exit_status {
    Some(code) =>
      if code == 255 || code < 0 {
        @contracts.AGENT_STOP_LOST
      } else {
        @contracts.AGENT_STOP_INTERRUPTED
      }
    None => @contracts.AGENT_STOP_LOST
  }
}

///|
/// Readable `last_error` for a remote EOF classification. Kept free of paths
/// and credentials so it is safe in records, events and the UI.
pub fn remote_eof_last_error(stop_reason : String) -> String {
  match stop_reason {
    @contracts.AGENT_STOP_LOST => "remote agent connection lost"
    @contracts.AGENT_STOP_INTERRUPTED => "remote agent exited mid-turn"
    _ => ""
  }
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
    ProcessLauncher::Runtime(_) =>
      Err(
        "runtime launcher is stdio-only and does not build a local argv",
      )
  }
}
