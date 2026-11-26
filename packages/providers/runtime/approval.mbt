///|
/// Decision-bound approval for paired runtime execution (A1.3b).
///
/// The node never approves anything and keeps no approval state machine. When
/// a high-risk operation reaches it without a grant, it returns
/// `approval_required` with a binding: operation, run id, command digest,
/// policy version/hash and snapshot expiry. This module is the primary side of
/// that handshake:
///
/// 1. send the operation without a grant;
/// 2. on `approval_required`, ask the host's `ApprovalPort` (the existing
///    Decision inbox) for an answer, resuming the same Decision when a pending
///    binding already exists;
/// 3. on approval, mint a short-lived `@policy.ApprovalGrant` bound to the run,
///    digest, policy version, a one-shot nonce and the Decision id;
/// 4. resend the same operation with the grant and report the typed outcome.
///
/// Denied or expired approvals never send the operation. A missing primary
/// channel waits (optionally) and then ends `unverifiable`; it never executes
/// offline. Audit stays on the primary and never contains argv values, env
/// values, grant nonces or credentials.

///|
/// What the host's Decision inbox answers about one remote approval request.
///
/// - `Approved(decision_id)` — the owner approved; a grant may be minted.
/// - `Denied(decision_id)` — the owner denied; nothing is executed.
/// - `Expired(decision_id)` — the Decision expired or was withdrawn.
/// - `Pending(decision_id)` — no answer yet; the binding is kept and the same
///   Decision is resumed on the next attempt.
/// - `Unavailable(reason)` — the Decision machinery cannot answer now; the
///   operation ends unverifiable and never executes.
pub(all) enum ApprovalOutcome {
  Approved(String)
  Denied(String)
  Expired(String)
  Pending(String)
  Unavailable(String)
}

///|
pub(all) struct ApprovalRequest {
  runtime_id : String
  rpc_method : String
  run_id : String
  client_request_id : String
  /// The command/path being approved, for the Decision detail. The host
  /// redacts it before display; it never enters audit.
  command : Array[String]
  /// Execution payload values the digest binds (stdin, env values, fs content,
  /// git worktree flags, cwd), formatted for the Decision detail and redacted
  /// there. This is what the owner reviews; it never enters audit.
  payload : Array[String]
  digest : String
  policy_version : String
  policy_hash : String
  risk : String
  reason : String
  /// One-shot grant nonce, minted before the Decision is created so the
  /// Decision, the owner answer and the grant are bound to the same value.
  /// It is internal metadata and must never be displayed or audited.
  nonce : String
  /// Non-empty when this request resumes an already pending Decision.
  decision_id : String
  /// Hard expiry for an answer and the grant.
  expires_at_ms : Int64
  snapshot_expires_at_ms : Int64
}

///|
/// The approval seam the host implements over its existing Decision flow.
pub type ApprovalPort = async (ApprovalRequest) -> ApprovalOutcome

///|
pub struct ApprovalContext {
  port : ApprovalPort
  ttl_ms : Int64
  wait_ms : Int64
}

///|
/// `ttl_ms` is the grant lifetime requested by the primary (clamped to the
/// policy core's ceiling); `wait_ms` bounds how long an operation waits for a
/// reconnect before ending unverifiable. Zero means "do not wait".
pub fn ApprovalContext::new(
  port~ : ApprovalPort,
  ttl_ms~ : Int64 = 60_000L,
  wait_ms~ : Int64 = 0L,
) -> ApprovalContext {
  {
    port,
    ttl_ms: ttl_ms.max(1L).min(@policy.MAX_GRANT_TTL_MS),
    wait_ms: wait_ms.max(0L),
  }
}

///|
pub(all) enum ApprovalFailure {
  /// The owner denied the request. Carries the Decision id.
  Denied(String)
  /// The Decision expired or was withdrawn. Carries the Decision id.
  Expired(String)
  /// The owner has not answered yet. Carries the Decision id.
  Pending(String)
  /// The primary could not verify or reach the operation. Never a success.
  Unavailable(String)
  /// The node rejected the operation or its grant. Carries the JSON-RPC code
  /// and a fixed label (`policy_denied`, `digest_mismatch`, ...).
  Rejected(Int, String)
  /// An unexpected JSON-RPC error (input, path, host).
  Rpc(@contracts.RpcError)
}

///|
pub fn ApprovalFailure::error_text(self : ApprovalFailure) -> String {
  match self {
    Denied(decision_id) =>
      "owner denied the remote operation (decision " + decision_id + ")"
    Expired(decision_id) =>
      "the approval decision expired before an answer (decision " +
      decision_id +
      ")"
    Pending(decision_id) =>
      "waiting for the owner's decision " + decision_id
    Unavailable(reason) => "operation is unverifiable: " + reason
    Rejected(_code, label) => "remote operation was rejected: " + label
    Rpc(error) => error.message
  }
}

///|
pub fn ApprovalFailure::is_unverifiable(self : ApprovalFailure) -> Bool {
  match self {
    Unavailable(_) | Pending(_) => true
    _ => false
  }
}

///|
/// One binding remembered across reconnects. No argv, env value or grant text
/// is kept: only the identifiers needed to resume verification.
pub(all) struct PendingApproval {
  decision_id : String
  nonce : String
  digest : String
  policy_version : String
  policy_hash : String
  expires_at_ms : Int64
}

///|
fn payload_detail_lines(items : Array[String]) -> String {
  let mut out = ""
  for item in items {
    out = out + "\n  " + @contracts.redact_secrets(item)
  }
  out
}

///|
fn bounded_payload_value(value : String) -> String {
  let trimmed = if value.length() > 256 {
    value[:256].to_owned() + "…[truncated]"
  } else {
    value
  }
  // Redact before the value is carried into the Decision request; the detail
  // redacts again, so double redaction is harmless and keeps the raw secret
  // out of the request object itself.
  @contracts.redact_secrets(trimmed)
}

///|
/// The execution-affecting values the node's digest binds, rendered for the
/// owner's Decision detail. Nothing here is audited.
fn approval_payload(params : Map[String, @json.Json]) -> Array[String] {
  let items : Array[String] = []
  let cwd = @contracts.string_field_or(params, "cwd", "")
  if cwd != "" {
    items.push("cwd=" + bounded_payload_value(cwd))
  }
  match params.get("env") {
    Some(@json.Json::Object(env)) =>
      for name, value in env {
        match value {
          @json.Json::String(text) =>
            items.push("env " + name + "=" + bounded_payload_value(text))
          _ => ()
        }
      }
    _ => ()
  }
  match params.get("stdin") {
    Some(@json.Json::String(value)) =>
      items.push("stdin=" + bounded_payload_value(value))
    _ => ()
  }
  match params.get("content") {
    Some(@json.Json::String(value)) =>
      items.push("content=" + bounded_payload_value(value))
    _ => ()
  }
  if @contracts.bool_field_or(params, "force", false) {
    items.push("force=true")
  }
  let expected_head = @contracts.string_field_or(params, "expected_head", "")
  if expected_head != "" {
    items.push("expected_head=" + bounded_payload_value(expected_head))
  }
  let expected_branch = @contracts.string_field_or(
    params,
    "expected_branch",
    "",
  )
  if expected_branch != "" {
    items.push("expected_branch=" + bounded_payload_value(expected_branch))
  }
  items
}

///|
/// The safe, redacted text a host can put into a Decision detail.
pub fn ApprovalRequest::detail(self : ApprovalRequest) -> String {
  let command = @contracts.redact_secrets(self.command.join(" "))
  let payload = if self.payload.is_empty() {
    ""
  } else {
    "\nPayload:" + payload_detail_lines(self.payload)
  }
  "Remote runtime: " +
  self.rpc_method +
  " on " +
  self.runtime_id +
  "\nRun: " +
  self.run_id +
  "\nPolicy: " +
  self.policy_version +
  "\nPolicy hash: " +
  self.policy_hash +
  "\nCommand digest: " +
  self.digest +
  "\nRisk: " +
  self.risk +
  "\nReason: " +
  self.reason +
  "\nCommand:\n" +
  command +
  payload
}

///|
struct ApprovalBinding {
  operation : String
  run_id : String
  digest : String
  policy_version : String
  policy_hash : String
  risk : String
  reason : String
  snapshot_expires_at_ms : Int64
}

///|
fn approval_binding_from_error(
  error : @contracts.RpcError,
) -> ApprovalBinding? {
  let data = match error.data {
    Some(value) => value
    None => return None
  }
  let object = match @contracts.as_object(data) {
    Some(value) => value
    None => return None
  }
  if @contracts.string_field_or(object, "kind", "") != "approval_binding" {
    return None
  }
  let digest = @contracts.string_field_or(object, "digest", "")
  if digest == "" {
    return None
  }
  Some({
    operation: @contracts.string_field_or(object, "operation", ""),
    run_id: @contracts.string_field_or(object, "run_id", ""),
    digest,
    policy_version: @contracts.string_field_or(
      object,
      "policy_version",
      "",
    ),
    policy_hash: @contracts.string_field_or(object, "policy_hash", ""),
    risk: @contracts.string_field_or(object, "risk", ""),
    reason: @contracts.string_field_or(object, "reason", ""),
    snapshot_expires_at_ms: @contracts.int64_field_or(
      object,
      "snapshot_expires_at_ms",
      0L,
    ),
  })
}

///|
fn grant_label_from_error(error : @contracts.RpcError) -> String {
  let data = match error.data {
    Some(value) => value
    None => return "grant_rejected"
  }
  let object = match @contracts.as_object(data) {
    Some(value) => value
    None => return "grant_rejected"
  }
  let label = @contracts.string_field_or(object, "reason", "")
  if label == "" {
    "grant_rejected"
  } else {
    label
  }
}

///|
/// The current publication a mutating call must be bound to. The primary
/// refuses to send a mutation until the runtime has acknowledged installing
/// exactly this version and hash: a node that rejected the update, never
/// received it, or runs in operator-override mode must not be trusted to
/// execute under the primary's current rules.
fn delivered_policy(
  machine : RuntimeMachine,
  rpc_method : String,
) -> Result[@transport.PolicyAnnouncement, String] {
  let announcement = match machine.state.policy_announcement() {
    Some(value) => value
    None => {
      machine.policy_audit(
        "policy.delivery",
        "rejected",
        "method=" + rpc_method + " reason=no_policy_published",
      )
      return Err("no policy snapshot is published to this runtime")
    }
  }
  if !machine.state.policy_installed(
    machine.runtime_id,
    announcement.version,
    announcement.hash,
  ) {
    machine.policy_audit(
      "policy.delivery",
      "rejected",
      "method=" +
      rpc_method +
      " policy_version=" +
      announcement.version +
      " reason=policy_not_installed",
    )
    return Err(
      "the runtime has not acknowledged the current policy snapshot",
    )
  }
  Ok(announcement)
}

///|
fn mutation_result_matches(
  result : @json.Json,
  publication : @transport.PolicyAnnouncement,
) -> Bool {
  let object = match @contracts.as_object(result) {
    Some(value) => value
    None => return false
  }
  let policy = match object.get("policy") {
    Some(@json.Json::Object(value)) => value
    _ => return false
  }
  @contracts.string_field_or(policy, "policy_version", "") ==
  publication.version &&
  @contracts.string_field_or(policy, "policy_hash", "") == publication.hash
}

///|
/// Reject a mutating success that does not carry the current policy metadata.
/// This closes the operator-override gap: a node running `--allow-workspace`
/// stamps no policy metadata, so its success is never recorded as verified on
/// the primary.
fn verified_mutation_result(
  machine : RuntimeMachine,
  rpc_method : String,
  result : @json.Json,
  publication : @transport.PolicyAnnouncement,
) -> Result[Unit, String] {
  if mutation_result_matches(result, publication) {
    return Ok(())
  }
  machine.policy_audit(
    "policy.delivery",
    "rejected",
    "method=" +
    rpc_method +
    " policy_version=" +
    publication.version +
    " reason=result_not_verified",
  )
  Err("the runtime's mutation result cannot be verified under the current policy")
}

///|
fn RuntimeMachine::invalidate_stale_pending(
  self : RuntimeMachine,
  publication : @transport.PolicyAnnouncement,
  rpc_method : String,
) -> Unit {
  let stale : Array[(String, PendingApproval)] = []
  for key, pending in self.pending_approvals {
    if pending.policy_version != publication.version ||
      pending.policy_hash != publication.hash {
      stale.push((key, pending))
    }
  }
  for pair in stale {
    let (key, pending) = pair
    self.forget_pending(key)
    self.policy_audit(
      "policy.approval_invalidated",
      "invalidated",
      "method=" +
      rpc_method +
      " old_policy_version=" +
      pending.policy_version +
      " new_policy_version=" +
      publication.version,
    )
  }
}

///|
fn RuntimeMachine::policy_audit(
  self : RuntimeMachine,
  action : String,
  outcome : String,
  detail : String,
) -> Unit {
  self.state.record_audit(action, self.runtime_id, outcome, detail)
}

///|
fn classify_rpc_failure(
  error : @contracts.RpcError,
) -> ApprovalFailure {
  if error.code == @transport.ERR_POLICY_STALE {
    Unavailable(error.message)
  } else if error.code == @transport.ERR_POLICY_DENIED {
    Rejected(error.code, "policy_denied")
  } else if error.code == @transport.ERR_APPROVAL_INVALID {
    Rejected(error.code, grant_label_from_error(error))
  } else if error.code == @contracts.ERR_HOST {
    Unavailable(error.message)
  } else if error.code == @transport.ERR_REVOKED {
    Unavailable("runtime session is no longer connected")
  } else {
    Rpc(error)
  }
}

///|
pub fn RuntimeMachine::pending_approval_count(self : RuntimeMachine) -> Int {
  self.pending_approvals.length()
}

///|
pub fn RuntimeMachine::pending_approval(
  self : RuntimeMachine,
  rpc_method : String,
  binding_run_id : String,
) -> PendingApproval? {
  self.pending_approvals.get(rpc_method + "|" + binding_run_id)
}

///|
fn RuntimeMachine::forget_pending(self : RuntimeMachine, key : String) -> Unit {
  self.pending_approvals.remove(key)
  let mut index = 0
  while index < self.pending_order.length() {
    if self.pending_order[index] == key {
      let _ = self.pending_order.remove(index)
    } else {
      index = index + 1
    }
  }
}

///|
fn RuntimeMachine::remember_pending(
  self : RuntimeMachine,
  key : String,
  pending : PendingApproval,
) -> Unit {
  if !self.pending_approvals.contains(key) {
    self.pending_order.push(key)
    while self.pending_order.length() > MAX_PENDING_APPROVALS {
      let oldest = self.pending_order.remove(0)
      self.pending_approvals.remove(oldest)
    }
  }
  self.pending_approvals.set(key, pending)
}

///|
async fn RuntimeMachine::wait_for_channel(
  self : RuntimeMachine,
  wait_ms : Int64,
) -> Result[@transport.SessionChannel, ApprovalFailure] {
  let deadline = @async.now() + wait_ms
  while true {
    match self.state.channel_for(self.runtime_id) {
      Some(value) => return Ok(value)
      None => ()
    }
    if @async.now() >= deadline {
      return Err(
        Unavailable(
          "runtime is unreachable; high-risk operations never run offline",
        ),
      )
    }
    @async.sleep(20)
  } nobreak {
    Err(Unavailable("runtime is unreachable"))
  }
}

///|
fn fresh_pending(
  now_ms : Int64,
  ttl_ms : Int64,
  binding : ApprovalBinding,
) -> Result[PendingApproval, ApprovalFailure] {
  let nonce = match @transport.random_hex(16) {
    Ok(value) => value
    Err(_) =>
      return Err(Unavailable("cannot generate an approval nonce"))
  }
  let mut expires_at_ms = now_ms + ttl_ms
  if binding.snapshot_expires_at_ms > 0L &&
    binding.snapshot_expires_at_ms < expires_at_ms {
    expires_at_ms = binding.snapshot_expires_at_ms
  }
  if expires_at_ms <= now_ms {
    return Err(
      Unavailable(
        "the policy snapshot expires before an approval grant could be used",
      ),
    )
  }
  Ok({
    decision_id: "",
    nonce,
    digest: binding.digest,
    policy_version: binding.policy_version,
    policy_hash: binding.policy_hash,
    expires_at_ms,
  })
}

///|
/// Send one mutating operation with Decision-bound approval. This is the
/// generic path behind the typed exec/fs wrappers; PTY and git mutations can
/// use it with their own binding id.
pub async fn RuntimeMachine::mutate_with_approval(
  self : RuntimeMachine,
  rpc_method~ : String,
  params~ : Map[String, @json.Json],
  binding_run_id~ : String,
  client_request_id~ : String,
  command~ : Array[String],
  approval~ : ApprovalContext,
) -> Result[@json.Json, ApprovalFailure] {
  let channel = match self.wait_for_channel(approval.wait_ms) {
    Ok(value) => value
    Err(failure) => {
      self.policy_audit(
        "policy.approval_unavailable",
        "unavailable",
        "method=" +
        rpc_method +
        " run_id=" +
        binding_run_id +
        " reason=transport_unreachable",
      )
      return Err(failure)
    }
  }
  // Delivery enforcement runs before the first send: the node must have
  // acknowledged installing the primary's current publication, and pending
  // approvals from an older publication are invalidated here.
  let publication = match delivered_policy(self, rpc_method) {
    Ok(value) => value
    Err(reason) => {
      self.policy_audit(
        "policy.approval_unavailable",
        "unavailable",
        "method=" +
        rpc_method +
        " run_id=" +
        binding_run_id +
        " reason=policy_not_delivered",
      )
      return Err(Unavailable(reason))
    }
  }
  self.invalidate_stale_pending(publication, rpc_method)
  let request_params : Map[String, @json.Json] = Map([])
  for key, value in params {
    request_params.set(key, value)
  }
  if client_request_id != "" {
    request_params.set(
      "client_request_id",
      @contracts.json_string(client_request_id),
    )
  }
  let first_error = match channel.request(rpc_method, request_params) {
    Ok(value) =>
      match verified_mutation_result(self, rpc_method, value, publication) {
        Ok(_) => return Ok(value)
        Err(reason) => return Err(Unavailable(reason))
      }
    Err(error) =>
      if error.code == @transport.ERR_APPROVAL_REQUIRED {
        error
      } else {
        let failure = classify_rpc_failure(error)
        self.policy_audit(
          "policy.decision",
          failure.error_text(),
          "method=" +
          rpc_method +
          " run_id=" +
          binding_run_id +
          " outcome=rejected_without_execution",
        )
        return Err(failure)
      }
  }
  let binding = match approval_binding_from_error(first_error) {
    Some(value) => value
    None =>
      return Err(
        Unavailable(
          "runtime did not return a verifiable approval binding",
        ),
      )
  }
  if binding.run_id != "" && binding.run_id != binding_run_id {
    self.policy_audit(
      "policy.approval_rejected",
      "rejected",
      "method=" +
      rpc_method +
      " run_id=" +
      binding_run_id +
      " reason=run_binding_mismatch",
    )
    return Err(Rejected(@transport.ERR_APPROVAL_INVALID, "run_mismatch"))
  }
  if binding.policy_version != publication.version ||
    binding.policy_hash != publication.hash {
    self.policy_audit(
      "policy.approval_invalidated",
      "invalidated",
      "method=" +
      rpc_method +
      " run_id=" +
      binding_run_id +
      " binding_policy_version=" +
      binding.policy_version +
      " current_policy_version=" +
      publication.version +
      " reason=policy_changed_in_flight",
    )
    return Err(
      Unavailable(
        "the policy changed while the operation was in flight; it was not executed",
      ),
    )
  }
  let key = rpc_method + "|" + binding_run_id
  let now_ms = @async.now()
  let pending = match self.pending_approvals.get(key) {
    Some(existing) =>
      if existing.digest == binding.digest &&
        existing.policy_version == binding.policy_version &&
        existing.policy_hash == binding.policy_hash {
        existing
      } else {
        self.policy_audit(
          "policy.approval_invalidated",
          "invalidated",
          "method=" +
          rpc_method +
          " run_id=" +
          binding_run_id +
          " old_policy_version=" +
          existing.policy_version +
          " new_policy_version=" +
          binding.policy_version,
        )
        let fresh = match fresh_pending(now_ms, approval.ttl_ms, binding) {
          Ok(value) => value
          Err(failure) => return Err(failure)
        }
        self.remember_pending(key, fresh)
        fresh
      }
    None => {
      let fresh = match fresh_pending(now_ms, approval.ttl_ms, binding) {
        Ok(value) => value
        Err(failure) => return Err(failure)
      }
      self.remember_pending(key, fresh)
      fresh
    }
  }
  let resumed = pending.decision_id != ""
  self.policy_audit(
    "policy.approval_requested",
    if resumed {
      "resumed"
    } else {
      "new"
    },
    "method=" +
    rpc_method +
    " run_id=" +
    binding_run_id +
    " digest=" +
    binding.digest +
    " policy_version=" +
    binding.policy_version +
    " risk=" +
    binding.risk,
  )
  let request : ApprovalRequest = {
    runtime_id: self.runtime_id,
    rpc_method,
    run_id: binding_run_id,
    client_request_id,
    command,
    payload: approval_payload(params),
    digest: binding.digest,
    policy_version: binding.policy_version,
    policy_hash: binding.policy_hash,
    risk: binding.risk,
    reason: binding.reason,
    nonce: pending.nonce,
    decision_id: pending.decision_id,
    expires_at_ms: pending.expires_at_ms,
    snapshot_expires_at_ms: binding.snapshot_expires_at_ms,
  }
  let outcome = (approval.port)(request)
  match outcome {
    Approved(approved_id) => {
      let updated : PendingApproval = { ..pending, decision_id: approved_id }
      self.remember_pending(key, updated)
      self.policy_audit(
        "policy.approval_granted",
        "granted",
        "method=" +
        rpc_method +
        " run_id=" +
        binding_run_id +
        " decision_id=" +
        approved_id,
      )
      let issued_at_ms = @async.now()
      if issued_at_ms >= pending.expires_at_ms {
        self.forget_pending(key)
        self.policy_audit(
          "policy.approval_expired",
          "expired",
          "method=" +
          rpc_method +
          " run_id=" +
          binding_run_id +
          " decision_id=" +
          approved_id,
        )
        return Err(Expired(approved_id))
      }
      // The publication must still match the binding at mint time: a rotation
      // between the owner's answer and the grant would otherwise mint a grant
      // for rules the node no longer runs.
      let mint_publication = match delivered_policy(self, rpc_method) {
        Ok(value) => value
        Err(reason) => {
          self.forget_pending(key)
          self.policy_audit(
            "policy.approval_invalidated",
            "invalidated",
            "method=" +
            rpc_method +
            " run_id=" +
            binding_run_id +
            " reason=policy_not_delivered_at_mint",
          )
          return Err(Unavailable(reason))
        }
      }
      if mint_publication.version != binding.policy_version ||
        mint_publication.hash != binding.policy_hash {
        self.forget_pending(key)
        self.policy_audit(
          "policy.approval_invalidated",
          "invalidated",
          "method=" +
          rpc_method +
          " run_id=" +
          binding_run_id +
          " old_policy_version=" +
          binding.policy_version +
          " new_policy_version=" +
          mint_publication.version +
          " reason=policy_changed_at_mint",
        )
        return Err(
          Unavailable(
            "the policy changed before the approval could be used; nothing was executed",
          ),
        )
      }
      let grant = match
        @policy.ApprovalGrant::new(
          run_id=binding_run_id,
          command_digest=binding.digest,
          policy_version=binding.policy_version,
          policy_hash=binding.policy_hash,
          nonce=pending.nonce,
          issued_at_ms~,
          expires_at_ms=pending.expires_at_ms,
          reason=binding.reason,
          decision_id=approved_id,
        ) {
        Ok(value) => value
        Err(message) =>
          return Err(Unavailable("cannot mint an approval grant: " + message))
      }
      let grant_channel = match self.wait_for_channel(approval.wait_ms) {
        Ok(value) => value
        Err(failure) => return Err(failure)
      }
      request_params.set(
        "approval",
        @contracts.json_string(grant.encode()),
      )
      match grant_channel.request(rpc_method, request_params) {
        Ok(value) =>
          match
            verified_mutation_result(self, rpc_method, value, mint_publication) {
            Ok(_) => {
              self.forget_pending(key)
              self.policy_audit(
                "policy.approval_used",
                "used",
                "method=" +
                rpc_method +
                " run_id=" +
                binding_run_id +
                " decision_id=" +
                approved_id,
              )
              Ok(value)
            }
            Err(reason) => {
              self.forget_pending(key)
              self.policy_audit(
                "policy.approval_unavailable",
                "unavailable",
                "method=" +
                rpc_method +
                " run_id=" +
                binding_run_id +
                " decision_id=" +
                approved_id +
                " reason=result_not_verified",
              )
              Err(Unavailable(reason))
            }
          }
        Err(error) => {
          let code = error.code
          if code == @transport.ERR_APPROVAL_INVALID {
            let label = grant_label_from_error(error)
            self.forget_pending(key)
            self.policy_audit(
              "policy.approval_rejected",
              "rejected",
              "method=" +
              rpc_method +
              " run_id=" +
              binding_run_id +
              " decision_id=" +
              approved_id +
              " reason=" +
              label,
            )
            Err(Rejected(code, label))
          } else if code == @transport.ERR_POLICY_STALE ||
            code == @transport.ERR_APPROVAL_REQUIRED {
            self.policy_audit(
              "policy.approval_unavailable",
              "unavailable",
              "method=" +
              rpc_method +
              " run_id=" +
              binding_run_id +
              " reason=policy_changed_or_unverifiable",
            )
            Err(Unavailable(error.message))
          } else if code == @contracts.ERR_HOST || code == @transport.ERR_REVOKED {
            self.policy_audit(
              "policy.approval_unavailable",
              "unavailable",
              "method=" +
              rpc_method +
              " run_id=" +
              binding_run_id +
              " reason=transport_lost",
            )
            Err(Unavailable(error.message))
          } else {
            Err(Rpc(error))
          }
        }
      }
    }
    Denied(denied_id) => {
      self.forget_pending(key)
      self.policy_audit(
        "policy.approval_denied",
        "denied",
        "method=" + rpc_method + " run_id=" + binding_run_id +
        " decision_id=" + denied_id,
      )
      Err(Denied(denied_id))
    }
    Expired(expired_id) => {
      self.forget_pending(key)
      self.policy_audit(
        "policy.approval_expired",
        "expired",
        "method=" + rpc_method + " run_id=" + binding_run_id +
        " decision_id=" + expired_id,
      )
      Err(Expired(expired_id))
    }
    Pending(pending_id) => {
      let updated : PendingApproval = {
        ..pending,
        decision_id: pending_id,
      }
      self.remember_pending(key, updated)
      self.policy_audit(
        "policy.approval_pending",
        "pending",
        "method=" + rpc_method + " run_id=" + binding_run_id +
        " decision_id=" + pending_id,
      )
      Err(Pending(pending_id))
    }
    Unavailable(reason) => {
      self.policy_audit(
        "policy.approval_unavailable",
        "unavailable",
        "method=" + rpc_method + " run_id=" + binding_run_id,
      )
      Err(Unavailable(reason))
    }
  }
}

///|
/// Exec with Decision-bound approval. Returns the run snapshot and whether the
/// node answered with an existing run (idempotent replay); a denied, expired
/// or unverifiable approval is an `Err`, never a success.
pub async fn RuntimeMachine::exec_start_approved(
  self : RuntimeMachine,
  run_id~ : String,
  client_request_id~ : String,
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Map[String, String] = Map([]),
  inherit_env~ : Array[String] = [],
  timeout_ms~ : Int = 0,
  risk~ : String = "",
  stdin~ : String? = None,
  max_output_bytes~ : Int = 0,
  approval~ : ApprovalContext,
) -> Result[(RunSnapshot, Bool), ApprovalFailure] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("argv", @contracts.json_string_array(argv))
  if cwd != "" {
    params.set("cwd", @contracts.json_string(cwd))
  }
  if !env.is_empty() {
    let entries : Array[(String, @json.Json)] = []
    for name, value in env {
      entries.push((name, @contracts.json_string(value)))
    }
    params.set("env", @contracts.json_object(entries))
  }
  if !inherit_env.is_empty() {
    params.set("inherit_env", @contracts.json_string_array(inherit_env))
  }
  if timeout_ms > 0 {
    params.set("timeout_ms", @contracts.json_int(timeout_ms))
  }
  if risk != "" {
    params.set("risk", @contracts.json_string(risk))
  }
  match stdin {
    Some(value) => params.set("stdin", @contracts.json_string(value))
    None => ()
  }
  if max_output_bytes > 0 {
    params.set("max_output_bytes", @contracts.json_int(max_output_bytes))
  }
  let result = self.mutate_with_approval(
    rpc_method=@contracts.METHOD_RUNTIME_EXEC_START,
    params~,
    binding_run_id=run_id,
    client_request_id~,
    command=argv,
    approval~,
  )
  let json = match result {
    Ok(value) => value
    Err(Rejected(_code, label)) =>
      if label == "replayed_nonce" {
        // The grant was already consumed. The run may still exist exactly
        // once under this run id; reconcile by status instead of re-executing.
        match self.exec_status(run_id) {
          Ok(Some(run)) => {
            self.policy_audit(
              "policy.approval_replay_reconciled",
              "existing",
              "run_id=" + run_id + " outcome=status_reconciled",
            )
            return Ok((run, true))
          }
          _ => ()
        }
        return Err(Rejected(@transport.ERR_APPROVAL_INVALID, label))
      } else {
        return Err(Rejected(_code, label))
      }
    Err(failure) => return Err(failure)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None =>
      return Err(
        Rpc(
          @contracts.RpcError::new(
            @contracts.ERR_INTERNAL,
            "exec.start returned a non-object",
          ),
        ),
      )
  }
  let existing = @contracts.bool_field_or(object, "existing", false)
  let run_json = match object.get("run") {
    Some(value) => value
    None =>
      return Err(
        Rpc(
          @contracts.RpcError::new(
            @contracts.ERR_INTERNAL,
            "exec.start returned no run",
          ),
        ),
      )
  }
  let run = match RunSnapshot::from_json(run_json) {
    Some(value) => value
    None =>
      return Err(
        Rpc(
          @contracts.RpcError::new(
            @contracts.ERR_INTERNAL,
            "exec.start returned an invalid run",
          ),
        ),
      )
  }
  Ok((run, existing))
}

///|
/// fs.write with Decision-bound approval. The node's digest covers the path
/// *and* the full content (plus the resolved cwd and workspace root), so a
/// grant cannot authorize a different file or different bytes. The Decision
/// detail shows the path and a redacted, length-bounded preview of the
/// content; the digest binds the full value.
pub async fn RuntimeMachine::fs_write_approved(
  self : RuntimeMachine,
  path~ : String,
  content~ : String,
  client_request_id~ : String,
  approval~ : ApprovalContext,
) -> Result[@json.Json, ApprovalFailure] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  params.set("content", @contracts.json_string(content))
  self.mutate_with_approval(
    rpc_method=@contracts.METHOD_RUNTIME_FS_WRITE,
    params~,
    binding_run_id=client_request_id,
    client_request_id~,
    command=["fs.write", path],
    approval~,
  )
}
