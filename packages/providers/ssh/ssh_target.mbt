///|
/// SSH target and argv construction.
///
/// Pattern source: MoSpace `services/remote/remote.mbt` (`Target`,
/// `ssh_argv`, `shell_quote`), Apache-2.0. The argv order, the
/// `BatchMode=yes` / `ConnectTimeout=` options and the single-quote escaping
/// rule are kept as-is.
///
/// M2 adds explicit `user` / `use_ssh_config` / host-key policy fields. When
/// `use_ssh_config` is false the client is pinned to `-F /dev/null`, so the
/// machine record is the only source of truth; when it is true the user's
/// `~/.ssh/config` still applies and `ssh -G` records what actually took
/// effect (architecture §8.3, ADR-0008).
pub struct SshTarget {
  host : String
  port : Int
  user : String
  identity : String
  use_ssh_config : Bool
  host_key_policy : String
  known_hosts_file : String
  timeout_seconds : Int
  extra_options : Array[String]
}

///|
pub fn SshTarget::new(
  host~ : String,
  port~ : Int = 22,
  user~ : String = "",
  identity~ : String = "",
  use_ssh_config~ : Bool = true,
  host_key_policy~ : String = "accept-new",
  known_hosts_file~ : String = "",
  timeout_seconds~ : Int = 10,
  extra_options~ : Array[String] = [],
) -> SshTarget {
  {
    host,
    port,
    user,
    identity,
    use_ssh_config,
    host_key_policy,
    known_hosts_file,
    timeout_seconds,
    extra_options,
  }
}

///|
pub fn SshTarget::is_configured(self : SshTarget) -> Bool {
  self.host.trim() != ""
}

///|
/// `user@host` when a user is explicit, otherwise `host`. The caller has
/// already validated both parts; nothing here is shell text.
pub fn SshTarget::destination(self : SshTarget) -> String {
  if self.user != "" {
    self.user + "@" + self.host
  } else {
    self.host
  }
}

///|
/// Quote one value for a POSIX shell: wrap in single quotes, and turn an
/// embedded single quote into `'\''`. Same rule as MoSpace `shell_quote`
/// (Apache-2.0), so a path or argument stays literal no matter what
/// metacharacters it contains.
pub fn shell_quote(text : String) -> String {
  "'" + text.replace_all(old="'", new="'\\''") + "'"
}

///|
/// Options shared by a real connection and `ssh -G`, in argv order. Host-key
/// policy `config` means "let ~/.ssh/config decide" and adds nothing.
pub fn target_options(target : SshTarget) -> Array[String] {
  let options : Array[String] = [
    "BatchMode=yes",
    "ConnectTimeout=" + target.timeout_seconds.max(1).to_string(),
  ]
  match target.host_key_policy {
    "accept-new" => options.push("StrictHostKeyChecking=accept-new")
    "yes" => options.push("StrictHostKeyChecking=yes")
    "no" => options.push("StrictHostKeyChecking=no")
    _ => ()
  }
  if target.known_hosts_file != "" {
    options.push("UserKnownHostsFile=" + target.known_hosts_file)
  }
  for option in target.extra_options {
    options.push(option)
  }
  options
}

///|
/// The argv for one remote command. `ssh` must stay non-interactive: a
/// background host cannot answer a password prompt, so credentials come from
/// an identity file, an agent or the system SSH config.
pub fn ssh_argv(
  target : SshTarget,
  remote_command : String,
) -> Array[String] {
  let argv : Array[String] = ["ssh"]
  if !target.use_ssh_config {
    argv.push("-F")
    argv.push("/dev/null")
  }
  for option in target_options(target) {
    argv.push("-o")
    argv.push(option)
  }
  if target.port > 0 {
    argv.push("-p")
    argv.push(target.port.to_string())
  }
  if target.identity != "" {
    argv.push("-i")
    argv.push(target.identity)
  }
  argv.push(target.destination())
  argv.push(remote_command)
  argv
}

///|
/// The argv for a duplex stdio process. `-T` forces "no PTY", so the remote
/// command's stdin/stdout/stderr stay raw byte pipes: a protocol line written
/// to stdin reaches the remote process unchanged and its stdout/stderr come
/// back on separate local pipes. This is transport-only; nothing here knows
/// what protocol travels over the pipes (architecture §6.1/§6.3).
pub fn ssh_stdio_argv(
  target : SshTarget,
  remote_command : String,
) -> Array[String] {
  let base = ssh_argv(target, remote_command)
  let argv : Array[String] = ["ssh", "-T"]
  for index in 1..<base.length() {
    argv.push(base[index])
  }
  argv
}

///|
/// `ssh -G` argv: read-only resolution of the effective configuration. It
/// never opens a network connection. `ConnectTimeout` is irrelevant here but
/// harmless; `target_options` is reused so the recorded values match what a
/// real connection would use.
pub fn ssh_g_argv(target : SshTarget) -> Array[String] {
  let argv : Array[String] = ["ssh"]
  if !target.use_ssh_config {
    argv.push("-F")
    argv.push("/dev/null")
  }
  for option in target_options(target) {
    argv.push("-o")
    argv.push(option)
  }
  if target.port > 0 {
    argv.push("-p")
    argv.push(target.port.to_string())
  }
  if target.identity != "" {
    argv.push("-i")
    argv.push(target.identity)
  }
  argv.push("-G")
  argv.push(target.destination())
  argv
}

///|
/// Build a remote command that runs `argv` without pasting it into a shell
/// string. Every element travels as a positional parameter of a fixed
/// `sh -c` script, quoted with `shell_quote`; the script itself contains no
/// user input, so shell metacharacters in `cwd` or the arguments stay data.
///
/// `sh -c '<script>' monexus-run <cwd> <argv0> <argv1> ...`
pub fn remote_exec_command(cwd : String, argv : Array[String]) -> String {
  if argv.is_empty() {
    return "true"
  }
  let script = "cd -- \"$1\" && shift && exec \"$@\""
  let parts : Array[String] = [
    "sh",
    "-c",
    shell_quote(script),
    "monexus-run",
    shell_quote(cwd),
  ]
  for arg in argv {
    parts.push(shell_quote(arg))
  }
  parts.join(" ")
}

///|
/// Static probe script. It contains no user input and only reads; the remote
/// side is assumed to be a POSIX shell (architecture §8.1).
///
/// M2 fields: hostname, CPU count (for `max_parallel`), docker CLI presence,
/// and a deliberately conservative GUI heuristic. `has_docker` means the CLI
/// exists, not that the daemon is reachable; `has_gui` is only true when the
/// SSH session exposes X11/Wayland (see notes in the profile).
pub fn probe_script() -> String {
  [
    "printf 'OS=%s\\n' \"$(uname -s)\"",
    "printf 'ARCH=%s\\n' \"$(uname -m)\"",
    "printf 'KERNEL=%s\\n' \"$(uname -r)\"",
    "printf 'HOSTNAME=%s\\n' \"$(uname -n 2>/dev/null || hostname 2>/dev/null || printf unknown)\"",
    "if [ -z \"${SHELL:-}\" ]; then",
    "  SHELL=\"$(awk -F: -v u=\"$(id -un)\" '$1==u{print $7; exit}' /etc/passwd 2>/dev/null)\"",
    "fi",
    "printf 'SHELL=%s\\n' \"${SHELL:-}\"",
    "printf 'CPUS=%s\\n' \"$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 0)\"",
    "printf 'DOCKER=%s\\n' \"$(command -v docker 2>/dev/null || printf '')\"",
    "if [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}\" ] || [ -S /tmp/.X11-unix/X0 ]; then",
    "  printf 'GUI=yes\\n'",
    "else",
    "  printf 'GUI=no\\n'",
    "fi",
    "for t in git gcc clang cmake moon node bun python3; do",
    "  if command -v \"$t\" >/dev/null 2>&1; then",
    "    printf 'TOOL=%s=%s\\n' \"$t\" \"$(command -v \"$t\")\"",
    "  else",
    "    printf 'TOOL=%s=\\n' \"$t\"",
    "  fi",
    "done",
  ].join("\n")
}

///|
/// The probe is run through a POSIX login shell so `PATH` matches an
/// interactive login (`sh -lc`). The script itself is fixed and quoted; no
/// user input is interpolated.
pub fn probe_command() -> String {
  "sh -lc " + shell_quote(probe_script())
}
