///|
/// Policy snapshot distribution (A1.3b).
///
/// The primary serializes its current `@policy.PolicySnapshot` and sends it
/// together with the snapshot version and content hash. The announcement is
/// carried in the `runtime.hello` result on connect and in a
/// `runtime.policy.update` notification when the policy changes. The node
/// verifies the pinned hash with `@policy.PolicySnapshot::decode_pinned`
/// before installing anything, persists the announcement in its 0700 state
/// directory and re-verifies it on the next open.
///
/// Wire shape (one JSON object):
///
/// ```json
/// { "version": "pol-...", "hash": "<64 hex>", "snapshot": "<snapshot JSON>" }
/// ```
///
/// The snapshot text is the canonical `PolicySnapshot::encode()` document;
/// the hash is pinned out of band in the announcement so a tampered state file
/// or a mixed-up snapshot/hash pair is rejected. Announcements are bounded so
/// they cannot push a frame past the transport limit.

///|
pub const MAX_POLICY_SNAPSHOT_TEXT_BYTES : Int = 16_384

///|
pub const MAX_POLICY_ANNOUNCEMENT_BYTES : Int = 24_576

///|
pub const POLICY_ACK_INSTALLED : String = "installed"

///|
pub const POLICY_ACK_REJECTED : String = "rejected"

///|
pub(all) struct PolicyAnnouncement {
  version : String
  hash : String
  snapshot : String
}

///|
fn policy_hash_text_ok(hash : String) -> Bool {
  if hash.length() != 64 {
    return false
  }
  for ch in hash {
    let code = ch.to_int()
    let lower_hex = code >= 48 && code <= 57 || code >= 97 && code <= 102
    if !lower_hex {
      return false
    }
  }
  true
}

///|
fn policy_version_text_ok(version : String) -> Bool {
  if version == "" || version.length() > 128 {
    return false
  }
  for ch in version {
    let code = ch.to_int()
    let allowed = code >= 33 && code <= 126
    if !allowed {
      return false
    }
  }
  true
}

///|
pub fn PolicyAnnouncement::new(
  version : String,
  hash : String,
  snapshot : String,
) -> Result[PolicyAnnouncement, String] {
  if !policy_version_text_ok(version) {
    return Err("policy announcement version is invalid")
  }
  if !policy_hash_text_ok(hash) {
    return Err("policy announcement hash is invalid")
  }
  if snapshot.length() > MAX_POLICY_SNAPSHOT_TEXT_BYTES {
    return Err("policy snapshot text exceeds the transport bound")
  }
  let announcement : PolicyAnnouncement = { version, hash, snapshot }
  let encoded = announcement.to_json().stringify()
  if encoded.length() > MAX_POLICY_ANNOUNCEMENT_BYTES {
    return Err("policy announcement exceeds the transport bound")
  }
  Ok(announcement)
}

///|
/// Build an announcement from an already constructed snapshot. The snapshot's
/// own content hash is the pin; `verify` recomputes it on the receiving side.
pub fn PolicyAnnouncement::from_snapshot(
  snapshot : @policy.PolicySnapshot,
) -> Result[PolicyAnnouncement, String] {
  PolicyAnnouncement::new(
    snapshot.version,
    snapshot.content_hash,
    snapshot.encode(),
  )
}

///|
pub fn PolicyAnnouncement::to_json(self : PolicyAnnouncement) -> @json.Json {
  @contracts.json_object([
    ("version", @contracts.json_string(self.version)),
    ("hash", @contracts.json_string(self.hash)),
    ("snapshot", @contracts.json_string(self.snapshot)),
  ])
}

///|
/// Params for the `runtime.policy.update` notification: the announcement is
/// the params object itself, so the same shape is used on connect and on
/// change.
pub fn PolicyAnnouncement::to_params(
  self : PolicyAnnouncement,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("version", @contracts.json_string(self.version))
  params.set("hash", @contracts.json_string(self.hash))
  params.set("snapshot", @contracts.json_string(self.snapshot))
  params
}

///|
pub fn PolicyAnnouncement::from_json(
  json : @json.Json,
) -> Result[PolicyAnnouncement, String] {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err("policy announcement is not an object")
  }
  let version = match @contracts.string_field(object, "version") {
    Some(value) => value
    None => return Err("policy announcement is missing version")
  }
  let hash = match @contracts.string_field(object, "hash") {
    Some(value) => value
    None => return Err("policy announcement is missing hash")
  }
  let snapshot = match @contracts.string_field(object, "snapshot") {
    Some(value) => value
    None => return Err("policy announcement is missing snapshot")
  }
  PolicyAnnouncement::new(version, hash, snapshot)
}

///|
/// Verify the pinned hash and decode the snapshot strictly. The node calls
/// this before installing an announcement, so a bad hash or a malformed or
/// mismatched snapshot leaves the previous policy (or fail-closed) in place.
pub fn PolicyAnnouncement::verify(
  self : PolicyAnnouncement,
) -> Result[@policy.PolicySnapshot, String] {
  let snapshot = match
    @policy.PolicySnapshot::decode_pinned(self.snapshot, self.hash) {
    Ok(value) => value
    Err(message) =>
      return Err("policy snapshot failed verification: " + message)
  }
  if snapshot.version != self.version {
    return Err(
      "policy announcement version does not match its snapshot",
    )
  }
  Ok(snapshot)
}

///|
/// Persist an announcement in the node's 0700 state directory. The file is
/// written 0600 with a temp file, fsync and an atomic rename; it contains no
/// secret material, only the public snapshot and its pin.
pub async fn save_policy_announcement(
  path : String,
  text : String,
) -> Result[Unit, String] {
  if text.length() > MAX_POLICY_ANNOUNCEMENT_BYTES {
    return Err("refusing to persist an oversized policy announcement")
  }
  let dir = parent_dir(path)
  if dir != "" {
    match validate_private_dir(dir, "runtime state dir") {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  let temp = path + ".tmp"
  @fs.write_file(temp, text, permission=0o600, sync=@fs.SyncMode::Full) catch {
    error => return Err("cannot write policy file: " + safe_error(error))
  }
  @fs.chmod(temp, 0o600) catch { _ => () }
  @fs.rename(temp, path, replace=true) catch {
    error => return Err("cannot replace policy file: " + safe_error(error))
  }
  Ok(())
}

///|
/// Load an announcement from the node state directory. The file must be a
/// regular 0600 file, matching the state-directory policy; the caller still
/// has to call `PolicyAnnouncement::verify` before trusting its contents.
pub async fn load_policy_announcement(
  path : String,
) -> Result[PolicyAnnouncement, String] {
  // lstat: a symlink in the 0700 state dir must not masquerade as a 0600
  // regular file, and the size is bounded before any read.
  let stat = match lstat_path(path) {
    None => return Err("policy file is missing")
    Some(value) => value
  }
  match stat.kind {
    Regular =>
      if (stat.mode & 0o777) != 0o600 {
        return Err(
          "policy file must be 0600 (found mode " + mode_text(stat.mode) + ")",
        )
      }
    SymLink => return Err("policy file must not be a symlink")
    _ => return Err("policy file is not a regular file")
  }
  if stat.size > MAX_POLICY_ANNOUNCEMENT_BYTES.to_int64() {
    return Err("policy file exceeds the transport bound")
  }
  let data = @fs.read_file(path) catch {
    error => return Err("cannot read policy file: " + safe_error(error))
  }
  let text = data.text() catch {
    error => return Err("cannot decode policy file: " + safe_error(error))
  }
  if text.length() > MAX_POLICY_ANNOUNCEMENT_BYTES {
    return Err("policy file exceeds the transport bound")
  }
  let parsed = try {
    @json.parse(text)
  } catch {
    _ => return Err("policy file is not valid JSON")
  }
  PolicyAnnouncement::from_json(parsed)
}
