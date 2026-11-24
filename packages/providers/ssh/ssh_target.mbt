///|
/// SSH target and argv construction.
///
/// Pattern source: MoSpace `services/remote/remote.mbt` (`Target`,
/// `ssh_argv`, `shell_quote`), Apache-2.0. The argv order, the
/// `BatchMode=yes` / `ConnectTimeout=` options and the single-quote escaping
/// rule are kept as-is; `extra_options` is the spike-local addition used by
/// the loopback test to point at a throwaway known_hosts file without
/// touching the user's global SSH configuration.
pub struct SshTarget {
  host : String
  port : Int
  identity : String
  timeout_seconds : Int
  extra_options : Array[String]
}

///|
pub fn SshTarget::new(
  host~ : String,
  port~ : Int = 22,
  identity~ : String = "",
  timeout_seconds~ : Int = 10,
  extra_options~ : Array[String] = [],
) -> SshTarget {
  { host, port, identity, timeout_seconds, extra_options, }
}

///|
pub fn SshTarget::is_configured(self : SshTarget) -> Bool {
  self.host.trim() != ""
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
/// The argv for one remote command. `ssh` must stay non-interactive: a
/// background host cannot answer a password prompt, so credentials come from
/// an identity file, an agent or the system SSH config.
pub fn ssh_argv(
  target : SshTarget,
  remote_command : String,
) -> Array[String] {
  let argv : Array[String] = ["ssh"]
  argv.push("-o")
  argv.push("BatchMode=yes")
  argv.push("-o")
  argv.push("ConnectTimeout=" + target.timeout_seconds.max(1).to_string())
  for option in target.extra_options {
    argv.push("-o")
    argv.push(option)
  }
  if target.port > 0 && target.port != 22 {
    argv.push("-p")
    argv.push(target.port.to_string())
  }
  if target.identity != "" {
    argv.push("-i")
    argv.push(target.identity)
  }
  argv.push(target.host)
  argv.push(remote_command)
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
pub fn probe_script() -> String {
  [
    "printf 'OS=%s\\n' \"$(uname -s)\"",
    "printf 'ARCH=%s\\n' \"$(uname -m)\"",
    "printf 'KERNEL=%s\\n' \"$(uname -r)\"",
    "printf 'SHELL=%s\\n' \"${SHELL:-}\"",
    "for t in git gcc clang cmake moon; do",
    "  if command -v \"$t\" >/dev/null 2>&1; then",
    "    printf 'TOOL=%s=%s\\n' \"$t\" \"$(command -v \"$t\")\"",
    "  else",
    "    printf 'TOOL=%s=\\n' \"$t\"",
    "  fi",
    "done",
  ].join("\n")
}
