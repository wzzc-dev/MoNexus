///|
/// Signed webhook endpoint (ADR-0014 §4, A3.1).
///
/// `/hooks/<trigger_id>` is split off before the `/ws` bearer check, so a
/// webhook never needs the owner's WS token and a WS request never reaches
/// the HMAC path. Everything stays on the existing loopback listener; a TLS
/// reverse proxy is the owner's responsibility and no forwarding header is
/// trusted (§4.1, §4.3).

///|
struct TriggerWebhookReply {
  code : Int32
  reason : String
  body : @json.Json
  retry_after : String
}

///|
fn trigger_webhook_reply(
  code : Int32,
  reason : String,
  body : @json.Json,
) -> TriggerWebhookReply {
  { code, reason, body, retry_after: "" }
}

///|
fn trigger_webhook_retry_reply(
  reason : String,
  body : @json.Json,
) -> TriggerWebhookReply {
  { code: 429, reason, body, retry_after: "1" }
}

///|
async fn trigger_webhook_respond(
  conn : @http.ServerConnection,
  reply : TriggerWebhookReply,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(@http.CaseInsensitiveString("Content-Type"), "application/json")
  headers.set(@http.CaseInsensitiveString("Cache-Control"), "no-store")
  if reply.retry_after != "" {
    headers.set(
      @http.CaseInsensitiveString("Retry-After"),
      reply.retry_after,
    )
  }
  conn.send_response(reply.code, reply.reason, extra_headers=headers)
  conn.write_string(reply.body.stringify())
  conn.end_response()
}

///|
async fn trigger_webhook_method_not_allowed(
  conn : @http.ServerConnection,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(@http.CaseInsensitiveString("Content-Type"), "application/json")
  headers.set(@http.CaseInsensitiveString("Cache-Control"), "no-store")
  headers.set(@http.CaseInsensitiveString("Allow"), "POST")
  conn.send_response(405, "Method Not Allowed", extra_headers=headers)
  conn.write_string(
    @contracts.webhook_error_response("method_not_allowed").stringify(),
  )
  conn.end_response()
}

// ---------------------------------------------------------------------------
// Environment-clamped configuration (ADR-0014 §4.5)
// ---------------------------------------------------------------------------

///|
fn trigger_env_positive_int(name : String) -> Int {
  match @env.get_env_var(name) {
    Some(text) => {
      let value = @string.parse_int64(text.trim()) catch { _ => 0L }
      if value > 0L && value <= 2_147_483_647L {
        value.to_int()
      } else {
        0
      }
    }
    None => 0
  }
}

///|
fn trigger_webhook_config_body_limit() -> Int {
  @contracts.webhook_body_limit(
    trigger_env_positive_int("MONEXUS_WEBHOOK_BODY_LIMIT"),
  )
}

///|
fn trigger_webhook_config_freshness_s() -> Int {
  @contracts.webhook_freshness_window_s(
    trigger_env_positive_int("MONEXUS_WEBHOOK_FRESHNESS_S"),
  )
}

///|
fn trigger_webhook_config_read_timeout_ms() -> Int {
  @contracts.webhook_read_timeout_ms(
    trigger_env_positive_int("MONEXUS_WEBHOOK_READ_TIMEOUT_MS"),
  )
}

///|
fn trigger_webhook_config_rate(
  name : String,
  fallback : Int,
  cap : Int,
) -> Int {
  let configured = trigger_env_positive_int(name)
  if configured <= 0 {
    fallback
  } else {
    configured.min(cap)
  }
}

// ---------------------------------------------------------------------------
// Request parsing helpers
// ---------------------------------------------------------------------------

///|
fn trigger_webhook_content_type_ok(value : String) -> Bool {
  let lower = value.trim().to_string().to_lower()
  lower == "application/json" ||
  lower.has_prefix("application/json;") ||
  lower.has_prefix("application/json ")
}

///|
fn trigger_webhook_content_length(
  headers : @http.Headers,
) -> Result[Int64?, String] {
  match headers.get(@http.CaseInsensitiveString("Content-Length")) {
    None => Ok(None)
    Some(value) => {
      let text = value.trim().to_string()
      if text == "" {
        return Err("Content-Length is empty")
      }
      let mut digits = true
      for ch in text {
        if ch < '0' || ch > '9' {
          digits = false
          break
        }
      }
      if !digits {
        return Err("Content-Length must be a non-negative integer")
      }
      let parsed = @string.parse_int64(text) catch {
        _ => return Err("Content-Length is not a number")
      }
      Ok(Some(parsed))
    }
  }
}

///|
fn trigger_webhook_concat_bytes(parts : Array[Bytes], total : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  let mut cursor = 0
  for part in parts {
    for index in 0..<part.length() {
      out[cursor + index] = part[index]
    }
    cursor = cursor + part.length()
  }
  Bytes::from_fixedarray(out)
}

///|
/// Bounded body read. `Content-Length` is checked separately, but the actual
/// read is capped independently so a lying header still gets 413 (§4.5). The
/// whole read shares one deadline, so a slow sender cannot stretch a 5s read
/// timeout across many chunks.
async fn trigger_webhook_read_body(
  conn : @http.ServerConnection,
  limit : Int,
  timeout_ms : Int,
) -> Result[Bytes, String] {
  let parts : Array[Bytes] = []
  let mut total = 0
  let deadline = @async.now() + timeout_ms.to_int64()
  for _ in 0..<4096 {
    let left = deadline - @async.now()
    if left <= 0L {
      return Err("read_timeout")
    }
    let remaining = limit - total + 1
    let chunk = @async.with_timeout_opt(
      left.to_int(),
      async fn() -> Bytes? { conn.read_some(max_len=remaining) },
    )
    let ended = match chunk {
      None => return Err("read_timeout")
      Some(value) =>
        match value {
          None => true
          Some(bytes) =>
            if bytes.length() == 0 {
              true
            } else {
              total = total + bytes.length()
              if total > limit {
                return Err("too_large")
              }
              parts.push(bytes)
              false
            }
        }
    }
    if ended {
      return Ok(trigger_webhook_concat_bytes(parts, total))
    }
  }
  Err("too_large")
}

///|
fn trigger_webhook_header(
  headers : @http.Headers,
  name : String,
) -> String? {
  headers.get(@http.CaseInsensitiveString(name))
}

///|
fn trigger_webhook_detail(
  body_hash : String,
  body_length : Int,
  extra : String,
) -> String {
  let head = "body_sha256=" + body_hash + " bytes=" + body_length.to_string()
  if extra == "" {
    head
  } else {
    head + " " + extra
  }
}

// ---------------------------------------------------------------------------
// Rate limiting, concurrency and audit
// ---------------------------------------------------------------------------

///|
fn trigger_webhook_bucket_allow(
  state : HostState,
  key : String,
  now_ms : Int64,
  per_minute : Int,
  burst : Int,
) -> Bool {
  let bucket = match state.trigger_buckets.get(key) {
    Some(value) => value
    None => @contracts.trigger_rate_bucket_new(now_ms, burst)
  }
  let (updated, allowed) = @contracts.trigger_rate_take(
    bucket,
    now_ms,
    per_minute,
    burst,
  )
  state.trigger_buckets.set(key, updated)
  allowed
}

///|
async fn trigger_webhook_rate_allow(
  state : HostState,
  trigger_id : String,
  key_id : String,
  now_ms : Int64,
) -> Bool {
  let trigger_per_min = trigger_webhook_config_rate(
    "MONEXUS_WEBHOOK_RATE_TRIGGER_PER_MIN",
    @contracts.TRIGGER_WEBHOOK_RATE_TRIGGER_PER_MIN,
    @contracts.TRIGGER_WEBHOOK_RATE_TRIGGER_CAP,
  )
  let key_per_min = trigger_webhook_config_rate(
    "MONEXUS_WEBHOOK_RATE_KEY_PER_MIN",
    @contracts.TRIGGER_WEBHOOK_RATE_KEY_PER_MIN,
    @contracts.TRIGGER_WEBHOOK_RATE_KEY_CAP,
  )
  let global_per_min = trigger_webhook_config_rate(
    "MONEXUS_WEBHOOK_RATE_GLOBAL_PER_MIN",
    @contracts.TRIGGER_WEBHOOK_RATE_GLOBAL_PER_MIN,
    @contracts.TRIGGER_WEBHOOK_RATE_GLOBAL_CAP,
  )
  state.mutex.acquire()
  let trigger_ok = trigger_webhook_bucket_allow(
    state,
    "webhook:trigger:" + trigger_id,
    now_ms,
    trigger_per_min,
    @contracts.TRIGGER_WEBHOOK_RATE_TRIGGER_BURST,
  )
  let key_ok = trigger_webhook_bucket_allow(
    state,
    "webhook:key:" + key_id,
    now_ms,
    key_per_min,
    @contracts.TRIGGER_WEBHOOK_RATE_KEY_BURST,
  )
  let global_ok = trigger_webhook_bucket_allow(
    state,
    "webhook:global",
    now_ms,
    global_per_min,
    @contracts.TRIGGER_WEBHOOK_RATE_GLOBAL_BURST,
  )
  state.mutex.release()
  trigger_ok && key_ok && global_ok
}

///|
async fn trigger_webhook_inflight_acquire(
  state : HostState,
  trigger_id : String,
) -> Bool {
  state.mutex.acquire()
  let current = match state.webhook_inflight.get(trigger_id) {
    Some(value) => value
    None => 0
  }
  let acquired = current < @contracts.TRIGGER_WEBHOOK_CONCURRENCY_MAX
  if acquired {
    state.webhook_inflight.set(trigger_id, current + 1)
  }
  state.mutex.release()
  acquired
}

///|
async fn trigger_webhook_inflight_release(
  state : HostState,
  trigger_id : String,
) -> Unit {
  state.mutex.acquire()
  let current = match state.webhook_inflight.get(trigger_id) {
    Some(value) => value
    None => 0
  }
  let next = if current > 0 { current - 1 } else { 0 }
  if next == 0 {
    state.webhook_inflight.remove(trigger_id)
  } else {
    state.webhook_inflight.set(trigger_id, next)
  }
  state.mutex.release()
}

///|
/// One detailed `trigger.rejected` per failed request. `detail` carries only
/// the failure category, byte count and body hash; the raw body, headers and
/// configuration are never persisted (§4.5, §4.6).
async fn trigger_webhook_audit(
  state : HostState,
  trigger_id : String,
  reason : String,
  detail : String,
  key_id : String,
  delivery_id : String,
  event_id : String,
  suffix : String,
) -> Unit {
  state.mutex.acquire()
  let payload = @contracts.trigger_rejected_payload(
    trigger_id,
    @contracts.TRIGGER_SOURCE_WEBHOOK,
    reason,
    trigger_short_detail(detail),
    event_id=event_id,
    delivery_id=delivery_id,
    key_id=key_id,
  )
  let event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_REJECTED,
    trigger_record_subject(trigger_id),
    payload,
    "",
    state.host_id,
    "trigger-reject/" + trigger_id + "/webhook/" + suffix + "/" + reason,
  )
  match state.store.append_event(event) {
    Ok(inserted) =>
      if inserted {
        state.publish(event)
      }
    Err(message) =>
      println("monexus-host: cannot persist webhook rejection: " + message)
  }
  state.mutex.release()
}

///|
/// Coalesced `rate_limited` audit: at most one event per trigger per minute,
/// carrying the number of suppressed rejections (§4.5).
async fn trigger_webhook_rate_audit(
  state : HostState,
  trigger_id : String,
  detail : String,
  key_id : String,
  delivery_id : String,
) -> Unit {
  state.mutex.acquire()
  let now_ms = @async.now()
  let previous = state.webhook_audit.get(trigger_id)
  let should_emit = match previous {
    None => true
    Some(entry) => now_ms - entry.last_ms >= 60_000L
  }
  if should_emit {
    let suppressed = match previous {
      Some(entry) => entry.suppressed
      None => 0
    }
    let payload = @contracts.trigger_rejected_payload(
      trigger_id,
      @contracts.TRIGGER_SOURCE_WEBHOOK,
      @contracts.TRIGGER_REJECT_RATE_LIMITED,
      trigger_short_detail(detail),
      suppressed_count=suppressed,
      delivery_id=delivery_id,
      key_id=key_id,
    )
    let bucket = (now_ms / 60_000L).to_string()
    let event = trigger_envelope(
      state,
      @contracts.EVENT_TRIGGER_REJECTED,
      trigger_record_subject(trigger_id),
      payload,
      "",
      state.host_id,
      "trigger-reject/" + trigger_id + "/webhook-rate/" + bucket,
    )
    match state.store.append_event(event) {
      Ok(inserted) =>
        if inserted {
          state.publish(event)
        }
      Err(message) =>
        println("monexus-host: cannot persist webhook rate audit: " + message)
    }
    state.webhook_audit.set(trigger_id, { last_ms: now_ms, suppressed: 0 })
  } else {
    let entry = match previous {
      Some(value) => value
      None => { last_ms: now_ms, suppressed: 0 }
    }
    state.webhook_audit.set(
      trigger_id,
      { last_ms: entry.last_ms, suppressed: entry.suppressed + 1 },
    )
  }
  state.mutex.release()
}

///|
async fn trigger_webhook_unauthorized(
  state : HostState,
  conn : @http.ServerConnection,
  trigger_id : String,
  reason : String,
  detail : String,
  key_id : String,
  delivery_id : String,
  event_id : String,
  suffix : String,
) -> Unit {
  trigger_webhook_audit(
    state,
    trigger_id,
    reason,
    detail,
    key_id,
    delivery_id,
    event_id,
    suffix,
  )
  trigger_webhook_respond(
    conn,
    trigger_webhook_reply(
      401,
      "Unauthorized",
      @contracts.webhook_unauthorized_response(),
    ),
  )
}

// ---------------------------------------------------------------------------
// Authentication helpers
// ---------------------------------------------------------------------------

///|
fn trigger_webhook_key_reject_reason(
  key : @contracts.WebhookKeyRecord,
  now_ms : Int64,
) -> String {
  if !key.enabled {
    return @contracts.TRIGGER_REJECT_DISABLED
  }
  if key.revoked_at != "" {
    return @contracts.TRIGGER_REJECT_SOURCE_DENIED
  }
  if !@contracts.webhook_key_active(key, now_ms) {
    return @contracts.TRIGGER_REJECT_EXPIRED
  }
  ""
}

///|
fn trigger_webhook_trigger_reject_reason(
  trigger : @contracts.TriggerRecord,
  now_ms : Int64,
) -> String {
  if trigger.kind != @contracts.TRIGGER_TYPE_WEBHOOK {
    return @contracts.TRIGGER_REJECT_SOURCE_DENIED
  }
  if !trigger.enabled {
    return @contracts.TRIGGER_REJECT_DISABLED
  }
  if @contracts.trigger_is_expired_at(trigger.expires_at, now_ms) {
    return @contracts.TRIGGER_REJECT_EXPIRED
  }
  ""
}

// ---------------------------------------------------------------------------
// Endpoint
// ---------------------------------------------------------------------------

///|
async fn handle_trigger_webhook(
  state : HostState,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  // Flag off: indistinguishable from an unknown key. No audit is written
  // because the trigger system itself is disabled (ADR-0014 §7).
  if !state.trigger_enabled {
    trigger_webhook_respond(
      conn,
      trigger_webhook_reply(
        401,
        "Unauthorized",
        @contracts.webhook_unauthorized_response(),
      ),
    )
    return
  }
  if request.meth != @http.RequestMethod::Post {
    trigger_webhook_method_not_allowed(conn)
    return
  }
  let trigger_id = match @contracts.trigger_webhook_path_trigger_id(
    request.path,
  ) {
    Ok(value) => value
    Err(_) => {
      trigger_webhook_respond(
        conn,
        trigger_webhook_reply(
          401,
          "Unauthorized",
          @contracts.webhook_unauthorized_response(),
        ),
      )
      return
    }
  }
  let content_type_ok = match trigger_webhook_header(
    request.headers,
    "Content-Type",
  ) {
    Some(value) => trigger_webhook_content_type_ok(value)
    None => false
  }
  if !content_type_ok {
    trigger_webhook_respond(
      conn,
      trigger_webhook_reply(
        400,
        "Bad Request",
        @contracts.webhook_error_response("invalid_content_type"),
      ),
    )
    return
  }
  let declared = match trigger_webhook_content_length(request.headers) {
    Ok(value) => value
    Err(_) => {
      trigger_webhook_respond(
        conn,
        trigger_webhook_reply(
          400,
          "Bad Request",
          @contracts.webhook_error_response("invalid_content_length"),
        ),
      )
      return
    }
  }
  let body_limit = trigger_webhook_config_body_limit()
  match declared {
    Some(length) =>
      if length > body_limit.to_int64() {
        trigger_webhook_respond(
          conn,
          trigger_webhook_reply(
            413,
            "Payload Too Large",
            @contracts.webhook_error_response("payload_too_large"),
          ),
        )
        return
      }
    None => ()
  }
  let read_timeout_ms = trigger_webhook_config_read_timeout_ms()
  let body = match trigger_webhook_read_body(conn, body_limit, read_timeout_ms) {
    Ok(value) => value
    Err(reason) => {
      let reply = if reason == "too_large" {
        trigger_webhook_reply(
          413,
          "Payload Too Large",
          @contracts.webhook_error_response("payload_too_large"),
        )
      } else {
        trigger_webhook_reply(
          400,
          "Bad Request",
          @contracts.webhook_error_response("invalid_body"),
        )
      }
      trigger_webhook_respond(conn, reply)
      return
    }
  }
  match declared {
    Some(length) =>
      if body.length().to_int64() != length {
        trigger_webhook_respond(
          conn,
          trigger_webhook_reply(
            400,
            "Bad Request",
            @contracts.webhook_error_response("invalid_content_length"),
          ),
        )
        return
      }
    None => ()
  }
  let now_ms = @async.now()
  let body_hash = @contracts.webhook_body_sha256_hex(body)
  let key_id_text = match trigger_webhook_header(
    request.headers,
    @contracts.TRIGGER_WEBHOOK_HEADER_KEY_ID,
  ) {
    Some(value) => value
    None => ""
  }
  if !@contracts.webhook_key_id_valid(key_id_text) {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
      trigger_webhook_detail(
        body_hash,
        body.length(),
        "missing or malformed key id",
      ),
      "",
      "",
      body_hash,
      body_hash,
    )
    return
  }
  let key_id = key_id_text
  let nonce = match trigger_webhook_header(
    request.headers,
    @contracts.TRIGGER_WEBHOOK_HEADER_NONCE,
  ) {
    Some(value) =>
      if @contracts.webhook_nonce_valid(value) {
        value
      } else {
        ""
      }
    None => ""
  }
  if nonce == "" {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
      trigger_webhook_detail(
        body_hash,
        body.length(),
        "missing or malformed nonce",
      ),
      key_id,
      "",
      body_hash,
      key_id + "/" + body_hash,
    )
    return
  }
  let delivery = match trigger_webhook_header(
    request.headers,
    @contracts.TRIGGER_WEBHOOK_HEADER_DELIVERY_ID,
  ) {
    Some(value) =>
      if @contracts.webhook_delivery_id_valid(value) {
        value
      } else {
        "!"
      }
    None => ""
  }
  if delivery == "!" {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
      trigger_webhook_detail(
        body_hash,
        body.length(),
        "malformed delivery id",
      ),
      key_id,
      "",
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  let timestamp = match trigger_webhook_header(
    request.headers,
    @contracts.TRIGGER_WEBHOOK_HEADER_TIMESTAMP,
  ) {
    Some(value) => value
    None => ""
  }
  let timestamp_ms = match @contracts.webhook_timestamp_parse_ms(timestamp) {
    Some(value) => value
    None => {
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_STALE_TIMESTAMP,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "missing or unparsable timestamp",
        ),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
  }
  let signature = match trigger_webhook_header(
    request.headers,
    @contracts.TRIGGER_WEBHOOK_HEADER_SIGNATURE,
  ) {
    Some(value) => value
    None => ""
  }
  // Short reads only; secret-file I/O stays outside the mutex.
  state.mutex.acquire()
  let key_result = state.store.get_webhook_key(key_id)
  let trigger_result = state.store.get_trigger(trigger_id)
  state.mutex.release()
  let key = match key_result {
    Ok(Some(value)) => value
    Ok(None) => {
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
        trigger_webhook_detail(body_hash, body.length(), "unknown key"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
    Err(message) => {
      println("monexus-host: webhook key lookup failed: " + message)
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
        trigger_webhook_detail(body_hash, body.length(), "key lookup failed"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
  }
  if key.trigger_id != trigger_id {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
      trigger_webhook_detail(body_hash, body.length(), "key is bound elsewhere"),
      key_id,
      delivery,
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  let key_reason = trigger_webhook_key_reject_reason(key, now_ms)
  if key_reason != "" {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      key_reason,
      trigger_webhook_detail(body_hash, body.length(), "key is not active"),
      key_id,
      delivery,
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  let trigger = match trigger_result {
    Ok(Some(value)) => value
    Ok(None) => {
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
        trigger_webhook_detail(body_hash, body.length(), "unknown trigger"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
    Err(message) => {
      println("monexus-host: webhook trigger lookup failed: " + message)
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
        trigger_webhook_detail(body_hash, body.length(), "trigger lookup failed"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
  }
  let trigger_reason = trigger_webhook_trigger_reject_reason(trigger, now_ms)
  if trigger_reason != "" {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      trigger_reason,
      trigger_webhook_detail(body_hash, body.length(), "trigger is not active"),
      key_id,
      delivery,
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  // Secret path is derived from our own key id, never from a request field.
  let expected_secret_path = @contracts.webhook_secret_relative_path(key_id)
  if key.secret_path != expected_secret_path {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
      trigger_webhook_detail(body_hash, body.length(), "secret path mismatch"),
      key_id,
      delivery,
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  let secret_path = state.state_dir + "/" + expected_secret_path
  let secret_data = @fs.read_file(secret_path) catch {
    _ => {
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
        trigger_webhook_detail(body_hash, body.length(), "secret is unreadable"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
  }
  let secret_text = secret_data.text() catch {
    _ => {
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
        trigger_webhook_detail(body_hash, body.length(), "secret is not UTF-8"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
  }
  let secret = match @contracts.webhook_secret_from_hex(secret_text) {
    Some(value) => value
    None => {
      trigger_webhook_unauthorized(
        state,
        conn,
        trigger_id,
        @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
        trigger_webhook_detail(body_hash, body.length(), "secret is malformed"),
        key_id,
        delivery,
        body_hash,
        key_id + "/" + nonce,
      )
      return
    }
  }
  let expected_signature = @contracts.webhook_sign(
    secret.exact_view(),
    key_id,
    trigger_id,
    timestamp,
    nonce,
    body.exact_view(),
  )
  if !@contracts.webhook_signature_matches(signature, expected_signature) {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_INVALID_SIGNATURE,
      trigger_webhook_detail(body_hash, body.length(), "signature mismatch"),
      key_id,
      delivery,
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  let freshness_s = trigger_webhook_config_freshness_s()
  if !@contracts.webhook_timestamp_fresh(timestamp_ms, now_ms, freshness_s) {
    trigger_webhook_unauthorized(
      state,
      conn,
      trigger_id,
      @contracts.TRIGGER_REJECT_STALE_TIMESTAMP,
      trigger_webhook_detail(body_hash, body.length(), "timestamp is stale"),
      key_id,
      delivery,
      body_hash,
      key_id + "/" + nonce,
    )
    return
  }
  if !trigger_webhook_rate_allow(state, trigger_id, key_id, now_ms) {
    trigger_webhook_rate_audit(
      state,
      trigger_id,
      trigger_webhook_detail(body_hash, body.length(), "request rate exceeded"),
      key_id,
      delivery,
    )
    trigger_webhook_respond(
      conn,
      trigger_webhook_retry_reply(
        "Too Many Requests",
        @contracts.webhook_error_response("rate_limited"),
      ),
    )
    return
  }
  if !trigger_webhook_inflight_acquire(state, trigger_id) {
    trigger_webhook_rate_audit(
      state,
      trigger_id,
      trigger_webhook_detail(
        body_hash,
        body.length(),
        "concurrency limit reached",
      ),
      key_id,
      delivery,
    )
    trigger_webhook_respond(
      conn,
      trigger_webhook_retry_reply(
        "Too Many Requests",
        @contracts.webhook_error_response("too_many_inflight"),
      ),
    )
    return
  }
  let reply = trigger_webhook_process(
    state,
    trigger_id,
    key_id,
    nonce,
    delivery,
    body,
    body_hash,
    now_ms,
    freshness_s,
  )
  trigger_webhook_inflight_release(state, trigger_id)
  trigger_webhook_respond(conn, reply)
}

///|
/// Parse the untrusted body, render only declared payload fields and commit
/// one webhook fire. The store transaction is the authority for key/trigger
/// activity, nonce uniqueness and fire dedupe (ADR-0014 §4.4).
async fn trigger_webhook_process(
  state : HostState,
  trigger_id : String,
  key_id : String,
  nonce : String,
  delivery : String,
  body : Bytes,
  body_hash : String,
  now_ms : Int64,
  freshness_s : Int,
) -> TriggerWebhookReply {
  let text = @utf8.decode(body.exact_view()) catch {
    _ =>
      return trigger_webhook_reply(
        400,
        "Bad Request",
        @contracts.webhook_error_response("invalid_body"),
      )
  }
  let json = @json.parse(
    text,
    max_nesting_depth=8,
    reject_duplicate_keys=true,
  ) catch {
    _ =>
      return trigger_webhook_reply(
        400,
        "Bad Request",
        @contracts.webhook_error_response("invalid_json"),
      )
  }
  let root = match @contracts.webhook_payload_shape(json) {
    Ok(value) => value
    Err(_) =>
      return trigger_webhook_reply(
        400,
        "Bad Request",
        @contracts.webhook_error_response("invalid_payload"),
      )
  }
  state.mutex.acquire()
  let trigger = match state.store.get_trigger(trigger_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
        trigger_webhook_detail(body_hash, body.length(), "unknown trigger"),
        key_id,
        delivery,
        nonce,
        key_id + "/" + nonce,
      )
      return trigger_webhook_reply(
        401,
        "Unauthorized",
        @contracts.webhook_unauthorized_response(),
      )
    }
    Err(message) => {
      state.mutex.release()
      println("monexus-host: webhook trigger re-read failed: " + message)
      return trigger_webhook_reply(
        401,
        "Unauthorized",
        @contracts.webhook_unauthorized_response(),
      )
    }
  }
  let recheck_reason = trigger_webhook_trigger_reject_reason(trigger, now_ms)
  if recheck_reason != "" {
    state.mutex.release()
    trigger_webhook_audit(
      state,
      trigger_id,
      recheck_reason,
      trigger_webhook_detail(
        body_hash,
        body.length(),
        "trigger changed before commit",
      ),
      key_id,
      delivery,
      nonce,
      key_id + "/" + nonce,
    )
    return trigger_webhook_reply(
      401,
      "Unauthorized",
      @contracts.webhook_unauthorized_response(),
    )
  }
  let payload_vars = match @contracts.webhook_payload_vars(
    root,
    trigger.source.payload_fields,
  ) {
    Ok(value) => value
    Err(_) => {
      state.mutex.release()
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_POLICY_DENIED,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "declared payload field is not scalar",
        ),
        key_id,
        delivery,
        nonce,
        key_id + "/" + nonce,
      )
      return trigger_webhook_reply(
        400,
        "Bad Request",
        @contracts.webhook_error_response("invalid_payload"),
      )
    }
  }
  let vars : Map[String, String] = Map([])
  for pair in payload_vars {
    let (name, value) = pair
    vars.set(name, value)
  }
  // Built-ins are written last so a declared payload field cannot spoof them.
  vars.set("trigger_id", trigger.id)
  vars.set("source", @contracts.TRIGGER_SOURCE_WEBHOOK)
  vars.set("delivery_id", delivery)
  vars.set("key_id", key_id)
  vars.set("nonce", nonce)
  vars.set("fired_at", @contracts.format_rfc3339(now_ms))
  let event_id = if delivery != "" { delivery } else { nonce }
  let fire_key = @contracts.webhook_fire_key(delivery, nonce)
  let prepared = match trigger_prepare(
    state,
    trigger,
    @contracts.TRIGGER_SOURCE_WEBHOOK,
    fire_key,
    event_id,
    vars,
    1,
    trigger.id,
    "",
    state.host_id,
    now_ms,
    trigger.next_fire_at,
    0L,
    key_id,
    false,
  ) {
    Ok(value) => value
    Err(attempt) => {
      state.mutex.release()
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_INVALID_TARGET,
        trigger_webhook_detail(body_hash, body.length(), attempt.detail),
        key_id,
        delivery,
        event_id,
        key_id + "/" + nonce,
      )
      return trigger_webhook_reply(
        400,
        "Bad Request",
        @contracts.webhook_error_response("invalid_target"),
      )
    }
  }
  let nonce_expires_ms = @contracts.webhook_nonce_expiry_ms(
    now_ms,
    freshness_s,
  )
  let outcome = state.store.record_trigger_webhook_event(
    prepared.task_events,
    prepared.fired_event,
    prepared.task,
    prepared.fire,
    prepared.record_after,
    key_id,
    nonce,
    body_hash,
    nonce_expires_ms,
    now_ms,
    now_ms,
  )
  let reply = match outcome {
    Ok(@machines.WebhookFireApplied) => {
      for event in prepared.task_events {
        state.publish(event)
      }
      state.publish(prepared.fired_event)
      let _ = state.store.touch_webhook_key(
        key_id,
        @contracts.format_rfc3339(now_ms),
      )
      trigger_webhook_reply(
        202,
        "Accepted",
        @contracts.webhook_accepted_response(trigger.id, prepared.task.id, false),
      )
    }
    Ok(@machines.WebhookFireDuplicate(task_id~)) => {
      let _ = state.store.touch_webhook_key(
        key_id,
        @contracts.format_rfc3339(now_ms),
      )
      trigger_webhook_reply(
        202,
        "Accepted",
        @contracts.webhook_accepted_response(trigger.id, task_id, true),
      )
    }
    Ok(_) =>
      trigger_webhook_reply(
        401,
        "Unauthorized",
        @contracts.webhook_unauthorized_response(),
      )
    Err(message) => {
      println("monexus-host: webhook commit failed: " + message)
      trigger_webhook_reply(
        500,
        "Internal Server Error",
        @contracts.webhook_error_response("internal_error"),
      )
    }
  }
  state.mutex.release()
  // A committed fire may queue its one agent Run through the existing
  // run.create handler. Rejected/duplicate commits are no-ops here: the
  // ledger row either does not exist or already carries a run_id.
  match trigger_start_run_for_fire(state, trigger.id, fire_key) {
    Ok(_) => ()
    Err(message) =>
      println(
        "monexus-host: cannot start run for webhook trigger fire: " + message,
      )
  }
  match outcome {
    Ok(@machines.WebhookFireNonceReuse) =>
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_NONCE_REUSE,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "nonce reused with a different body",
        ),
        key_id,
        delivery,
        event_id,
        key_id + "/" + nonce,
      )
    Ok(@machines.WebhookFireKeyInactive) =>
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_SOURCE_DENIED,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "key was revoked or disabled before commit",
        ),
        key_id,
        delivery,
        event_id,
        key_id + "/" + nonce,
      )
    Ok(@machines.WebhookFireDisabled) =>
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_DISABLED,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "trigger was disabled before commit",
        ),
        key_id,
        delivery,
        event_id,
        key_id + "/" + nonce,
      )
    Ok(@machines.WebhookFireExpired) =>
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_EXPIRED,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "trigger expired before commit",
        ),
        key_id,
        delivery,
        event_id,
        key_id + "/" + nonce,
      )
    Ok(@machines.WebhookFireNotFound) =>
      trigger_webhook_audit(
        state,
        trigger_id,
        @contracts.TRIGGER_REJECT_UNKNOWN_KEY,
        trigger_webhook_detail(
          body_hash,
          body.length(),
          "trigger disappeared before commit",
        ),
        key_id,
        delivery,
        event_id,
        key_id + "/" + nonce,
      )
    _ => ()
  }
  reply
}
