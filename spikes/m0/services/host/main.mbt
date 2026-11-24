///|
/// M0 spike entry point. This is deliberately small: the binary exists to
/// prove that a MoonBit native executable builds and links inside the MoNexus
/// workspace, and to expose the three other spike paths as subcommands.
async fn main {
  let args = @env.args()
  let (code, message) = run_host_command(args) catch {
    error => (2, "monexus-host: " + error.to_string())
  }
  if message != "" {
    println(message)
  }
  @env.exit(code)
}

///|
async fn run_host_command(args : Array[String]) -> (Int32, String) {
  let command = if args.length() > 1 { args[1] } else { "version" }
  match command {
    "version" => (0, host_version_line())
    "help" | "--help" | "-h" => (0, usage_text())
    "pty-check" => pty_check_command(args[2:].to_owned())
    "ssh-probe" => ssh_probe_command(args[2:].to_owned())
    "ssh-run" => ssh_run_command(args[2:].to_owned())
    "acp" => acp_command(args[2:].to_owned())
    _ =>
      (
        2,
        "monexus-host: unknown command " +
        command +
        "\n" +
        usage_text(),
      )
  }
}

///|
/// Version string of the spike binary. The real `monexus-host` version
/// scheme lands with M1; M0 only needs a reproducible, printable value.
const HOST_VERSION : String = "0.0.1-m0"

///|
fn host_version_line() -> String {
  "monexus-host " + HOST_VERSION + " (M0 spike)"
}

///|
fn usage_text() -> String {
  [
    "usage:",
    "  monexus-host version",
    "  monexus-host pty-check [--shell sh] [--cmd <line>]",
    "  monexus-host ssh-probe --ssh-host H [--ssh-port P] [--identity FILE]",
    "      [--known-hosts FILE] [--strict accept-new] [--timeout SECONDS]",
    "  monexus-host ssh-run --ssh-host H [--ssh-port P] [--identity FILE]",
    "      [--known-hosts FILE] [--strict accept-new] [--cwd DIR] [--timeout SECONDS]",
    "      -- argv...",
    "  monexus-host acp --command CMD [--arg A]... [--cwd DIR] [--workspace DIR]",
    "      --prompt TEXT [--timeout SECONDS]",
  ].join("\n")
}
