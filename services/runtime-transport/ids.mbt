///|
/// Small validation and formatting helpers shared by the transport modules.
///
/// Everything here is deliberately allocation-bounded: identifiers, detail
/// strings and peer addresses come from untrusted frames, and none of them may
/// be allowed to grow state or logs without a cap.

///|
/// Allow only characters that are safe in an id without quoting or escaping.
pub fn is_safe_id(text : String) -> Bool {
  if text == "" || text.length() > MAX_RUNTIME_ID_LEN {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' ||
      ch == ':'
    if !ok {
      return false
    }
  }
  true
}

///|
pub fn is_safe_token_text(text : String, max_len : Int) -> Bool {
  if text == "" || text.length() > max_len {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' ||
      ch == ':'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Truncate a string to at most `limit` characters. Used for bounded
/// diagnostics; callers pass already-redacted text.
pub fn clamp_text(text : String, limit : Int) -> String {
  if text.length() <= limit {
    return text
  }
  let out = StringBuilder()
  let mut index = 0
  while index < text.length() && index < limit {
    match text.get_char(index) {
      Some(ch) => out.write_char(ch)
      None => break
    }
    index = index + 1
  }
  out.to_string()
}

///|
/// Redact credential-looking values and bound the result.
pub fn safe_detail(text : String) -> String {
  clamp_text(@contracts.redact_secrets(text), MAX_DETAIL_LEN)
}

///|
/// Redact an exception before it reaches a log or a client. Messages are
/// bounded and secret-shaped substrings are removed.
pub fn safe_error(error : Error) -> String {
  safe_detail(error.to_string())
}

///|
/// Strip the ephemeral port from a socket address so rate limiting is keyed by
/// host, not by connection. A peer that opens a new socket per attempt must not
/// get a fresh budget.
pub fn source_host(peer : String) -> String {
  let result = if peer.has_prefix("[") {
    match peer.find("]") {
      Some(index) => {
        let end = index + 1
        if end <= peer.length() {
          peer.substring(start=0, end=end)
        } else {
          peer
        }
      }
      None => peer
    }
  } else {
    match peer.rev_find(":") {
      Some(index) => peer.substring(start=0, end=index)
      None => peer
    }
  }
  clamp_text(result, MAX_PEER_LEN)
}

///|
/// Clamp a millisecond duration into the Int32 range accepted by
/// `@async.with_timeout_opt`, never returning zero or a negative timeout.
pub fn timeout_ms_of(value : Int64) -> Int {
  if value <= 1L {
    return 1
  }
  if value > 2_000_000_000L {
    return 2_000_000_000
  }
  value.to_int()
}

///|
/// Milliseconds since the Unix epoch for wire fields and audit entries.
pub fn wire_ts(now_ms : Int64) -> String {
  now_ms.to_string()
}
