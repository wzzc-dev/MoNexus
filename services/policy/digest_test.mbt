///|
/// Command digest tests: the canonical serialization is stable across
/// processes and excludes secret values.

///|
fn vector_request() -> @policy.ExecutionRequest {
  @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["git", "status", "--porcelain"],
    cwd="/home/user/ws",
    workspace_root="/home/user/ws",
    env_names=["PATH", "LANG", "PATH"],
  )
}

///|
test "digest: known vector" {
  let request = vector_request()
  let expected_canonical = "monexus.exec.v2\n" +
    "{\"argv\":[\"git\",\"status\",\"--porcelain\"]," +
    "\"content\":\"\"," +
    "\"cwd\":\"/home/user/ws\"," +
    "\"env\":[\"LANG\",\"PATH\"]," +
    "\"env_values\":[]," +
    "\"git_expected_branch\":\"\"," +
    "\"git_expected_head\":\"\"," +
    "\"git_force\":false," +
    "\"operation\":\"exec\"," +
    "\"stdin\":\"\"," +
    "\"workspace_root\":\"/home/user/ws\"}"
  assert_eq(request.canonical(), expected_canonical)
  assert_eq(
    request.digest(),
    "sha256:76ed7d1bb9e5ef3c6054c6ef5a66dbea15b6e8af529ee82247cbb2057f63f08c",
  )
}

///|
test "digest: env name order and duplicates do not change it" {
  let a = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["moon", "test"],
    cwd="/w",
    workspace_root="/w",
    env_names=["PATH", "LANG"],
  )
  let b = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["moon", "test"],
    cwd="/w",
    workspace_root="/w",
    env_names=["LANG", "PATH", "LANG"],
  )
  assert_eq(a.digest(), b.digest())
}

///|
test "digest: argv order and semantic fields are significant" {
  let base = vector_request()
  let reordered = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["git", "--porcelain", "status"],
    cwd="/home/user/ws",
    workspace_root="/home/user/ws",
    env_names=["LANG", "PATH"],
  )
  assert_false(base.digest() == reordered.digest())
  let other_cwd = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["git", "status", "--porcelain"],
    cwd="/home/user/ws/sub",
    workspace_root="/home/user/ws",
    env_names=["LANG", "PATH"],
  )
  assert_false(base.digest() == other_cwd.digest())
  let other_operation = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Pty,
    argv=["git", "status", "--porcelain"],
    cwd="/home/user/ws",
    workspace_root="/home/user/ws",
    env_names=["LANG", "PATH"],
  )
  assert_false(base.digest() == other_operation.digest())
  let other_root = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["git", "status", "--porcelain"],
    cwd="/home/user/ws",
    workspace_root="/home/user",
    env_names=["LANG", "PATH"],
  )
  assert_false(base.digest() == other_root.digest())
}

///|
test "digest: env values are bound but no secret reaches diagnostics" {
  let secret = "supersecret-token-value"
  // v2 binds explicit environment values in the canonical text. The text is
  // hashed and never sent or logged; only names reach a Decision or audit.
  let request = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["echo", "hello"],
    cwd="/w",
    workspace_root="/w",
    env_names=["API_KEY"],
    env_values=[("API_KEY", secret)],
  )
  assert_true(
    request.canonical().contains(
      "\"env_values\":[[\"API_KEY\",\"" + secret + "\"]]",
    ),
  )
  assert_true(request.canonical().contains("\"env\":[\"API_KEY\"]"))
  let decision = @policy.evaluate(
    @policy.PolicyContext::with_snapshot(
      test_snapshot(),
      now_ms=TEST_T0,
      primary_reachable=true,
    ),
    request,
  )
  assert_false(decision.reason.contains(secret))
  assert_false(decision.encode().contains(secret))
  assert_true(decision.reason.contains("API_KEY"))
}

///|
test "digest: env values, stdin, fs content and git flags are individually bound" {
  let exec_base = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["echo", "hello"],
    cwd="/w",
    workspace_root="/w",
    env_names=["PATH"],
  )
  let exec_env_value = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["echo", "hello"],
    cwd="/w",
    workspace_root="/w",
    env_names=["PATH"],
    env_values=[("PATH", "/usr/local/bin")],
  )
  assert_false(exec_base.digest() == exec_env_value.digest())
  let exec_stdin = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["echo", "hello"],
    cwd="/w",
    workspace_root="/w",
    env_names=["PATH"],
    stdin="piped input",
  )
  assert_false(exec_base.digest() == exec_stdin.digest())
  assert_false(exec_env_value.digest() == exec_stdin.digest())
  let write_one = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::FsWrite,
    argv=["notes.txt"],
    cwd="/w",
    workspace_root="/w",
    content="one",
  )
  let write_two = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::FsWrite,
    argv=["notes.txt"],
    cwd="/w",
    workspace_root="/w",
    content="two",
  )
  assert_false(write_one.digest() == write_two.digest())
  let git_plain = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::GitWrite,
    argv=["worktree.remove", "wt"],
    cwd="/w",
    workspace_root="/w",
  )
  let git_forced = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::GitWrite,
    argv=["worktree.remove", "wt"],
    cwd="/w",
    workspace_root="/w",
    git_force=true,
  )
  assert_false(git_plain.digest() == git_forced.digest())
  let git_head = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::GitWrite,
    argv=["worktree.remove", "wt"],
    cwd="/w",
    workspace_root="/w",
    git_expected_head="0123456789abcdef",
  )
  assert_false(git_plain.digest() == git_head.digest())
  let git_branch = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::GitWrite,
    argv=["worktree.remove", "wt"],
    cwd="/w",
    workspace_root="/w",
    git_expected_branch="feature",
  )
  assert_false(git_plain.digest() == git_branch.digest())
  assert_false(git_head.digest() == git_branch.digest())
}

///|
test "digest: escaping keeps the serialization valid JSON" {
  let request = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["printf", "a\"b", "line\nbreak", "back\\slash"],
    cwd="/w",
    workspace_root="/w",
    env_names=["PATH"],
  )
  assert_true(request.canonical().contains("\"a\\\"b\""))
  assert_true(request.canonical().contains("\"line\\nbreak\""))
  assert_true(request.canonical().contains("\"back\\\\slash\""))
  assert_false(request.canonical().contains("line\nbreak"))
}
