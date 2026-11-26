///|
/// Signed webhook contracts (ADR-0014 §4, A3.1).
///
/// Pure pieces only: header validation, the exact signing string, HMAC-SHA256,
/// constant-time comparison, payload shaping and response JSON. The host owns
/// the HTTP connection, token buckets, concurrency gate and secret files.

///|
pub const TRIGGER_WEBHOOK_PATH_PREFIX : String = "/hooks/"

///|
pub const TRIGGER_WEBHOOK_SIGNING_VERSION : String = "monexus-webhook-v1"

///|
pub const TRIGGER_WEBHOOK_KEY_ID_PREFIX : String = "whk_"

///|
pub const TRIGGER_WEBHOOK_KEY_ID_LENGTH : Int = 30

///|
pub const TRIGGER_WEBHOOK_SIGNATURE_PREFIX : String = "v1="

///|
pub const TRIGGER_WEBHOOK_SIGNATURE_HEX_LENGTH : Int = 64

///|
pub const TRIGGER_WEBHOOK_HEADER_KEY_ID : String = "X-Monexus-Key-Id"

///|
pub const TRIGGER_WEBHOOK_HEADER_TIMESTAMP : String = "X-Monexus-Timestamp"

///|
pub const TRIGGER_WEBHOOK_HEADER_NONCE : String = "X-Monexus-Nonce"

///|
pub const TRIGGER_WEBHOOK_HEADER_DELIVERY_ID : String = "X-Monexus-Delivery-Id"

///|
pub const TRIGGER_WEBHOOK_HEADER_SIGNATURE : String = "X-Monexus-Signature"

///|
pub const TRIGGER_WEBHOOK_BODY_DEFAULT : Int = 65_536

///|
pub const TRIGGER_WEBHOOK_BODY_CAP : Int = 262_144

///|
pub const TRIGGER_WEBHOOK_FRESHNESS_DEFAULT_S : Int = 300

///|
pub const TRIGGER_WEBHOOK_FRESHNESS_CAP_S : Int = 900

///|
pub const TRIGGER_WEBHOOK_NONCE_MIN : Int = 16

///|
pub const TRIGGER_WEBHOOK_NONCE_MAX : Int = 64

///|
pub const TRIGGER_WEBHOOK_DELIVERY_MIN : Int = 1

///|
pub const TRIGGER_WEBHOOK_DELIVERY_MAX : Int = 64

///|
pub const TRIGGER_WEBHOOK_NONCE_TTL_GRACE_MS : Int64 = 120_000

///|
pub const TRIGGER_WEBHOOK_PAYLOAD_FIELDS_MAX : Int = 8

///|
pub const TRIGGER_WEBHOOK_PAYLOAD_SEGMENTS_MAX : Int = 2

///|
pub const TRIGGER_WEBHOOK_PAYLOAD_VALUE_MAX : Int = 512

///|
pub const TRIGGER_WEBHOOK_SHAPE_DEPTH_MAX : Int = 3

///|
pub const TRIGGER_WEBHOOK_OBJECT_KEY_MAX : Int = 64

///|
pub const TRIGGER_WEBHOOK_RATE_TRIGGER_PER_MIN : Int = 60

///|
pub const TRIGGER_WEBHOOK_RATE_TRIGGER_BURST : Int = 20

///|
pub const TRIGGER_WEBHOOK_RATE_TRIGGER_CAP : Int = 600

///|
pub const TRIGGER_WEBHOOK_RATE_KEY_PER_MIN : Int = 120

///|
pub const TRIGGER_WEBHOOK_RATE_KEY_BURST : Int = 40

///|
pub const TRIGGER_WEBHOOK_RATE_KEY_CAP : Int = 1_200

///|
pub const TRIGGER_WEBHOOK_RATE_GLOBAL_PER_MIN : Int = 300

///|
pub const TRIGGER_WEBHOOK_RATE_GLOBAL_BURST : Int = 100

///|
pub const TRIGGER_WEBHOOK_RATE_GLOBAL_CAP : Int = 3_000

///|
pub const TRIGGER_WEBHOOK_CONCURRENCY_MAX : Int = 8

///|
pub const TRIGGER_WEBHOOK_READ_TIMEOUT_DEFAULT_MS : Int = 5_000

///|
pub const TRIGGER_WEBHOOK_READ_TIMEOUT_CAP_MS : Int = 10_000

///|
/// At most this many active signing keys may be bound to one trigger. Key
/// rotation needs a brief overlap, not an unbounded key set.
pub const TRIGGER_WEBHOOK_KEYS_MAX : Int = 8

///|
/// Extract `<trigger_id>` from `/hooks/<trigger_id>`. A nested path, an empty
/// id or a non-token character is rejected before any store lookup.
pub fn trigger_webhook_path_trigger_id(path : String) -> Result[String, String] {
  if !path.has_prefix(TRIGGER_WEBHOOK_PATH_PREFIX) {
    return Err("not a webhook path")
  }
  let trigger_id = path.substring(start=TRIGGER_WEBHOOK_PATH_PREFIX.length())
  if trigger_id.length() == 0 || trigger_id.length() > 64 {
    return Err("invalid webhook path")
  }
  for ch in trigger_id {
    let allowed = (ch >= '0' && ch <= '9') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      ch == '_' ||
      ch == '-'
    if !allowed {
      return Err("invalid webhook path")
    }
  }
  Ok(trigger_id)
}

///|
/// A key object bound to exactly one trigger. `secret_path` points at the
/// owner-only secret file; the secret itself is never stored in SQLite, an
/// event or a log line (ADR-0014 §4.3).
pub(all) struct WebhookKeyRecord {
  key_id : String
  trigger_id : String
  org_id : String
  name : String
  secret_path : String
  enabled : Bool
  created_at : String
  revoked_at : String
  expires_at : String
  last_used_at : String
}

///|
pub fn WebhookKeyRecord::new(
  key_id~ : String,
  trigger_id~ : String,
  org_id~ : String = "",
  name~ : String = "",
  secret_path~ : String = "",
  enabled~ : Bool = true,
  created_at~ : String = "",
  revoked_at~ : String = "",
  expires_at~ : String = "",
  last_used_at~ : String = "",
) -> WebhookKeyRecord {
  {
    key_id,
    trigger_id,
    org_id,
    name,
    secret_path,
    enabled,
    created_at,
    revoked_at,
    expires_at,
    last_used_at,
  }
}

///|
/// RPC/audit view. `secret_path` is intentionally absent so a `list`/`get`
/// never even points at the file; only `trigger.source.add` returns the
/// secret, and only once.
pub fn webhook_key_record_to_json(record : WebhookKeyRecord) -> @json.Json {
  json_object([
    ("key_id", json_string(record.key_id)),
    ("trigger_id", json_string(record.trigger_id)),
    ("org_id", json_string(record.org_id)),
    ("name", json_string(record.name)),
    ("enabled", json_bool(record.enabled)),
    ("created_at", json_string(record.created_at)),
    ("revoked_at", json_string(record.revoked_at)),
    ("expires_at", json_string(record.expires_at)),
    ("last_used_at", json_string(record.last_used_at)),
  ])
}

///|
/// A key is usable only while enabled, not revoked, and not expired.
pub fn webhook_key_active(record : WebhookKeyRecord, now_ms : Int64) -> Bool {
  if !record.enabled || record.revoked_at != "" {
    return false
  }
  if record.expires_at == "" {
    return true
  }
  match trigger_parse_rfc3339_ms(record.expires_at) {
    Some(expires_ms) => now_ms < expires_ms
    None => false
  }
}

///|
/// Location of the secret file, relative to the host state directory
/// (normally `~/.monexus`). The directory is 0700 and the file 0600.
pub fn webhook_secret_relative_path(key_id : String) -> String {
  "secrets/webhook/" + key_id + ".key"
}

///|
pub fn webhook_secret_hex(secret : BytesView) -> String {
  @hex.encode(secret)
}

///|
/// Secrets are exactly 256 bits (64 hex characters). Short or malformed files
/// fail closed instead of authenticating with a truncated key.
pub fn webhook_secret_from_hex(text : String) -> Bytes? {
  let trimmed = text.trim().to_owned()
  if !webhook_is_hex(trimmed, 64) {
    return None
  }
  let decoded = @hex.decode(trimmed) catch { _ => return None }
  if decoded.length() != 32 {
    return None
  }
  Some(decoded)
}

///|
pub fn webhook_is_hex(text : String, length : Int) -> Bool {
  if text.length() != length {
    return false
  }
  for ch in text {
    let ok = (ch >= '0' && ch <= '9') ||
      (ch >= 'a' && ch <= 'f') ||
      (ch >= 'A' && ch <= 'F')
    if !ok {
      return false
    }
  }
  true
}

///|
/// `whk_` plus exactly one ULID. Rejecting other shapes keeps path traversal
/// and arbitrary header text away from the secret file name.
pub fn webhook_key_id_valid(key_id : String) -> Bool {
  if key_id.length() != TRIGGER_WEBHOOK_KEY_ID_LENGTH ||
    !key_id.has_prefix(TRIGGER_WEBHOOK_KEY_ID_PREFIX) {
    return false
  }
  for index in TRIGGER_WEBHOOK_KEY_ID_PREFIX.length()..<key_id.length() {
    let ch = match key_id.get_char(index) {
      Some(value) => value
      None => return false
    }
    let allowed = (ch >= '0' && ch <= '9') ||
      (ch >= 'A' && ch <= 'Z')
    if !allowed || ch == 'I' || ch == 'L' || ch == 'O' || ch == 'U' {
      return false
    }
  }
  true
}

///|
/// `[A-Za-z0-9_-]{16,64}`. A retry must reuse the nonce with the same body.
pub fn webhook_nonce_valid(nonce : String) -> Bool {
  if nonce.length() < TRIGGER_WEBHOOK_NONCE_MIN ||
    nonce.length() > TRIGGER_WEBHOOK_NONCE_MAX {
    return false
  }
  for ch in nonce {
    let allowed = (ch >= '0' && ch <= '9') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      ch == '_' ||
      ch == '-'
    if !allowed {
      return false
    }
  }
  true
}

///|
/// `[A-Za-z0-9._-]{1,64}`.
pub fn webhook_delivery_id_valid(delivery_id : String) -> Bool {
  if delivery_id.length() < TRIGGER_WEBHOOK_DELIVERY_MIN ||
    delivery_id.length() > TRIGGER_WEBHOOK_DELIVERY_MAX {
    return false
  }
  for ch in delivery_id {
    let allowed = (ch >= '0' && ch <= '9') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      ch == '.' ||
      ch == '_' ||
      ch == '-'
    if !allowed {
      return false
    }
  }
  true
}

///|
/// Unix milliseconds or RFC3339 UTC. The caller signs the raw header text,
/// not this parsed value, so a sender that signs `2026-...Z` keeps working.
pub fn webhook_timestamp_parse_ms(text : String) -> Int64? {
  let value = text.trim().to_owned()
  if value == "" || value.length() > 19 {
    if value == "" {
      return None
    }
    // RFC3339 is longer than 19 characters; fall through to it below.
  }
  let mut digits = value.length() > 0
  for ch in value {
    if ch < '0' || ch > '9' {
      digits = false
      break
    }
  }
  if digits {
    let parsed = @string.parse_int64(value) catch { _ => return None }
    return Some(parsed)
  }
  trigger_parse_rfc3339_ms(value)
}

///|
/// ±window, in milliseconds. A timestamp too far in the future is rejected
/// just like an old one, so a skewed sender cannot pre-mint replays.
pub fn webhook_timestamp_fresh(
  timestamp_ms : Int64,
  now_ms : Int64,
  window_s : Int,
) -> Bool {
  let window_ms = webhook_freshness_window_s(window_s).to_int64() * 1000L
  let difference = if timestamp_ms > now_ms {
    timestamp_ms - now_ms
  } else {
    now_ms - timestamp_ms
  }
  difference <= window_ms
}

///|
/// Clamp the configured freshness window to the adr cap (900s), defaulting
/// to 300s for unset or non-positive values.
pub fn webhook_freshness_window_s(configured_s : Int) -> Int {
  if configured_s <= 0 {
    TRIGGER_WEBHOOK_FRESHNESS_DEFAULT_S
  } else {
    configured_s.min(TRIGGER_WEBHOOK_FRESHNESS_CAP_S)
  }
}

///|
pub fn webhook_body_limit(configured : Int) -> Int {
  if configured <= 0 {
    TRIGGER_WEBHOOK_BODY_DEFAULT
  } else {
    configured.min(TRIGGER_WEBHOOK_BODY_CAP)
  }
}

///|
pub fn webhook_read_timeout_ms(configured : Int) -> Int {
  if configured <= 0 {
    TRIGGER_WEBHOOK_READ_TIMEOUT_DEFAULT_MS
  } else {
    configured.min(TRIGGER_WEBHOOK_READ_TIMEOUT_CAP_MS)
  }
}

///|
/// Exact bytes from ADR-0014 §4.2. No JSON canonicalization is applied; the
/// raw body is appended after the final newline.
pub fn webhook_signing_bytes(
  key_id : String,
  trigger_id : String,
  timestamp : String,
  nonce : String,
  raw_body : BytesView,
) -> Bytes {
  let head = TRIGGER_WEBHOOK_SIGNING_VERSION + "\n" +
    key_id + "\n" + trigger_id + "\n" + timestamp + "\n" + nonce + "\n"
  let encoded = @utf8.encode(head)
  let total = encoded.length() + raw_body.length()
  let out : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  for index in 0..<encoded.length() {
    out[index] = encoded[index]
  }
  for index in 0..<raw_body.length() {
    out[encoded.length() + index] = raw_body[index]
  }
  Bytes::from_fixedarray(out)
}

///|
/// `v1=<lowercase hex>` for the provided secret and signing bytes.
pub fn webhook_signature_hex(secret : BytesView, signing : BytesView) -> String {
  let digest = @crypto.hmac(@crypto.SHA256::new(), secret, signing)
  TRIGGER_WEBHOOK_SIGNATURE_PREFIX +
  @hex.encode(Bytes::from_fixedarray(digest).exact_view())
}

///|
/// Compute the signature directly from the request fields.
pub fn webhook_sign(
  secret : BytesView,
  key_id : String,
  trigger_id : String,
  timestamp : String,
  nonce : String,
  raw_body : BytesView,
) -> String {
  webhook_signature_hex(
    secret,
    webhook_signing_bytes(key_id, trigger_id, timestamp, nonce, raw_body),
  )
}

///|
/// Constant-time comparison of two `v1=<hex>` signatures. Length differences
/// and malformed hex fail closed; equal-length values never stop early.
pub fn webhook_signature_matches(provided : String, expected : String) -> Bool {
  if provided.length() != expected.length() {
    return false
  }
  let left = webhook_signature_hex_part(provided)
  let right = webhook_signature_hex_part(expected)
  match (left, right) {
    (Some(a), Some(b)) => {
      let a_bytes = @hex.decode(a) catch { _ => return false }
      let b_bytes = @hex.decode(b) catch { _ => return false }
      if a_bytes.length() != b_bytes.length() {
        return false
      }
      let mut difference = 0
      for index in 0..<a_bytes.length() {
        difference = difference |
          (a_bytes[index].to_int() ^ b_bytes[index].to_int())
      }
      difference == 0
    }
    _ => false
  }
}

///|
fn webhook_signature_hex_part(signature : String) -> String? {
  if !signature.has_prefix(TRIGGER_WEBHOOK_SIGNATURE_PREFIX) {
    return None
  }
  let hex = signature.substring(
    start=TRIGGER_WEBHOOK_SIGNATURE_PREFIX.length(),
  )
  if !webhook_is_hex(hex, TRIGGER_WEBHOOK_SIGNATURE_HEX_LENGTH) {
    return None
  }
  Some(hex)
}

///|
/// `delivery:<id>` when the sender supplied one, otherwise `nonce:<nonce>`.
/// `(trigger_id, fire_key)` is unique, so a retry with a new timestamp/nonce
/// but the same delivery id still maps to the same Task (ADR-0014 §4.4).
pub fn webhook_fire_key(delivery_id : String, nonce : String) -> String {
  if delivery_id != "" {
    "delivery:" + delivery_id
  } else {
    "nonce:" + nonce
  }
}

///|
pub fn webhook_nonce_expiry_ms(
  now_ms : Int64,
  window_s : Int,
) -> Int64 {
  now_ms + webhook_freshness_window_s(window_s).to_int64() * 1000L +
  TRIGGER_WEBHOOK_NONCE_TTL_GRACE_MS
}

///|
pub fn webhook_body_sha256_hex(body : Bytes) -> String {
  trigger_sha256_bytes_hex(body)
}

// ---------------------------------------------------------------------------
// Response bodies
// ---------------------------------------------------------------------------

///|
/// `{"accepted":true,"trigger_id":...,"task_id":...,"duplicate":false}`.
pub fn webhook_accepted_response(
  trigger_id : String,
  task_id : String,
  duplicate : Bool,
) -> @json.Json {
  json_object([
    ("accepted", json_bool(true)),
    ("trigger_id", json_string(trigger_id)),
    ("task_id", json_string(task_id)),
    ("duplicate", json_bool(duplicate)),
  ])
}

///|
/// Uniform 401 body. It deliberately says nothing about which check failed.
pub fn webhook_unauthorized_response() -> @json.Json {
  json_object([("accepted", json_bool(false)), ("error", json_string("unauthorized"))])
}

///|
/// Non-authentication failures (400/413/429) may name the reason category;
/// they never echo headers, body or configuration.
pub fn webhook_error_response(reason : String) -> @json.Json {
  json_object([("accepted", json_bool(false)), ("error", json_string(reason))])
}

// ---------------------------------------------------------------------------
// Untrusted payload
// ---------------------------------------------------------------------------

///|
/// Strict body shape from ADR-0014 §4.5: top-level object, keys ≤64 chars,
/// scalars or at most three nesting levels. Unknown fields are allowed; they
/// are simply ignored by template substitution.
pub fn webhook_payload_shape(
  body : @json.Json,
) -> Result[Map[String, @json.Json], String] {
  let root = match as_object(body) {
    Some(value) => value
    None => return Err("payload must be a top-level JSON object")
  }
  for key, value in root {
    if key.length() == 0 || key.length() > TRIGGER_WEBHOOK_OBJECT_KEY_MAX {
      return Err("payload keys must be 1..64 characters")
    }
    if !webhook_shape_value_valid(value, 2) {
      return Err("payload nesting exceeds three levels")
    }
  }
  Ok(root)
}

///|
fn webhook_shape_value_valid(value : @json.Json, depth : Int) -> Bool {
  match value {
    @json.Json::Object(map) => {
      if depth > TRIGGER_WEBHOOK_SHAPE_DEPTH_MAX {
        return false
      }
      for key, item in map {
        if key.length() == 0 || key.length() > TRIGGER_WEBHOOK_OBJECT_KEY_MAX {
          return false
        }
        if !webhook_shape_value_valid(item, depth + 1) {
          return false
        }
      }
      true
    }
    @json.Json::Array(items) => {
      if depth > TRIGGER_WEBHOOK_SHAPE_DEPTH_MAX {
        return false
      }
      for item in items {
        if !webhook_shape_value_valid(item, depth + 1) {
          return false
        }
      }
      true
    }
    _ => true
  }
}

///|
/// Declared template fields: at most 8 dot paths, at most two segments, each
/// segment `[A-Za-z0-9_-]+`. This is a whitelist, not a JSONPath evaluator.
pub fn webhook_payload_fields_valid(fields : Array[String]) -> Bool {
  if fields.length() > TRIGGER_WEBHOOK_PAYLOAD_FIELDS_MAX {
    return false
  }
  let seen : Map[String, Bool] = Map([])
  for field in fields {
    if !webhook_payload_field_valid(field) {
      return false
    }
    if seen.contains(field) {
      return false
    }
    seen.set(field, true)
  }
  true
}

///|
pub fn webhook_payload_field_valid(field : String) -> Bool {
  if field == "" || field.length() > 128 {
    return false
  }
  let mut segments = 0
  let mut segment_length = 0
  for ch in field {
    if ch == '.' {
      if segment_length == 0 || segments >= TRIGGER_WEBHOOK_PAYLOAD_SEGMENTS_MAX - 1 {
        return false
      }
      segments = segments + 1
      segment_length = 0
      continue
    }
    let allowed = (ch >= '0' && ch <= '9') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      ch == '_' ||
      ch == '-'
    if !allowed {
      return false
    }
    segment_length = segment_length + 1
  }
  segment_length > 0 &&
  segments < TRIGGER_WEBHOOK_PAYLOAD_SEGMENTS_MAX
}

///|
/// Values for the declared fields only. Missing fields render empty; a field
/// that resolves to an object/array is rejected instead of stringified.
/// Every value is truncated to 512 characters before touching a template.
pub fn webhook_payload_vars(
  root : Map[String, @json.Json],
  fields : Array[String],
) -> Result[Array[(String, String)], String] {
  if !webhook_payload_fields_valid(fields) {
    return Err("invalid payload_fields")
  }
  let vars : Array[(String, String)] = []
  for field in fields {
    let found = webhook_payload_lookup(root, field)
    let text = match found {
      None => ""
      Some(value) =>
        match value {
          @json.Json::String(text) => text
          @json.Json::Number(number, ..) => number.to_string()
          @json.Json::True => "true"
          @json.Json::False => "false"
          @json.Json::Null => ""
          _ => return Err("payload field must resolve to a scalar")
        }
    }
    let bounded = if text.length() > TRIGGER_WEBHOOK_PAYLOAD_VALUE_MAX {
      text.substring(start=0, end=TRIGGER_WEBHOOK_PAYLOAD_VALUE_MAX)
    } else {
      text
    }
    vars.push((field, bounded))
  }
  Ok(vars)
}

///|
fn webhook_payload_lookup(
  root : Map[String, @json.Json],
  field : String,
) -> @json.Json? {
  match field.split_once(".") {
    Some(parts) => {
      let (head, tail) = parts
      let parent = match root.get(head.to_owned()) {
        Some(value) => value
        None => return None
      }
      let object = match as_object(parent) {
        Some(value) => value
        None => return None
      }
      object.get(tail.to_owned())
    }
    None => root.get(field)
  }
}
