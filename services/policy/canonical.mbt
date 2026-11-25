///|
/// Canonical JSON fragments. The digest and content-hash algorithms are
/// defined over these exact strings, so they must stay stable:
///
/// * object keys are emitted in a fixed, documented order;
/// * strings use JSON escaping with lowercase `\u00xx` for control characters;
/// * arrays preserve order unless the field is explicitly sorted;
/// * integers are plain decimal, never floats.
///
/// No locale or process state is consulted, so the same request produces the
/// same digest in a different process on the same platform.

///|
fn hex_digit(value : Int32) -> Char {
  if value < 10 {
    (value + 48).unsafe_to_char()
  } else {
    (value + 87).unsafe_to_char()
  }
}

///|
fn four_hex(value : Int32) -> String {
  let mut out = ""
  let mut shift = 12
  while shift >= 0 {
    out = out + hex_digit((value >> shift) & 15).to_string()
    shift = shift - 4
  }
  out
}

///|
/// Quote one string as a canonical JSON string. Escapes quote, backslash,
/// the short control escapes and everything below U+0020. Non-ASCII text is
/// emitted as UTF-8 by the digest encoder, not as \u escapes.
pub fn canonical_quote(text : String) -> String {
  let mut out = "\""
  for ch in text {
    match ch {
      '"' => out = out + "\\\""
      '\\' => out = out + "\\\\"
      '\n' => out = out + "\\n"
      '\r' => out = out + "\\r"
      '\t' => out = out + "\\t"
      _ =>
        if ch.to_int() < 32 {
          out = out + "\\u" + four_hex(ch.to_int())
        } else {
          out = out + ch.to_string()
        }
    }
  }
  out + "\""
}

///|
pub fn canonical_bool(value : Bool) -> String {
  if value {
    "true"
  } else {
    "false"
  }
}

///|
pub fn canonical_int64(value : Int64) -> String {
  value.to_string()
}

///|
/// Emit a JSON array of strings in the given order. Callers that need
/// order-independence pass `sorted_unique(...)` first.
pub fn canonical_string_array(values : Array[String]) -> String {
  let mut out = "["
  let mut index = 0
  while index < values.length() {
    if index > 0 {
      out = out + ","
    }
    out = out + canonical_quote(values[index])
    index = index + 1
  }
  out + "]"
}
