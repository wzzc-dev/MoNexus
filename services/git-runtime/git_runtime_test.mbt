///|
fn test_git_env() -> Map[String, String] {
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
async fn test_git(
  cwd : String,
  args : Array[String],
) -> (Int, String, String) {
  let (code, out, err) = @process.collect_output(
    "git",
    args,
    extra_env=test_git_env(),
    inherit_env=false,
    cwd=cwd,
  )
  (code.to_int(), out.text(), err.text())
}

///|
async fn must_git(cwd : String, args : Array[String]) -> Unit {
  let (code, _, err) = test_git(cwd, args)
  if code != 0 {
    println("test git setup failed: " + err)
  }
  assert_eq(code, 0)
}

///|
async fn setup_repo(prefix : String) -> (String, String, String) {
  let dir = @fs.tmpdir(prefix=prefix)
  let root = dir + "/repo"
  @fs.mkdir(root, permission=0o700, recursive=true, allow_exist=true)
  must_git(dir, ["init", "-q", root])
  @fs.write_file(
    root + "/a.txt",
    "hello\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  must_git(root, ["add", "a.txt"])
  must_git(root, ["commit", "-q", "-m", "init"])
  (dir, root, dir + "/state")
}

///|
async fn file_mode(path : String) -> String {
  let (code, out, _) = @process.collect_output("stat", [
    "-c", "%a", path,
  ]) catch {
    _ => return ""
  }
  if code != 0 {
    return ""
  }
  out.text().trim().to_owned()
}

///|
async fn status_of(rt : GitRuntime) -> GitCommandResult? {
  match rt.status() {
    Ok(value) => Some(value)
    Err(_) => None
  }
}

///|
async test "status, diff, log, show and branches run under the root" {
  let (dir, root, state) = setup_repo("monexus-git-basic-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = match GitRuntime::new(root, state) {
    Ok(value) => value
    Err(error) => {
      println(error.message)
      assert_true(false)
      return
    }
  }
  defer rt.close()
  let status = match status_of(rt) {
    Some(value) => value
    None => {
      assert_true(false)
      return
    }
  }
  assert_true(status.ok())
  assert_true(status.seq > 0L)
  assert_true(status.stdout.contains("##"))
  @fs.write_file(
    root + "/a.txt",
    "hello world\n",
    create_mode=@fs.CreateMode::TruncateExisting,
    permission=0o600,
  )
  let diff = match rt.diff() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(diff.stdout.contains("hello world"))
  assert_true(diff.seq > status.seq)
  let log = match rt.log(max_count=5) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(log.ok())
  assert_true(log.stdout.contains("init"))
  let shown = match rt.show(rev="HEAD") {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(shown.ok())
  assert_true(shown.stdout.contains("hello"))
  let before = match rt.branches() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(before.result.ok())
  assert_true(before.branches.length() > 0)
  let mut has_current = false
  for branch in before.branches {
    if branch.current {
      has_current = true
    }
  }
  assert_true(has_current)
  let created = match rt.create_branch(name="feature-test") {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(created.ok())
  let after = match rt.branches() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  let mut found = false
  for branch in after.branches {
    if branch.name == "feature-test" {
      found = true
    }
  }
  assert_true(found)
  let checkout = match rt.checkout(branch="checkout-test", create=true) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(checkout.ok())
  let current = match rt.branches() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  let mut on_checkout = false
  for branch in current.branches {
    if branch.current && branch.name == "checkout-test" {
      on_checkout = true
    }
  }
  assert_true(on_checkout)
}

///|
async test "all path escapes are rejected before git runs" {
  let (dir, root, state) = setup_repo("monexus-git-escape-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = match GitRuntime::new(root, state) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  defer rt.close()
  let outside = dir + "/outside.txt"
  @fs.write_file(
    outside,
    "outside secret\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let parent_escape = match rt.diff(path="../outside.txt") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(parent_escape)
  let absolute_escape = match rt.diff(path="/etc/passwd") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(absolute_escape)
  let show_escape = match rt.show(rev="HEAD", path="../outside.txt") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(show_escape)
  @fs.symlink(target=outside, root + "/link.txt") catch {
    _ => {
      assert_true(false)
      return
    }
  }
  let symlink_escape = match rt.diff(path="link.txt") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(symlink_escape)
  let worktree_escape = match
    rt.worktree_add(WorktreeAddRequest::new(path="../escape-wt", base="HEAD")) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(worktree_escape)
  let worktree_abs_escape = match
    rt.worktree_add(WorktreeAddRequest::new(path=dir + "/outside-wt", base="HEAD")) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(worktree_abs_escape)
  let worktree_parent_escape = match
    rt.worktree_add(
      WorktreeAddRequest::new(path=root + "/../escape-wt", base="HEAD"),
    ) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::OutsideRoot
  }
  assert_true(worktree_parent_escape)
}

///|
async test "output and the operation log are bounded" {
  let (dir, root, _state) = setup_repo("monexus-git-bounded-")
  defer @fs.rmdir(dir, recursive=true)
  let state = dir + "/state"
  let limits = GitLimits::new(
    max_output_bytes=1_024,
    max_output_lines=64,
    timeout_ms=10_000,
    ops_log_bytes=1_024L,
  )
  let rt = match GitRuntime::new_with_limits(root, state, limits) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  defer rt.close()
  let lines : Array[String] = []
  for index in 0..<300 {
    lines.push(
      "line-" + index.to_string() +
      " abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz0123456789",
    )
  }
  @fs.write_file(
    root + "/a.txt",
    lines.join("\n") + "\n",
    create_mode=@fs.CreateMode::TruncateExisting,
    permission=0o600,
  )
  let diff = match rt.diff() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(diff.truncated)
  assert_true(diff.stdout_bytes > 1_024L)
  assert_true(diff.stdout_kept_bytes <= 1_024L)
  assert_true(diff.stdout_lines > 64L)
  assert_true(diff.stdout_kept_bytes < diff.stdout_bytes)
  for _ in 0..<40 {
    let _ = status_of(rt)
  }
  let log_status = rt.log_status()
  assert_true(log_status.path.starts_with(state + "/"))
  assert_true(log_status.bytes <= 1_024L)
  assert_true(log_status.truncated)
}

///|
async test "argv injection stays a literal argument" {
  let (dir, root, state) = setup_repo("monexus-git-inject-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = match GitRuntime::new(root, state) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  defer rt.close()
  @fs.write_file(
    root + "/--help",
    "literal\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let literal = match rt.diff(path="--help") {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(literal.ok())
  assert_true(!literal.stdout.to_lower().contains("usage: git"))
  let branch_inject = match rt.create_branch(name="--upload-pack=evil") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::InvalidArgument
  }
  assert_true(branch_inject)
  let branch_space = match rt.create_branch(name="evil branch") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::InvalidArgument
  }
  assert_true(branch_space)
  let rev_inject = match rt.show(rev="--help") {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::InvalidArgument
  }
  assert_true(rev_inject)
  let base_inject = match
    rt.worktree_add(
      WorktreeAddRequest::new(path="wt-inject", base="--upload-pack=evil"),
    ) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::InvalidArgument
  }
  assert_true(base_inject)
  let path_ok = match rt.diff(path="-rf") {
    Ok(value) => value.ok()
    Err(_) => false
  }
  assert_true(path_ok)
}

///|
async test "worktrees expose lease metadata and never adopt an existing path" {
  let (dir, root, state) = setup_repo("monexus-git-worktree-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = match GitRuntime::new(root, state) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  defer rt.close()
  let request = WorktreeAddRequest::new(
    path="wt-one",
    branch="wt-branch",
    base="HEAD",
    client_request_id="req-1",
  )
  let first = match rt.worktree_add(request) {
    Ok(value) => value
    Err(error) => {
      println(error.message)
      assert_true(false)
      return
    }
  }
  assert_true(first.registered)
  assert_true(first.branch == "wt-branch")
  assert_true(first.head != "")
  assert_true(first.path.starts_with(root + "/"))
  let listed = match rt.worktrees() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_eq(listed.worktrees.length(), 2)
  let mut found_registered = false
  for info in listed.worktrees {
    if info.path == first.path && info.registered &&
      info.request_id == "req-1" {
      found_registered = true
    }
  }
  assert_true(found_registered)
  let repeated = match
    rt.worktree_add(
      WorktreeAddRequest::new(
        path="wt-one",
        branch="wt-branch",
        base="HEAD",
        client_request_id="req-1",
      ),
    ) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(repeated.path == first.path)
  let listed_again = match rt.worktrees() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_eq(listed_again.worktrees.length(), 2)
  let conflicting = match
    rt.worktree_add(
      WorktreeAddRequest::new(
        path="wt-one",
        branch="wt-branch",
        base="HEAD",
        client_request_id="req-2",
      ),
    ) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::Conflict
  }
  assert_true(conflicting)
  @fs.mkdir(root + "/adopt-me", permission=0o700)
  let adopted = match
    rt.worktree_add(WorktreeAddRequest::new(path="adopt-me", base="HEAD")) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::Conflict
  }
  assert_true(adopted)
  let wrong_head = match
    rt.worktree_remove(
      WorktreeRemoveRequest::new(
        path="wt-one",
        expected_head="0000000000000000000000000000000000000000",
      ),
    ) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::Conflict
  }
  assert_true(wrong_head)
  let removed = match
    rt.worktree_remove(
      WorktreeRemoveRequest::new(
        path="wt-one",
        expected_head=first.head,
        expected_branch=first.branch,
      ),
    ) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_true(removed.removed.path == first.path)
  assert_true(!(@fs.exists(first.path)))
  let after = match rt.worktrees() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  assert_eq(after.worktrees.length(), 1)
  let main_remove = match
    rt.worktree_remove(WorktreeRemoveRequest::new(path="")) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::InvalidArgument
  }
  assert_true(main_remove)
  let non_worktree = match
    rt.worktree_remove(WorktreeRemoveRequest::new(path="a.txt")) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::NotFound
  }
  assert_true(non_worktree)
}

///|
async test "a worktree made by another run is not silently adopted" {
  let (dir, root, state) = setup_repo("monexus-git-lease-")
  defer @fs.rmdir(dir, recursive=true)
  must_git(root, ["worktree", "add", "--detach", "manual-wt", "HEAD"])
  let rt = match GitRuntime::new(root, state) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  defer rt.close()
  let listed = match rt.worktrees() {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  let mut manual_seen_unregistered = false
  for info in listed.worktrees {
    if info.relative_path == "manual-wt" && !info.registered {
      manual_seen_unregistered = true
    }
  }
  assert_true(manual_seen_unregistered)
  let refused = match
    rt.worktree_add(WorktreeAddRequest::new(path="manual-wt", base="HEAD")) {
    Ok(_) => false
    Err(error) => error.kind is GitErrorKind::Conflict
  }
  assert_true(refused)
}

///|
async test "state directories are 0700, the log is 0600 and leaks no secrets" {
  let (dir, root, state) = setup_repo("monexus-git-perm-")
  defer @fs.rmdir(dir, recursive=true)
  let rt = match GitRuntime::new(root, state) {
    Ok(value) => value
    Err(_) => {
      assert_true(false)
      return
    }
  }
  defer rt.close()
  assert_eq(file_mode(state), "700")
  assert_eq(file_mode(rt.ops_log_path()), "600")
  let secret = "SECRET_TOKEN_VALUE_1234567890"
  @fs.write_file(
    root + "/secret.txt",
    secret + "\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let _ = status_of(rt)
  let _ = rt.diff(path="secret.txt")
  let log_data = @fs.read_file(rt.ops_log_path()) catch {
    _ => {
      assert_true(false)
      return
    }
  }
  let log_text = log_data.text() catch { _ => "" }
  assert_true(!log_text.contains(secret))
  assert_true(!log_text.contains(root))
  assert_true(!log_text.contains("secret.txt"))
  let env = git_env()
  assert_true(env.contains("PATH"))
  assert_true(!env.contains("HOME"))
  assert_true(!env.contains("SSH_AUTH_SOCK"))
  assert_true(!env.contains("SSH_AGENT_PID"))
}
