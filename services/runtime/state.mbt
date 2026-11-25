///|
/// Node-local runtime state root (ADR-0012 §1): `~/.monexus/runtime/<id>/`.
///
/// Everything the execution plane persists lives below one real-path root:
/// the durable event outbox (`outbox.db`), per-run stream logs (`logs/<run_id>/`)
/// and the default command root (`work/`). The root is forced to mode 0700 so
/// no other local user can read logs, events or the outbox.
///
/// This module is transport-agnostic. It opens no sockets, holds no
/// credentials and never touches `~/.ssh`.
pub struct RuntimeState {
  root : String
  work_dir : String
  logs_dir : String
  outbox_path : String
}

///|
/// Create (or reopen) the runtime state root. `root` is resolved with
/// `realpath` after creation, so later containment checks compare real paths.
pub async fn RuntimeState::open(root : String) -> Result[RuntimeState, String] {
  let requested = root.trim()
  if requested == "" {
    return Err("runtime state root is required")
  }
  @fs.mkdir(requested, permission=0o700, recursive=true, allow_exist=true) catch {
    error =>
      return Err("cannot create runtime state root: " + error.to_string())
  }
  @fs.chmod(requested, 0o700) catch {
    error =>
      return Err("cannot set 0700 on runtime state root: " + error.to_string())
  }
  let real = @fs.realpath(requested) catch {
    error =>
      return Err("cannot resolve runtime state root: " + error.to_string())
  }
  let work = real + "/work"
  let logs = real + "/logs"
  for dir in [work, logs] {
    @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
      error =>
        return Err(
          "cannot create runtime state directory: " + error.to_string(),
        )
    }
    @fs.chmod(dir, 0o700) catch {
      error =>
        return Err(
          "cannot set 0700 on runtime state directory: " + error.to_string(),
        )
    }
  }
  Ok({
    root: real,
    work_dir: work,
    logs_dir: logs,
    outbox_path: real + "/outbox.db",
  })
}

///|
pub fn RuntimeState::root(self : RuntimeState) -> String {
  self.root
}

///|
/// Default command root for this slice. A1.1's `exec.start` will narrow this
/// to a primary-registered Workspace root instead.
pub fn RuntimeState::work_dir(self : RuntimeState) -> String {
  self.work_dir
}

///|
pub fn RuntimeState::logs_dir(self : RuntimeState) -> String {
  self.logs_dir
}

///|
pub fn RuntimeState::outbox_path(self : RuntimeState) -> String {
  self.outbox_path
}

///|
/// Directory holding one run's stream logs. `run_id` is primary-assigned and
/// validated before it becomes a path component.
pub async fn RuntimeState::run_log_dir(
  self : RuntimeState,
  run_id : String,
) -> Result[String, String] {
  match validate_resource_id(run_id, "run_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let dir = self.logs_dir + "/" + run_id
  @fs.mkdir(dir, permission=0o700, recursive=false, allow_exist=true) catch {
    error => return Err("cannot create run log directory: " + error.to_string())
  }
  @fs.chmod(dir, 0o700) catch {
    _ => ()
  }
  Ok(dir)
}

///|
/// Create the two append-only stream logs (0600) before a run starts, so an
/// event's `(stream, offset, length)` reference always has a backing file.
pub async fn RuntimeState::ensure_run_logs(
  self : RuntimeState,
  run_id : String,
) -> Result[(String, String), String] {
  let dir = match self.run_log_dir(run_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let out = dir + "/stdout.log"
  let err = dir + "/stderr.log"
  for path in [out, err] {
    @fs.write_file(
      path,
      "",
      create_mode=@fs.CreateMode::OpenOrCreate,
      permission=0o600,
      append=true,
      sync=@fs.SyncMode::Data,
    ) catch {
      error => return Err("cannot create run stream log: " + error.to_string())
    }
    @fs.chmod(path, 0o600) catch {
      _ => ()
    }
  }
  Ok((out, err))
}
