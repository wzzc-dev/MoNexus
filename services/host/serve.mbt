///|
/// Write `host.json` atomically with mode 0600. A crash between create and
/// rename leaves only the temporary file, never a half-written discovery
/// file that a client could trust.
async fn write_host_info(state : HostState) -> Result[Unit, String] {
  let path = @contracts.host_info_path(state.state_dir)
  let temp_path = path + ".tmp"
  let text = state.host_info().to_json().stringify()
  @fs.write_file(
    temp_path,
    text,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  ) catch {
    error => return Err("cannot write host.json: " + error.to_string())
  }
  @fs.rename(temp_path, path, replace=true) catch {
    error => return Err("cannot publish host.json: " + error.to_string())
  }
  Ok(())
}

///|
async fn remove_host_info(state : HostState) -> Unit {
  @fs.remove(@contracts.host_info_path(state.state_dir)) catch { _ => () }
}

///|
/// Run the M1 host until cancelled (SIGINT/SIGTERM). Returns an error before
/// serving when the state directory cannot be prepared or another instance
/// already holds the lock.
pub async fn serve(options : HostOptions) -> Result[Unit, String] {
  @fs.mkdir(
    options.state_dir,
    permission=0o700,
    recursive=true,
    allow_exist=true,
  ) catch {
    error =>
      return Err(
        "cannot create state dir " + options.state_dir + ": " +
        error.to_string(),
      )
  }
  let lock_path = @contracts.host_lock_path(options.state_dir)
  let lock = @fs.open(
    lock_path,
    mode=@fs.Mode::ReadWrite,
    create_mode=@fs.CreateMode::OpenOrCreate,
    permission=0o600,
  ) catch {
    error => return Err("cannot open lock file: " + error.to_string())
  }
  let locked = lock.try_lock(@fs.Lock::Exclusive) catch { _ => false }
  if !locked {
    lock.close()
    return Err(
      "another monexus-host instance is already running in " +
      options.state_dir,
    )
  }
  // One SQLite file per state dir: machine projection + append-only events.
  // It is opened before host.json is published so a broken database never
  // produces a discovery file that points at an unusable host.
  let db_path = options.state_dir + "/monexus.db"
  let store = match @machines.MachineStore::open(db_path) {
    Ok(value) => value
    Err(message) => {
      lock.close()
      return Err("cannot open " + db_path + ": " + message)
    }
  }
  match store.prune_heartbeats() {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: warning: cannot prune heartbeat events: " + message)
  }
  match store.reconcile_projection() {
    Ok((live, removed)) =>
      println(
        "monexus-host: machine projection rebuilt from events (live=" +
        live.to_string() +
        " tombstoned=" +
        removed.to_string() +
        ")",
      )
    Err(message) => {
      store.close()
      lock.close()
      return Err("cannot rebuild machine projection: " + message)
    }
  }
  match store.reconcile_workspace_projection() {
    Ok(_) => ()
    Err(message) => {
      store.close()
      lock.close()
      return Err("cannot rebuild workspace projection: " + message)
    }
  }
  let addr = @socket.Addr::parse(
    "127.0.0.1:" + options.port.to_string(),
  ) catch {
    error => {
      store.close()
      lock.close()
      return Err("invalid bind address: " + error.to_string())
    }
  }
  let server = @http.Server::Server(addr, reuse_addr=false)
  let state = HostState::new(options, server.addr().port(), store)
  match write_host_info(state) {
    Ok(_) => ()
    Err(message) => {
      store.close()
      lock.close()
      return Err(message)
    }
  }
  println("monexus-host listening on " + state.ws_url)
  @async.with_task_group(async fn(group) {
    state.group.val = Some(group)
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() { heartbeat_loop(state) },
    )
    server.run_forever(allow_failure=true, max_connections=64) <|
    ((request, _body, conn) => {
      handle_connection(state, request, conn)
    })
  })
  // Best-effort cleanup for a server that stopped without cancellation.
  // SIGINT/SIGTERM cancel the task group; the next start rewrites host.json
  // and the OS releases the flock when the process exits.
  remove_host_info(state)
  server.close()
  state.store.close()
  lock.close()
  Ok(())
}
