///|
/// Length-prefixed JSON-RPC frames over a pinned TLS stream.
///
/// A1.0 deviation: `moonbitlang/async@0.22.x` has no TLS-capable HTTP server,
/// so `@websocket.Conn::from_http_server` cannot be used behind TLS (see
/// README "Findings"). The spike therefore runs the existing JSON-RPC request
/// and response objects over a raw TLS stream with a 4-byte big-endian length
/// prefix. There is deliberately no plaintext variant of these functions:
/// every helper here takes `@tls.Tls`, so a caller cannot accidentally
/// downgrade the transport.

///|
pub const MAX_FRAME_BYTES : Int = 65_536

///|
pub suberror FrameError {
  FrameTooLarge(Int)
  FrameEmpty
}

///|
fn u32_be_to_int(header : Bytes) -> Int {
  header[0].to_int() * 16_777_216 +
  header[1].to_int() * 65_536 +
  header[2].to_int() * 256 +
  header[3].to_int()
}

///|
fn int_to_u32_be(value : Int) -> Bytes {
  Bytes::makei(
    4,
    index => ((value >> ((3 - index) * 8)) & 0xff).to_byte(),
  )
}

///|
pub async fn write_frame(tls : @tls.Tls, value : @json.Json) -> Unit raise {
  let body = @utf8.encode(value.stringify())
  let size = body.length()
  if size > MAX_FRAME_BYTES {
    raise FrameTooLarge(size)
  }
  tls.write(int_to_u32_be(size).exact_view())
  tls.write(body.exact_view())
}

///|
pub async fn read_frame(tls : @tls.Tls) -> @json.Json raise {
  let header = tls.read_exactly(4)
  let size = u32_be_to_int(header)
  if size == 0 {
    raise FrameEmpty
  }
  if size > MAX_FRAME_BYTES {
    raise FrameTooLarge(size)
  }
  let body = tls.read_exactly(size)
  let text = @utf8.decode(body.exact_view())
  @json.parse(text)
}

///|
/// Compare the peer leaf certificate's SHA-256 fingerprint with the pinned
/// value. Fails closed: no payload is exchanged unless this returns `Ok`.
/// This is the second pinning layer; the client also pins the CA via
/// `TrustedRoot::CustomPemFile` so an unrelated CA cannot complete the
/// handshake at all.
pub fn verify_pin(
  tls : @tls.Tls,
  expected_sha256_hex : String,
) -> Result[Unit, String] raise {
  let der = match tls.get_peer_certificate() {
    Some(value) => value
    None => return Err("peer presented no certificate")
  }
  let actual = @protocol.sha256_hex(der.exact_view())
  if actual == expected_sha256_hex {
    Ok(())
  } else {
    Err("certificate pin mismatch")
  }
}
