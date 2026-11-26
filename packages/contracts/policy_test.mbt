///|
/// M6 policy, audit and Inbox contract tests. Pure — no host or SQLite.

///|
test "policy: critical commands are denied" {
  let verdict = evaluate_command_policy("sudo rm -rf /")
  assert_eq(verdict.action, POLICY_DENY)
  assert_eq(verdict.risk, RISK_CRITICAL)
  assert_eq(evaluate_command_policy("mkfs.ext4 /dev/sda1").action, POLICY_DENY)
  assert_eq(evaluate_command_policy("systemctl restart nginx").action, POLICY_DENY)
}

///|
test "policy: destructive commands ask the owner" {
  let verdict = evaluate_command_policy("rm -rf build")
  assert_eq(verdict.action, POLICY_ASK)
  assert_eq(verdict.risk, RISK_HIGH)
  assert_eq(evaluate_command_policy("git push --force origin main").action, POLICY_ASK)
  assert_eq(evaluate_command_policy("apt install curl").action, POLICY_ASK)
}

///|
test "policy: read-only and scoped commands are allowed" {
  assert_eq(evaluate_command_policy("ls -la").action, POLICY_ALLOW)
  assert_eq(evaluate_command_policy("git status").risk, RISK_LOW)
  let scoped = evaluate_command_policy("moon test --target native")
  assert_eq(scoped.action, POLICY_ALLOW)
  assert_eq(scoped.risk, RISK_MEDIUM)
}

///|
test "redaction: key=value, bearer and sk tokens are removed" {
  let text = "API_KEY=abc123\nAuthorization: Bearer xyz\nuse sk-abcdef1234567890 now"
  let clean = redact_secrets(text)
  assert_false(clean.contains("abc123"))
  assert_false(clean.contains("xyz"))
  assert_false(clean.contains("abcdef1234567890"))
  assert_true(clean.contains("[redacted]"))
}

///|
test "redaction: private key blocks are removed" {
  let text = "before\n-----BEGIN PRIVATE KEY-----\nMIIsecret\n-----END PRIVATE KEY-----\nafter"
  let clean = redact_secrets(text)
  assert_false(clean.contains("MIIsecret"))
  assert_true(clean.contains("before"))
  assert_true(clean.contains("after"))
}

///|
test "audit: detail is redacted and survives JSON round-trip" {
  let record = AuditRecord::new(
    id="aud_1",
    action="policy.verdict",
    actor="host",
    subject="run/run_1",
    outcome="ask",
    ts="2026-01-01T00:00:00Z",
    target="tsk_1",
    policy=POLICY_ASK,
    risk=RISK_HIGH,
    detail="token=supersecret rm -rf build",
    decision_id="dec_1",
    run_id="run_1",
  )
  assert_false(record.detail.contains("supersecret"))
  let parsed = match audit_from_json(record.to_json()) {
    Some(value) => value
    None => fail("audit record did not round-trip")
  }
  assert_eq(parsed.action, "policy.verdict")
  assert_eq(parsed.actor, "host")
  assert_eq(parsed.target, "tsk_1")
  assert_eq(parsed.policy, POLICY_ASK)
  assert_eq(parsed.risk, RISK_HIGH)
  assert_eq(parsed.outcome, "ask")
  assert_eq(parsed.decision_id, "dec_1")
  assert_eq(parsed.run_id, "run_1")
  assert_eq(parsed.ts, "2026-01-01T00:00:00Z")
  let listed = match audit_list_from_result(audit_list_result([record])) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(listed.length(), 1)
  assert_eq(listed[0].id, "aud_1")
}

///|
test "secret key names are detected" {
  assert_true(is_secret_key_name("GITHUB_TOKEN"))
  assert_true(is_secret_key_name("api_key"))
  assert_true(is_secret_key_name("DB_PASSWORD"))
  assert_false(is_secret_key_name("PATH"))
  assert_false(is_secret_key_name("HOME"))
}

///|
test "inbox: pending decisions need the owner" {
  assert_eq(
    decision_inbox_bucket("pending", "approval", "", "waiting_approval"),
    INBOX_NEEDS_YOU,
  )
  assert_eq(
    decision_inbox_bucket("pending", "recovery", "", "lost"),
    INBOX_NEEDS_YOU,
  )
  assert_eq(
    decision_inbox_bucket("pending", "permission", "", ""),
    INBOX_NEEDS_YOU,
  )
}

///|
test "inbox: answered work that is still running waits" {
  assert_eq(
    decision_inbox_bucket("answered", "recovery", "retry", "queued"),
    INBOX_WAITING,
  )
  assert_eq(
    decision_inbox_bucket("answered", "approval", "approve", "running"),
    INBOX_WAITING,
  )
  assert_eq(
    decision_inbox_bucket("answered", "permission", "allow_once", "running"),
    INBOX_WAITING,
  )
}

///|
test "inbox: finished work and terminal answers are handled" {
  assert_eq(
    decision_inbox_bucket("answered", "recovery", "retry", "succeeded"),
    INBOX_HANDLED,
  )
  assert_eq(
    decision_inbox_bucket("answered", "approval", "deny", "failed"),
    INBOX_HANDLED,
  )
  assert_eq(
    decision_inbox_bucket("answered", "verify", "waive", "succeeded"),
    INBOX_HANDLED,
  )
  assert_eq(
    decision_inbox_bucket("expired", "verify", "", "cancelled"),
    INBOX_HANDLED,
  )
  assert_eq(
    decision_inbox_bucket("answered", "permission", "allow_once", ""),
    INBOX_HANDLED,
  )
}

///|
test "run: recovery fields round-trip" {
  let run = RunRecord::new(
    id="run_r",
    task_id="tsk_r",
    agent_id="",
    machine_id="mch_1",
    workspace_id="wsp_1",
    worktree_id="wt_1",
    mode=RUN_MODE_COMMAND,
    command="echo ok",
    prompt="",
    idempotency_key="task/tsk_r/0",
    created_at="2026-01-01T00:00:00Z",
  )
  let recovered = {
    ..run,
    stop_reason: STOP_REASON_LOST,
    durable: "tmux",
    tmux_session: "monexus-run-test",
    log_path: "/tmp/run.log",
    exit_path: "/tmp/run.exit",
    exit_code: 7,
    retried_from: "run_0",
    attempt: 2,
  }
  let parsed = match run_from_json(recovered.to_json()) {
    Some(value) => value
    None => fail("run did not round-trip")
  }
  assert_eq(parsed.stop_reason, STOP_REASON_LOST)
  assert_eq(parsed.durable, "tmux")
  assert_eq(parsed.tmux_session, "monexus-run-test")
  assert_eq(parsed.exit_code, 7)
  assert_eq(parsed.retried_from, "run_0")
  assert_eq(parsed.attempt, 2)
}

///|
/// A5 redaction units: proxy capability tokens (`mxp_`), node lease tokens
/// (`mxs_`), Authorization headers and profile API-key headers never survive
/// a persisted surface.
test "redaction: mxp/mxs tokens and profile headers are removed" {
  let text = "MONEXUS_CREDENTIAL_PROXY_TOKEN=mxp_abcdef0123456789\n" +
    "node token mxs_1234567890abcdef trailing\n" +
    "authorization: Bearer bearer-value-123\n" +
    "x-api-key: sk-abcdef0123456789"
  let clean = redact_secrets(text)
  assert_false(clean.contains("mxp_abcdef0123456789"))
  assert_false(clean.contains("mxs_1234567890abcdef"))
  assert_false(clean.contains("bearer-value-123"))
  assert_false(clean.contains("sk-abcdef0123456789"))
  assert_true(clean.contains("[redacted]"))
  // Redaction also works when the token is embedded in a JSON-ish event
  // payload with quotes or commas around it.
  let embedded = "{\"token\":\"mxp_quoted-token\",\"next\":\"mxs_comma-token\",}"
  let embedded_clean = redact_secrets(embedded)
  assert_false(embedded_clean.contains("mxp_quoted-token"))
  assert_false(embedded_clean.contains("mxs_comma-token"))
  // The proxy env names are treated as secret-shaped names too.
  assert_true(is_secret_key_name("MONEXUS_CREDENTIAL_PROXY_TOKEN"))
  assert_true(is_secret_key_name("MONEXUS_CREDENTIAL_NODE_TOKEN"))
}
