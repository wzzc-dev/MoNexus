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
/// Process-local counter mixed into the random half. Without it, two IDs made
/// in the same millisecond share the deterministic chacha8 stream and the
/// event table's UNIQUE(id) silently drops the second insert.
let ulid_counter : Ref[Int] = Ref(0)

///|
/// Generate a ULID: 10 characters of millisecond time plus 16 characters of
/// randomness (80 bits) and a process-local counter. IDs are lexicographically
/// sortable by time and unique within one host process.
pub fn new_ulid(ms : Int64) -> String {
  let rand = @random.Rand::chacha8()
  let digits : Array[Int] = []
  for _ in 0..<16 {
    digits.push(rand.int(limit=32).to_int())
  }
  let counter = ulid_counter.val
  ulid_counter.val = counter + 1
  let mut remaining = counter
  let mut index = 15
  while index >= 8 {
    digits[index] = remaining & 31
    remaining = remaining >> 5
    index = index - 1
  }
  let mut out = encode_ulid_time(ms)
  for digit in digits {
    out = out + ulid_digit(digit)
  }
  out
}

///|
/// ADR 0002-style prefixed identifier: `<prefix>_<ULID>`.
pub fn new_id(prefix : String, ms : Int64) -> String {
  prefix + "_" + new_ulid(ms)
}

///|
/// ADR-0017 §2.1 canonical object prefixes. New objects never use `agt_` or
/// `ses_`; those remain legacy aliases handled elsewhere.
pub const BOT_ID_PREFIX : String = "bot"

///|
pub const AGENT_ID_PREFIX : String = "agw"

///|
pub const CHAT_ID_PREFIX : String = "cht"

///|
pub const AGENT_SESSION_ID_PREFIX : String = "asn"

///|
pub const PROJECT_ID_PREFIX : String = "prj"

///|
pub const LEGACY_AGENT_ID_PREFIX : String = "agt"

///|
pub const LEGACY_SESSION_ID_PREFIX : String = "ses"

///|
pub fn new_bot_id(ms : Int64) -> String {
  new_id(BOT_ID_PREFIX, ms)
}

///|
pub fn new_agent_id(ms : Int64) -> String {
  new_id(AGENT_ID_PREFIX, ms)
}

///|
pub fn new_chat_id(ms : Int64) -> String {
  new_id(CHAT_ID_PREFIX, ms)
}

///|
pub fn new_agent_session_id(ms : Int64) -> String {
  new_id(AGENT_SESSION_ID_PREFIX, ms)
}

///|
/// Existing Project IDs keep the frozen `prj_` prefix.
pub fn new_project_id(ms : Int64) -> String {
  new_id(PROJECT_ID_PREFIX, ms)
}

///|
/// Generate an ID only for an ADR-0017 canonical object kind. Legacy `agt` and
/// `ses` prefixes are rejected instead of being silently reused.
pub fn new_canonical_id(prefix : String, ms : Int64) -> Result[String, String] {
  match prefix {
    "bot" | "agw" | "cht" | "asn" | "prj" => Ok(new_id(prefix, ms))
    "agt" | "ses" =>
      Err("legacy prefix cannot be used for a new ADR-0017 object")
    _ => Err("unknown canonical ADR-0017 object prefix")
  }
}

///|
fn ulid_suffix_valid(value : String) -> Bool {
  if value.length() != 26 {
    return false
  }
  for index in 0..<value.length() {
    let ch = match value.get_char(index) {
      Some(found) => found
      None => return false
    }
    if !ULID_ALPHABET.contains(ch.to_string()) {
      return false
    }
  }
  true
}

///|
pub fn prefixed_id_valid(prefix : String, value : String) -> Bool {
  let head = prefix + "_"
  if !value.has_prefix(head) {
    return false
  }
  ulid_suffix_valid(value[head.length():].to_owned())
}

///|
pub fn is_bot_id(value : String) -> Bool {
  prefixed_id_valid(BOT_ID_PREFIX, value)
}

///|
pub fn is_agent_id(value : String) -> Bool {
  prefixed_id_valid(AGENT_ID_PREFIX, value)
}

///|
pub fn is_chat_id(value : String) -> Bool {
  prefixed_id_valid(CHAT_ID_PREFIX, value)
}

///|
pub fn is_agent_session_id(value : String) -> Bool {
  prefixed_id_valid(AGENT_SESSION_ID_PREFIX, value)
}

///|
pub fn is_project_id(value : String) -> Bool {
  prefixed_id_valid(PROJECT_ID_PREFIX, value)
}

///|
pub fn is_legacy_agent_id(value : String) -> Bool {
  value.has_prefix(LEGACY_AGENT_ID_PREFIX + "_")
}

///|
pub fn is_legacy_session_id(value : String) -> Bool {
  value.has_prefix(LEGACY_SESSION_ID_PREFIX + "_")
}

///|
/// True only for an ADR-0017 canonical object ID. Legacy IDs fail even when
/// they otherwise look like a ULID.
pub fn is_canonical_object_id(value : String) -> Bool {
  is_bot_id(value) ||
  is_agent_id(value) ||
  is_chat_id(value) ||
  is_agent_session_id(value) ||
  is_project_id(value)
}

///|
fn ulid_digit(index : Int) -> String {
  let found = ULID_ALPHABET.get_char(index)
  match found {
    Some(ch) => ch.to_string()
    None => "0"
  }
}
