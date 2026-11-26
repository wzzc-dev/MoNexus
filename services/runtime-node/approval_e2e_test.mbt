///|
/// Decision-bound approval end-to-end tests (A1.3b).
///
/// A real primary, node and paired session run over pinned TLS (the harness
/// in `host_e2e_test.mbt`). These tests cover the primary-side approval seam:
/// the node's 1007 binding is turned into an `ApprovalRequest`, the owner's
/// answer decides execution, a pending Decision survives a reconnect, an
/// unreachable runtime ends `unverifiable`, and policy rotation invalidates
/// outstanding approvals.

///|
fn ae_count(text : String, needle : String) -> Int {
  let mut count = 0
  for piece in text.split(needle) {
    let _ = piece
    count = count + 1
  }
  count - 1
}

///|
/// Wait until a started run is terminal. `exec.start` only spawns the run, so
/// the provider must not read its side effects before this returns.
async fn ae_wait_run(
  machine : @provider_runtime.RuntimeMachine,
  run_id : String,
  timeout_ms : Int64,
) -> @provider_runtime.RunSnapshot {
  let deadline = @async.now() + timeout_ms
  while @async.now() < deadline {
    match machine.exec_status(run_id) {
      Ok(Some(run)) =>
        if run.is_terminal() {
          return run
        }
      Ok(None) => ()
      Err(_) => ()
    }
    @async.sleep(20)
  }
  abort("run did not finish: " + run_id)
}

///|
async fn ae_read_text(path : String) -> String {
  let data = @fs.read_file(path) catch { _ => abort("cannot read " + path) }
  data.text() catch { _ => abort("cannot decode " + path) }
}

///|
/// Publish a snapshot and wait until the node has installed it. The primary
/// pushes `runtime.policy.update` to the live channel; the node verifies the
/// pin before replacing its gate.
async fn ae_publish_snapshot(
  h : NodeHarness,
  snapshot : @policy.PolicySnapshot,
) -> Unit {
  match h.state.publish_policy(snapshot) {
    Ok(_) => ()
    Err(message) => abort("cannot publish the test policy: " + message)
  }
  host_wait_for("policy install " + snapshot.version, 10_000L, () => {
    match h.host.policy().verified_snapshot() {
      Some(value) => value.version == snapshot.version
      None => false
    }
  })
  // Mutating calls are refused until the primary records the node's ack.
  host_wait_policy_ack(h.state, h.runtime_id, 10_000L)
}

///|
/// Publish a policy and wait until the node has installed it. The primary
/// pushes `runtime.policy.update` to the live channel; the node verifies the
/// pin before replacing its gate.
async fn ae_publish(h : NodeHarness, version : String) -> @policy.PolicySnapshot {
  let now = @async.now()
  let snapshot = pa_snapshot(version, now - 1_000L, now + 3_600_000L)
  ae_publish_snapshot(h, snapshot)
  snapshot
}

///|
async test "paired runtime runs high-risk work only under an owner Decision" {
  host_run_scenario(
    "mn-approval-e2e",
    "rt-approval-e2e",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    async fn(h) {
      let snapshot = ae_publish(h, "pol-e2e-v1")
      // The owner approves everything through the Decision port. The port
      // records the exact binding handed to it.
      let seen : Ref[Array[@provider_runtime.ApprovalRequest]] = Ref([])
      let port : @provider_runtime.ApprovalPort = async fn(request) {
        seen.val.push(request)
        @provider_runtime.ApprovalOutcome::Approved("dec-approve")
      }
      let approval = @provider_runtime.ApprovalContext::new(
        port~,
        ttl_ms=30_000L,
        wait_ms=2_000L,
      )
      let marker = h.workspace + "/approved.txt"
      let argv = ["sh", "-c", "echo once >> " + marker]
      let result = h.machine.exec_start_approved(
        run_id="e2e-run-approved",
        client_request_id="e2e-approved-1",
        argv~,
        approval~,
      )
      let (run, existing) = match result {
        Ok(value) => value
        Err(failure) => abort("approved exec failed: " + failure.error_text())
      }
      assert_true(!existing)
      assert_eq(run.run_id, "e2e-run-approved")
      assert_eq(seen.val.length(), 1)
      let request = seen.val[0]
      assert_eq(request.runtime_id, "rt-approval-e2e")
      assert_eq(request.run_id, "e2e-run-approved")
      assert_eq(request.policy_version, "pol-e2e-v1")
      assert_eq(request.policy_hash, snapshot.content_hash)
      assert_eq(request.risk, @contracts.RISK_HIGH)
      assert_true(request.digest.has_prefix("sha256:"))
      assert_true(request.decision_id == "")
      let finished = ae_wait_run(h.machine, "e2e-run-approved", 5_000L)
      assert_eq(finished.status, @contracts.RUN_STATUS_SUCCEEDED)
      let marker_text = ae_read_text(marker)
      assert_eq(ae_count(marker_text, "once"), 1)
      assert_eq(host_audit_count(h.state, "policy.approval_requested"), 1)
      assert_eq(host_audit_count(h.state, "policy.approval_granted"), 1)
      assert_eq(host_audit_count(h.state, "policy.approval_used"), 1)
      // A denial never reaches execution. Its command carries a
      // credential-shaped value on purpose: the Decision detail redacts it,
      // the runtime core would refuse to execute it, and neither audit ring
      // ever sees it.
      let denied_seen : Ref[Array[@provider_runtime.ApprovalRequest]] = Ref([])
      let deny_port : @provider_runtime.ApprovalPort = async fn(request) {
        denied_seen.val.push(request)
        @provider_runtime.ApprovalOutcome::Denied("dec-denied")
      }
      let deny_approval = @provider_runtime.ApprovalContext::new(
        port=deny_port,
        ttl_ms=30_000L,
        wait_ms=2_000L,
      )
      let deny_marker = h.workspace + "/denied.txt"
      let denied = h.machine.exec_start_approved(
        run_id="e2e-run-denied",
        client_request_id="e2e-denied-1",
        argv=[
          "sh",
          "-c",
          "TOKEN=s3cr3t-value; echo no >> " + deny_marker,
        ],
        approval=deny_approval,
      )
      match denied {
        Ok(_) => abort("denied operation executed")
        Err(@provider_runtime.ApprovalFailure::Denied(decision_id)) =>
          assert_eq(decision_id, "dec-denied")
        Err(@provider_runtime.ApprovalFailure::Expired(decision_id)) =>
          abort("denied decision reported as expired: " + decision_id)
        Err(@provider_runtime.ApprovalFailure::Pending(decision_id)) =>
          abort("denied decision reported as pending: " + decision_id)
        Err(@provider_runtime.ApprovalFailure::Unavailable(reason)) =>
          abort("denied decision reported as unavailable: " + reason)
        Err(@provider_runtime.ApprovalFailure::Rejected(_code, label)) =>
          abort("denied decision reported as rejected: " + label)
        Err(@provider_runtime.ApprovalFailure::Rpc(error)) =>
          abort("denied decision reported as rpc: " + error.message)
      }
      assert_true(!@fs.exists(deny_marker) catch { _ => true })
      assert_eq(host_audit_count(h.state, "policy.approval_denied"), 1)
      assert_eq(denied_seen.val.length(), 1)
      assert_true(denied_seen.val[0].detail().contains("[redacted]"))
      assert_true(!denied_seen.val[0].detail().contains("s3cr3t-value"))
      assert_true(!h.state.audit_text().contains("s3cr3t-value"))
      assert_true(!h.host.audit_text().contains("s3cr3t-value"))
      // A pending Decision survives a reconnect: the second attempt resumes
      // the same Decision id and grant nonce instead of minting a new one.
      let calls : Ref[Int] = Ref(0)
      let first_ids : Ref[Array[String]] = Ref([])
      let decide_port : @provider_runtime.ApprovalPort = async fn(request) {
        calls.val = calls.val + 1
        if calls.val == 1 {
          first_ids.val.push(request.decision_id)
          first_ids.val.push(request.nonce)
          @provider_runtime.ApprovalOutcome::Pending("dec-pending")
        } else {
          assert_eq(request.decision_id, "dec-pending")
          assert_eq(request.nonce, first_ids.val[1])
          @provider_runtime.ApprovalOutcome::Approved("dec-pending")
        }
      }
      let pending_approval = @provider_runtime.ApprovalContext::new(
        port=decide_port,
        ttl_ms=30_000L,
        wait_ms=2_000L,
      )
      let pending_marker = h.workspace + "/pending.txt"
      let pending_argv = ["sh", "-c", "echo resumed >> " + pending_marker]
      let pending_first = h.machine.exec_start_approved(
        run_id="e2e-run-pending",
        client_request_id="e2e-pending-1",
        argv=pending_argv,
        approval=pending_approval,
      )
      match pending_first {
        Ok(_) => abort("pending operation executed")
        Err(@provider_runtime.ApprovalFailure::Pending(decision_id)) =>
          assert_eq(decision_id, "dec-pending")
        Err(_) => abort("pending operation did not report a pending decision")
      }
      assert_eq(calls.val, 1)
      assert_true(!@fs.exists(pending_marker) catch { _ => true })
      // Drop the session; the node reconnects and the primary's hello carries
      // the snapshot again. The approval binding itself lives on the primary.
      h.state.drop_channel(h.runtime_id)
      host_wait_for("runtime reconnect", 10_000L, () => h.machine.is_connected())
      host_wait_for("policy reinstall", 10_000L, () => {
        ae_count(h.host.audit_text(), "policy.snapshot_installed") >= 2
      })
      let pending_second = h.machine.exec_start_approved(
        run_id="e2e-run-pending",
        client_request_id="e2e-pending-1",
        argv=pending_argv,
        approval=pending_approval,
      )
      match pending_second {
        Ok(_) => ()
        Err(failure) => abort("resumed exec failed: " + failure.error_text())
      }
      assert_eq(calls.val, 2)
      let _pending_run = ae_wait_run(h.machine, "e2e-run-pending", 5_000L)
      assert_eq(ae_count(ae_read_text(pending_marker), "resumed"), 1)
      assert_eq(host_audit_count(h.state, "policy.approval_pending"), 1)
      // A runtime with no live channel can never be approved. The call waits
      // for the configured window and then ends unverifiable, never success.
      let absent = @provider_runtime.RuntimeMachine::new(
        h.state,
        "rt-absent-e2e",
      )
      let absent_port : @provider_runtime.ApprovalPort = async fn(_request) {
        abort("an unreachable runtime must not reach the owner")
        @provider_runtime.ApprovalOutcome::Unavailable("unreachable")
      }
      let absent_approval = @provider_runtime.ApprovalContext::new(
        port=absent_port,
        ttl_ms=30_000L,
        wait_ms=150L,
      )
      let started = @async.now()
      let absent_result = absent.exec_start_approved(
        run_id="e2e-run-absent",
        client_request_id="e2e-absent-1",
        argv=["sh", "-c", "echo no >> " + h.workspace + "/absent.txt"],
        approval=absent_approval,
      )
      let elapsed = @async.now() - started
      match absent_result {
        Ok(_) => abort("an unreachable runtime executed the command")
        Err(@provider_runtime.ApprovalFailure::Unavailable(_reason)) => ()
        Err(_) => abort("an unreachable runtime did not end unverifiable")
      }
      assert_true(elapsed >= 100L)
      assert_eq(host_audit_count(h.state, "policy.approval_unavailable"), 1)
    },
  )
}

///|
async test "policy rotation invalidates an outstanding approval" {
  host_run_scenario(
    "mn-approval-rotate",
    "rt-approval-rotate",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    async fn(h) {
      let _v1 = ae_publish(h, "pol-rot-v1")
      let calls : Ref[Int] = Ref(0)
      let remembered : Ref[Array[String]] = Ref([])
      let port : @provider_runtime.ApprovalPort = async fn(request) {
        calls.val = calls.val + 1
        if calls.val == 1 {
          assert_eq(request.policy_version, "pol-rot-v1")
          remembered.val.push(request.nonce)
          @provider_runtime.ApprovalOutcome::Pending("dec-rotate")
        } else {
          // The v1 pending approval was invalidated by the rotation, so this
          // is a fresh Decision under v2 with a fresh nonce.
          assert_eq(request.policy_version, "pol-rot-v2")
          assert_eq(request.decision_id, "")
          assert_true(request.nonce != remembered.val[0])
          @provider_runtime.ApprovalOutcome::Approved("dec-rotate-v2")
        }
      }
      let approval = @provider_runtime.ApprovalContext::new(
        port~,
        ttl_ms=30_000L,
        wait_ms=2_000L,
      )
      let marker = h.workspace + "/rotated.txt"
      let argv = ["sh", "-c", "echo rotated >> " + marker]
      let first = h.machine.exec_start_approved(
        run_id="e2e-run-rotate",
        client_request_id="e2e-rotate-1",
        argv~,
        approval~,
      )
      match first {
        Ok(_) => abort("pending rotation operation executed")
        Err(@provider_runtime.ApprovalFailure::Pending(decision_id)) =>
          assert_eq(decision_id, "dec-rotate")
        Err(_) => abort("rotation operation did not stay pending")
      }
      assert_true(!@fs.exists(marker) catch { _ => true })
      // Publish a new policy version. The node installs it and verifies grants
      // against it, so the outstanding v1 approval can no longer pass.
      let _v2 = ae_publish(h, "pol-rot-v2")
      let second = h.machine.exec_start_approved(
        run_id="e2e-run-rotate",
        client_request_id="e2e-rotate-1",
        argv~,
        approval~,
      )
      match second {
        Ok(_) => ()
        Err(failure) => abort("rotated exec failed: " + failure.error_text())
      }
      assert_eq(calls.val, 2)
      let _rotated_run = ae_wait_run(h.machine, "e2e-run-rotate", 5_000L)
      assert_eq(ae_count(ae_read_text(marker), "rotated"), 1)
      assert_true(host_audit_count(h.state, "policy.approval_invalidated") >= 1)
      assert_true(host_audit_count(h.state, "policy.version_published") >= 2)
    },
  )
}

///|
async test "fs.write is approved only for the bound path and content" {
  host_run_scenario(
    "mn-fs-approval-e2e",
    "rt-fs-approval-e2e",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    async fn(h) {
      // This snapshot permits read-only work only, so fs.write needs the
      // owner's Decision instead of being allowed outright.
      let snapshot = pa_gated_snapshot("pol-fs-e2e")
      ae_publish_snapshot(h, snapshot)
      let seen : Ref[Array[@provider_runtime.ApprovalRequest]] = Ref([])
      let port : @provider_runtime.ApprovalPort = async fn(request) {
        seen.val.push(request)
        @provider_runtime.ApprovalOutcome::Approved("dec-fs-e2e")
      }
      let approval = @provider_runtime.ApprovalContext::new(
        port~,
        ttl_ms=30_000L,
        wait_ms=2_000L,
      )
      let result = h.machine.fs_write_approved(
        path="approved-fs.txt",
        content="alpha",
        client_request_id="e2e-fs-1",
        approval~,
      )
      match result {
        Ok(_) => ()
        Err(failure) => abort("approved fs.write failed: " + failure.error_text())
      }
      assert_eq(seen.val.length(), 1)
      let request = seen.val[0]
      assert_eq(request.runtime_id, "rt-fs-approval-e2e")
      assert_eq(request.run_id, "e2e-fs-1")
      assert_eq(request.policy_version, "pol-fs-e2e")
      assert_eq(request.policy_hash, snapshot.content_hash)
      assert_eq(request.risk, @contracts.RISK_MEDIUM)
      // The owner reviews the path and a redacted preview of the content; the
      // grant's digest binds the full content the node will write.
      assert_true(request.detail().contains("approved-fs.txt"))
      assert_true(request.detail().contains("alpha"))
      assert_eq(ae_read_text(h.workspace + "/approved-fs.txt"), "alpha")
      assert_eq(host_audit_count(h.state, "policy.approval_requested"), 1)
      assert_eq(host_audit_count(h.state, "policy.approval_used"), 1)
    },
  )
}
