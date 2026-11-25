///|
/// Small shared helpers. Kept dependency-free so the policy core can be
/// reused by the A1.2 transport without pulling in host or runtime code.

///|
/// Copy, sort and de-duplicate a string array. Rule arrays are canonicalized
/// this way so a snapshot's content hash does not depend on declaration order.
pub fn sorted_unique(values : Array[String]) -> Array[String] {
  let sorted = values.copy()
  sorted.sort()
  let out : Array[String] = []
  let mut index = 0
  while index < sorted.length() {
    if index == 0 || sorted[index] != sorted[index - 1] {
      out.push(sorted[index])
    }
    index = index + 1
  }
  out
}

///|
pub fn array_contains(values : Array[String], needle : String) -> Bool {
  values.contains(needle)
}

///|
/// Whether `text` contains any of the (already lowercase) needles.
pub fn text_has_any(text : String, needles : Array[String]) -> Bool {
  for needle in needles {
    if text.contains(needle) {
      return true
    }
  }
  false
}

///|
/// Last path component, lowercased. `/usr/bin/Git` -> `git`. Used for
/// conservative command matching; no filesystem access.
pub fn command_basename(token : String) -> String {
  let lower = token.to_lower()
  let mut name = lower
  for part in lower.split("/") {
    name = part.to_owned()
  }
  name
}

///|
/// Join argv into one lowercase text for conservative substring matching.
/// Quoted arguments are matched as literal text; that can only over-classify.
pub fn command_text(argv : Array[String]) -> String {
  let lower : Array[String] = []
  for item in argv {
    lower.push(item.to_lower())
  }
  lower.join(" ")
}

///|
fn is_control_char(ch : Char) -> Bool {
  let code = ch.to_int()
  code < 32 || code == 127
}

///|
/// Reject control characters in values that may be echoed into reasons or
/// stored in events. Returns false when a control character is present.
pub fn is_printable_text(text : String) -> Bool {
  for ch in text {
    if is_control_char(ch) {
      return false
    }
  }
  true
}

///|
/// Version / nonce / id charset: printable ASCII without whitespace or any
/// character that could forge a log line or a path. Length is checked by the
/// caller.
pub fn is_token_text(text : String) -> Bool {
  if text == "" {
    return false
  }
  for ch in text {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '.' || ch == '_' || ch == '-' || ch == '~' || ch == ':' ||
      ch == '/' || ch == '@'
    if !ok {
      return false
    }
  }
  true
}

///|
/// POSIX environment variable name: [A-Za-z_][A-Za-z0-9_]*.
pub fn is_env_name(name : String) -> Bool {
  if name == "" {
    return false
  }
  let mut index = 0
  for ch in name {
    let first = index == 0
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') || ch == '_'
    let head_ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') || ch == '_'
    if first && !head_ok {
      return false
    }
    if !ok {
      return false
    }
    index = index + 1
  }
  true
}
