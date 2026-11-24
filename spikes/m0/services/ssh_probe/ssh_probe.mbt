///|
/// Machine facts collected by `probe`. Fields mirror `MachineProfile` in
/// architecture §6.1; only what the spike can prove is filled in.
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
/// Run one remote command through the system `ssh` client and return its
/// stdout/stderr/exit code. The timeout is a host-side backstop around
/// `ConnectTimeout` (which only covers connection setup).
///
/// Errors are raised as plain `Error` with a printable message: the M0 spike
/// has no ProviderError mapping yet, and the caller only prints them.
async fn run_remote(
  target : SshTarget,
  remote_command : String,
  timeout_seconds : Int,
) -> RemoteCommandResult raise {
  guard target.is_configured() else { fail("SSH target is not configured") }
  let argv = ssh_argv(target, remote_command)
  let budget_ms = timeout_seconds.max(1) * 1_000
  let collected = @async.with_timeout_opt(budget_ms, async fn() {
    @process.collect_output(argv[0], argv[1:].to_owned())
  })
  let (exit_code, stdout, stderr) = match collected {
    Some(value) => value
    None => fail("SSH command timed out after " + timeout_seconds.to_string() + "s")
  }
  { exit_code, stdout: stdout.text(), stderr: stderr.text(), }
}

///|
/// Probe the remote machine: OS/arch/kernel/shell and a fixed tool list.
/// This is the read-only half of `MachineProvider.probe` (architecture
/// §6.1); it never mutates the target.
pub async fn probe(
  target : SshTarget,
  timeout_seconds~ : Int = 15,
) -> MachineProfile raise {
  let result = run_remote(target, probe_script(), timeout_seconds)
  if result.exit_code != 0 {
    // ssh uses 255 for connection/auth failures; report that as an auth
    // failure when there is no other remote stderr to go by (§8.3).
    if result.exit_code == 255 {
      fail("SSH authentication or connection failed: " + result.stderr)
    }
    fail(
      "remote probe failed with exit code " +
      result.exit_code.to_string() +
      (if result.stderr == "" { "" } else { ": " + result.stderr }),
    )
  }
  parse_probe(result.stdout)
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
) -> RemoteCommandResult raise {
  guard !argv.is_empty() else { fail("empty argv") }
  let result = run_remote(target, remote_exec_command(cwd, argv), timeout_seconds)
  if result.exit_code == 255 {
    fail("SSH authentication or connection failed: " + result.stderr)
  }
  result
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
