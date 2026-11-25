///|
/// ASCII and path helpers shared by the schema validators.
///
/// Every helper is a pure predicate over the exact declared text: there is no
/// normalisation, trimming or "best effort" repair. A value either satisfies
/// the published grammar or the recipe is refused with a stable reason code.
fn is_digit(ch : Char) -> Bool {
  ch >= '0' && ch <= '9'
}

///|
fn is_lower_alnum(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
}

///|
fn is_upper_alnum(ch : Char) -> Bool {
  (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
}

///|
fn is_alnum(ch : Char) -> Bool {
  is_lower_alnum(ch) || is_upper_alnum(ch)
}

///|
fn is_name_tail(ch : Char) -> Bool {
  is_lower_alnum(ch) || ch == '-'
}

///|
fn is_env_tail(ch : Char) -> Bool {
  is_alnum(ch) || ch == '_'
}

///|
fn is_path_segment_char(ch : Char) -> Bool {
  is_alnum(ch) || ch == '.' || ch == '_' || ch == '-'
}

///|
fn is_host_path_char(ch : Char) -> Bool {
  let code = ch.to_int()
  // Printable ASCII except comma (host paths are embedded in the CSV-like
  // `--mount` argument, so a comma would change its meaning) and '`'/'$'
  // quoting metacharacters that only confuse diagnostics. The path is passed
  // as a single argv element, never through a shell.
  code >= 32 && code <= 126 && ch != ',' && ch != '`' && ch != '$'
}

///|
fn has_control_chars(text : String, allow_layout : Bool) -> Bool {
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return true
    }
    let code = ch.to_int()
    if code < 32 {
      let layout = allow_layout &&
        (ch == '\n' || ch == '\r' || ch == '\t')
      if !layout {
        return true
      }
    } else if code == 127 {
      return true
    }
  }
  false
}

///|
/// `[a-z0-9][a-z0-9-]{0,63}` (ADR-0013 §2.1).
pub fn is_valid_recipe_name(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  let first = match text.get_char(0) {
    Some(ch) => ch
    None => return false
  }
  if !is_lower_alnum(first) {
    return false
  }
  for index in 1..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if !is_name_tail(ch) {
      return false
    }
  }
  true
}

///|
fn valid_numeric_identifier(text : String) -> Bool {
  if text.length() == 0 || text.length() > 9 {
    return false
  }
  if text.length() > 1 && text.get_char(0) == Some('0') {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if !is_digit(ch) {
      return false
    }
  }
  true
}

///|
fn valid_prerelease(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  let parts = text.split(".")
  let mut count = 0
  for raw in parts {
    let part = raw.to_owned()
    count = count + 1
    if count > 8 || part.length() == 0 || part.length() > 32 {
      return false
    }
    let mut numeric = true
    for index in 0..<part.length() {
      let ch = match part.get_char(index) {
        Some(value) => value
        None => return false
      }
      if !is_alnum(ch) && ch != '-' {
        return false
      }
      if !is_digit(ch) {
        numeric = false
      }
    }
    if numeric && !valid_numeric_identifier(part) {
      return false
    }
  }
  true
}

///|
fn valid_build_metadata(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  let parts = text.split(".")
  let mut count = 0
  for raw in parts {
    let part = raw.to_owned()
    count = count + 1
    if count > 8 || part.length() == 0 || part.length() > 32 {
      return false
    }
    for index in 0..<part.length() {
      let ch = match part.get_char(index) {
        Some(value) => value
        None => return false
      }
      if !is_alnum(ch) && ch != '-' {
        return false
      }
    }
  }
  true
}

///|
/// Strict SemVer 2.0.0: `MAJOR.MINOR.PATCH[-prerelease][+build]`.
/// Numeric identifier width is capped so a version cannot smuggle an
/// arbitrarily long token into canonical bytes or logs.
pub fn is_valid_semver(text : String) -> Bool {
  if text.length() == 0 || text.length() > 128 {
    return false
  }
  let mut core = text
  match text.find("+") {
    Some(index) => {
      if index >= text.length() - 1 {
        return false
      }
      let build = text[index + 1:].to_owned()
      if !valid_build_metadata(build) {
        return false
      }
      core = text[:index].to_owned()
    }
    None => ()
  }
  match core.find("-") {
    Some(index) => {
      if index >= core.length() - 1 {
        return false
      }
      let pre = core[index + 1:].to_owned()
      if !valid_prerelease(pre) {
        return false
      }
      core = core[:index].to_owned()
    }
    None => ()
  }
  let parts = core.split(".")
  let collected : Array[String] = []
  for raw in parts {
    collected.push(raw.to_owned())
  }
  if collected.length() != 3 {
    return false
  }
  for part in collected {
    if !valid_numeric_identifier(part) {
      return false
    }
  }
  true
}

///|
/// `name@version`, both halves validated. A single `@` is required because
/// recipe names may not contain `@` (ADR-0013 §2.1).
pub fn parse_recipe_identity(text : String) -> (String, String)? {
  let index = match text.find("@") {
    Some(value) => value
    None => return None
  }
  let name = text[:index].to_owned()
  let version = text[index + 1:].to_owned()
  if !is_valid_recipe_name(name) || !is_valid_semver(version) {
    return None
  }
  if version.contains("@") {
    return None
  }
  Some((name, version))
}

///|
fn valid_date_part(text : String, index : Int, length : Int) -> Int? {
  let mut value = 0
  for offset in 0..<length {
    let ch = match text.get_char(index + offset) {
      Some(found) => found
      None => return None
    }
    if !is_digit(ch) {
      return None
    }
    value = value * 10 + (ch.to_int() - 48)
  }
  Some(value)
}

///|
/// `YYYY-MM-DDTHH:MM:SSZ` only. Offsets and fractional seconds are rejected so
/// canonical bytes and audit ordering are unambiguous.
pub fn is_valid_timestamp(text : String) -> Bool {
  if text.length() != 20 {
    return false
  }
  let separators : FixedArray[(Int, Char)] = [(4, '-'), (7, '-'), (10, 'T'),
    (13, ':'), (16, ':'), (19, 'Z')]
  for entry in separators {
    let (index, expected) = entry
    if text.get_char(index) != Some(expected) {
      return false
    }
  }
  let year = match valid_date_part(text, 0, 4) {
    Some(value) => value
    None => return false
  }
  let month = match valid_date_part(text, 5, 2) {
    Some(value) => value
    None => return false
  }
  let day = match valid_date_part(text, 8, 2) {
    Some(value) => value
    None => return false
  }
  let hour = match valid_date_part(text, 11, 2) {
    Some(value) => value
    None => return false
  }
  let minute = match valid_date_part(text, 14, 2) {
    Some(value) => value
    None => return false
  }
  let second = match valid_date_part(text, 17, 2) {
    Some(value) => value
    None => return false
  }
  year >= 1970 && year <= 9999 && month >= 1 && month <= 12 &&
  day >= 1 && day <= 31 && hour <= 23 && minute <= 59 && second <= 59
}

///|
/// `[A-Za-z_][A-Za-z0-9_]{0,127}`. Only names ever come from a recipe; values
/// are supplied by the caller at create time (ADR-0013 §4.3).
pub fn is_valid_env_name(text : String) -> Bool {
  if text.length() == 0 || text.length() > 128 {
    return false
  }
  let first = match text.get_char(0) {
    Some(ch) => ch
    None => return false
  }
  if !(is_alpha_underscore(first)) {
    return false
  }
  for index in 1..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if !is_env_tail(ch) {
      return false
    }
  }
  true
}

///|
fn is_alpha_underscore(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

///|
/// Trust-store key identifiers double as `ssh-keygen -Y verify -I` identities
/// and allowed-signers principals, so the grammar is deliberately narrow.
pub fn is_valid_key_id(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = is_alnum(ch) || ch == '.' || ch == '_' || ch == '-' || ch == '@'
    if !ok {
      return false
    }
  }
  true
}

///|
fn valid_repo_component(text : String) -> Bool {
  if text.length() == 0 || text.length() > 128 {
    return false
  }
  let first = match text.get_char(0) {
    Some(ch) => ch
    None => return false
  }
  let last = match text.get_char(text.length() - 1) {
    Some(ch) => ch
    None => return false
  }
  if !is_lower_alnum(first) || !is_lower_alnum(last) {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = is_lower_alnum(ch) || ch == '.' || ch == '_' || ch == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
fn valid_registry_host(text : String) -> Bool {
  if text.length() == 0 || text.length() > 128 {
    return false
  }
  let mut host = text
  match text.rev_find(":") {
    Some(index) => {
      let port = text[index + 1:].to_owned()
      if port.length() == 0 || port.length() > 5 {
        return false
      }
      for offset in 0..<port.length() {
        let ch = match port.get_char(offset) {
          Some(value) => value
          None => return false
        }
        if !is_digit(ch) {
          return false
        }
      }
      host = text[:index].to_owned()
    }
    None => ()
  }
  if host.length() == 0 {
    return false
  }
  let first = match host.get_char(0) {
    Some(ch) => ch
    None => return false
  }
  let last = match host.get_char(host.length() - 1) {
    Some(ch) => ch
    None => return false
  }
  if first == '.' || first == '-' || last == '.' || last == '-' {
    return false
  }
  for index in 0..<host.length() {
    let ch = match host.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = is_alnum(ch) || ch == '.' || ch == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
fn valid_tag(text : String) -> Bool {
  if text.length() == 0 || text.length() > 128 {
    return false
  }
  let first = match text.get_char(0) {
    Some(ch) => ch
    None => return false
  }
  if !(is_alnum(first) || first == '_') {
    return false
  }
  for index in 1..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = is_alnum(ch) || ch == '.' || ch == '_' || ch == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Split `registry/repo:tag` into the digest-stable repository part. The tag is
/// display-only (ADR-0013 §2.1); pull/create always use `repo@sha256:`.
/// Returns `None` for any reference outside the accepted grammar.
pub fn image_repository(text : String) -> String? {
  if text.length() == 0 || text.length() > 255 {
    return None
  }
  if has_control_chars(text, false) || text.contains("@") {
    return None
  }
  let last_slash = match text.rev_find("/") {
    Some(value) => value
    None => -1
  }
  // A colon before the last slash is a registry port, not a tag separator.
  let mut tag_index = -1
  let mut scan = last_slash + 1
  while scan < text.length() {
    if text.get_char(scan) == Some(':') {
      tag_index = scan
      break
    }
    scan = scan + 1
  }
  let mut repository = text
  if tag_index >= 0 {
    let tag = text[tag_index + 1:].to_owned()
    if !valid_tag(tag) {
      return None
    }
    repository = text[:tag_index].to_owned()
  }
  if repository.length() == 0 || repository.length() > 200 {
    return None
  }
  let parts = repository.split("/")
  let components : Array[String] = []
  for raw in parts {
    components.push(raw.to_owned())
  }
  if components.length() == 0 {
    return None
  }
  let mut start = 0
  if components.length() >= 2 {
    let first = components[0]
    let looks_like_registry = first.contains(".") || first.contains(":") ||
      first == "localhost"
    if looks_like_registry {
      if !valid_registry_host(first) {
        return None
      }
      start = 1
    }
  }
  if start >= components.length() {
    return None
  }
  for index in start..<components.length() {
    if !valid_repo_component(components[index]) {
      return None
    }
  }
  Some(repository)
}

///|
/// `sha256:<64 lowercase hex>`; the tag never participates in execution.
pub fn is_valid_image_digest(text : String) -> Bool {
  if text.length() != 71 {
    return false
  }
  if !text.has_prefix("sha256:") {
    return false
  }
  for index in 7..<71 {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if !(is_digit(ch) || (ch >= 'a' && ch <= 'f')) {
      return false
    }
  }
  true
}

///|
/// Absolute, normalised container path: `/a/b`, never `/`, no `..`, no empty
/// segment, no trailing slash, and a conservative character set so the value
/// can be embedded in `--mount` without quoting.
pub fn is_valid_container_path(text : String) -> Bool {
  if text.length() < 2 || text.length() > 200 {
    return false
  }
  if text.get_char(0) != Some('/') {
    return false
  }
  if text.get_char(text.length() - 1) == Some('/') {
    return false
  }
  let mut segment_length = 0
  for index in 1..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if ch == '/' {
      if segment_length == 0 {
        return false
      }
      segment_length = 0
      continue
    }
    if !is_path_segment_char(ch) {
      return false
    }
    segment_length = segment_length + 1
  }
  segment_length > 0 && !segment_is_dot(text)
}

///|
fn segment_is_dot(text : String) -> Bool {
  // `is_valid_container_path` already rejects empty segments; `..` and `.`
  // must be rejected explicitly. Check every segment.
  let parts = text.split("/")
  for raw in parts {
    let part = raw.to_owned()
    if part == "." || part == ".." {
      return true
    }
  }
  false
}

///|
/// Absolute, normalised host path destined for a bind mount. Control
/// characters and commas are refused; `..` and empty segments would make
/// realpath checks meaningless.
pub fn is_valid_host_path(text : String) -> Bool {
  if text.length() < 2 || text.length() > 4096 {
    return false
  }
  if text.get_char(0) != Some('/') {
    return false
  }
  if text.get_char(text.length() - 1) == Some('/') {
    return false
  }
  let mut segment_length = 0
  for index in 1..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if ch == '/' {
      if segment_length == 0 {
        return false
      }
      segment_length = 0
      continue
    }
    if !is_host_path_char(ch) {
      return false
    }
    segment_length = segment_length + 1
  }
  if segment_length == 0 || segment_is_dot(text) {
    return false
  }
  true
}

///|
/// `user` accepts the image default, a numeric `uid[:gid]`, or a plain name.
/// `root` is syntactically valid; its risk classification belongs to the plan
/// stage (ADR-0013 §4.1), not to the schema.
pub fn is_valid_user(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  if has_control_chars(text, false) {
    return false
  }
  let colon = text.find(":")
  match colon {
    Some(index) => {
      let left = text[:index].to_owned()
      let right = text[index + 1:].to_owned()
      if right.contains(":") {
        return false
      }
      numeric_user_part(left) && numeric_user_part(right)
    }
    None => {
      if numeric_user_part(text) {
        return true
      }
      let first = match text.get_char(0) {
        Some(ch) => ch
        None => return false
      }
      if !(is_alnum(first) || first == '_') {
        return false
      }
      for offset in 1..<text.length() {
        let ch = match text.get_char(offset) {
          Some(value) => value
          None => return false
        }
        let ok = is_alnum(ch) || ch == '.' || ch == '_' || ch == '-'
        if !ok {
          return false
        }
      }
      true
    }
  }
}

///|
fn numeric_user_part(text : String) -> Bool {
  if text.length() == 0 || text.length() > 10 {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if !is_digit(ch) {
      return false
    }
  }
  true
}

///|
/// Byte-wise UTF-8 ordering, used to sort canonical object keys. UTF-8 byte
/// order equals code-point order, so the result is independent of locale.
pub fn compare_utf8(left : String, right : String) -> Int32 {
  let left_bytes = @utf8.encode(left).exact_view()
  let right_bytes = @utf8.encode(right).exact_view()
  let common = if left_bytes.length() < right_bytes.length() {
    left_bytes.length()
  } else {
    right_bytes.length()
  }
  let mut index = 0
  while index < common {
    let a = left_bytes[index].to_int()
    let b = right_bytes[index].to_int()
    if a < b {
      return -1
    }
    if a > b {
      return 1
    }
    index = index + 1
  }
  let left_len = left_bytes.length()
  let right_len = right_bytes.length()
  if left_len < right_len {
    -1
  } else if left_len > right_len {
    1
  } else {
    0
  }
}

///|
/// Absolute, normalised path for `source.path` metadata. It is never used as a
/// bind mount, so the character set is wider than `is_valid_host_path`
/// (commas and spaces are fine), but `..` and empty segments are still
/// refused so two spellings cannot denote the same origin.
pub fn is_valid_source_path(text : String) -> Bool {
  if text.length() < 2 || text.length() > 4096 {
    return false
  }
  if text.get_char(0) != Some('/') {
    return false
  }
  if has_control_chars(text, false) {
    return false
  }
  let mut segment_length = 0
  for index in 1..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    if ch == '/' {
      if segment_length == 0 {
        return false
      }
      segment_length = 0
      continue
    }
    segment_length = segment_length + 1
  }
  segment_length > 0 && !segment_is_dot(text)
}
