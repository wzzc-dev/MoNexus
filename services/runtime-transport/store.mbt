///|
/// Durable primary state: pairing records, credential hashes, revocation
/// records and ack cursors.
///
/// The snapshot contains **no plaintext secrets**: pairing codes are stored as
/// SHA-256 hashes and machine credentials as SHA-256 token hashes. The file
/// backing store writes a 0600 file inside a 0700 directory using a temp file,
/// `fsync` and an atomic rename. A `StateStore` is a pair of async function
/// values so tests can substitute an in-memory store without a second state
/// implementation.

///|
pub(all) struct PairingRecord {
  code_id : String
  code_hash : String
  created_at_ms : Int64
  expires_at_ms : Int64
  used : Bool
}

///|
pub(all) struct CredentialRecord {
  runtime_id : String
  credential_id : String
  token_hash : String
  generation : Int
  issued_at_ms : Int64
  /// `None` = valid until revoked or rotated (production policy).
  expires_at_ms : Int64?
  revoked : Bool
  capabilities : Array[String]
}

///|
pub(all) struct RevokedRecord {
  runtime_id : String
  credential_id : String
  token_hash : String
  revoked_at_ms : Int64
  reason : String
}

///|
pub(all) struct AckRecord {
  runtime_id : String
  cursor : Int64
  updated_at_ms : Int64
}

///|
pub(all) struct StateSnapshot {
  version : Int
  pairings : Array[PairingRecord]
  credentials : Array[CredentialRecord]
  revoked : Array[RevokedRecord]
  acks : Array[AckRecord]
}

///|
pub fn StateSnapshot::empty() -> StateSnapshot {
  { version: 1, pairings: [], credentials: [], revoked: [], acks: [] }
}

///|
fn pairing_to_json(record : PairingRecord) -> @json.Json {
  @contracts.json_object([
    ("code_id", @contracts.json_string(record.code_id)),
    ("code_hash", @contracts.json_string(record.code_hash)),
    ("created_at_ms", @contracts.json_int64(record.created_at_ms)),
    ("expires_at_ms", @contracts.json_int64(record.expires_at_ms)),
    ("used", @contracts.json_bool(record.used)),
  ])
}

///|
fn credential_to_json(record : CredentialRecord) -> @json.Json {
  let expires = match record.expires_at_ms {
    Some(value) => @contracts.json_int64(value)
    None => @contracts.json_null()
  }
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(record.runtime_id)),
    ("credential_id", @contracts.json_string(record.credential_id)),
    ("token_hash", @contracts.json_string(record.token_hash)),
    ("generation", @contracts.json_int(record.generation)),
    ("issued_at_ms", @contracts.json_int64(record.issued_at_ms)),
    ("expires_at_ms", expires),
    ("revoked", @contracts.json_bool(record.revoked)),
    ("capabilities", @contracts.json_string_array(record.capabilities)),
  ])
}

///|
fn revoked_to_json(record : RevokedRecord) -> @json.Json {
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(record.runtime_id)),
    ("credential_id", @contracts.json_string(record.credential_id)),
    ("token_hash", @contracts.json_string(record.token_hash)),
    ("revoked_at_ms", @contracts.json_int64(record.revoked_at_ms)),
    ("reason", @contracts.json_string(record.reason)),
  ])
}

///|
fn ack_to_json(record : AckRecord) -> @json.Json {
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(record.runtime_id)),
    ("cursor", @contracts.json_int64(record.cursor)),
    ("updated_at_ms", @contracts.json_int64(record.updated_at_ms)),
  ])
}

///|
pub fn StateSnapshot::to_json(self : StateSnapshot) -> @json.Json {
  let pairings : Array[@json.Json] = []
  for record in self.pairings {
    pairings.push(pairing_to_json(record))
  }
  let credentials : Array[@json.Json] = []
  for record in self.credentials {
    credentials.push(credential_to_json(record))
  }
  let revoked : Array[@json.Json] = []
  for record in self.revoked {
    revoked.push(revoked_to_json(record))
  }
  let acks : Array[@json.Json] = []
  for record in self.acks {
    acks.push(ack_to_json(record))
  }
  @contracts.json_object([
    ("version", @contracts.json_int(self.version)),
    ("pairings", @contracts.json_array(pairings)),
    ("credentials", @contracts.json_array(credentials)),
    ("revoked", @contracts.json_array(revoked)),
    ("acks", @contracts.json_array(acks)),
  ])
}

///|
fn json_objects(items : @json.Json) -> Array[@json.Json] {
  match items.as_array() {
    Some(values) => values
    None => []
  }
}

///|
fn pairing_from_json(json : @json.Json) -> PairingRecord? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    code_id: @contracts.string_field_or(object, "code_id", ""),
    code_hash: @contracts.string_field_or(object, "code_hash", ""),
    created_at_ms: @contracts.int64_field_or(object, "created_at_ms", 0L),
    expires_at_ms: @contracts.int64_field_or(object, "expires_at_ms", 0L),
    used: @contracts.bool_field_or(object, "used", false),
  })
}

///|
fn credential_from_json(json : @json.Json) -> CredentialRecord? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let expires_at_ms = match object.get("expires_at_ms") {
    Some(value) => @contracts.as_int64(value)
    None => None
  }
  let capabilities : Array[String] = []
  match object.get("capabilities") {
    Some(value) =>
      match value.as_array() {
        Some(items) =>
          for item in items {
            match item.as_string() {
              Some(text) => capabilities.push(text)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  Some({
    runtime_id: @contracts.string_field_or(object, "runtime_id", ""),
    credential_id: @contracts.string_field_or(object, "credential_id", ""),
    token_hash: @contracts.string_field_or(object, "token_hash", ""),
    generation: @contracts.int_field_or(object, "generation", 1),
    issued_at_ms: @contracts.int64_field_or(object, "issued_at_ms", 0L),
    expires_at_ms,
    revoked: @contracts.bool_field_or(object, "revoked", false),
    capabilities,
  })
}

///|
fn revoked_from_json(json : @json.Json) -> RevokedRecord? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    runtime_id: @contracts.string_field_or(object, "runtime_id", ""),
    credential_id: @contracts.string_field_or(object, "credential_id", ""),
    token_hash: @contracts.string_field_or(object, "token_hash", ""),
    revoked_at_ms: @contracts.int64_field_or(object, "revoked_at_ms", 0L),
    reason: @contracts.string_field_or(object, "reason", ""),
  })
}

///|
fn ack_from_json(json : @json.Json) -> AckRecord? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    runtime_id: @contracts.string_field_or(object, "runtime_id", ""),
    cursor: @contracts.int64_field_or(object, "cursor", 0L),
    updated_at_ms: @contracts.int64_field_or(object, "updated_at_ms", 0L),
  })
}

///|
/// Decode a snapshot. Unknown extra fields are ignored; known fields of the
/// wrong shape are dropped rather than aborting, except for a wrong top-level
/// shape or version, which is a hard error.
pub fn StateSnapshot::from_json(json : @json.Json) -> Result[StateSnapshot, String] {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err("state snapshot is not an object")
  }
  let version = @contracts.int_field_or(object, "version", 0)
  if version != 1 {
    return Err("unsupported state snapshot version")
  }
  let pairings : Array[PairingRecord] = []
  match object.get("pairings") {
    Some(value) =>
      for item in json_objects(value) {
        match pairing_from_json(item) {
          Some(record) => pairings.push(record)
          None => ()
        }
      }
    None => ()
  }
  let credentials : Array[CredentialRecord] = []
  match object.get("credentials") {
    Some(value) =>
      for item in json_objects(value) {
        match credential_from_json(item) {
          Some(record) => credentials.push(record)
          None => ()
        }
      }
    None => ()
  }
  let revoked : Array[RevokedRecord] = []
  match object.get("revoked") {
    Some(value) =>
      for item in json_objects(value) {
        match revoked_from_json(item) {
          Some(record) => revoked.push(record)
          None => ()
        }
      }
    None => ()
  }
  let acks : Array[AckRecord] = []
  match object.get("acks") {
    Some(value) =>
      for item in json_objects(value) {
        match ack_from_json(item) {
          Some(record) => acks.push(record)
          None => ()
        }
      }
    None => ()
  }
  Ok({ version, pairings, credentials, revoked, acks })
}

///|
/// Swappable persistence for `PrimaryState`. Both functions are async so the
/// file implementation can use `@fs` and tests can use an in-memory cell.
pub struct StateStore {
  load : async () -> Result[StateSnapshot?, String]
  save : async (StateSnapshot) -> Result[Unit, String]
  location : String
}

///|
pub fn StateStore::location(self : StateStore) -> String {
  self.location
}

///|
/// In-memory store for tests and for ephemeral primaries. `save` replaces the
/// previous snapshot; `load` returns the last saved value.
pub fn StateStore::memory() -> StateStore {
  let cell : Ref[StateSnapshot?] = Ref(None)
  {
    load: () => {
      let current = cell.val
      Ok(current)
    },
    save: snapshot => {
      cell.val = Some(snapshot)
      Ok(())
    },
    location: "memory",
  }
}

///|
/// Open (or create) a file-backed store under `dir`. The directory is created
/// 0700 (and chmod'ed even if it already existed); the snapshot file is written
/// 0600. An existing state file with group/other permissions is refused rather
/// than silently tightened, so a permissions regression is visible.
pub async fn StateStore::open(dir : String) -> Result[StateStore, String] {
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    error => return Err("cannot create state directory: " + safe_error(error))
  }
  @fs.chmod(dir, 0o700) catch {
    error => return Err("cannot secure state directory: " + safe_error(error))
  }
  let path = dir + "/transport-state.json"
  let initial = match stat_path(path) {
    None => None
    Some(info) =>
      match info.kind {
        Regular => {
          if !is_private_mode(info.mode) {
            return Err(
              "state file must not be accessible by group or other (found mode " +
              mode_text(info.mode) + ")",
            )
          }
          let data = @fs.read_file(path) catch {
            error => return Err("cannot read state file: " + safe_error(error))
          }
          let text = data.text() catch {
            error => return Err("cannot decode state file: " + safe_error(error))
          }
          let json = @json.parse(
            text,
            max_nesting_depth=MAX_JSON_DEPTH,
            reject_duplicate_keys=true,
          ) catch {
            error => return Err("state file is not valid JSON: " + safe_error(error))
          }
          let snapshot = match StateSnapshot::from_json(json) {
            Ok(value) => value
            Err(message) => return Err(message)
          }
          Some(snapshot)
        }
        _ => return Err("state path is not a regular file")
      }
  }
  let load : async () -> Result[StateSnapshot?, String] = () => {
    // A single primary process owns the store; reloading on demand keeps the
    // interface uniform with the in-memory store.
    Ok(initial)
  }
  let save : async (StateSnapshot) -> Result[Unit, String] = snapshot => {
    let text = snapshot.to_json().stringify()
    let temp = path + ".tmp"
    @fs.write_file(temp, text, permission=0o600, sync=@fs.SyncMode::Full) catch {
      error => return Err("cannot write state file: " + safe_error(error))
    }
    @fs.chmod(temp, 0o600) catch { _ => () }
    @fs.rename(temp, path, replace=true) catch {
      error => return Err("cannot replace state file: " + safe_error(error))
    }
    Ok(())
  }
  Ok({ load, save, location: dir })
}
