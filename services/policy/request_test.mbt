///|
/// Regression tests for the A2.2 container-engine path exemption.
///
/// Executing environment recipes needs `docker` argv whose bind sources live
/// outside the workspace (ADR-0013 §5). Only the workspace path-containment
/// loop is exempted, and only when argv[0]'s basename is a container engine;
/// the built-in classifier still marks every such argv High. These tests pin
/// both halves of that split.

///|
test "request: non-container argv outside the workspace is still rejected" {
  let absolute = ws_request(
    @policy.PolicyOperation::Exec,
    ["cat", "/etc/passwd"],
  )
  assert_eq(
    absolute.validate(),
    Some("command path argument escapes the workspace root"),
  )
  let decision = @policy.evaluate(online_context(test_snapshot()), absolute)
  assert_eq(decision.kind.label(), "deny")
  assert_false(decision.is_allowed())
  // Relative traversal is resolved against cwd and rejected the same way.
  let relative = ws_request(
    @policy.PolicyOperation::Exec,
    ["cat", "../secrets"],
  )
  assert_eq(
    relative.validate(),
    Some("command path argument escapes the workspace root"),
  )
  // A non-container command may not use the container exemption either.
  let find_root = ws_request(
    @policy.PolicyOperation::Exec,
    ["find", "/", "-maxdepth", "1"],
  )
  assert_eq(
    find_root.validate(),
    Some("command path argument escapes the workspace root"),
  )
}

///|
test "request: container argv with a host path validates but stays High" {
  let request = ws_request(
    @policy.PolicyOperation::Exec,
    ["docker", "run", "-v", "/etc:/x", "alpine"],
  )
  // The bind source names a node-owned path, so containment does not apply.
  assert_eq(request.validate(), None)
  // It is still classified High and needs an exact, digest-bound grant; it
  // can never ride the read-only low-risk path.
  let decision = @policy.evaluate(online_context(test_snapshot()), request)
  assert_eq(decision.kind.label(), "approval_required")
  assert_eq(decision.risk, @contracts.RISK_HIGH)
  assert_true(decision.needs_primary())
  assert_false(decision.is_allowed())
  assert_true(decision.reason.contains("container"))
  // Even without a snapshot the risk stays High; absence of policy is
  // unverifiable, never an implicit low-risk allow.
  let missing = @policy.evaluate(
    @policy.PolicyContext::missing(
      reason="no snapshot on disk",
      now_ms=TEST_T0,
      primary_reachable=true,
    ),
    request,
  )
  assert_eq(missing.kind.label(), "unverifiable")
  assert_eq(missing.risk, @contracts.RISK_HIGH)
  assert_false(missing.is_allowed())
}

///|
test "request: a workspace file named docker cannot ride a low-risk path" {
  // A recipe may write an executable inside the workspace. Matching is by
  // basename, not by path, so it is still a container operation and still
  // High; only argv[0]'s *location* is workspace data.
  let request = ws_request(
    @policy.PolicyOperation::Exec,
    ["/home/user/ws/docker", "run", "alpine"],
  )
  assert_eq(request.validate(), None)
  let decision = @policy.evaluate(online_context(test_snapshot()), request)
  assert_eq(decision.kind.label(), "approval_required")
  assert_eq(decision.risk, @contracts.RISK_HIGH)
  assert_true(decision.needs_primary())
  assert_false(decision.is_allowed())
  assert_true(decision.reason.contains("container"))
  // The relative spelling is the same command.
  let relative = @policy.evaluate(
    online_context(test_snapshot()),
    ws_request(@policy.PolicyOperation::Exec, ["./docker", "run", "alpine"]),
  )
  assert_eq(relative.kind.label(), "approval_required")
  assert_eq(relative.risk, @contracts.RISK_HIGH)
}
