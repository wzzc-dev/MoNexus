///|
/// Length-prefixed JSON-RPC frames over a pinned TLS stream.
///
/// A1 deviation from ADR-0012's WSS wording: `moonbitlang/async@0.22.7` has
/// no TLS-capable HTTP server, so the WebSocket server cannot be used behind
/// TLS. The transport runs the existing `@contracts` JSON-RPC envelope over
/// the raw TLS stream with a 4-byte big-endian length prefix:
///
/// ```text
/// 4 bytes big-endian N (1..65536), then N bytes of UTF-8 JSON
/// ```
///
/// Every helper takes `@tls.Tls`; there is no plaintext variant and no
/// fallback path. Exceeding the bound, an empty frame, invalid JSON or a
/// non-object top level is a protocol failure and the caller closes the
/// connection.

///|
pub suberror FrameError {
  FrameTooLarge(Int)
  FrameEmpty
  FrameNotObject
  FrameMalformed(String)
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
  Bytes::makei(4, index => ((value >> ((3 - index) * 8)) & 0xff).to_byte())
}

///|
pub async fn write_frame(tls : @tls.Tls, value : @json.Json) -> Unit raise {
  let body = @utf8.encode(value.stringify())
  let size = body.length()
  if size == 0 {
    raise FrameEmpty
  }
  if size > MAX_FRAME_BYTES {
    raise FrameTooLarge(size)
  }
  tls.write(int_to_u32_be(size).exact_view())
  tls.write(body.exact_view())
}

///|
pub async fn read_frame(tls : @tls.Tls) -> @json.Json raise {
  let header = tls.read_exactly(MAX_FRAME_HEADER_BYTES)
  let size = u32_be_to_int(header)
  if size == 0 {
    raise FrameEmpty
  }
  if size > MAX_FRAME_BYTES {
    raise FrameTooLarge(size)
  }
  let body = tls.read_exactly(size)
  let text = @utf8.decode(body.exact_view()) catch {
    _ => raise FrameMalformed("frame is not valid UTF-8")
  }
  let value = @json.parse(
    text,
    max_nesting_depth=MAX_JSON_DEPTH,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise FrameMalformed("frame is not valid JSON")
  }
  match value.as_object() {
    Some(_) => value
    None => raise FrameNotObject
  }
}

///|
/// Encode one frame to bytes without writing it. Bounded by the same 64 KiB
/// cap; used by tests and by callers that need the exact wire bytes.
pub fn encode_frame(value : @json.Json) -> Result[Bytes, FrameError] {
  match value.as_object() {
    Some(_) => ()
    None => return Err(FrameNotObject)
  }
  let body = @utf8.encode(value.stringify())
  if body.length() == 0 {
    return Err(FrameEmpty)
  }
  if body.length() > MAX_FRAME_BYTES {
    return Err(FrameTooLarge(body.length()))
  }
  let size = body.length()
  let out = Bytes::makei(MAX_FRAME_HEADER_BYTES + size, index => {
    if index < MAX_FRAME_HEADER_BYTES {
      ((size >> ((3 - index) * 8)) & 0xff).to_byte()
    } else {
      body[index - MAX_FRAME_HEADER_BYTES]
    }
  })
  Ok(out)
}
