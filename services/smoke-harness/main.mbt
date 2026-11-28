///|
/// Native workspace smoke harness.
///
/// Shell still owns the ephemeral OS fixture: temp HOME/state, sshd, keys,
/// known_hosts, host process lifecycle and cleanup. This executable owns the
/// assertions and all host RPC/JSON work through `monexus/host-client` and
/// `monexus/contracts`.

fn usage() -> String {
  [
    "usage:",
    "  smoke_harness workspace",
    "",
    "The workspace subcommand is invoked by scripts/workspace_smoke.sh, which",
    "exports MONEXUS_SMOKE_* fixture variables before starting it.",
  ].join("\n")
}

///|
struct SmokeEnv {
  work : String
  state_dir : String
  repo : String
  remote_root : String
  wrapper : String
  real_ssh_dir : String
  ssh_available : Bool
  ssh_ready : Bool
  ssh_port : Int
  ssh_user : String
  ssh_identity : String
  known_hosts : String
}

///|
fn required_env(name : String) -> Result[String, String] {
  match @env.get_env_var(name) {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing required environment variable " + name)
  }
}

///|
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(value) if value != "" => value
    _ => default
  }
}

///|
fn env_flag(name : String) -> Bool {
  match @env.get_env_var(name) {
    Some(value) =>
      match value.to_lower() {
        "1" | "true" | "yes" | "on" => true
        _ => false
      }
    None => false
  }
}

///|
fn env_int(name : String) -> Int {
  match @env.get_env_var(name) {
    Some(value) => @string.parse_int(value) catch { _ => 0 }
    None => 0
  }
}

///|
fn load_env() -> Result[SmokeEnv, String] {
  let work = match required_env("MONEXUS_SMOKE_WORK") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let state_dir = match required_env("MONEXUS_SMOKE_STATE_DIR") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let repo = match required_env("MONEXUS_SMOKE_REPO") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let remote_root = env_or("MONEXUS_SMOKE_REMOTE_ROOT", repo)
  let wrapper = match required_env("MONEXUS_SMOKE_WRAPPER") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({
    work,
    state_dir,
    repo,
    remote_root,
    wrapper,
    real_ssh_dir: env_or("MONEXUS_SMOKE_REAL_SSH_DIR", ""),
    ssh_available: env_flag("MONEXUS_SMOKE_SSH_AVAILABLE"),
    ssh_ready: env_flag("MONEXUS_SMOKE_SSH_READY"),
    ssh_port: env_int("MONEXUS_SMOKE_SSH_PORT"),
    ssh_user: env_or("MONEXUS_SMOKE_SSH_USER", ""),
    ssh_identity: env_or("MONEXUS_SMOKE_SSH_IDENTITY", ""),
    known_hosts: env_or("MONEXUS_SMOKE_KNOWN_HOSTS", ""),
  })
}

///|
async fn main {
  let (code, message) = run_cli() catch {
    error => (2, "smoke-harness: " + error.to_string())
  }
  if message != "" {
    println(message)
  }
  @env.exit(code)
}

///|
async fn run_cli() -> (Int32, String) {
  let args = @env.args()
  let command = if args.length() > 1 { args[1] } else { "help" }
  match command {
    "workspace" => run_workspace_command()
    "help" | "--help" | "-h" => (0, usage())
    _ => (2, "smoke-harness: unknown command " + command + "\n" + usage())
  }
}

///|
async fn run_workspace_command() -> (Int32, String) {
  let env = match load_env() {
    Ok(value) => value
    Err(message) => return (2, message)
  }
  let report = Report::new()
  let ssh_before = ssh_snapshot(env.real_ssh_dir)
  workspace_flow(env, report, ssh_before) catch {
    error => report.fail("workspace smoke flow completed", error.to_string())
  }
  report.summary()
  if report.ok() {
    (0, "")
  } else {
    (1, "")
  }
}

///|
/// Snapshot regular files directly under the real user's `~/.ssh`, without
/// following symlinks. The shell section must never write there; comparing
/// this before/after is the guard for that boundary.
async fn ssh_snapshot(directory : String) -> String {
  if directory == "" {
    return ""
  }
  let exists = @fs.exists(directory) catch { _ => false }
  if !exists {
    return ""
  }
  let kind = @fs.kind(directory, follow_symlink=false) catch {
    _ => @fs.FileKind::Unknown
  }
  if !(kind is @fs.FileKind::Directory) {
    return ""
  }
  let names = @fs.readdir(
    directory,
    include_hidden=true,
    include_special=false,
    sort=true,
  ) catch {
    _ => return ""
  }
  let lines : Array[String] = []
  for name in names {
    let path = directory + "/" + name
    let file_kind = @fs.kind(path, follow_symlink=false) catch {
      _ => @fs.FileKind::Unknown
    }
    if file_kind is @fs.FileKind::Regular {
      let size = @fs.file_size(path) catch { _ => 0L }
      let (mtime, nanos) = @fs.mtime(path, follow_symlink=false) catch {
        _ => (0L, 0)
      }
      lines.push(
        name +
        " " +
        size.to_string() +
        " " +
        mtime.to_string() +
        "." +
        nanos.to_string(),
      )
    }
  }
  lines.join("\n")
}
