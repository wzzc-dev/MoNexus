///|
/// Hashing and encoding helpers used by the A1.0 pairing spike.
///
/// Everything here is a thin wrapper over `moonbitlang/x/crypto` and
/// `moonbitlang/core/encoding`. The spike does not implement any cipher,
/// signature scheme or key exchange of its own: confidentiality comes from
/// `moonbitlang/async/tls` (OpenSSL on Linux), and the only cryptographic
/// operations defined here are SHA-256 for fingerprints and HMAC-SHA256 for
/// the optional challenge-response credential proof.
///
/// No asymmetric signature API is exposed by MoonBit core or
/// `moonbitlang/x@0.5.6`, so a node cannot present a public-key signature.
/// See README "Findings" for the consequences.

///|
/// Hex-encode a byte view. Used for fingerprints, nonces and secret material
/// that is only ever compared, never printed.
pub fn hex_of(bytes : BytesView) -> String {
  @hex.encode(bytes)
}

///|
/// Decode a hex string; `None` for malformed or non-hex input.
pub fn bytes_of_hex(text : String) -> Bytes? {
  let decoded = @hex.decode(text) catch { _ => return None }
  Some(decoded)
}

///|
/// True when a string is hex of exactly `length` characters.
pub fn is_hex_of_length(text : String, length : Int) -> Bool {
  if text.length() != length {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
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
/// SHA-256 digest as raw bytes.
pub fn sha256_bytes(data : BytesView) -> Bytes {
  let digest = @crypto.sha256(data)
  Bytes::from_fixedarray(digest)
}

///|
/// SHA-256 digest as lowercase hex.
pub fn sha256_hex(data : BytesView) -> String {
  hex_of(sha256_bytes(data).exact_view())
}

///|
/// SHA-256 of a string's UTF-8 bytes.
pub fn sha256_text(text : String) -> String {
  sha256_hex(@utf8.encode(text).exact_view())
}

///|
/// HMAC-SHA256. Used for the challenge-response machine credential proof.
pub fn hmac_sha256(key : BytesView, message : BytesView) -> Bytes {
  let mac = @crypto.hmac(@crypto.SHA256::new(), key, message)
  Bytes::from_fixedarray(mac)
}

///|
/// HMAC-SHA256 over a string transcript.
pub fn hmac_sha256_text(key : BytesView, message : String) -> Bytes {
  hmac_sha256(key, @utf8.encode(message).exact_view())
}

///|
/// Constant-time byte comparison. Length is not secret (both values come from
/// the same protocol field), but the comparison itself must not stop early.
pub fn constant_time_eq(left : BytesView, right : BytesView) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let mut diff = 0
  for index in 0..<left.length() {
    diff = diff | (left[index].to_int() ^ right[index].to_int())
  }
  diff == 0
}

///|
/// Compare two hex strings without leaking the first mismatch position.
pub fn constant_time_hex_eq(left : String, right : String) -> Bool {
  let left_bytes = match bytes_of_hex(left) {
    Some(value) => value
    None => return false
  }
  let right_bytes = match bytes_of_hex(right) {
    Some(value) => value
    None => return false
  }
  constant_time_eq(left_bytes.exact_view(), right_bytes.exact_view())
}
