///|
/// The workspace smoke flow. The shell wrapper owns ephemeral OS fixtures;
/// this file owns the assertions, typed RPC calls and polling.

///|
struct Captured {
  code : Int
  stdout : String
  stderr : String
}

///|
fn bool_text(value : Bool) -> String {
  if value {
    "true"
  } else {
    "false"
  }
}

///|
/// The shell smoke compared `jq -r` output through command substitution,
/// which drops trailing newlines. Keep that observable assertion semantics
/// while the typed RPC still returns the exact file text.
fn shell_text(text : String) -> String {
  text.trim_end(chars="\n").to_owned()
}

///|
async fn run_capture(
  program : String,
  args : Array[String],
) -> Result[Captured, String] {
  let (code, stdout_data, stderr_data) = @process.collect_output(
    program,
    args,
  ) catch {
    error => return Err(error.to_string())
  }
  let stdout = stdout_data.text() catch { _ => "" }
  let stderr = stderr_data.text() catch { _ => "" }
  Ok({
    code: code.to_int(),
    stdout: stdout.trim().to_owned(),
    stderr: stderr.trim().to_owned(),
  })
}

///|
async fn connect_host(state_dir : String) -> Result[@client.RpcClient, String] {
  let info = match @client.read_host_info(state_dir) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  @client.connect(info)
}

///|
async fn connect_host_retry(
  state_dir : String,
  tries : Int,
) -> Result[@client.RpcClient, String] {
  let mut last_error = "host is not reachable"
  for _ in 0..<tries {
    match connect_host(state_dir) {
      Ok(client) => return Ok(client)
      Err(message) => last_error = message
    }
    @async.sleep(100)
  }
  Err(last_error)
}

///|
async fn path_exists(path : String) -> Bool {
  @fs.exists(path) catch { _ => false }
}

///|
async fn read_text(path : String) -> Result[String, String] {
  let data = @fs.read_file(path) catch {
    error => return Err("cannot read " + path + ": " + error.to_string())
  }
  let text = data.text() catch {
    error => return Err("cannot decode " + path + ": " + error.to_string())
  }
  Ok(text)
}

///|
async fn read_text_trim(path : String) -> String {
  match read_text(path) {
    Ok(text) => text.trim().to_owned()
    Err(_) => ""
  }
}

///|
async fn directory_names(path : String) -> String {
  let names = @fs.readdir(
    path,
    include_hidden=true,
    include_special=false,
    sort=true,
  ) catch {
    _ => return ""
  }
  names.join(" ")
}

///|
async fn git_branch(directory : String) -> String {
  let result = match
    run_capture(
      "git",
      ["-C", directory, "symbolic-ref", "--short", "HEAD"],
    ) {
    Ok(value) => value
    Err(_) => return ""
  }
  if result.code == 0 {
    result.stdout
  } else {
    result.stderr
  }
}

///|
fn entries_have_name(
  entries : Array[@contracts.WorkspaceEntry],
  name : String,
) -> Bool {
  for entry in entries {
    if entry.name == name {
      return true
    }
  }
  false
}

///|
fn leases_have_id(
  records : Array[@contracts.LeaseRecord],
  id : String,
) -> Bool {
  for record in records {
    if record.id == id {
      return true
    }
  }
  false
}

///|
fn events_have_type(
  events : Array[@contracts.EventEnvelope],
  event_type : String,
) -> Bool {
  for event in events {
    if event.event_type == event_type {
      return true
    }
  }
  false
}

///|
fn git_changes_text(status : @contracts.GitStatus) -> String {
  let lines : Array[String] = []
  for change in status.changes {
    lines.push(change.path + " " + change.status)
  }
  lines.join(", ")
}

///|
async fn write_with_fresh_client(
  env : SmokeEnv,
  workspace_id : String,
  path : String,
  content : String,
) -> Result[Unit, String] {
  let client = match connect_host(env.state_dir) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let result = write_workspace_file(client, workspace_id, path, content)
  client.close()
  result
}

///|
async fn restart_host(env : SmokeEnv) -> Result[Unit, String] {
  let result = match
    run_capture("bash", [env.wrapper, "--restart-host"]) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if result.code == 0 {
    Ok(())
  } else {
    Err(
      "restart exited " +
      result.code.to_string() +
      "\n" +
      result.stdout +
      "\n" +
      result.stderr,
    )
  }
}

///|
async fn workspace_flow(
  env : SmokeEnv,
  report : Report,
  ssh_before : String,
) -> Unit {
  let client = match connect_host_retry(env.state_dir, 20) {
    Ok(value) => value
    Err(message) => {
      report.fail("host started on a temp state dir", message)
      return
    }
  }
  match client.call_host_status(smoke_request_id("status")) {
    Ok(status) =>
      if status.status == @contracts.HOST_STATUS_ONLINE {
        report.pass("host started on a temp state dir")
      } else {
        report.fail("host started on a temp state dir", status.status)
      }
    Err(message) => report.fail("host started on a temp state dir", message)
  }

  // -----------------------------------------------------------------------
  println("== 1. local: open/list/read/write/stat/move/remove/git ==")
  // -----------------------------------------------------------------------
  let real_repo = @fs.realpath(env.repo) catch { _ => env.repo }
  let open_result = open_workspace(client, "", env.repo)
  let (ws, root, is_git) = match open_result {
    Ok(record) => {
      report.pass("workspace.open returned " + record.id)
      (record.id, record.root, record.is_git)
    }
    Err(message) => {
      report.fail("workspace.open returned an id", message)
      ("", "", false)
    }
  }
  report.eq("workspace root is the realpath", real_repo, root)
  report.eq("local workspace is git", "true", bool_text(is_git))

  match list_files(client, ws, "") {
    Ok(entries) => {
      if entries_have_name(entries, "README.md") {
        report.pass("listFiles includes README.md")
      } else {
        report.fail("listFiles includes README.md", entries_to_text(entries))
      }
      if entries_have_name(entries, "notes.txt") {
        report.pass("listFiles includes notes.txt")
      } else {
        report.fail("listFiles includes notes.txt", entries_to_text(entries))
      }
    }
    Err(message) => {
      report.fail("listFiles includes README.md", message)
      report.fail("listFiles includes notes.txt", message)
    }
  }

  match read_workspace_file(client, ws, "README.md") {
    Ok(text) =>
      report.eq("read returns file text", "hello m3", shell_text(text))
    Err(message) => report.fail("read returns file text", message)
  }

  match
    write_workspace_file(client, ws, "README.md", "hello m3 updated\n") {
    Ok(_) => report.pass("write acknowledges it")
    Err(message) => report.fail("write acknowledges it", message)
  }
  report.eq(
    "write is atomic and visible on disk",
    "hello m3 updated",
    read_text_trim(env.repo + "/README.md"),
  )
  let names = directory_names(env.repo)
  if names.contains("monexus-tmp") {
    report.fail("write left no temp file behind", names)
  } else {
    report.pass("write left no temp file behind")
  }
  match read_workspace_file(client, ws, "README.md") {
    Ok(text) =>
      report.eq("read back after write", "hello m3 updated", shell_text(text))
    Err(message) => report.fail("read back after write", message)
  }

  match stat_workspace_path(client, ws, "README.md") {
    Ok(stat) => {
      report.eq("stat kind is file", "file", stat.kind)
      report.eq("stat size is positive", "true", bool_text(stat.size > 0))
    }
    Err(message) => {
      report.fail("stat kind is file", message)
      report.fail("stat size is positive", message)
    }
  }

  let move_error = match
    move_workspace_path(client, ws, "notes.txt", "docs/notes.md") {
    Ok(_) => "move unexpectedly succeeded"
    Err(message) => message
  }
  report.contains(
    "move rejects a missing parent directory",
    "NotFound",
    move_error,
  )
  let _ = @fs.mkdir(
    env.repo + "/docs",
    recursive=true,
    allow_exist=true,
  ) catch {
    _ => ()
  }
  match move_workspace_path(client, ws, "notes.txt", "docs/notes.md") {
    Ok(_) => report.pass("move acknowledges it")
    Err(message) => report.fail("move acknowledges it", message)
  }
  if path_exists(env.repo + "/docs/notes.md") {
    report.pass("move created the destination")
  } else {
    report.fail("move created the destination", "")
  }
  let _ = @fs.write_file(env.repo + "/scratch.txt", "scratch\n") catch {
    _ => ()
  }
  match remove_workspace_path(client, ws, "scratch.txt") {
    Ok(_) => report.pass("remove acknowledges it")
    Err(message) => report.fail("remove acknowledges it", message)
  }
  if path_exists(env.repo + "/scratch.txt") {
    report.fail("remove deleted the file", "")
  } else {
    report.pass("remove deleted the file")
  }
  let escape_text = match
    read_workspace_file(client, ws, "../../../etc/passwd") {
    Ok(text) => "read unexpectedly returned: " + text
    Err(message) => message
  }
  report.contains(
    "relative paths cannot escape the root",
    "Internal",
    escape_text,
  )

  match git_status(client, ws) {
    Ok(status) => {
      report.eq("git status reports the branch", "master", status.branch)
      let changes = git_changes_text(status)
      report.contains("git status reports the modified file", "README.md", changes)
      report.contains("git status reports the moved directory", "docs/", changes)
    }
    Err(message) => {
      report.fail("git status reports the branch", message)
      report.fail("git status reports the modified file", message)
      report.fail("git status reports the moved directory", message)
    }
  }
  match git_diff(client, ws, "README.md") {
    Ok(diff) => {
      report.contains("git diff shows the change", "hello m3 updated", diff.text)
      report.eq("git diff marks truncation false", "false", bool_text(diff.truncated))
    }
    Err(message) => {
      report.fail("git diff shows the change", message)
      report.fail("git diff marks truncation false", message)
    }
  }

  // -----------------------------------------------------------------------
  println("\n== 2. local: two parallel worktrees do not interfere ==")
  // -----------------------------------------------------------------------
  let wt_a_dir = env.work + "/wt-a"
  let wt_b_dir = env.work + "/wt-b"
  let wt_a_id = match create_worktree(client, ws, "m3-a", wt_a_dir) {
    Ok(record) => {
      report.pass("worktree.create returned " + record.id)
      record.id
    }
    Err(message) => {
      report.fail("first worktree created", message)
      ""
    }
  }
  let wt_b_id = match create_worktree(client, ws, "m3-b", wt_b_dir) {
    Ok(record) => {
      report.pass("worktree.create returned " + record.id)
      record.id
    }
    Err(message) => {
      report.fail("second worktree created", message)
      ""
    }
  }
  if path_exists(wt_a_dir + "/.git") && path_exists(wt_b_dir + "/.git") {
    report.pass("both worktree directories are git checkouts")
  } else {
    report.fail("both worktree directories are git checkouts", "")
  }
  report.eq("worktree branch matches", "m3-a", git_branch(wt_a_dir))
  report.eq("second worktree branch matches", "m3-b", git_branch(wt_b_dir))

  let ws_a = match open_workspace(client, "", wt_a_dir) {
    Ok(record) => record.id
    Err(_) => ""
  }
  let ws_b = match open_workspace(client, "", wt_b_dir) {
    Ok(record) => record.id
    Err(_) => ""
  }
  let write_a : Ref[Result[Unit, String]] = Ref(Err("not started"))
  let write_b : Ref[Result[Unit, String]] = Ref(Err("not started"))
  @async.with_task_group(async fn(group) {
    let task_a = group.spawn(async fn() -> Result[Unit, String] {
      write_with_fresh_client(env, ws_a, "a.txt", "from-a\n")
    })
    let task_b = group.spawn(async fn() -> Result[Unit, String] {
      write_with_fresh_client(env, ws_b, "b.txt", "from-b\n")
    })
    write_a.val = task_a.wait()
    write_b.val = task_b.wait()
  })
  report.eq(
    "parallel worktree A write succeeded",
    "from-a",
    read_text_trim(wt_a_dir + "/a.txt"),
  )
  report.eq(
    "parallel worktree B write succeeded",
    "from-b",
    read_text_trim(wt_b_dir + "/b.txt"),
  )
  if path_exists(wt_a_dir + "/b.txt") {
    report.fail("worktree A leaked B file", "")
  } else {
    report.pass("worktree A did not receive B file")
  }
  if path_exists(wt_b_dir + "/a.txt") {
    report.fail("worktree B leaked A file", "")
  } else {
    report.pass("worktree B did not receive A file")
  }
  report.eq(
    "parent checkout was untouched",
    "hello m3 updated",
    read_text_trim(env.repo + "/README.md"),
  )
  match list_files(client, ws_a, "") {
    Ok(entries) => {
      let text = entries_to_text(entries)
      report.contains("worktree A lists its own file", "a.txt", text)
      report.not_contains("worktree A does not list B file", "b.txt", text)
    }
    Err(message) => {
      report.fail("worktree A lists its own file", message)
      report.fail("worktree A does not list B file", message)
    }
  }
  match list_files(client, ws_b, "") {
    Ok(entries) => {
      let text = entries_to_text(entries)
      report.contains("worktree B lists its own file", "b.txt", text)
      report.not_contains("worktree B does not list A file", "a.txt", text)
    }
    Err(message) => {
      report.fail("worktree B lists its own file", message)
      report.fail("worktree B does not list A file", message)
    }
  }

  // -----------------------------------------------------------------------
  println("\n== 3. leases: one active run per worktree / non-git workspace ==")
  // -----------------------------------------------------------------------
  let lease_id = match
    acquire_lease(client, "worktree", wt_a_id, "run-1") {
    Ok(record) => {
      report.pass("first worktree lease acquired " + record.id)
      record.id
    }
    Err(message) => {
      report.fail("first worktree lease acquired", message)
      ""
    }
  }
  let second = acquire_lease(client, "worktree", wt_a_id, "run-2")
  match second {
    Ok(record) => {
      report.fail(
        "second run on the same worktree is refused",
        record.to_json().stringify(),
      )
      report.contains(
        "lease conflict is readable",
        "Conflict",
        record.to_json().stringify(),
      )
    }
    Err(message) => {
      report.pass("second run on the same worktree is refused")
      report.contains("lease conflict is readable", "Conflict", message)
    }
  }
  match list_leases(client) {
    Ok(leases) =>
      if leases_have_id(leases, lease_id) {
        report.pass("lease.list shows the active lease")
      } else {
        report.fail("lease.list shows the active lease", leases_text(leases))
      }
    Err(message) => report.fail("lease.list shows the active lease", message)
  }
  match release_lease(client, lease_id) {
    Ok(_) => report.pass("lease release acknowledged")
    Err(message) => report.fail("lease release acknowledged", message)
  }
  let lease2_id = match acquire_lease(client, "worktree", wt_a_id, "run-2") {
    Ok(record) => {
      report.pass("lease can be re-acquired after release")
      record.id
    }
    Err(message) => {
      report.fail("lease re-acquired", message)
      ""
    }
  }

  let plain = env.work + "/plain"
  let _ = @fs.mkdir(plain, recursive=true, allow_exist=true) catch { _ => () }
  let _ = @fs.write_file(plain + "/file.txt", "plain\n") catch { _ => () }
  let (ws_plain, plain_is_git) = match open_workspace(client, "", plain) {
    Ok(record) => (record.id, record.is_git)
    Err(_) => ("", false)
  }
  report.eq("non-git workspace reports is_git false", "false", bool_text(plain_is_git))
  let lease3_id = match
    acquire_lease(client, "workspace", ws_plain, "run-3") {
    Ok(record) => {
      report.pass("non-git workspace exclusive lease acquired")
      record.id
    }
    Err(message) => {
      report.fail("non-git lease acquired", message)
      ""
    }
  }
  match acquire_lease(client, "workspace", ws_plain, "run-4") {
    Ok(record) =>
      report.fail(
        "second run on a non-git workspace is refused",
        record.to_json().stringify(),
      )
    Err(_) => report.pass("second non-git run refused")
  }
  let _ = release_lease(client, lease3_id)
  let _ = release_lease(client, lease2_id)

  // -----------------------------------------------------------------------
  println("\n== 4. terminal: local PTY and transcript cursor ==")
  // -----------------------------------------------------------------------
  let term = match
    open_terminal(client, ws, "printf m3-local-ok\\n", 24, 80) {
    Ok(record) => {
      report.pass("terminal.open returned " + record.session_id)
      record.session_id
    }
    Err(message) => {
      report.fail("terminal.open returned a session", message)
      ""
    }
  }
  @async.sleep(1000)
  let first_read = read_terminal(client, term, 0L)
  let cursor = match first_read {
    Ok(payload) => {
      report.contains("local PTY produced command output", "m3-local-ok", payload.text)
      payload.cursor
    }
    Err(message) => {
      report.fail("local PTY produced command output", message)
      0L
    }
  }
  match read_terminal(client, term, 0L) {
    Ok(payload) =>
      report.contains("terminal.read honours the cursor", "m3-local-ok", payload.text)
    Err(message) => report.fail("terminal.read honours the cursor", message)
  }
  match read_terminal(client, term, cursor) {
    Ok(payload) => report.eq("reading at the cursor is incremental", "", payload.text)
    Err(message) => report.fail("reading at the cursor is incremental", message)
  }

  let term2 = match open_terminal(client, ws, "", 24, 80) {
    Ok(record) => record.session_id
    Err(message) => {
      report.fail("interactive terminal opened", message)
      ""
    }
  }
  let _ = write_terminal(client, term2, "printf m3-write-ok\\n")
  @async.sleep(700)
  match read_terminal(client, term2, 0L) {
    Ok(payload) =>
      report.contains("terminal.write reaches the shell", "m3-write-ok", payload.text)
    Err(message) => report.fail("terminal.write reaches the shell", message)
  }
  let _ = close_terminal(client, term2)
  let closed_text = match read_terminal(client, term2, 0L) {
    Ok(payload) => payload.text
    Err(message) => message
  }
  report.contains("closed terminal is gone", "NotFound", closed_text)

  // -----------------------------------------------------------------------
  println("\n== 5. bookkeeping survives a host restart ==")
  // -----------------------------------------------------------------------
  client.close()
  let restart_detail = match restart_host(env) {
    Ok(_) => ""
    Err(message) => message
  }
  let restarted = if restart_detail == "" {
    match connect_host_retry(env.state_dir, 50) {
      Ok(value) => Some(value)
      Err(message) => {
        report.fail("host restarted on the same state dir", message)
        None
      }
    }
  } else {
    report.fail("host restarted on the same state dir", restart_detail)
    None
  }
  let client2 = match restarted {
    Some(value) => {
      report.pass("host restarted on the same state dir")
      value
    }
    None => return
  }
  match list_workspaces(client2) {
    Ok(records) => {
      let text = workspaces_text(records)
      report.contains("parent workspace survives restart", ws, text)
      report.contains("parallel worktree workspaces survive restart", ws_a, text)
      report.contains("non-git workspace survives restart", ws_plain, text)
    }
    Err(message) => {
      report.fail("parent workspace survives restart", message)
      report.fail("parallel worktree workspaces survive restart", message)
      report.fail("non-git workspace survives restart", message)
    }
  }
  match list_worktrees(client2, ws) {
    Ok(records) => {
      let text = worktrees_text(records)
      report.contains("worktree A survives restart", wt_a_id, text)
      report.contains("worktree B survives restart", wt_b_id, text)
    }
    Err(message) => {
      report.fail("worktree A survives restart", message)
      report.fail("worktree B survives restart", message)
    }
  }
  match list_leases(client2) {
    Ok(leases) =>
      if leases_have_id(leases, lease_id) {
        report.fail("released leases did not come back", leases_text(leases))
      } else {
        report.pass("released leases did not come back")
      }
    Err(message) => report.fail("released leases did not come back", message)
  }
  match list_events(client2, 0L, 400) {
    Ok(events) => {
      check_event(report, events, "workspace.opened")
      check_event(report, events, "worktree.created")
      check_event(report, events, "worktree.ready")
      check_event(report, events, "lease.acquired")
      check_event(report, events, "lease.released")
      check_event(report, events, "workspace.changed")
    }
    Err(message) => {
      report.fail("event replay includes workspace.opened", message)
      report.fail("event replay includes worktree.created", message)
      report.fail("event replay includes worktree.ready", message)
      report.fail("event replay includes lease.acquired", message)
      report.fail("event replay includes lease.released", message)
      report.fail("event replay includes workspace.changed", message)
    }
  }

  let close_guard = close_workspace(client2, ws)
  match close_guard {
    Ok(_) =>
      report.fail(
        "closing a workspace with live worktrees is refused",
        "close unexpectedly succeeded",
      )
    Err(_) => report.pass("closing a workspace with live worktrees is refused")
  }
  let close_guard_text = match close_guard {
    Ok(_) => "close unexpectedly succeeded"
    Err(message) => message
  }
  report.contains("close conflict is readable", "Conflict", close_guard_text)
  match remove_worktree(client2, wt_a_id) {
    Ok(_) => report.pass("worktree.remove A acknowledged")
    Err(message) => report.fail("worktree.remove A acknowledged", message)
  }
  if path_exists(wt_a_dir) {
    report.fail("worktree A directory removed", "")
  } else {
    report.pass("worktree A directory removed")
  }
  let _ = remove_worktree(client2, wt_b_id)
  match list_worktrees(client2, ws) {
    Ok(records) =>
      report.eq(
        "worktree.list is empty after removal",
        "[]",
        if records.length() == 0 {
          "[]"
        } else {
          "[" + worktrees_text(records) + "]"
        },
      )
    Err(message) => report.fail("worktree.list is empty after removal", message)
  }
  match close_workspace(client2, ws) {
    Ok(_) => report.pass("parent workspace closes after worktrees are archived")
    Err(message) =>
      report.fail("parent workspace closes after worktrees are archived", message)
  }
  match list_workspaces(client2) {
    Ok(records) => {
      let text = workspaces_text(records)
      report.not_contains("closed parent workspace is tombstoned", ws, text)
      report.contains("worktree workspaces remain open", ws_a, text)
    }
    Err(message) => {
      report.fail("closed parent workspace is tombstoned", message)
      report.fail("worktree workspaces remain open", message)
    }
  }

  // -----------------------------------------------------------------------
  println("\n== 6. loopback SSH: same contract over ssh ==")
  // -----------------------------------------------------------------------
  if !env.ssh_available {
    report.skip(
      "ephemeral sshd/ssh/tmux unavailable; SSH contract section skipped",
    )
  } else if !env.ssh_ready {
    report.fail(
      "ephemeral sshd did not start",
      env_or("MONEXUS_SMOKE_SSHD_LOG", ""),
    )
  } else {
    report.pass("ephemeral sshd on 127.0.0.1:" + env.ssh_port.to_string())
    ssh_workspace_flow(env, client2, report)
  }

  // -----------------------------------------------------------------------
  println("\n== 7. user ~/.ssh guard ==")
  // -----------------------------------------------------------------------
  let ssh_after = ssh_snapshot(env.real_ssh_dir)
  if ssh_before == ssh_after {
    report.pass("user ~/.ssh was not modified")
  } else {
    report.fail("user ~/.ssh was modified", ssh_after)
  }
  client2.close()
}

///|
fn entries_to_text(entries : Array[@contracts.WorkspaceEntry]) -> String {
  let names : Array[String] = []
  for entry in entries {
    names.push(entry.name)
  }
  names.join(", ")
}

///|
fn workspaces_text(records : Array[@contracts.WorkspaceRecord]) -> String {
  let ids : Array[String] = []
  for record in records {
    ids.push(record.id)
  }
  ids.join(", ")
}

///|
fn worktrees_text(records : Array[@contracts.WorktreeRecord]) -> String {
  let ids : Array[String] = []
  for record in records {
    ids.push(record.id)
  }
  ids.join(", ")
}

///|
fn leases_text(records : Array[@contracts.LeaseRecord]) -> String {
  let ids : Array[String] = []
  for record in records {
    ids.push(record.id)
  }
  ids.join(", ")
}

///|
fn check_event(
  report : Report,
  events : Array[@contracts.EventEnvelope],
  event_type : String,
) -> Unit {
  if events_have_type(events, event_type) {
    report.pass("event replay includes " + event_type)
  } else {
    let found : Array[String] = []
    for event in events {
      found.push(event.event_type)
    }
    report.fail("event replay includes " + event_type, found.join(", "))
  }
}
