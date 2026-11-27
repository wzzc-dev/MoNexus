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
/// Run a helper command (git init in the example workspace) without turning a
/// missing optional tool into a host failure.
async fn run_quiet(argv : Array[String]) -> Unit {
  let _ = @process.collect_output(argv[0], argv[1:]) catch { _ => return }
  ()
}

///|
/// Create the first-run layout under the state directory: `agents/`,
/// `artifacts/`, `logs/`, and a tiny example workspace. Existing files are
/// never overwritten, and a missing `git` only costs the repository init.
async fn init_state_layout(state_dir : String) -> Result[Unit, String] {
  for name in ["agents", "artifacts", "logs", "examples"] {
    let path = state_dir + "/" + name
    @fs.mkdir(path, permission=0o700, recursive=true, allow_exist=true) catch {
      error =>
        return Err("cannot create " + path + ": " + error.to_string())
    }
  }
  let sample = state_dir + "/examples/hello-workspace"
  @fs.mkdir(sample, permission=0o700, recursive=true, allow_exist=true) catch {
    error =>
      return Err("cannot create " + sample + ": " + error.to_string())
  }
  let readme_path = sample + "/README.md"
  let readme = [
    "# Hello Workspace",
    "",
    "This is the MoNexus example workspace created on first run.",
    "",
    "- Open it from Projects with the root path shown below.",
    "- Create a worktree, start an agent session, or dispatch a task.",
    "",
    "Root: " + sample,
    "",
  ].join("\n")
  if !(@fs.exists(readme_path) catch { _ => false }) {
    @fs.write_file(
      readme_path,
      readme,
      create_mode=@fs.CreateMode::CreateOrTruncate,
      permission=0o600,
    ) catch {
      error => return Err("cannot write " + readme_path + ": " + error.to_string())
    }
  }
  let agents_md = sample + "/AGENTS.md"
  if !(@fs.exists(agents_md) catch { _ => false }) {
    @fs.write_file(
      agents_md,
      [
        "# AGENTS.md",
        "",
        "Project conventions for agents. MoNexus keeps this file read-only",
        "for sessions; durable agent memory lives in AGENTS/<id>/MEMORY.md.",
        "",
      ].join("\n"),
      create_mode=@fs.CreateMode::CreateOrTruncate,
      permission=0o600,
    ) catch {
      error => return Err("cannot write " + agents_md + ": " + error.to_string())
    }
  }
  // A git repository makes worktrees/diffs usable immediately. Best effort:
  // git is optional for the host itself.
  if !(@fs.exists(sample + "/.git") catch { _ => false }) {
    ignore(
      @async.with_timeout_opt(
        10_000,
        async fn() {
          run_quiet(["git", "-C", sample, "init", "-q"])
          run_quiet(["git", "-C", sample, "add", "README.md", "AGENTS.md"])
          run_quiet([
            "git", "-C", sample,
            "-c", "user.email=monexus@localhost",
            "-c", "user.name=MoNexus",
            "commit", "-qm", "example workspace",
          ])
        },
      ),
    )
  }
  Ok(())
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
  match init_state_layout(options.state_dir) {
    Ok(_) => ()
    Err(message) => return Err(message)
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
  // Task / Run projections are rebuilt from the same append-only log, so a
  // crash between the event write and the projection write is repaired here.
  match store.reconcile_task_projection() {
    Ok((projects, tasks, runs)) =>
      println(
        "monexus-host: task projection rebuilt from events (projects=" +
        projects.to_string() +
        " tasks=" +
        tasks.to_string() +
        " runs=" +
        runs.to_string() +
        ")",
      )
    Err(message) => {
      store.close()
      lock.close()
      return Err("cannot rebuild task projection: " + message)
    }
  }
  // Environment / recipe projections replay from the same append-only log.
  // Trust keys are owner configuration loaded from the trust file, never from
  // events; they are mirrored into `recipe_trust` for inspection.
  match store.reconcile_environment_projection() {
    Ok(_) => ()
    Err(message) => {
      store.close()
      lock.close()
      return Err("cannot rebuild environment projection: " + message)
    }
  }
  match store.reconcile_bots_projection() {
    Ok(counts) =>
      println(
        "monexus-host: bot projection rebuilt from events (bots=" +
        counts.bots.to_string() +
        " agents=" +
        counts.agents.to_string() +
        " chats=" +
        counts.chats.to_string() +
        " sessions=" +
        counts.sessions.to_string() +
        " memberships=" +
        counts.memberships.to_string() +
        ")",
      )
    Err(message) => {
      store.close()
      lock.close()
      return Err("cannot rebuild bot projection: " + message)
    }
  }
  let trust = load_host_trust(options.state_dir)
  persist_trust_rows(store, trust)
  let verifier = @recipes.probe_verifier()
  if !verifier.usable {
    println(
      "monexus-host: recipe verifier is not usable (" + verifier.detail +
      "); recipe imports will be refused",
    )
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
  let state = HostState::new(options, server.addr().port(), store, trust, verifier)
  if options.trigger_enabled {
    match state.store.reconcile_trigger_projection() {
      Ok(count) =>
        println(
          "monexus-host: trigger projection rebuilt from events (triggers=" +
          count.to_string() + ")",
        )
      Err(message) => {
        state.store.close()
        lock.close()
        return Err("cannot rebuild trigger projection: " + message)
      }
    }
    // First run with A3 enabled: start the dispatcher at the current head so
    // pre-existing history is not replayed as trigger input. Later restarts
    // resume from the persisted cursor.
    match state.store.trigger_event_cursor() {
      Ok(None) =>
        match state.store.last_seq() {
          Ok(seq) => {
            match state.store.set_trigger_event_cursor(seq) {
              Ok(_) => ()
              Err(message) => {
                state.store.close()
                lock.close()
                return Err("cannot initialize trigger cursor: " + message)
              }
            }
          }
          Err(message) => {
            state.store.close()
            lock.close()
            return Err("cannot read event sequence: " + message)
          }
        }
      Ok(Some(_)) => ()
      Err(message) => {
        state.store.close()
        lock.close()
        return Err("cannot read trigger cursor: " + message)
      }
    }
    // Apply the missed-slot policy exactly once before the schedule loop
    // starts (ADR-0014 §3.4). A startup failure leaves the host unserved
    // rather than silently skipping the reconciliation.
    match trigger_schedule_startup(state) {
      Ok(_) => ()
      Err(message) => {
        state.store.close()
        lock.close()
        return Err("cannot reconcile schedule triggers: " + message)
      }
    }
  }
  // ACP processes do not survive a host restart (M0), so close every session
  // that was live and expire its pending decisions before serving clients.
  match reconcile_agent_sessions(state) {
    Ok(_) => ()
    Err(message) => {
      state.store.close()
      lock.close()
      return Err("cannot reconcile agent sessions: " + message)
    }
  }
  // A1.5: the paired runtime listener is part of the production host. It is
  // opened before host.json so a bad certificate, key or policy file refuses
  // startup instead of advertising a host with an unverifiable runtime plane.
  match open_runtime_host(state, options) {
    Ok(_) => ()
    Err(message) => {
      state.store.close()
      lock.close()
      return Err(message)
    }
  }
  match write_host_info(state) {
    Ok(_) => ()
    Err(message) => {
      close_runtime_host(state)
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
    if options.runtime_listen.trim() != "" {
      // The accept loop is bounded by the server's close flag; the attach
      // loop registers a RuntimeMachine and agent launcher only while a live
      // paired channel exists. Neither is started when the listener is off.
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() {
          match state.runtime_server.val {
            Some(server) => server.run()
            None => ()
          }
        },
      )
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() { runtime_attach_loop(state) },
      )
    }
    if options.trigger_enabled {
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() { trigger_loop(state) },
      )
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() { trigger_schedule_loop(state) },
      )
    }
    // M6: settle or reattach every Run that survived a restart before any
    // client can observe a stale `running` status.
    reconcile_runs(state)
    // A2.1: reconcile environments once at start, then every 60s. The scan is
    // read-only and convergent; it never creates an environment.
    reconcile_environments(state)
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() { environment_reconcile_loop(state) },
    )
    // A3.2: repair the Task-then-Run split for fires committed before a
    // crash and queue Runs for fires created by the startup schedule pass.
    // This needs the task group, because run dispatch spawns an executor.
    if options.trigger_enabled {
      trigger_start_pending_runs(state)
    }
    server.run_forever(allow_failure=true, max_connections=64) <|
    ((request, _body, conn) => {
      handle_connection(state, request, conn)
    })
  })
  // Best-effort cleanup for a server that stopped without cancellation.
  // SIGINT/SIGTERM cancel the task group; the next start rewrites host.json
  // and the OS releases the flock when the process exits.
  remove_host_info(state)
  close_runtime_host(state)
  server.close()
  state.store.close()
  lock.close()
  Ok(())
}
