///|
/// One PTY run: everything the spike prints as evidence.
pub struct PtyCheckResult {
  output : String
  exit_code : Int
  pid : Int
}

///|
/// Drive one command line through a real pseudo-terminal.
///
/// Reuse, not reimplementation: `moonbit-community/pty@0.4.4` (Apache-2.0) is
/// the same PTY package MoSpace's `services/terminal` builds on. MoUI's
/// `examples/terminal/pty_host` uses the same openpty + posix_spawn shape;
/// here we take the packaged binding instead of copying its C file, so the
/// spike carries no third-party C source.
///
/// The command line must end in `exit <n>` (or otherwise terminate the
/// shell); `read_all` then reaches EOF and `wait` reports the exit status.
pub async fn run_pty_check(
  shell : String,
  command : String,
) -> PtyCheckResult {
  let (output, exit_code, pid) = @pty_ffi.with_pty(
    shell,
    [],
    rows=24,
    cols=80,
  ) <| pty => {
    let pid = pty.pid()
    // A shell only executes a complete line; append the newline the caller
    // did not have to think about.
    let line = if command.has_suffix("\n") {
      command
    } else {
      command + "\n"
    }
    // A write can fail if the child exits immediately; the point of the check
    // is what came back on the terminal, so a failed write is not fatal.
    pty.write(@utf8.encode(line)) catch { _ => () }
    let output = pty.read_all().text()
    let exit_code = pty.wait()
    (output, exit_code, pid)
  }
  { output, exit_code, pid, }
}
