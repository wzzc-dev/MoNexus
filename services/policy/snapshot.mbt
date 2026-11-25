///|
/// Versioned, hash-bound policy snapshot issued by the primary (ADR-0012 §5).
///
/// Wire format: one JSON object with exactly these top-level fields:
///
/// ```json
/// {
///   "format": "monexus.policy.snapshot",
///   "format_version": 1,
///   "version": "pol-2026-11-26.1",
///   "issued_at_ms": 1764000000000,
///   "expires_at_ms": 1764003600000,
///   "hash": "<64 lowercase hex>",
///   "rules": { ... }
/// }
/// ```
///
/// `hash` is the SHA-256 of the canonical body (see `canonical_body` below);
/// the `hash` field itself is excluded. Decoding rejects malformed JSON,
/// unknown format versions, unknown keys, invalid field types, out-of-range
/// timestamps and any content/hash mismatch. There is deliberately no
/// default-allow snapshot: a failed decode yields an error, and the caller
/// must treat the policy as unavailable.

///|
pub const POLICY_FORMAT : String = "monexus.policy.snapshot"

///|
pub const POLICY_FORMAT_VERSION : Int = 1

///|
pub const POLICY_SNAPSHOT_DOMAIN : String = "monexus.policy.snapshot.v1"

///|
/// Clock skew tolerated when deciding whether a snapshot is fresh.
pub const POLICY_CLOCK_SKEW_MS : Int64 = 60_000L

///|
/// The rules carried by a snapshot. Arrays are sorted and de-duplicated on
/// construction, so the content hash is independent of declaration order.
///
/// * `allow_read_only` — permit low-risk read-only exec/fs/git operations
///   locally, even when the snapshot is stale or the primary is unreachable.
/// * `allowed_operations` — operation labels (`fs.write`, `git.write`, ...)
///   the primary permits locally while the snapshot is fresh and reachable.
/// * `allowed_argv_prefixes` — argv text prefixes permitted locally (for
///   example `"moon test"`), matched against the lowercased joined argv.
/// * `denied_operations` / `denied_patterns` — explicit deny rules. A deny
///   applies even when the primary is unreachable.
/// * `high_risk_operations` / `high_risk_patterns` — additional high-risk
///   categories on top of the built-in ones.
/// * `env_allowlist` — environment variable names the runtime may request.
///   An empty list permits no names. Values are never part of a request.
pub(all) struct PolicyRules {
  allow_read_only : Bool
  allowed_operations : Array[String]
  allowed_argv_prefixes : Array[String]
  denied_operations : Array[String]
  denied_patterns : Array[String]
  high_risk_operations : Array[String]
  high_risk_patterns : Array[String]
  env_allowlist : Array[String]
}

///|
pub fn PolicyRules::new(
  allow_read_only~ : Bool = false,
  allowed_operations~ : Array[String] = [],
  allowed_argv_prefixes~ : Array[String] = [],
  denied_operations~ : Array[String] = [],
  denied_patterns~ : Array[String] = [],
  high_risk_operations~ : Array[String] = [],
  high_risk_patterns~ : Array[String] = [],
  env_allowlist~ : Array[String] = [],
) -> PolicyRules {
  {
    allow_read_only,
    allowed_operations: sorted_unique(allowed_operations),
    allowed_argv_prefixes: sorted_unique(allowed_argv_prefixes),
    denied_operations: sorted_unique(denied_operations),
    denied_patterns: sorted_unique(denied_patterns),
    high_risk_operations: sorted_unique(high_risk_operations),
    high_risk_patterns: sorted_unique(high_risk_patterns),
    env_allowlist: sorted_unique(env_allowlist),
  }
}

///|
fn PolicyRules::canonical(self : PolicyRules) -> String {
  "{" +
  "\"allow_read_only\":" + canonical_bool(self.allow_read_only) + "," +
  "\"allowed_argv_prefixes\":" +
  canonical_string_array(self.allowed_argv_prefixes) + "," +
  "\"allowed_operations\":" +
  canonical_string_array(self.allowed_operations) + "," +
  "\"denied_operations\":" +
  canonical_string_array(self.denied_operations) + "," +
  "\"denied_patterns\":" + canonical_string_array(self.denied_patterns) +
  "," +
  "\"env_allowlist\":" + canonical_string_array(self.env_allowlist) + "," +
  "\"high_risk_operations\":" +
  canonical_string_array(self.high_risk_operations) + "," +
  "\"high_risk_patterns\":" +
  canonical_string_array(self.high_risk_patterns) + "}"
}

///|
pub(all) struct PolicySnapshot {
  version : String
  issued_at_ms : Int64
  expires_at_ms : Int64
  content_hash : String
  rules : PolicyRules
}

///|
/// Canonical body that the content hash covers. Keys are emitted in fixed
/// order; the `hash` field is not part of it.
fn canonical_body(
  version : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
  rules : PolicyRules,
) -> String {
  POLICY_SNAPSHOT_DOMAIN + "\n" + "{" +
  "\"expires_at_ms\":" + canonical_int64(expires_at_ms) + "," +
  "\"format\":" + canonical_quote(POLICY_FORMAT) + "," +
  "\"format_version\":" + POLICY_FORMAT_VERSION.to_string() + "," +
  "\"issued_at_ms\":" + canonical_int64(issued_at_ms) + "," +
  "\"rules\":" + rules.canonical() + "," +
  "\"version\":" + canonical_quote(version) + "}"
}

///|
fn validate_version(version : String) -> String? {
  if version.length() == 0 || version.length() > 128 ||
    !is_token_text(version) {
    return Some("policy snapshot version is empty or invalid")
  }
  None
}

///|
fn validate_timestamp_range(
  issued_at_ms : Int64,
  expires_at_ms : Int64,
) -> String? {
  if issued_at_ms < 0L || expires_at_ms <= issued_at_ms {
    return Some("policy snapshot time range is invalid")
  }
  None
}

///|
fn validate_rule_texts(values : Array[String], field : String) -> String? {
  for value in values {
    if value == "" || value.length() > 256 || !is_printable_text(value) {
      return Some("policy snapshot rule " + field + " has an invalid entry")
    }
  }
  None
}

///|
fn PolicyRules::validate(self : PolicyRules) -> String? {
  let fields : Array[(String, Array[String])] = [
    ("allowed_operations", self.allowed_operations),
    ("allowed_argv_prefixes", self.allowed_argv_prefixes),
    ("denied_operations", self.denied_operations),
    ("denied_patterns", self.denied_patterns),
    ("high_risk_operations", self.high_risk_operations),
    ("high_risk_patterns", self.high_risk_patterns),
  ]
  for entry in fields {
    let (field, values) = entry
    match validate_rule_texts(values, field) {
      Some(reason) => return Some(reason)
      None => ()
    }
  }
  for name in self.env_allowlist {
    if !is_env_name(name) || name.length() > 128 {
      return Some("policy snapshot env allowlist has an invalid name")
    }
  }
  None
}

///|
/// Build a snapshot and compute its content hash. Fails on an invalid version,
/// an inverted/negative time range or invalid rule text.
pub fn PolicySnapshot::new(
  version~ : String,
  issued_at_ms~ : Int64,
  expires_at_ms~ : Int64,
  rules~ : PolicyRules,
) -> Result[PolicySnapshot, String] {
  match validate_version(version) {
    Some(reason) => return Err(reason)
    None => ()
  }
  match validate_timestamp_range(issued_at_ms, expires_at_ms) {
    Some(reason) => return Err(reason)
    None => ()
  }
  match rules.validate() {
    Some(reason) => return Err(reason)
    None => ()
  }
  let hash = sha256_hex(
    canonical_body(version, issued_at_ms, expires_at_ms, rules),
  )
  Ok({ version, issued_at_ms, expires_at_ms, content_hash: hash, rules })
}

///|
pub fn PolicySnapshot::body_hash(
  version : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
  rules : PolicyRules,
) -> String {
  sha256_hex(canonical_body(version, issued_at_ms, expires_at_ms, rules))
}

///|
/// Encode the snapshot as JSON including its content hash. Round-tripping
/// `encode` through `decode` yields the same hash.
pub fn PolicySnapshot::encode(self : PolicySnapshot) -> String {
  "{" +
  "\"expires_at_ms\":" + canonical_int64(self.expires_at_ms) + "," +
  "\"format\":" + canonical_quote(POLICY_FORMAT) + "," +
  "\"format_version\":" + POLICY_FORMAT_VERSION.to_string() + "," +
  "\"hash\":" + canonical_quote(self.content_hash) + "," +
  "\"issued_at_ms\":" + canonical_int64(self.issued_at_ms) + "," +
  "\"rules\":" + self.rules.canonical() + "," +
  "\"version\":" + canonical_quote(self.version) + "}"
}

///|
/// Fresh when `now_ms` is inside [issued - skew, expires]. A snapshot whose
/// issue time is further in the future than the skew allowance is not fresh.
pub fn PolicySnapshot::is_fresh(self : PolicySnapshot, now_ms : Int64) -> Bool {
  now_ms + POLICY_CLOCK_SKEW_MS >= self.issued_at_ms &&
  now_ms <= self.expires_at_ms
}

///|
pub fn PolicySnapshot::hash_matches(
  self : PolicySnapshot,
  expected_hash : String,
) -> Bool {
  self.content_hash == expected_hash.to_lower()
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

///|
fn parse_object(text : String) -> Result[Map[String, @json.Json], String] {
  let parsed = try {
    @json.parse(text)
  } catch {
    _ => return Err("policy snapshot is not valid JSON")
  }
  match parsed {
    @json.Json::Object(object) => Ok(object)
    _ => Err("policy snapshot is not a JSON object")
  }
}

///|
fn object_has_unknown_keys(
  object : Map[String, @json.Json],
  allowed : Array[String],
) -> Bool {
  for key in object.keys() {
    if !allowed.contains(key) {
      return true
    }
  }
  false
}

///|
fn required_string(
  object : Map[String, @json.Json],
  key : String,
) -> Result[String, String] {
  match object.get(key) {
    Some(@json.Json::String(value)) => Ok(value)
    Some(_) => Err("policy snapshot field " + key + " has the wrong type")
    None => Err("policy snapshot is missing field " + key)
  }
}

///|
fn required_int64(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Int64, String] {
  match object.get(key) {
    Some(@json.Json::Number(value, ..)) =>
      if value < 0.0 || value > 10_000_000_000_000.0 ||
        value != value.to_int64().to_double() {
        Err("policy snapshot field " + key + " is not a valid timestamp")
      } else {
        Ok(value.to_int64())
      }
    Some(_) => Err("policy snapshot field " + key + " has the wrong type")
    None => Err("policy snapshot is missing field " + key)
  }
}

///|
fn optional_bool(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Bool, String] {
  match object.get(key) {
    None => Ok(false)
    Some(@json.Json::True) => Ok(true)
    Some(@json.Json::False) => Ok(false)
    Some(_) => Err("policy snapshot field " + key + " has the wrong type")
  }
}

///|
fn optional_string_array(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Array[String], String] {
  match object.get(key) {
    None => Ok([])
    Some(@json.Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          @json.Json::String(value) => out.push(value)
          _ =>
            return Err(
              "policy snapshot field " + key + " must be an array of strings",
            )
        }
      }
      Ok(out)
    }
    Some(_) => Err("policy snapshot field " + key + " must be an array")
  }
}

///|
fn rules_from_json(
  json : @json.Json,
) -> Result[PolicyRules, String] {
  let object = match json {
    @json.Json::Object(value) => value
    _ => return Err("policy snapshot rules are not an object")
  }
  let allowed_keys : Array[String] = [
    "allow_read_only", "allowed_argv_prefixes", "allowed_operations",
    "denied_operations", "denied_patterns", "env_allowlist",
    "high_risk_operations", "high_risk_patterns",
  ]
  if object_has_unknown_keys(object, allowed_keys) {
    return Err("policy snapshot rules contain an unknown field")
  }
  let allow_read_only = match optional_bool(object, "allow_read_only") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let allowed_operations = match optional_string_array(
    object,
    "allowed_operations",
  ) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let allowed_argv_prefixes = match optional_string_array(
    object,
    "allowed_argv_prefixes",
  ) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let denied_operations = match optional_string_array(
    object,
    "denied_operations",
  ) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let denied_patterns = match optional_string_array(object, "denied_patterns") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let high_risk_operations = match optional_string_array(
    object,
    "high_risk_operations",
  ) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let high_risk_patterns = match optional_string_array(
    object,
    "high_risk_patterns",
  ) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let env_allowlist = match optional_string_array(object, "env_allowlist") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  Ok(PolicyRules::new(
    allow_read_only~,
    allowed_operations~,
    allowed_argv_prefixes~,
    denied_operations~,
    denied_patterns~,
    high_risk_operations~,
    high_risk_patterns~,
    env_allowlist~,
  ))
}

///|
/// Whether a string is 64 lowercase hex characters, the only accepted form of
/// a content hash or hex digest body.
fn is_hex64(text : String) -> Bool {
  if text.length() != 64 {
    return false
  }
  for ch in text {
    let ok = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
    if !ok {
      return false
    }
  }
  true
}

///|
/// Decode and fully validate a stored snapshot. Hash mismatch, unknown
/// format version, unknown keys and malformed/invalid content all return an
/// error; the caller must not fall back to a permissive policy.
pub fn PolicySnapshot::decode(text : String) -> Result[PolicySnapshot, String] {
  let object = match parse_object(text) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let allowed_keys : Array[String] = [
    "expires_at_ms", "format", "format_version", "hash", "issued_at_ms",
    "rules", "version",
  ]
  if object_has_unknown_keys(object, allowed_keys) {
    return Err("policy snapshot contains an unknown field")
  }
  let format = match required_string(object, "format") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if format != POLICY_FORMAT {
    return Err("policy snapshot format is not recognized")
  }
  let format_version = match required_int64(object, "format_version") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if format_version != POLICY_FORMAT_VERSION.to_int64() {
    return Err(
      "policy snapshot has unknown format_version " + format_version.to_string(),
    )
  }
  let version = match required_string(object, "version") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let issued_at_ms = match required_int64(object, "issued_at_ms") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let expires_at_ms = match required_int64(object, "expires_at_ms") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let hash = match required_string(object, "hash") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if !is_hex64(hash) {
    return Err("policy snapshot content hash is malformed")
  }
  let rules_json = match object.get("rules") {
    Some(value) => value
    None => return Err("policy snapshot is missing field rules")
  }
  let rules = match rules_from_json(rules_json) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let snapshot = match PolicySnapshot::new(
    version~,
    issued_at_ms~,
    expires_at_ms~,
    rules~,
  ) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if snapshot.content_hash != hash {
    return Err("policy snapshot content hash mismatch")
  }
  Ok(snapshot)
}

///|
/// Decode with an additional pinned hash (for example the hash delivered over
/// the authenticated runtime channel). A mismatch is a hard error.
pub fn PolicySnapshot::decode_pinned(
  text : String,
  expected_hash : String,
) -> Result[PolicySnapshot, String] {
  let snapshot = match PolicySnapshot::decode(text) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if !snapshot.hash_matches(expected_hash) {
    return Err("policy snapshot does not match the pinned hash")
  }
  Ok(snapshot)
}
