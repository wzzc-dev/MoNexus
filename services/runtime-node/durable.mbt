///|
/// Durable idempotency for one-shot node mutations (A1.3b fix).
///
/// The in-memory `IdempotencyCache` is lost on restart, and fs/pty/git
/// mutations have no durable run record like exec does. A response lost after
/// a successful write could therefore be retried into a second execution.
/// This store writes a `pending` tombstone before dispatch and the bounded
/// result after success, both 0600 in the node's 0700 state dir:
///
/// - a replay after a crash sees `pending` and is refused, never re-executed;
/// - a normal replay returns the recorded result.
///
/// The store is bounded; eviction only forgets old results, so the tombstone
/// window is the approval window in practice. Keys are
/// `rpc_method|client_request_id`, the same identity the transport uses.

///|
pub const MAX_DURABLE_ENTRIES : Int = 64

///|
pub const MAX_DURABLE_RESULT_CHARS : Int = 16_384

///|
pub const MAX_DURABLE_FILE_BYTES : Int64 = 2_097_152L

///|
pub const DURABLE_STATE_PENDING : String = "pending"

///|
pub const DURABLE_STATE_DONE : String = "done"

///|
pub(all) enum DurableLookup {
  DurableMissing
  DurablePending
  DurableDone(@json.Json)
}

///|
struct DurableEntry {
  state : String
  result : String
}

///|
pub struct DurableIdempotency {
  mut path : String
  entries : Map[String, DurableEntry]
  order : Array[String]
}

///|
fn durable_key(rpc_method : String, client_request_id : String) -> String {
  rpc_method + "|" + client_request_id
}

///|
fn durable_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(index) =>
      if index <= 0 {
        "/"
      } else {
        path.substring(start=0, end=index)
      }
    None => ""
  }
}

///|
fn durable_encode(value : DurableIdempotency) -> String {
  let mut out = "{\"entries\":["
  let mut first = true
  for pair in value.entries.iter() {
    let (key, entry) = pair
    if !first {
      out = out + ","
    }
    out = out + "{\"key\":" + @policy.canonical_quote(key) +
      ",\"result\":" + @policy.canonical_quote(entry.result) +
      ",\"state\":" + @policy.canonical_quote(entry.state) + "}"
    first = false
  }
  out + "]}"
}

///|
fn durable_parse(text : String) -> Result[DurableIdempotency, String] {
  let parsed = try {
    @json.parse(text)
  } catch {
    _ => return Err("idempotency file is not valid JSON")
  }
  let object = match parsed {
    @json.Json::Object(value) => value
    _ => return Err("idempotency file is not an object")
  }
  for key in object.keys() {
    if key != "entries" {
      return Err("idempotency file contains an unknown field")
    }
  }
  let items = match object.get("entries") {
    Some(@json.Json::Array(value)) => value
    _ => return Err("idempotency file is missing entries")
  }
  let entries : Map[String, DurableEntry] = Map([])
  let order : Array[String] = []
  for item in items {
    let record = match item {
      @json.Json::Object(value) => value
      _ => return Err("idempotency entry is not an object")
    }
    for key in record.keys() {
      if key != "key" && key != "state" && key != "result" {
        return Err("idempotency entry contains an unknown field")
      }
    }
    let key = match record.get("key") {
      Some(@json.Json::String(value)) => value
      _ => return Err("idempotency entry is missing its key")
    }
    let state = match record.get("state") {
      Some(@json.Json::String(value)) => value
      _ => return Err("idempotency entry is missing its state")
    }
    if state != DURABLE_STATE_PENDING && state != DURABLE_STATE_DONE {
      return Err("idempotency entry has an unknown state")
    }
    let result = match record.get("result") {
      Some(@json.Json::String(value)) => value
      _ => ""
    }
    if key.length() > 512 {
      return Err("idempotency entry key is too long")
    }
    if entries.contains(key) {
      return Err("idempotency file contains a duplicate key")
    }
    entries.set(key, { state, result })
    order.push(key)
  }
  Ok({
    path: "",
    entries,
    order,
  })
}

///|
async fn durable_save(store : DurableIdempotency) -> Result[Unit, String] {
  if store.path == "" {
    return Ok(())
  }
  let dir = durable_parent_dir(store.path)
  if dir != "" {
    match @transport.validate_private_dir(dir, "runtime state dir") {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  let text = durable_encode(store)
  if text.length().to_int64() > MAX_DURABLE_FILE_BYTES {
    return Err("idempotency file would exceed its bound")
  }
  let temp = store.path + ".tmp"
  @fs.write_file(temp, text, permission=0o600, sync=@fs.SyncMode::Full) catch {
    error => return Err("cannot write idempotency file: " + error.to_string())
  }
  @fs.chmod(temp, 0o600) catch { _ => () }
  @fs.rename(temp, store.path, replace=true) catch {
    error =>
      return Err("cannot replace idempotency file: " + error.to_string())
  }
  Ok(())
}

///|
/// Open the durable idempotency store. A missing file is an empty store; a
/// malformed or non-0600 file is an error rather than silently forgotten,
/// because forgetting a tombstone could permit a second execution.
pub async fn DurableIdempotency::open(
  path : String,
) -> Result[DurableIdempotency, String] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok({ path, entries: Map([]), order: [] })
  }
  let stat = match @transport.lstat_path(path) {
    None => return Err("idempotency file is missing")
    Some(value) => value
  }
  match stat.kind {
    @transport.PathKind::Regular =>
      if (stat.mode & 0o777) != 0o600 {
        return Err(
          "idempotency file must be 0600 (found mode " +
          @transport.mode_text(stat.mode) + ")",
        )
      }
    _ => return Err("idempotency file is not a regular file")
  }
  if stat.size > MAX_DURABLE_FILE_BYTES {
    return Err("idempotency file exceeds its bound")
  }
  let data = @fs.read_file(path) catch {
    error => return Err("cannot read idempotency file: " + error.to_string())
  }
  let text = data.text() catch {
    error => return Err("cannot decode idempotency file: " + error.to_string())
  }
  let store = match durable_parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  store.path = path
  Ok(store)
}

///|
pub fn DurableIdempotency::lookup(
  self : DurableIdempotency,
  rpc_method : String,
  client_request_id : String,
) -> DurableLookup {
  if client_request_id == "" {
    return DurableMissing
  }
  match self.entries.get(durable_key(rpc_method, client_request_id)) {
    None => DurableMissing
    Some(entry) =>
      if entry.state == DURABLE_STATE_DONE {
        let parsed = try {
          @json.parse(entry.result)
        } catch {
          _ => return DurablePending
        }
        DurableDone(parsed)
      } else {
        DurablePending
      }
  }
}

///|
/// Record the tombstone before dispatch. Persisted before the executor runs,
/// so a crash mid-execution cannot allow a retry to execute twice.
pub async fn DurableIdempotency::begin(
  self : DurableIdempotency,
  rpc_method : String,
  client_request_id : String,
) -> Result[Unit, String] {
  if client_request_id == "" {
    return Ok(())
  }
  let key = durable_key(rpc_method, client_request_id)
  if !self.entries.contains(key) {
    while self.order.length() >= MAX_DURABLE_ENTRIES {
      let oldest = self.order.remove(0)
      self.entries.remove(oldest)
    }
    self.order.push(key)
  }
  self.entries.set(key, { state: DURABLE_STATE_PENDING, result: "" })
  durable_save(self)
}

///|
/// Record a successful result. Persistence failure leaves the in-memory
/// tombstone in place; the caller reports success but audits the failure.
pub async fn DurableIdempotency::finish(
  self : DurableIdempotency,
  rpc_method : String,
  client_request_id : String,
  result : @json.Json,
) -> Result[Unit, String] {
  if client_request_id == "" {
    return Ok(())
  }
  let text = result.stringify()
  if text.length() > MAX_DURABLE_RESULT_CHARS {
    // The result is too large to remember durably. Keep the tombstone so a
    // restart refuses a second execution; a live replay still hits the
    // in-memory cache above this layer.
    return durable_save(self)
  }
  self.entries.set(
    durable_key(rpc_method, client_request_id),
    { state: DURABLE_STATE_DONE, result: text },
  )
  durable_save(self)
}

///|
/// A request that did not execute leaves no tombstone, so a later retry can
/// run normally.
pub async fn DurableIdempotency::abandon(
  self : DurableIdempotency,
  rpc_method : String,
  client_request_id : String,
) -> Unit {
  if client_request_id == "" {
    return
  }
  let key = durable_key(rpc_method, client_request_id)
  self.entries.remove(key)
  let mut index = 0
  while index < self.order.length() {
    if self.order[index] == key {
      let _ = self.order.remove(index)
    } else {
      index = index + 1
    }
  }
  let _ = durable_save(self)
}

///|
pub fn DurableIdempotency::length(self : DurableIdempotency) -> Int {
  self.entries.length()
}
