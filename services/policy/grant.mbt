///|
/// Approval grants (ADR-0012 §5).
///
/// A grant is the primary's authority: it is created only after the owner
/// answers an existing Decision, and it is bound to one run id, one command
/// digest, one policy version, one nonce and a short lifetime. This module
/// never creates a Decision and never approves anything; it only decodes and
/// verifies a grant the primary issued, and burns its nonce exactly once.
///
/// Grants carry no secret values beyond the nonce itself. Error strings are
/// fixed text and never echo the nonce, digest or other credential material.

///|
pub const GRANT_FORMAT : String = "monexus.approval.grant"

///|
pub const GRANT_FORMAT_VERSION : Int = 1

///|
/// Hard lifetime ceiling. Grants are short-lived on purpose. The node persists
/// consumed nonces with their grant expiry, so a restart cannot replay a grant
/// that was already used; the ceiling bounds how long the replay memory must
/// be kept.
pub const MAX_GRANT_TTL_MS : Int64 = 600_000L

///|
/// Clock skew tolerated when checking a grant's issue time.
pub const GRANT_CLOCK_SKEW_MS : Int64 = 60_000L

///|
pub(all) struct ApprovalGrant {
  run_id : String
  command_digest : String
  policy_version : String
  /// The exact snapshot hash the Decision was made under. Version text alone
  /// is not unique; a same-version republish with different rules must not
  /// validate an old grant.
  policy_hash : String
  nonce : String
  issued_at_ms : Int64
  expires_at_ms : Int64
  reason : String
  decision_id : String
}

///|
/// Whether a digest string has the canonical `sha256:` + 64 lowercase hex form.
fn is_command_digest(text : String) -> Bool {
  if !text.has_prefix(COMMAND_DIGEST_PREFIX) {
    return false
  }
  let body = text[COMMAND_DIGEST_PREFIX.length():].to_owned()
  is_hex64(body)
}

///|
fn is_policy_hash(text : String) -> Bool {
  text.length() == 64 && is_hex64(text)
}

///|
fn validate_grant_fields(
  run_id : String,
  command_digest : String,
  policy_version : String,
  policy_hash : String,
  nonce : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
  reason : String,
  decision_id : String,
) -> String? {
  if run_id == "" || run_id.length() > 128 || !is_token_text(run_id) {
    return Some("approval grant run_id is invalid")
  }
  if !is_command_digest(command_digest) {
    return Some("approval grant command digest is invalid")
  }
  if policy_version == "" || policy_version.length() > 128 ||
    !is_token_text(policy_version) {
    return Some("approval grant policy version is invalid")
  }
  if !is_policy_hash(policy_hash) {
    return Some("approval grant policy hash is invalid")
  }
  if nonce.length() < 16 || nonce.length() > 128 || !is_token_text(nonce) {
    return Some("approval grant nonce is invalid")
  }
  if issued_at_ms < 0L || expires_at_ms <= issued_at_ms {
    return Some("approval grant time range is invalid")
  }
  if expires_at_ms - issued_at_ms > MAX_GRANT_TTL_MS {
    return Some("approval grant lifetime exceeds the maximum")
  }
  if reason.length() > 512 || !is_printable_text(reason) {
    return Some("approval grant reason is invalid")
  }
  if decision_id.length() > 128 || !is_printable_text(decision_id) {
    return Some("approval grant decision id is invalid")
  }
  None
}

///|
pub fn ApprovalGrant::new(
  run_id~ : String,
  command_digest~ : String,
  policy_version~ : String,
  policy_hash~ : String,
  nonce~ : String,
  issued_at_ms~ : Int64,
  expires_at_ms~ : Int64,
  reason~ : String = "",
  decision_id~ : String = "",
) -> Result[ApprovalGrant, String] {
  match validate_grant_fields(
    run_id,
    command_digest,
    policy_version,
    policy_hash,
    nonce,
    issued_at_ms,
    expires_at_ms,
    reason,
    decision_id,
  ) {
    Some(error) => return Err(error)
    None => ()
  }
  Ok({
    run_id,
    command_digest,
    policy_version,
    policy_hash,
    nonce,
    issued_at_ms,
    expires_at_ms,
    reason,
    decision_id,
  })
}

///|
pub fn ApprovalGrant::encode(self : ApprovalGrant) -> String {
  "{" +
  "\"command_digest\":" + canonical_quote(self.command_digest) + "," +
  "\"decision_id\":" + canonical_quote(self.decision_id) + "," +
  "\"expires_at_ms\":" + canonical_int64(self.expires_at_ms) + "," +
  "\"format\":" + canonical_quote(GRANT_FORMAT) + "," +
  "\"format_version\":" + GRANT_FORMAT_VERSION.to_string() + "," +
  "\"issued_at_ms\":" + canonical_int64(self.issued_at_ms) + "," +
  "\"nonce\":" + canonical_quote(self.nonce) + "," +
  "\"policy_hash\":" + canonical_quote(self.policy_hash) + "," +
  "\"policy_version\":" + canonical_quote(self.policy_version) + "," +
  "\"reason\":" + canonical_quote(self.reason) + "," +
  "\"run_id\":" + canonical_quote(self.run_id) + "}"
}

///|
fn optional_string_field(
  object : Map[String, @json.Json],
  key : String,
) -> Result[String, String] {
  match object.get(key) {
    None => Ok("")
    Some(@json.Json::String(value)) => Ok(value)
    Some(_) => Err("approval grant field " + key + " has the wrong type")
  }
}

///|
/// Decode a grant. Malformed JSON, unknown keys, missing fields, wrong types
/// and out-of-range values return fixed error strings; no field value is
/// echoed.
pub fn ApprovalGrant::decode(text : String) -> Result[ApprovalGrant, String] {
  let object = match parse_object(text) {
    Ok(value) => value
    Err(_) => return Err("approval grant is not valid JSON")
  }
  let allowed_keys : Array[String] = [
    "command_digest", "decision_id", "expires_at_ms", "format", "format_version",
    "issued_at_ms", "nonce", "policy_hash", "policy_version", "reason",
    "run_id",
  ]
  if object_has_unknown_keys(object, allowed_keys) {
    return Err("approval grant contains an unknown field")
  }
  let format = match required_string(object, "format") {
    Ok(value) => value
    Err(_) => return Err("approval grant is malformed")
  }
  if format != GRANT_FORMAT {
    return Err("approval grant format is not recognized")
  }
  let format_version = match required_int64(object, "format_version") {
    Ok(value) => value
    Err(_) => return Err("approval grant format_version is malformed")
  }
  if format_version != GRANT_FORMAT_VERSION.to_int64() {
    return Err("approval grant has an unknown format_version")
  }
  let run_id = match required_string(object, "run_id") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing run_id")
  }
  let command_digest = match required_string(object, "command_digest") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing command_digest")
  }
  let policy_version = match required_string(object, "policy_version") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing policy_version")
  }
  let policy_hash = match required_string(object, "policy_hash") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing policy_hash")
  }
  let nonce = match required_string(object, "nonce") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing nonce")
  }
  let issued_at_ms = match required_int64(object, "issued_at_ms") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing issued_at_ms")
  }
  let expires_at_ms = match required_int64(object, "expires_at_ms") {
    Ok(value) => value
    Err(_) => return Err("approval grant is missing expires_at_ms")
  }
  let reason = match optional_string_field(object, "reason") {
    Ok(value) => value
    Err(_) => return Err("approval grant reason is malformed")
  }
  let decision_id = match optional_string_field(object, "decision_id") {
    Ok(value) => value
    Err(_) => return Err("approval grant decision_id is malformed")
  }
  ApprovalGrant::new(
    run_id~,
    command_digest~,
    policy_version~,
    policy_hash~,
    nonce~,
    issued_at_ms~,
    expires_at_ms~,
    reason~,
    decision_id~,
  )
}

// ---------------------------------------------------------------------------
// Single-use nonce memory
// ---------------------------------------------------------------------------

///|
/// Bounded record of consumed grant nonces.
///
/// **Restart semantics:** this struct itself is in-memory; the node host
/// serializes it with `encode` before executing an approved request and
/// restores it with `decode` on the next start, so a restart does not forget a
/// consumed nonce. Persistence failure before execution is a refusal, not a
/// reason to run unrecorded.
///
/// Entries are pruned once their grant has expired, so the set only holds
/// nonces that could still be replayed. When the capacity is reached, the
/// entry with the earliest expiry is evicted; that grants a replay window for
/// the evicted nonce, so `capacity` must be far above the expected number of
/// live grants (default 1024 for short-lived approvals).
pub struct ConsumedNonces {
  capacity : Int
  entries : Map[String, Int64]
}

///|
pub fn ConsumedNonces::new(capacity? : Int = 1024) -> ConsumedNonces {
  { capacity: capacity.max(1), entries: Map([]) }
}

///|
pub fn ConsumedNonces::capacity(self : ConsumedNonces) -> Int {
  self.capacity
}

///|
pub fn ConsumedNonces::count(self : ConsumedNonces) -> Int {
  self.entries.length().to_int()
}

///|
pub fn ConsumedNonces::contains(self : ConsumedNonces, nonce : String) -> Bool {
  self.entries.contains(nonce)
}

///|
fn ConsumedNonces::prune(self : ConsumedNonces, now_ms : Int64) -> Unit {
  self.entries.retain(fn(_nonce, expires_at_ms) { expires_at_ms >= now_ms })
}

///|
/// Drop entries whose grant can no longer be replayed (the grant expired).
/// The node calls this after loading its durable nonce file and before it
/// saves a new copy.
pub fn ConsumedNonces::prune_expired(
  self : ConsumedNonces,
  now_ms : Int64,
) -> Unit {
  self.prune(now_ms)
}

///|
fn ConsumedNonces::evict_earliest(self : ConsumedNonces) -> Unit {
  let mut victim = ""
  let mut victim_expiry = 0L
  let mut first = true
  for pair in self.entries.iter() {
    let (nonce, expires_at_ms) = pair
    if first || expires_at_ms < victim_expiry {
      victim = nonce
      victim_expiry = expires_at_ms
      first = false
    }
  }
  if victim != "" {
    self.entries.remove(victim)
  }
}

///|
/// Record a nonce as consumed. Returns false when it was already present.
fn ConsumedNonces::consume(
  self : ConsumedNonces,
  nonce : String,
  expires_at_ms : Int64,
  now_ms : Int64,
) -> Bool {
  self.prune(now_ms)
  if self.entries.contains(nonce) {
    return false
  }
  if self.entries.length().to_int() >= self.capacity {
    self.evict_earliest()
  }
  self.entries.set(nonce, expires_at_ms)
  true
}

///|
/// Canonical encoding for the node's durable consumed-nonce file. The format
/// is `{"entries":[[nonce,expires_at_ms],...]}`; entries are pruned by the
/// caller before saving.
pub fn ConsumedNonces::encode(self : ConsumedNonces) -> String {
  let mut out = "{\"entries\":["
  let mut first = true
  for pair in self.entries.iter() {
    let (nonce, expires_at_ms) = pair
    if !first {
      out = out + ","
    }
    out = out + "[" + canonical_quote(nonce) + "," +
      canonical_int64(expires_at_ms) + "]"
    first = false
  }
  out + "]}"
}

///|
/// Decode a consumed-nonce file. Malformed entries, unknown keys and
/// out-of-range expiries are rejected rather than silently dropped: a corrupt
/// replay memory must fail closed, not forget a nonce that could be replayed.
pub fn ConsumedNonces::decode(
  text : String,
  capacity? : Int = 1024,
) -> Result[ConsumedNonces, String] {
  let parsed = try {
    @json.parse(text)
  } catch {
    _ => return Err("consumed nonce file is not valid JSON")
  }
  let object = match parsed {
    @json.Json::Object(value) => value
    _ => return Err("consumed nonce file is not an object")
  }
  for key in object.keys() {
    if key != "entries" {
      return Err("consumed nonce file contains an unknown field")
    }
  }
  let items = match object.get("entries") {
    Some(@json.Json::Array(value)) => value
    _ => return Err("consumed nonce file is missing entries")
  }
  // Refuse an oversized file rather than evicting entries while loading: a
  // forgotten nonce is a replay window, so a corrupt or oversized store must
  // fail closed.
  if items.length() > capacity.max(1) {
    return Err("consumed nonce file has too many entries")
  }
  let consumed = ConsumedNonces::new(capacity~)
  for item in items {
    let pair = match item {
      @json.Json::Array(value) => value
      _ => return Err("consumed nonce entry is not an array")
    }
    if pair.length() != 2 {
      return Err("consumed nonce entry has the wrong shape")
    }
    let nonce = match pair[0] {
      @json.Json::String(value) => value
      _ => return Err("consumed nonce entry has an invalid nonce")
    }
    if nonce.length() < 16 || nonce.length() > 128 || !is_token_text(nonce) {
      return Err("consumed nonce entry has an invalid nonce")
    }
    let expires_at_ms = match pair[1] {
      @json.Json::Number(value, ..) =>
        if value < 0.0 || value > 10_000_000_000_000.0 ||
          value != value.to_int64().to_double() {
          return Err("consumed nonce entry has an invalid expiry")
        } else {
          value.to_int64()
        }
      _ => return Err("consumed nonce entry has an invalid expiry")
    }
    if !consumed.consume(nonce, expires_at_ms, 0L) {
      return Err("consumed nonce file contains a duplicate nonce")
    }
  }
  Ok(consumed)
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

///|
pub(all) enum GrantError {
  MalformedGrant
  RunMismatch
  DigestMismatch
  PolicyUnavailable
  PolicyVersionMismatch
  PolicyHashMismatch
  PolicyStale
  NotYetValid
  Expired
  TtlTooLong
  ReplayedNonce
}

///|
pub fn GrantError::label(self : GrantError) -> String {
  match self {
    MalformedGrant => "malformed_grant"
    RunMismatch => "run_mismatch"
    DigestMismatch => "digest_mismatch"
    PolicyUnavailable => "policy_unavailable"
    PolicyVersionMismatch => "policy_version_mismatch"
    PolicyHashMismatch => "policy_hash_mismatch"
    PolicyStale => "policy_stale"
    NotYetValid => "not_yet_valid"
    Expired => "expired"
    TtlTooLong => "ttl_too_long"
    ReplayedNonce => "replayed_nonce"
  }
}

///|
/// Human-readable text safe for events and logs: fixed strings only, no
/// nonce, digest or policy token is echoed.
pub fn GrantError::message(self : GrantError) -> String {
  match self {
    MalformedGrant => "approval grant is malformed"
    RunMismatch => "approval grant was issued for a different run"
    DigestMismatch => "approval grant is bound to a different command digest"
    PolicyUnavailable => "no policy snapshot is available to verify the grant"
    PolicyVersionMismatch =>
      "approval grant names a different or unknown policy version"
    PolicyHashMismatch =>
      "approval grant names a different policy snapshot hash"
    PolicyStale => "approval grant's policy snapshot is stale"
    NotYetValid => "approval grant is not valid yet"
    Expired => "approval grant has expired"
    TtlTooLong => "approval grant lifetime exceeds the maximum"
    ReplayedNonce => "approval grant nonce was already consumed"
  }
}

///|
fn grant_is_structurally_valid(grant : ApprovalGrant) -> Bool {
  match validate_grant_fields(
    grant.run_id,
    grant.command_digest,
    grant.policy_version,
    grant.policy_hash,
    grant.nonce,
    grant.issued_at_ms,
    grant.expires_at_ms,
    grant.reason,
    grant.decision_id,
  ) {
    Some(_) => false
    None => true
  }
}

///|
/// Verify that a grant authorizes exactly this run and this digest under the
/// current policy. Does not consume the nonce; use `verify_and_consume` at
/// the execution boundary.
pub fn verify_grant(
  grant : ApprovalGrant,
  expected_run_id : String,
  expected_digest : String,
  snapshot : PolicySnapshot?,
  now_ms : Int64,
) -> Result[Unit, GrantError] {
  if !grant_is_structurally_valid(grant) {
    return Err(MalformedGrant)
  }
  if grant.run_id != expected_run_id {
    return Err(RunMismatch)
  }
  if grant.command_digest != expected_digest {
    return Err(DigestMismatch)
  }
  let policy = match snapshot {
    Some(value) => value
    None => return Err(PolicyUnavailable)
  }
  if grant.policy_version != policy.version {
    return Err(PolicyVersionMismatch)
  }
  if grant.policy_hash != policy.content_hash {
    return Err(PolicyHashMismatch)
  }
  if !policy.is_fresh(now_ms) {
    return Err(PolicyStale)
  }
  if now_ms > grant.expires_at_ms {
    return Err(Expired)
  }
  if now_ms + GRANT_CLOCK_SKEW_MS < grant.issued_at_ms {
    return Err(NotYetValid)
  }
  if grant.expires_at_ms - grant.issued_at_ms > MAX_GRANT_TTL_MS {
    return Err(TtlTooLong)
  }
  Ok(())
}

///|
/// Verify and consume in one step. The nonce is consumed only after every
/// check passes, so a failed attempt does not burn a valid grant.
pub fn verify_and_consume(
  grant : ApprovalGrant,
  expected_run_id : String,
  expected_digest : String,
  snapshot : PolicySnapshot?,
  now_ms : Int64,
  consumed : ConsumedNonces,
) -> Result[Unit, GrantError] {
  match verify_grant(grant, expected_run_id, expected_digest, snapshot, now_ms) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if !consumed.consume(grant.nonce, grant.expires_at_ms, now_ms) {
    return Err(ReplayedNonce)
  }
  Ok(())
}

///|
/// Convenience for the execution boundary: bind the grant to the exact
/// request the runtime is about to run.
pub fn verify_grant_for_request(
  grant : ApprovalGrant,
  run_id : String,
  request : ExecutionRequest,
  snapshot : PolicySnapshot?,
  now_ms : Int64,
) -> Result[Unit, GrantError] {
  verify_grant(grant, run_id, request.digest(), snapshot, now_ms)
}

///|
pub fn verify_and_consume_for_request(
  grant : ApprovalGrant,
  run_id : String,
  request : ExecutionRequest,
  snapshot : PolicySnapshot?,
  now_ms : Int64,
  consumed : ConsumedNonces,
) -> Result[Unit, GrantError] {
  verify_and_consume(
    grant,
    run_id,
    request.digest(),
    snapshot,
    now_ms,
    consumed,
  )
}
