///|
/// Crockford base32 alphabet used by ULID.
const ULID_ALPHABET : String = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

///|
/// 48-bit timestamp part of a ULID, encoded as 10 base32 characters.
/// Exposed separately so the encoding can be unit-tested deterministically.
pub fn encode_ulid_time(ms : Int64) -> String {
  let max_time : Int64 = 281_474_976_710_655
  let value : Int64 = if ms < 0 {
    0
  } else if ms > max_time {
    max_time
  } else {
    ms
  }
  let mut out = ""
  for shift in [45, 40, 35, 30, 25, 20, 15, 10, 5, 0] {
    let digit = (value >> shift) & 31
    out = out + ulid_digit(digit.to_int())
  }
  out
}

///|
/// Generate a ULID: 10 characters of millisecond time plus 16 characters of
/// randomness (80 bits). IDs are lexicographically sortable by time.
pub fn new_ulid(ms : Int64) -> String {
  let rand = @random.Rand::chacha8()
  let mut out = encode_ulid_time(ms)
  for _ in 0..<16 {
    out = out + ulid_digit(rand.int(limit=32).to_int())
  }
  out
}

///|
/// ADR 0002-style prefixed identifier: `<prefix>_<ULID>`.
pub fn new_id(prefix : String, ms : Int64) -> String {
  prefix + "_" + new_ulid(ms)
}

///|
fn ulid_digit(index : Int) -> String {
  let found = ULID_ALPHABET.get_char(index)
  match found {
    Some(ch) => ch.to_string()
    None => "0"
  }
}
