///|
/// Owner trust store for recipe signing keys (ADR-0013 §2.3).
///
/// The store is loaded from an owner-provided file. It must be a regular file
/// (not a symlink) whose mode allows the owner only to change it (`0600`, or
/// read-only `0400`). There is no TOFU: a key that is not in the store, or is
/// revoked, is refused. Recipes cannot add or replace keys.
///
/// The mode check shells out to the platform `stat` tool because the MoonBit
/// async FS API exposes kinds and timestamps but not permission bits. A
/// missing or unusable `stat` fails closed (`trust_store_unverifiable`); it is
/// never treated as "no restriction".

///|
pub const MAX_TRUST_STORE_BYTES : Int = 65_536

///|
/// One `recipe_trust(key_id, public_key, added_at, revoked_at)` row.
pub(all) struct TrustKey {
  key_id : String
  public_key : String
  added_at : String
  revoked_at : String?
}

///|
pub(all) struct TrustStore {
  keys : Map[String, TrustKey]
}

///|
pub fn TrustStore::empty() -> TrustStore {
  { keys: Map([]) }
}

///|
pub fn TrustStore::get(self : TrustStore, key_id : String) -> TrustKey? {
  self.keys.get(key_id)
}

///|
pub fn TrustStore::is_revoked(self : TrustStore, key_id : String) -> Bool {
  match self.keys.get(key_id) {
    Some(key) =>
      match key.revoked_at {
        Some(_) => true
        None => false
      }
    None => false
  }
}

///|
pub fn TrustStore::from_keys(keys : Array[TrustKey]) -> Result[TrustStore, RecipeError] {
  let store : Map[String, TrustKey] = Map([])
  for key in keys {
    let error = validate_trust_key(key)
    match error {
      Some(found) => return Err(found)
      None => ()
    }
    if store.contains(key.key_id) {
      return Err(
        RecipeError::new(DuplicateTrustKey).at("key_id").with_detail(
          "trust store contains a duplicated key id",
        ),
      )
    }
    store.set(key.key_id, key)
  }
  Ok({ keys: store })
}

///|
fn validate_trust_key(key : TrustKey) -> RecipeError? {
  if !is_valid_key_id(key.key_id) {
    return Some(
      RecipeError::new(KeyIdInvalid).at("key_id").with_detail(
        "trust store key id is outside the allowed grammar",
      ),
    )
  }
  if !is_valid_ed25519_public_key(key.public_key) {
    return Some(
      RecipeError::new(TrustKeyInvalid).at("public_key").with_detail(
        "expected an OpenSSH ssh-ed25519 public key without a comment",
      ),
    )
  }
  if !is_valid_timestamp(key.added_at) {
    return Some(
      RecipeError::new(TimestampInvalid).at("added_at").with_detail(
        "expected YYYY-MM-DDTHH:MM:SSZ",
      ),
    )
  }
  match key.revoked_at {
    Some(value) =>
      if !is_valid_timestamp(value) {
        return Some(
          RecipeError::new(TimestampInvalid).at("revoked_at").with_detail(
            "expected YYYY-MM-DDTHH:MM:SSZ",
          ),
        )
      }
    None => ()
  }
  None
}

///|
/// OpenSSH Ed25519 public key in the `ssh-ed25519 <base64>` form, with no
/// comment. The decoded blob is checked for the exact ed25519 key shape:
/// `string "ssh-ed25519"`, then a 32-byte `string`.
fn is_valid_ed25519_public_key(text : String) -> Bool {
  if text.length() < 30 || text.length() > 128 {
    return false
  }
  if !text.has_prefix("ssh-ed25519 ") {
    return false
  }
  let body = text[12:].to_owned()
  if body.length() == 0 || has_control_chars(body, false) {
    return false
  }
  for index in 0..<body.length() {
    if body.get_char(index) == Some(' ') {
      return false
    }
  }
  let bytes = @base64.decode(body) catch { _ => return false }
  if bytes.length() != 51 {
    return false
  }
  let view = bytes.exact_view()
  let expected : FixedArray[Int] = [0, 0, 0, 11, 115, 115, 104, 45, 101, 100,
    50, 53, 53, 49, 57, 0, 0, 0, 32]
  for index in 0..<19 {
    if view[index].to_int() != expected[index] {
      return false
    }
  }
  true
}

///|
/// Strict parse of the trust store document:
/// `{"keys":[{"key_id":…,"public_key":…,"added_at":…,"revoked_at":…}]}`.
pub fn parse_trust_store(text : String) -> Result[TrustStore, RecipeError] {
  if text.length() == 0 || text.length() > MAX_TRUST_STORE_BYTES {
    return Err(
      RecipeError::new(TrustStoreInvalid).with_detail(
        "trust store size is outside the allowed range",
      ),
    )
  }
  let json = @json.parse(text, reject_duplicate_keys=true, max_nesting_depth=16) catch {
    _ => return Err(RecipeError::new(TrustStoreInvalid).with_detail("invalid JSON"))
  }
  let object = match json {
    @json.Json::Object(value) => value
    _ =>
      return Err(
        RecipeError::new(TrustStoreInvalid).with_detail("object required"),
      )
  }
  for key in object.keys() {
    if key != "keys" {
      return Err(
        RecipeError::new(TrustStoreInvalid).with_detail(
          "unknown top-level field",
        ),
      )
    }
  }
  let items = match object.get("keys") {
    Some(@json.Json::Array(value)) => value
    _ =>
      return Err(
        RecipeError::new(TrustStoreInvalid).with_detail(
          "keys must be an array",
        ),
      )
  }
  let keys : Array[TrustKey] = []
  for item in items {
    let entry = match item {
      @json.Json::Object(value) => value
      _ =>
        return Err(
          RecipeError::new(TrustStoreInvalid).with_detail(
            "trust key must be an object",
          ),
        )
    }
    for field in entry.keys() {
      let allowed = field == "key_id" || field == "public_key" ||
        field == "added_at" || field == "revoked_at"
      if !allowed {
        return Err(
          RecipeError::new(TrustStoreInvalid).with_detail(
            "unknown trust key field",
          ),
        )
      }
    }
    let key_id = match entry.get("key_id") {
      Some(@json.Json::String(value)) => value
      _ =>
        return Err(
          RecipeError::new(TrustStoreInvalid).with_detail(
            "key_id must be a string",
          ),
        )
    }
    let public_key = match entry.get("public_key") {
      Some(@json.Json::String(value)) => value
      _ =>
        return Err(
          RecipeError::new(TrustStoreInvalid).with_detail(
            "public_key must be a string",
          ),
        )
    }
    let added_at = match entry.get("added_at") {
      Some(@json.Json::String(value)) => value
      _ =>
        return Err(
          RecipeError::new(TrustStoreInvalid).with_detail(
            "added_at must be a string",
          ),
        )
    }
    let revoked_at = match entry.get("revoked_at") {
      Some(@json.Json::String(value)) => Some(value)
      None => None
      _ =>
        return Err(
          RecipeError::new(TrustStoreInvalid).with_detail(
            "revoked_at must be a string",
          ),
        )
    }
    keys.push({ key_id, public_key, added_at, revoked_at })
  }
  match TrustStore::from_keys(keys) {
    Ok(store) => Ok(store)
    Err(error) => Err(error)
  }
}

// ---------------------------------------------------------------------------
// File loading with owner-only permission checks.

///|
async fn stat_tool_path() -> String? {
  let candidates = ["/usr/bin/stat", "/bin/stat"]
  for candidate in candidates {
    let executable = @fs.can_execute(candidate) catch { _ => false }
    if executable {
      return Some(candidate)
    }
  }
  None
}

///|
/// `stat -c %a` output must be exactly `600` or `400`. The tool is invoked
/// with an argv array (never a shell) and a bounded timeout.
pub async fn check_private_mode(path : String) -> Result[Unit, RecipeError] {
  let tool = match stat_tool_path() {
    Some(value) => value
    None =>
      return Err(
        RecipeError::new(TrustStoreUnverifiable).with_detail(
          "stat tool is not available",
        ),
      )
  }
  let budget_ms = 2_000
  let collected = @async.with_timeout_opt(budget_ms, async fn() {
    let result = @process.collect_output(tool, ["-c", "%a", path]) catch {
      _ => return None
    }
    Some(result)
  })
  let (code, stdout, _stderr) = match collected {
    Some(Some(value)) => value
    Some(None) =>
      return Err(
        RecipeError::new(TrustStoreUnverifiable).with_detail(
          "stat tool could not be spawned",
        ),
      )
    None =>
      return Err(
        RecipeError::new(TrustStoreUnverifiable).with_detail(
          "stat tool timed out",
        ),
      )
  }
  if code != 0 {
    return Err(
      RecipeError::new(TrustStoreUnverifiable).with_detail(
        "stat tool failed",
      ),
    )
  }
  let mode = stdout.text() catch {
    _ =>
      return Err(
        RecipeError::new(TrustStoreUnverifiable).with_detail(
          "stat output was not readable",
        ),
      )
  }
  let trimmed = mode.trim()
  if trimmed == "600" || trimmed == "400" {
    Ok(())
  } else {
    Err(
      RecipeError::new(TrustStoreInsecure).with_detail(
        "permissions must be 0600 or 0400",
      ),
    )
  }
}

///|
/// Load the owner trust store from `path`.
///
/// Fails closed on every indeterminate case: missing file, symlink, non-regular
/// file, group/other-accessible mode, unreadable content, invalid JSON.
pub async fn load_trust_store(path : String) -> Result[TrustStore, RecipeError] {
  if path == "" || path.length() > 4096 {
    return Err(
      RecipeError::new(TrustStoreInvalid).with_detail("path is invalid"),
    )
  }
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Err(
      RecipeError::new(TrustStoreMissing).with_detail(
        "trust store file does not exist",
      ),
    )
  }
  let kind = @fs.kind(path, follow_symlink=false) catch {
    _ =>
      return Err(
        RecipeError::new(TrustStoreUnverifiable).with_detail(
          "trust store kind could not be read",
        ),
      )
  }
  match kind {
    @fs.FileKind::SymLink =>
      return Err(
        RecipeError::new(TrustStoreInsecure).with_detail(
          "trust store must not be a symlink",
        ),
      )
    @fs.FileKind::Regular => ()
    _ =>
      return Err(
        RecipeError::new(TrustStoreInsecure).with_detail(
          "trust store must be a regular file",
        ),
      )
  }
  match check_private_mode(path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let text = @fs.read_file(path).text() catch {
    _ =>
      return Err(
        RecipeError::new(TrustStoreUnverifiable).with_detail(
          "trust store could not be read",
        ),
      )
  }
  parse_trust_store(text)
}
