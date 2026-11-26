///|
/// A3.1 webhook contract tests: path parsing, header shape, HMAC signing,
/// freshness, body limits, payload shape and the untrusted substitution
/// surface. The fixed HMAC vector is independent of the implementation.

///|
const WEBHOOK_TEST_KEY_ID : String = "whk_01HZZZZZZZZZZZZZZZZZZZZZZZ"

///|
const WEBHOOK_TEST_TRIGGER_ID : String = "trg_01HZZZZZZZZZZZZZZZZZZZZZZZ"

///|
const WEBHOOK_TEST_NONCE : String = "0123456789abcdef0123456789abcdef"

///|
const WEBHOOK_TEST_TIMESTAMP : String = "1767225600000"

///|
const WEBHOOK_TEST_BODY : String = "{\"title\":\"hello\"}"

///|
const WEBHOOK_TEST_SIGNATURE : String =
  "v1=1f4a6f070341a2086f4ddede377680a75f5bdf0d95f78d61d97d0adf5aff4064"

///|
fn webhook_test_secret() -> Bytes {
  let out : Array[Byte] = []
  for index in 0..<32 {
    out.push(index.to_byte())
  }
  Bytes::from_array(out)
}

///|
fn webhook_test_body() -> Bytes {
  @utf8.encode(WEBHOOK_TEST_BODY)
}

///|
fn webhook_test_repeat(ch : Char, count : Int) -> String {
  let mut out = ""
  for _ in 0..<count {
    out = out + ch.to_string()
  }
  out
}

///|
fn webhook_path_ok(path : String) -> Bool {
  match trigger_webhook_path_trigger_id(path) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn webhook_secret_bad(text : String) -> Bool {
  match webhook_secret_from_hex(text) {
    None => true
    Some(_) => false
  }
}

///|
fn webhook_shape_ok(body : @json.Json) -> Bool {
  match webhook_payload_shape(body) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn webhook_vars_bad(
  root : Map[String, @json.Json],
  fields : Array[String],
) -> Bool {
  match webhook_payload_vars(root, fields) {
    Ok(_) => false
    Err(_) => true
  }
}

///|
fn webhook_parse(text : String) -> @json.Json {
  @json.parse(text) catch {
    _ => @json.Json::null()
  }
}

///|
test "webhook path parsing strips only the trigger id" {
  assert_eq(
    trigger_webhook_path_trigger_id("/hooks/" + WEBHOOK_TEST_TRIGGER_ID),
    Ok(WEBHOOK_TEST_TRIGGER_ID),
  )
  assert_true(!webhook_path_ok("/hooks/"))
  assert_true(!webhook_path_ok("/hooks"))
  assert_true(!webhook_path_ok("/hooks/trg with space"))
  assert_true(!webhook_path_ok("/hooks/../ws"))
  assert_true(!webhook_path_ok("/ws"))
}

///|
test "signature vector matches an independent HMAC-SHA256" {
  let secret = webhook_test_secret()
  let body = webhook_test_body()
  let signature = webhook_sign(
    secret.exact_view(),
    WEBHOOK_TEST_KEY_ID,
    WEBHOOK_TEST_TRIGGER_ID,
    WEBHOOK_TEST_TIMESTAMP,
    WEBHOOK_TEST_NONCE,
    body.exact_view(),
  )
  assert_eq(signature, WEBHOOK_TEST_SIGNATURE)
  assert_true(webhook_signature_matches(signature, WEBHOOK_TEST_SIGNATURE))
  // One changed hex digit fails, a truncated value fails, and a missing
  // `v1=` prefix fails; none of these fall back to string ordering.
  assert_true(
    !webhook_signature_matches(
      "v1=1f4a6f070341a2086f4ddede377680a75f5bdf0d95f78d61d97d0adf5aff4065",
      WEBHOOK_TEST_SIGNATURE,
    ),
  )
  assert_true(
    !webhook_signature_matches("v1=8481e3b2", WEBHOOK_TEST_SIGNATURE),
  )
  assert_true(
    !webhook_signature_matches(
      "1f4a6f070341a2086f4ddede377680a75f5bdf0d95f78d61d97d0adf5aff4064",
      WEBHOOK_TEST_SIGNATURE,
    ),
  )
  assert_eq(
    webhook_body_sha256_hex(body),
    "cf6c63ce25116b04e3b776a2957606e18d8ac798dde21e3ec30882ac2dfbe0cb",
  )
}

///|
test "secret encoding is exactly one 256-bit key in lowercase hex" {
  let secret = webhook_test_secret()
  let hex = webhook_secret_hex(secret.exact_view())
  assert_eq(
    hex,
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
  )
  match webhook_secret_from_hex(hex) {
    Some(decoded) => assert_eq(decoded, secret)
    None => fail("valid secret hex was rejected")
  }
  assert_true(webhook_secret_bad(hex.substring(start=0, end=62)))
  assert_true(webhook_secret_bad("zz" + hex.substring(start=2)))
}

///|
test "key id, nonce and delivery id validators reject path characters" {
  assert_true(webhook_key_id_valid(WEBHOOK_TEST_KEY_ID))
  assert_true(!webhook_key_id_valid("whk_"))
  assert_true(!webhook_key_id_valid("whk_01HZZZZZZZZZZZZZZZZZZZZZZI"))
  assert_true(!webhook_key_id_valid("whk_../secrets/webhook"))
  assert_true(webhook_nonce_valid(WEBHOOK_TEST_NONCE))
  assert_true(!webhook_nonce_valid("short"))
  assert_true(!webhook_nonce_valid("0123456789abcde/0123456789abcdef"))
  assert_true(webhook_delivery_id_valid("delivery-1"))
  assert_true(!webhook_delivery_id_valid("delivery/1"))
}

///|
test "timestamp parsing and freshness accept ms or RFC3339" {
  assert_eq(
    webhook_timestamp_parse_ms(WEBHOOK_TEST_TIMESTAMP),
    Some(1_767_225_600_000L),
  )
  // The header is Unix milliseconds; a seconds-scale value is interpreted
  // as milliseconds, never silently multiplied.
  assert_eq(webhook_timestamp_parse_ms("1767225600"), Some(1_767_225_600L))
  assert_eq(
    webhook_timestamp_parse_ms("2026-01-01T00:00:00.000Z"),
    Some(1_767_225_600_000L),
  )
  assert_eq(webhook_timestamp_parse_ms(""), None)
  assert_eq(webhook_timestamp_parse_ms("not-a-time"), None)
  let now = 1_767_225_600_000L
  assert_true(webhook_timestamp_fresh(now, now, 300))
  assert_true(webhook_timestamp_fresh(now - 300_000L, now, 300))
  assert_true(!webhook_timestamp_fresh(now - 300_001L, now, 300))
  assert_true(!webhook_timestamp_fresh(now + 300_001L, now, 300))
  // The configured window is clamped to the adr cap.
  assert_eq(webhook_freshness_window_s(0), 300)
  assert_eq(webhook_freshness_window_s(900), 900)
  assert_eq(webhook_freshness_window_s(10_000), 900)
  assert_eq(webhook_body_limit(0), 65_536)
  assert_eq(webhook_body_limit(262_144), 262_144)
  assert_eq(webhook_body_limit(999_999), 262_144)
  assert_eq(webhook_read_timeout_ms(0), 5_000)
  assert_eq(webhook_read_timeout_ms(999_999), 10_000)
}

///|
test "accepted and rejected response shapes never echo the body" {
  let accepted = webhook_accepted_response(
    WEBHOOK_TEST_TRIGGER_ID,
    "tsk_1",
    false,
  ).stringify()
  assert_true(accepted.contains("\"accepted\":true"))
  assert_true(accepted.contains("\"task_id\":\"tsk_1\""))
  assert_true(accepted.contains("\"duplicate\":false"))
  let duplicate = webhook_accepted_response(
    WEBHOOK_TEST_TRIGGER_ID,
    "tsk_1",
    true,
  ).stringify()
  assert_true(duplicate.contains("\"duplicate\":true"))
  assert_eq(
    webhook_unauthorized_response().stringify(),
    "{\"accepted\":false,\"error\":\"unauthorized\"}",
  )
  let limited = webhook_error_response("rate_limited").stringify()
  assert_true(limited.contains("rate_limited"))
  assert_true(!limited.contains(WEBHOOK_TEST_BODY))
}

///|
test "payload shape is a bounded object of scalars and shallow nesting" {
  let ok = webhook_parse(
    "{\"title\":\"hello\",\"meta\":{\"tag\":\"x\"},\"items\":[1,2]}",
  )
  assert_true(webhook_shape_ok(ok))
  let deep = webhook_parse("{\"a\":{\"b\":{\"c\":{\"d\":1}}}}")
  assert_true(!webhook_shape_ok(deep))
  let array_root = webhook_parse("[1,2,3]")
  assert_true(!webhook_shape_ok(array_root))
  let long = webhook_parse(
    "{\"" + webhook_test_repeat('a', 65) + "\":1}",
  )
  assert_true(!webhook_shape_ok(long))
}

///|
test "payload variables are a declared, scalar, bounded whitelist" {
  let root = webhook_parse(
    "{\"title\":\"hello\",\"nested\":{\"tag\":\"x\"},\"obj\":{\"deep\":\"y\"},\"num\":42}",
  )
  let shaped = match webhook_payload_shape(root) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  match webhook_payload_vars(shaped, ["title", "nested.tag", "num", "missing"]) {
    Ok(pairs) => {
      assert_eq(pairs.length(), 4)
      let vars : Map[String, String] = Map([])
      for pair in pairs {
        let (name, value) = pair
        vars.set(name, value)
      }
      assert_eq(vars.get("title"), Some("hello"))
      assert_eq(vars.get("nested.tag"), Some("x"))
      assert_eq(vars.get("num"), Some("42"))
      assert_eq(vars.get("missing"), Some(""))
    }
    Err(message) => fail(message)
  }
  // An object/array field is rejected instead of stringified.
  assert_true(webhook_vars_bad(shaped, ["obj"]))
  // Only declared fields are extracted; undeclared payload fields cannot
  // become template variables at all.
  match webhook_payload_vars(shaped, ["title"]) {
    Ok(pairs) => assert_eq(pairs.length(), 1)
    Err(message) => fail(message)
  }
  // Field syntax is a bounded dot path, not a JSONPath expression.
  assert_true(!webhook_payload_fields_valid(["a.b.c"]))
  assert_true(!webhook_payload_fields_valid(["a[0]"]))
  assert_true(!webhook_payload_fields_valid(["a", "a"]))
  assert_true(
    webhook_payload_fields_valid(["a", "b", "c", "d", "e", "f", "g", "h"]),
  )
  assert_true(
    !webhook_payload_fields_valid(
      ["a", "b", "c", "d", "e", "f", "g", "h", "i"],
    ),
  )
  // A value is truncated to 512 characters before any template rendering.
  let long_body = webhook_parse(
    "{\"big\":\"" + webhook_test_repeat('x', 600) + "\"}",
  )
  let long_root = match webhook_payload_shape(long_body) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  match webhook_payload_vars(long_root, ["big"]) {
    Ok(pairs) => {
      let (_, value) = pairs[0]
      assert_eq(value.length(), 512)
    }
    Err(message) => fail(message)
  }
}

///|
test "nonce expiry covers the freshness window and the ledger grace" {
  assert_eq(webhook_nonce_expiry_ms(1_000L, 900), 1_000L + 900_000L + 120_000L)
  assert_eq(
    webhook_nonce_expiry_ms(1_000L, 10_000),
    1_000L + 900_000L + 120_000L,
  )
}

///|
test "key record JSON never exposes the secret file path" {
  let key = WebhookKeyRecord::new(
    key_id=WEBHOOK_TEST_KEY_ID,
    trigger_id=WEBHOOK_TEST_TRIGGER_ID,
    org_id=ORG_LOCAL,
    name="github",
    secret_path=webhook_secret_relative_path(WEBHOOK_TEST_KEY_ID),
    created_at="2026-01-01T00:00:00.000Z",
  )
  let rendered = webhook_key_record_to_json(key).stringify()
  assert_true(rendered.contains(WEBHOOK_TEST_KEY_ID))
  assert_true(!rendered.contains("secrets/webhook"))
  assert_true(!rendered.contains(".key"))
  // Activity is checked against enabled/revoked/expires.
  let now = 1_767_225_600_000L
  assert_true(webhook_key_active(key, now))
  let revoked = { ..key, revoked_at: "2026-01-02T00:00:00.000Z" }
  assert_true(!webhook_key_active(revoked, now))
  let disabled = { ..key, enabled: false }
  assert_true(!webhook_key_active(disabled, now))
  let expired = { ..key, expires_at: "2025-12-31T23:59:59.000Z" }
  assert_true(!webhook_key_active(expired, now))
  assert_eq(
    webhook_secret_relative_path(WEBHOOK_TEST_KEY_ID),
    "secrets/webhook/" + WEBHOOK_TEST_KEY_ID + ".key",
  )
}

///|
test "fire key prefers the delivery id and falls back to the nonce" {
  assert_eq(webhook_fire_key("delivery-1", "nonce"), "delivery:delivery-1")
  assert_eq(webhook_fire_key("", "nonce"), "nonce:nonce")
}
