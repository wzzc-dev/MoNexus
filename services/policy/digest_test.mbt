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
  let expected_canonical = "monexus.exec.v1\n" +
    "{\"argv\":[\"git\",\"status\",\"--porcelain\"]," +
    "\"cwd\":\"/home/user/ws\"," +
    "\"env\":[\"LANG\",\"PATH\"]," +
    "\"operation\":\"exec\"," +
    "\"workspace_root\":\"/home/user/ws\"}"
  assert_eq(request.canonical(), expected_canonical)
  assert_eq(
    request.digest(),
    "sha256:296305004bbb2b00ac43a41ad139de7a89f86d78a4552f3167f56cc43da0cd25",
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
test "digest: env values are excluded and no secret reaches diagnostics" {
  let secret = "supersecret-token-value"
  // The request model has no env value field at all: only names are digested.
  let request = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["echo", secret],
    cwd="/w",
    workspace_root="/w",
    env_names=["API_KEY"],
  )
  assert_true(request.canonical().contains("\"env\":[\"API_KEY\"]"))
  assert_false(request.canonical().contains("=" + secret))
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
