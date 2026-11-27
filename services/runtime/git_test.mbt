///|
async fn git_test_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
fn git_test_env() -> Map[String, String] {
  let env : Map[String, String] = Map([])
  env["PATH"] = match @env.get_env_var("PATH") {
    Some(value) if value != "" => value
    _ => "/usr/bin:/bin"
  }
  env["LC_ALL"] = "C"
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_CONFIG_GLOBAL"] = "/dev/null"
  env["GIT_TERMINAL_PROMPT"] = "0"
  env["GIT_AUTHOR_NAME"] = "MoNexus Test"
  env["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
  env["GIT_COMMITTER_NAME"] = "MoNexus Test"
  env["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
  env
}

///|
async fn git_test_run(
  cwd : String,
  args : Array[String],
) -> (Int, String, String) {
  let (code, out, err) = @process.collect_output(
    "git",
    args,
    extra_env=git_test_env(),
    inherit_env=false,
    cwd=cwd,
  )
  (code.to_int(), out.text(), err.text())
}

///|
async fn git_must(cwd : String, args : Array[String]) -> Unit {
  let (code, _, err) = git_test_run(cwd, args)
  if code != 0 {
    fail("test git setup failed: " + err)
  }
}

///|
/// Create a repository plus the runtime state root for one test.
async fn git_setup_repo(prefix : String) -> (String, String, String) {
  let dir = @fs.tmpdir(prefix=prefix)
  let root = dir + "/repo"
  @fs.mkdir(root, permission=0o700, recursive=true, allow_exist=true)
  // `GitRuntime::new` canonicalizes the workspace root; use the same spelling
  // so absolute-path assertions hold on macOS (/var -> /private/var).
  let root = @fs.realpath(root) catch { _ => root }
  git_must(dir, ["init", "-q", root])
  @fs.write_file(
    root + "/a.txt",
    "hello\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  git_must(root, ["add", "a.txt"])
  git_must(root, ["commit", "-q", "-m", "init"])
  (dir, root, dir + "/state")
}

///|
async fn git_open_executor(
  state_root : String,
  workspace_root : String,
) -> RuntimeExecutor {
  let executor = match RuntimeExecutor::open(state_root, "rt-git") {
    Ok(value) => value
    Err(message) => fail("cannot open runtime executor: " + message)
  }
  match executor.open_git(workspace_root=workspace_root) {
    Ok(_) => ()
    Err(error) => fail("cannot bind git: " + error.message)
  }
  executor
}

///|
async fn git_events(executor : RuntimeExecutor) -> Array[StoredEvent] {
  let events = match executor.pending_events(8_000) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events: " + message)
  }
  let out : Array[StoredEvent] = []
  for event in events {
    if event.run_id == "git" {
      out.push(event)
    }
  }
  out
}

///|
fn git_event_string(event : StoredEvent, name : String) -> String {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.string_field_or(object, name, "")
    None => ""
  }
}

///|
fn git_event_int(event : StoredEvent, name : String) -> Int {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.int_field_or(object, name, 0)
    None => 0
  }
}

///|
fn git_event_int64(event : StoredEvent, name : String) -> Int64 {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.int64_field_or(object, name, 0L)
    None => 0L
  }
}

///|
fn git_event_bool(event : StoredEvent, name : String) -> Bool {
  match @contracts.as_object(event.payload) {
    Some(object) => @contracts.bool_field_or(object, name, false)
    None => false
  }
}

///|
fn git_count_kind(events : Array[StoredEvent], kind : String) -> Int {
  let mut count = 0
  for event in events {
    if event.kind == kind {
      count = count + 1
    }
  }
  count
}

///|
async fn git_file_mode(path : String) -> String {
  let has_usr_bin = @fs.exists("/usr/bin/stat") catch { _ => false }
  let stat = if has_usr_bin { "/usr/bin/stat" } else { "/bin/stat" }
  let code_and_output = @process.collect_output(stat, ["-c", "%a", path]) catch {
    _ => return "stat-failed"
  }
  let (code, output, _) = code_and_output
  if code != 0 {
    // BSD/macOS stat spelling; GNU stat exits non-zero above.
    let fallback = @process.collect_output(stat, ["-f", "%Lp", path]) catch {
      _ => return "stat-failed"
    }
    let (fallback_code, fallback_output, _) = fallback
    if fallback_code != 0 {
      return "stat-failed"
    }
    let fallback_text = fallback_output.text() catch { _ => "" }
    return fallback_text.trim().to_owned()
  }
  let text = output.text() catch { _ => "" }
  text.trim().to_owned()
}

///|
async test "git status, diff, log and show publish durable events and logs" {
  let (dir, root, state_root) = git_setup_repo("rt-git-basic")
  defer git_test_cleanup(dir)
  let executor = git_open_executor(state_root, root)
  let status = match executor.git_status() {
    Ok(value) => value
    Err(error) => fail("git status failed: " + error.message)
  }
  assert_true(status.success)
  assert_eq(status.exit_code, 0)
  assert_eq(status.op, "status")
  assert_true(status.stdout_bytes > 0L)
  assert_true(status.stdout_preview.contains("##"))
  assert_true(status.op_id.contains("/"))
  assert_true(status.stdout_log != "")
  @fs.write_file(
    root + "/a.txt",
    "hello\nsecond\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let diff = match executor.git_diff() {
    Ok(value) => value
    Err(error) => fail("git diff failed: " + error.message)
  }
  assert_true(diff.success)
  assert_eq(diff.op, "diff")
  assert_true(diff.stdout_preview.contains("+second"))
  let log = match executor.git_log(max_count=5) {
    Ok(value) => value
    Err(error) => fail("git log failed: " + error.message)
  }
  assert_true(log.success)
  assert_true(log.stdout_preview.contains("init"))
  let show = match executor.git_show(rev="HEAD") {
    Ok(value) => value
    Err(error) => fail("git show failed: " + error.message)
  }
  assert_true(show.success)
  assert_true(show.stdout_preview.contains("a.txt"))
  let bad_show = match executor.git_show(rev="no-such-revision") {
    Ok(value) => value
    Err(error) => fail("git show of a bad revision must be a result: " + error.message)
  }
  assert_true(!bad_show.success)
  assert_true(bad_show.exit_code != 0)
  let branches = match executor.git_branches() {
    Ok(value) => value
    Err(error) => fail("git branches failed: " + error.message)
  }
  assert_true(branches.result.success)
  assert_true(branches.branches.length() > 0)
  let mut current = false
  for branch in branches.branches {
    if branch.current {
      current = true
    }
  }
  assert_true(current)
  let events = git_events(executor)
  assert_eq(events.length(), 6)
  let mut expected_run_seq = 0L
  for event in events {
    assert_eq(event.kind, EVENT_GIT_RESULT)
    assert_eq(event.run_seq, expected_run_seq)
    expected_run_seq = expected_run_seq + 1L
  }
  let last_result = events[4]
  assert_eq(git_event_string(last_result, "op"), "show")
  assert_true(!git_event_bool(last_result, "success"))
  let instance = executor.git_instance_id()
  assert_true(instance != "")
  let op_dir = executor.state_root() + "/logs/git/" + instance + "/" +
    diff.op_seq.to_string()
  assert_eq(git_file_mode(executor.state_root()), "700")
  assert_eq(git_file_mode(executor.state_root() + "/logs"), "700")
  assert_eq(git_file_mode(op_dir), "700")
  assert_eq(git_file_mode(op_dir + "/stdout.log"), "600")
  let slice = match
    executor.git_read_output(op_id=diff.op_id, stream="stdout", max_bytes=4_096) {
    Ok(value) => value
    Err(error) => fail("cannot read git output: " + error.message)
  }
  assert_true(slice.data.contains("+second"))
  assert_true(slice.bytes > 0L)
  assert_true(slice.eof)
  assert_true(slice.log_bytes > 0L)
  executor.close()
}

///|
async test "git rejects parent, absolute, symlink and .ssh path escapes" {
  let (dir, root, state_root) = git_setup_repo("rt-git-escape")
  defer git_test_cleanup(dir)
  let executor = git_open_executor(state_root, root)
  @fs.mkdir(dir + "/outside", permission=0o700, recursive=true, allow_exist=true)
  @fs.symlink(target=dir + "/outside", root + "/escape")
  let parent_error = match executor.git_diff(path="../outside") {
    Ok(_) => fail("a parent escape must be rejected")
    Err(error) => error
  }
  assert_eq(parent_error.code, @contracts.ERR_INVALID_PARAMS)
  assert_eq(parent_error.kind, "path_denied")
  let absolute_error = match executor.git_diff(path="/etc/passwd") {
    Ok(_) => fail("an absolute escape must be rejected")
    Err(error) => error
  }
  assert_eq(absolute_error.code, @contracts.ERR_INVALID_PARAMS)
  assert_eq(absolute_error.kind, "path_denied")
  let symlink_error = match executor.git_diff(path="escape") {
    Ok(_) => fail("a symlink escape must be rejected")
    Err(error) => error
  }
  assert_eq(symlink_error.kind, "path_denied")
  let ssh_error = match executor.git_diff(path=".ssh/config") {
    Ok(_) => fail("a .ssh path must be rejected")
    Err(error) => error
  }
  assert_eq(ssh_error.code, @contracts.ERR_INVALID_PARAMS)
  assert_eq(ssh_error.kind, "path_denied")
  match executor.git_worktree_add(path="../wt-outside") {
    Ok(_) => fail("a worktree parent escape must be rejected")
    Err(error) => assert_eq(error.kind, "path_denied")
  }
  match executor.git_worktree_add(path="/tmp/rt-wt-escape") {
    Ok(_) => fail("an absolute worktree escape must be rejected")
    Err(error) => assert_eq(error.kind, "path_denied")
  }
  match executor.git_worktree_add(path=".ssh/wt") {
    Ok(_) => fail("a .ssh worktree path must be rejected")
    Err(error) => assert_eq(error.kind, "path_denied")
  }
  match executor.git_diff(path=root + "/a.txt") {
    Ok(_) => ()
    Err(error) => fail("an absolute path inside the root must work: " + error.message)
  }
  let events = git_events(executor)
  inspect(git_count_kind(events, EVENT_GIT_ERRORED), content="5")
  let mut expected_run_seq = 0L
  for event in events {
    assert_eq(event.run_seq, expected_run_seq)
    expected_run_seq = expected_run_seq + 1L
  }
  let ssh_executor = match RuntimeExecutor::open(state_root + "-ssh", "rt-git-ssh") {
    Ok(value) => value
    Err(message) => fail("cannot open executor: " + message)
  }
  @fs.mkdir(dir + "/.ssh", permission=0o700, recursive=true, allow_exist=true)
  match ssh_executor.open_git(workspace_root=dir + "/.ssh") {
    Ok(_) => fail("a .ssh workspace root must be refused")
    Err(error) => assert_eq(error.kind, "path_denied")
  }
  ssh_executor.close()
  executor.close()
}

///|
async test "git worktree add and remove expose lease metadata and never adopt" {
  let (dir, root, state_root) = git_setup_repo("rt-git-worktree")
  defer git_test_cleanup(dir)
  let executor = git_open_executor(state_root, root)
  let added = match
    executor.git_worktree_add(
      path="wt-a",
      branch="lease-a",
      base="HEAD",
      client_request_id="req-wt-a",
    ) {
    Ok(value) => value
    Err(error) => fail("worktree add failed: " + error.message)
  }
  assert_true(added.result.success)
  assert_eq(added.result.op, "worktree_add")
  assert_eq(added.result.op_seq, 0L)
  let wt = added.worktree
  assert_eq(wt.relative_path, "wt-a")
  assert_eq(wt.branch, "lease-a")
  assert_true(wt.head != "")
  assert_true(wt.registered)
  assert_true(!wt.detached)
  assert_true(!wt.main)
  assert_eq(wt.request_id, "req-wt-a")
  assert_true(@fs.exists(wt.path) catch { _ => false })
  let events_after_add = git_events(executor)
  let add_event = events_after_add[events_after_add.length() - 1]
  assert_eq(add_event.kind, EVENT_GIT_WORKTREE_ADDED)
  assert_eq(git_event_string(add_event, "request_id"), "req-wt-a")
  assert_eq(git_event_string(add_event, "relative_path"), "wt-a")
  assert_eq(git_event_string(add_event, "branch"), "lease-a")
  assert_eq(git_event_string(add_event, "head"), wt.head)
  assert_true(git_event_bool(add_event, "registered"))
  let replay = match
    executor.git_worktree_add(
      path="wt-a",
      branch="lease-a",
      base="HEAD",
      client_request_id="req-wt-a",
    ) {
    Ok(value) => value
    Err(error) => fail("an idempotent worktree add must succeed: " + error.message)
  }
  assert_eq(replay.worktree.path, wt.path)
  match
    executor.git_worktree_add(path="wt-a", client_request_id="req-wt-other") {
    Ok(_) => fail("another request must not adopt a registered worktree")
    Err(error) => {
      assert_eq(error.code, @contracts.ERR_HOST)
      assert_eq(error.kind, "conflict")
    }
  }
  let listed = match executor.git_worktrees() {
    Ok(value) => value
    Err(error) => fail("worktree list failed: " + error.message)
  }
  let mut found = false
  for info in listed.worktrees {
    if info.relative_path == "wt-a" {
      found = true
      assert_true(info.registered)
      assert_eq(info.request_id, "req-wt-a")
      assert_eq(info.head, wt.head)
      assert_eq(info.branch, "lease-a")
    }
  }
  assert_true(found)
  match
    executor.git_worktree_remove(
      path="wt-a",
      expected_head="0000000000000000000000000000000000000000",
      expected_branch="lease-a",
    ) {
    Ok(_) => fail("a mismatched expected head must be rejected")
    Err(error) => assert_eq(error.kind, "conflict")
  }
  match
    executor.git_worktree_remove(
      path="wt-a",
      expected_head=wt.head,
      expected_branch="not-lease-a",
    ) {
    Ok(_) => fail("a mismatched expected branch must be rejected")
    Err(error) => assert_eq(error.kind, "conflict")
  }
  let removed = match
    executor.git_worktree_remove(
      path="wt-a",
      expected_head=wt.head,
      expected_branch="lease-a",
    ) {
    Ok(value) => value
    Err(error) => fail("worktree remove failed: " + error.message)
  }
  assert_true(removed.result.success)
  assert_eq(removed.removed.path, wt.path)
  assert_eq(removed.removed.branch, "lease-a")
  assert_eq(removed.removed.head, wt.head)
  assert_true(!(@fs.exists(wt.path) catch { _ => false }))
  let events = git_events(executor)
  let remove_event = events[events.length() - 1]
  assert_eq(remove_event.kind, EVENT_GIT_WORKTREE_REMOVED)
  assert_eq(git_event_string(remove_event, "relative_path"), "wt-a")
  assert_eq(git_event_string(remove_event, "head"), wt.head)
  assert_eq(git_event_string(remove_event, "branch"), "lease-a")
  assert_eq(git_count_kind(events, EVENT_GIT_ERRORED), 3)
  let mut expected_run_seq = 0L
  for event in events {
    assert_eq(event.run_seq, expected_run_seq)
    expected_run_seq = expected_run_seq + 1L
  }
  executor.close()
}

///|
async test "git output is bounded, redacted and readable through the runtime" {
  let (dir, root, state_root) = git_setup_repo("rt-git-bounded")
  defer git_test_cleanup(dir)
  let mut big_initial = ""
  let mut big_modified = ""
  let mut index = 0
  while index < 100 {
    big_initial = big_initial + "line-" + index.to_string() + "\n"
    big_modified = big_modified + "line-" + index.to_string() + "-changed\n"
    index = index + 1
  }
  @fs.write_file(
    root + "/big.txt",
    big_initial,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  git_must(root, ["add", "big.txt"])
  git_must(root, ["commit", "-q", "-m", "big"])
  @fs.write_file(
    root + "/big.txt",
    big_modified,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  @fs.write_file(
    root + "/secret.txt",
    "password=hunter2\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  git_must(root, ["add", "secret.txt"])
  git_must(root, ["commit", "-q", "-m", "secret"])
  @fs.write_file(
    root + "/secret.txt",
    "password=hunter2\nsk-supersecretkeyvalue123\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let limits = @git_runtime.GitLimits::new(
    max_output_bytes=1_024,
    max_output_lines=16,
    timeout_ms=10_000,
  )
  let executor = match
    RuntimeExecutor::open_with_limits(
      state_root,
      "rt-git-bounded",
      pty_limits=@pty_runtime.PtyLimits::new(),
      git_limits=limits,
    ) {
    Ok(value) => value
    Err(message) => fail("cannot open executor: " + message)
  }
  match executor.open_git(workspace_root=root) {
    Ok(_) => ()
    Err(error) => fail("cannot bind git: " + error.message)
  }
  let big = match executor.git_diff(path="big.txt") {
    Ok(value) => value
    Err(error) => fail("big diff failed: " + error.message)
  }
  assert_true(big.success)
  assert_true(big.truncated)
  assert_true(big.stdout_bytes > big.stdout_kept_bytes)
  assert_true(big.stdout_kept_bytes <= 1_024L)
  let secret = match executor.git_diff(path="secret.txt") {
    Ok(value) => value
    Err(error) => fail("secret diff failed: " + error.message)
  }
  assert_true(secret.success)
  assert_true(!secret.stdout_preview.contains("hunter2"))
  assert_true(!secret.stdout_preview.contains("sk-supersecretkeyvalue123"))
  let secret_slice = match
    executor.git_read_output(op_id=secret.op_id, max_bytes=4_096) {
    Ok(value) => value
    Err(error) => fail("cannot read secret diff: " + error.message)
  }
  assert_true(!secret_slice.data.contains("hunter2"))
  assert_true(!secret_slice.data.contains("sk-supersecretkeyvalue123"))
  assert_true(secret_slice.data.contains("[redacted]"))
  let big_slice = match
    executor.git_read_output(op_id=big.op_id, max_bytes=65_536) {
    Ok(value) => value
    Err(error) => fail("cannot read big diff: " + error.message)
  }
  assert_true(big_slice.data.length() <= 1_024)
  assert_true(big_slice.log_bytes <= 1_024L)
  let op_dir = executor.state_root() + "/logs/git/" +
    executor.git_instance_id() + "/" + big.op_seq.to_string()
  assert_eq(git_file_mode(op_dir), "700")
  assert_eq(git_file_mode(op_dir + "/stdout.log"), "600")
  match
    executor.git_read_output(op_id="unknown/1", stream="stdout") {
    Ok(_) => fail("an unknown instance must not be readable")
    Err(error) => assert_eq(error.kind, "not_found")
  }
  match
    executor.git_read_output(op_id=big.op_id, stream="combined") {
    Ok(_) => fail("an invalid stream must be rejected")
    Err(error) => assert_eq(error.kind, "invalid_argument")
  }
  executor.close()
}

///|
async test "git ack and restart do not redeliver events" {
  let (dir, root, state_root) = git_setup_repo("rt-git-ack")
  defer git_test_cleanup(dir)
  let executor = git_open_executor(state_root, root)
  let status = match executor.git_status() {
    Ok(value) => value
    Err(error) => fail("git status failed: " + error.message)
  }
  let events = git_events(executor)
  assert_eq(events.length(), 1)
  let last_seq = events[0].seq
  match executor.ack_through(last_seq) {
    Ok(_) => ()
    Err(message) => fail("ack failed: " + message)
  }
  let before = match executor.pending_events(100) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events: " + message)
  }
  inspect(before.length(), content="0")
  let cursor = executor.cursor()
  executor.close()
  let reopened = match RuntimeExecutor::open(state_root, "rt-git") {
    Ok(value) => value
    Err(message) => fail("cannot reopen executor: " + message)
  }
  assert_eq(reopened.cursor(), cursor)
  let after = match reopened.pending_events(100) {
    Ok(value) => value
    Err(message) => fail("cannot read pending events after restart: " + message)
  }
  inspect(after.length(), content="0")
  assert_eq(reopened.git_instance_id(), "")
  match reopened.git_status() {
    Ok(_) => fail("git must not be re-enabled without open_git")
    Err(error) => assert_eq(error.kind, "not_enabled")
  }
  match executor.git_status() {
    Ok(_) => fail("a closed executor must not run git")
    Err(error) => assert_eq(error.kind, "internal")
  }
  reopened.close()
  let _ = status
}
