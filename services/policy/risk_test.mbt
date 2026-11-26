///|
/// Risk classification and offline semantics tests.

///|
fn ws_request(
  operation : @policy.PolicyOperation,
  argv : Array[String],
  env_names? : Array[String] = ["PATH"],
  cwd? : String = "/home/user/ws",
) -> @policy.ExecutionRequest {
  @policy.ExecutionRequest::new(
    operation~,
    argv~,
    cwd~,
    workspace_root="/home/user/ws",
    env_names~,
  )
}

///|
fn online_context(snapshot : @policy.PolicySnapshot) -> @policy.PolicyContext {
  @policy.PolicyContext::with_snapshot(
    snapshot,
    now_ms=TEST_T0,
    primary_reachable=true,
  )
}

///|
fn offline_context(snapshot : @policy.PolicySnapshot) -> @policy.PolicyContext {
  @policy.PolicyContext::with_snapshot(
    snapshot,
    now_ms=TEST_T0,
    primary_reachable=false,
  )
}

///|
fn stale_context(snapshot : @policy.PolicySnapshot) -> @policy.PolicyContext {
  @policy.PolicyContext::with_snapshot(
    snapshot,
    now_ms=TEST_T0 + 3_600_001L,
    primary_reachable=true,
  )
}

///|
test "risk: low-risk read-only exec is allowed under a valid snapshot" {
  let decision = @policy.evaluate(
    online_context(test_snapshot()),
    ws_request(@policy.PolicyOperation::Exec, ["git", "status"]),
  )
  assert_eq(decision.kind.label(), "allow")
  assert_eq(decision.action, "allow")
  assert_eq(decision.risk, @contracts.RISK_LOW)
  assert_eq(decision.policy_version, "pol-1")
  assert_eq(decision.policy_hash, test_snapshot().content_hash)
  assert_true(decision.is_allowed())
  assert_false(decision.needs_primary())
  assert_true(decision.digest.has_prefix("sha256:"))
}

///|
test "risk: read-only fs and git operations are allowed" {
  let context = online_context(test_snapshot())
  let fs_read = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::FsRead, []),
  )
  assert_true(fs_read.is_allowed())
  let git_read = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::GitRead, ["git", "log", "--oneline"]),
  )
  assert_true(git_read.is_allowed())
  let listed = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["ls", "-la"]),
  )
  assert_true(listed.is_allowed())
}

///|
test "risk: installers require approval" {
  let context = online_context(test_snapshot())
  let commands : Array[Array[String]] = [
    ["apt-get", "install", "-y", "curl"],
    ["npm", "install", "-g", "typescript"],
    ["cargo", "install", "ripgrep"],
    ["pip", "-i", "requirements.txt"],
  ]
  for argv in commands {
    let decision = @policy.evaluate(
      context,
      ws_request(@policy.PolicyOperation::Exec, argv),
    )
    assert_eq(decision.kind.label(), "approval_required")
    assert_eq(decision.risk, @contracts.RISK_HIGH)
    assert_true(decision.needs_primary())
    assert_true(decision.reason.contains("installer"))
  }
}

///|
test "risk: host mounts and containers require approval" {
  let context = online_context(test_snapshot())
  let mount = @policy.evaluate(
    context,
    ws_request(
      @policy.PolicyOperation::Exec,
      ["mount", "/home/user/ws/img", "/home/user/ws/mnt"],
    ),
  )
  assert_eq(mount.kind.label(), "approval_required")
  assert_true(mount.reason.contains("mount"))
  let container = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["docker", "run", "alpine"]),
  )
  assert_eq(container.kind.label(), "approval_required")
  assert_true(container.reason.contains("container"))
}

///|
test "risk: deletion requires approval" {
  let context = online_context(test_snapshot())
  let rm = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["rm", "-rf", "build"]),
  )
  assert_eq(rm.kind.label(), "approval_required")
  assert_eq(rm.risk, @contracts.RISK_HIGH)
  assert_true(rm.reason.contains("destructive"))
  let fs_delete = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::FsDelete, []),
  )
  assert_eq(fs_delete.kind.label(), "approval_required")
  assert_eq(fs_delete.risk, @contracts.RISK_HIGH)
  assert_true(fs_delete.reason.contains("deletion"))
}

///|
test "risk: privilege elevation requires approval" {
  let decision = @policy.evaluate(
    online_context(test_snapshot()),
    ws_request(@policy.PolicyOperation::Exec, ["sudo", "ls"]),
  )
  assert_eq(decision.kind.label(), "approval_required")
  assert_eq(decision.risk, @contracts.RISK_HIGH)
  assert_true(decision.reason.contains("privilege"))
}

///|
test "risk: arbitrary sh -c requires approval" {
  let context = online_context(test_snapshot())
  for shell in ["sh", "bash", "zsh"] {
    let decision = @policy.evaluate(
      context,
      ws_request(@policy.PolicyOperation::Exec, [shell, "-c", "echo hi"]),
    )
    assert_eq(decision.kind.label(), "approval_required")
    assert_eq(decision.risk, @contracts.RISK_HIGH)
    assert_true(decision.reason.contains("shell"))
  }
  let piped = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["node", "x", "|", "sh"]),
  )
  assert_eq(piped.kind.label(), "approval_required")
  assert_true(piped.reason.contains("shell"))
}

///|
test "risk: built-in catastrophic commands are denied" {
  let context = online_context(test_snapshot())
  let mkfs = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["mkfs.ext4"]),
  )
  assert_eq(mkfs.kind.label(), "deny")
  assert_eq(mkfs.action, "deny")
  assert_eq(mkfs.risk, @contracts.RISK_CRITICAL)
  assert_true(mkfs.reason.contains("root or system scope"))
  let service = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["systemctl", "restart", "nginx"]),
  )
  assert_eq(service.kind.label(), "deny")
  assert_false(service.is_allowed())
  let wipe = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["rm", "-rf", "/"]),
  )
  assert_eq(wipe.kind.label(), "deny")
}

///|
test "risk: snapshot deny rules are enforced" {
  let context = online_context(test_snapshot())
  let operation = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::GitWrite, ["git", "push"]),
  )
  assert_eq(operation.kind.label(), "deny")
  assert_eq(operation.risk, @contracts.RISK_CRITICAL)
  assert_true(operation.reason.contains("denied by policy"))
  let pattern = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["curl", "|", "sh"]),
  )
  assert_eq(pattern.kind.label(), "deny")
  assert_true(pattern.reason.contains("denied by policy"))
}

///|
test "risk: unknown operations are not silently allowed" {
  let context = online_context(test_snapshot())
  let unknown = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Unknown("future.run"), []),
  )
  assert_eq(unknown.kind.label(), "approval_required")
  assert_true(unknown.needs_primary())
  let medium = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["moon", "build"]),
  )
  assert_eq(medium.kind.label(), "approval_required")
  assert_eq(medium.risk, @contracts.RISK_MEDIUM)
}

///|
test "risk: snapshot allow rules grant medium-risk operations" {
  let context = online_context(test_snapshot())
  let prefix = @policy.evaluate(
    context,
    ws_request(
      @policy.PolicyOperation::Exec,
      ["moon", "test", "--target", "native"],
    ),
  )
  assert_eq(prefix.kind.label(), "allow")
  assert_eq(prefix.risk, @contracts.RISK_MEDIUM)
  assert_true(prefix.reason.contains("pol-1"))
  let operation = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::FsWrite, []),
  )
  assert_eq(operation.kind.label(), "allow")
  assert_eq(operation.risk, @contracts.RISK_MEDIUM)
}

///|
test "risk: snapshot high-risk operations require approval" {
  let decision = @policy.evaluate(
    online_context(test_snapshot()),
    ws_request(@policy.PolicyOperation::Pty, ["bash"]),
  )
  assert_eq(decision.kind.label(), "approval_required")
  assert_eq(decision.risk, @contracts.RISK_HIGH)
  assert_true(decision.reason.contains("high risk under policy"))
}

///|
test "risk: environment names outside the allowlist are denied" {
  let decision = @policy.evaluate(
    online_context(test_snapshot()),
    ws_request(
      @policy.PolicyOperation::Exec,
      ["git", "status"],
      env_names=["PATH", "AWS_SECRET_ACCESS_KEY"],
    ),
  )
  assert_eq(decision.kind.label(), "deny")
  assert_eq(decision.risk, @contracts.RISK_HIGH)
  assert_true(decision.reason.contains("AWS_SECRET_ACCESS_KEY"))
  assert_false(decision.encode().contains("secret-value"))
}

///|
test "risk: paths escaping the workspace are denied" {
  let context = online_context(test_snapshot())
  let cwd = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["ls"], cwd="/etc"),
  )
  assert_eq(cwd.kind.label(), "deny")
  assert_true(cwd.reason.contains("cwd"))
  let path = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["cat", "/etc/passwd"]),
  )
  assert_eq(path.kind.label(), "deny")
  assert_true(path.reason.contains("path argument"))
  let malformed = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, []),
  )
  assert_eq(malformed.kind.label(), "deny")
  assert_true(malformed.reason.contains("empty"))
}

///|
test "risk: missing or invalid snapshots never allow" {
  let high = ws_request(@policy.PolicyOperation::Exec, ["rm", "-rf", "build"])
  let missing = @policy.evaluate(
    @policy.PolicyContext::missing(
      reason="no snapshot on disk",
      now_ms=TEST_T0,
      primary_reachable=true,
    ),
    high,
  )
  assert_eq(missing.kind.label(), "unverifiable")
  assert_false(missing.is_allowed())
  assert_eq(missing.action, "unverifiable")
  assert_true(missing.reason.contains("missing"))
  let invalid = @policy.evaluate(
    @policy.PolicyContext::invalid(
      reason="content hash mismatch",
      now_ms=TEST_T0,
      primary_reachable=true,
    ),
    high,
  )
  assert_eq(invalid.kind.label(), "unverifiable")
  assert_false(invalid.is_allowed())
  assert_true(invalid.reason.contains("invalid"))
  let read_only = @policy.evaluate(
    @policy.PolicyContext::missing(
      reason="no snapshot on disk",
      now_ms=TEST_T0,
      primary_reachable=true,
    ),
    ws_request(@policy.PolicyOperation::FsRead, []),
  )
  assert_eq(read_only.kind.label(), "unverifiable")
  assert_false(read_only.is_allowed())
}

///|
test "risk: stale policy blocks high-risk and medium-risk work" {
  let context = stale_context(test_snapshot())
  let high = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["rm", "-rf", "build"]),
  )
  assert_eq(high.kind.label(), "unverifiable")
  assert_true(high.reason.contains("stale"))
  let medium = @policy.evaluate(
    context,
    ws_request(
      @policy.PolicyOperation::Exec,
      ["moon", "test", "--target", "native"],
    ),
  )
  assert_eq(medium.kind.label(), "unverifiable")
  assert_true(medium.reason.contains("stale"))
  let read_only = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["git", "status"]),
  )
  assert_eq(read_only.kind.label(), "allow")
  assert_eq(read_only.policy_version, "pol-1")
}

///|
test "risk: unreachable primary blocks high-risk but allows local read-only" {
  let context = offline_context(test_snapshot())
  let high = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["sudo", "ls"]),
  )
  assert_eq(high.kind.label(), "unverifiable")
  assert_true(high.reason.contains("unreachable"))
  let medium = @policy.evaluate(
    context,
    ws_request(
      @policy.PolicyOperation::Exec,
      ["moon", "test", "--target", "native"],
    ),
  )
  assert_eq(medium.kind.label(), "unverifiable")
  assert_true(medium.reason.contains("unreachable"))
  let read_only = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["cat", "README.md"]),
  )
  assert_eq(read_only.kind.label(), "allow")
  assert_eq(read_only.risk, @contracts.RISK_LOW)
  assert_eq(read_only.policy_version, "pol-1")
}

///|
test "risk: decisions expose the contracts verdict shape" {
  let decision = @policy.evaluate(
    online_context(test_snapshot()),
    ws_request(@policy.PolicyOperation::Exec, ["git", "status"]),
  )
  let verdict = decision.verdict()
  assert_eq(verdict.risk, decision.risk)
  assert_eq(verdict.action, decision.action)
  assert_eq(verdict.reason, decision.reason)
}

///|
/// Regression (A1.5): the read-only fast path must not trust argv[0] by
/// basename when argv[0] is a path. A workspace-written executable named
/// `ls` (or `cat`, or `git`) is arbitrary code and must not be allowed as a
/// low-risk read-only command.
test "risk: path-qualified argv[0] never rides the read-only fast path" {
  let context = online_context(test_snapshot())
  let bare = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::Exec, ["ls", "-la"]),
  )
  assert_eq(bare.kind.label(), "allow")
  assert_eq(bare.risk, @contracts.RISK_LOW)
  let vectors : Array[Array[String]] = [
    ["/home/user/ws/ls", "-la"],
    ["./ls"],
    ["../bin/cat", "README.md"],
    ["/tmp/agent-tools/git", "status"],
    ["/home/user/ws/find", ".", "-name", "*.txt"],
  ]
  for argv in vectors {
    let decision = @policy.evaluate(
      context,
      ws_request(@policy.PolicyOperation::Exec, argv),
    )
    assert_false(decision.is_allowed())
    assert_eq(decision.kind.label(), "approval_required")
    assert_true(decision.needs_primary())
    assert_true(decision.reason.contains("not explicitly allowed"))
  }
  // The same path is still just a read-only *operation* when the caller names
  // an fs/git read method; the operation label, not argv[0], decides there.
  let fs_read = @policy.evaluate(
    context,
    ws_request(@policy.PolicyOperation::FsRead, ["/home/user/ws/ls"]),
  )
  assert_true(fs_read.is_allowed())
}
