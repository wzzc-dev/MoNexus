///|
/// Hashing, encoding and constant-time comparison helpers.
///
/// No cipher or key exchange is implemented here: confidentiality and
/// integrity come from pinned TLS (OpenSSL in `moonbitlang/async/tls`). The
/// only cryptographic operation below is SHA-256, used for credential and
/// pairing-code hashes, certificate fingerprints and event hashes.

///|
pub fn hex_of(bytes : BytesView) -> String {
  @hex.encode(bytes)
}

///|
pub fn bytes_of_hex(text : String) -> Bytes? {
  let decoded = @hex.decode(text) catch { _ => return None }
  Some(decoded)
}

///|
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
pub fn sha256_bytes(data : BytesView) -> Bytes {
  let digest = @crypto.sha256(data)
  Bytes::from_fixedarray(digest)
}

///|
pub fn sha256_hex(data : BytesView) -> String {
  hex_of(sha256_bytes(data).exact_view())
}

///|
pub fn sha256_text(text : String) -> String {
  sha256_hex(@utf8.encode(text).exact_view())
}

///|
/// Constant-time comparison for equal-length byte strings. Length is not
/// secret (both values come from the same protocol field); the comparison
/// itself must not stop at the first mismatch.
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
/// Constant-time comparison of two hex strings. Malformed input compares as
/// unequal without leaking a position.
pub fn constant_time_hex_eq(left : String, right : String) -> Bool {
  if left.length() != right.length() {
    return false
  }
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

///|
/// Draw CSPRNG bytes. Fails closed when the platform entropy source is
/// unavailable; there is no deterministic fallback.
pub fn random_bytes(count : Int) -> Result[Bytes, String] {
  if count <= 0 || count > 1024 {
    return Err("invalid entropy request size")
  }
  match @env.rand(count) {
    Some(value) => Ok(value)
    None => Err("platform entropy source is unavailable")
  }
}

///|
pub fn random_hex(count : Int) -> Result[String, String] {
  match random_bytes(count) {
    Ok(value) => Ok(hex_of(value.exact_view()))
    Err(message) => Err(message)
  }
}

///|
/// SHA-256 fingerprint of a DER certificate as lowercase hex. This is the
/// value pinned by the client and compared against `get_peer_certificate`.
pub fn certificate_fingerprint(der : BytesView) -> String {
  sha256_hex(der)
}
