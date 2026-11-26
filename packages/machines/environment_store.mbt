///|
/// Environment / recipe storage (ADR-0013 §6, A2.1).
///
/// Additive tables only: existing databases gain `recipes`, `recipe_trust` and
/// `environments`; nothing in the M1–M5 schemas changes. Recipe canonical
/// bytes and signatures are retained so "verify again before use" is possible
/// after a restart; environment records keep the plan digest and request id so
/// create retries and reconcile can be decided from durable state.

///|
fn environment_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS recipes (" +
    "id TEXT PRIMARY KEY, " +
    "name TEXT NOT NULL, " +
    "version TEXT NOT NULL, " +
    "content_hash TEXT NOT NULL, " +
    "key_id TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "canonical TEXT NOT NULL, " +
    "signature TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "tombstoned INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(name,version)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS recipe_trust (" +
    "key_id TEXT PRIMARY KEY, " +
    "public_key TEXT NOT NULL, " +
    "added_at TEXT NOT NULL, " +
    "revoked_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS environments (" +
    "id TEXT PRIMARY KEY, " +
    "workspace_id TEXT NOT NULL, " +
    "worktree_id TEXT NOT NULL, " +
    "machine_id TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "recipe_hash TEXT NOT NULL, " +
    "container_name TEXT NOT NULL, " +
    "plan_digest TEXT NOT NULL, " +
    "client_request_id TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "tombstoned INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS environments_request_idx " +
    "ON environments(client_request_id) WHERE client_request_id <> ''",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS environments_target_idx " +
    "ON environments(workspace_id,worktree_id)",
  )
}

// ---------------------------------------------------------------------------
// Recipes
// ---------------------------------------------------------------------------

///|
fn put_recipe_raw(
  conn : @sqlite3.Connection,
  record : @contracts.RecipeRecord,
  tombstoned : Bool,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO recipes (" +
    "id,name,version,content_hash,key_id,state,canonical,signature," +
    "record_json,tombstoned,created_at,updated_at" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) " +
    "ON CONFLICT(id) DO UPDATE SET " +
    "name=excluded.name,version=excluded.version," +
    "content_hash=excluded.content_hash,key_id=excluded.key_id," +
    "state=excluded.state,canonical=excluded.canonical," +
    "signature=excluded.signature,record_json=excluded.record_json," +
    "tombstoned=excluded.tombstoned,created_at=excluded.created_at," +
    "updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.name)
  stmt.bind(index=3, record.version)
  stmt.bind(index=4, record.content_hash)
  stmt.bind(index=5, record.key_id)
  stmt.bind(index=6, record.state)
  stmt.bind(index=7, record.canonical)
  stmt.bind(index=8, record.signature)
  stmt.bind(index=9, record.to_json().stringify())
  stmt.bind(index=10, if tombstoned { 1L } else { 0L })
  stmt.bind(index=11, record.imported_at)
  stmt.bind(index=12, record.imported_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn update_recipe_state_raw(
  conn : @sqlite3.Connection,
  record : @contracts.RecipeRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "UPDATE recipes SET state=?2, record_json=?3, updated_at=?4 WHERE id=?1",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.state)
  stmt.bind(index=3, record.to_json().stringify())
  let updated_at = if record.revoked_at == "" {
    record.imported_at
  } else {
    record.revoked_at
  }
  stmt.bind(index=4, updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn recipe_from_row(record_json : String) -> Option[@contracts.RecipeRecord] {
  let json = @json.parse(record_json) catch { _ => @json.Json::null() }
  @contracts.recipe_record_from_json(json)
}

///|
pub fn MachineStore::put_recipe(
  self : MachineStore,
  record : @contracts.RecipeRecord,
) -> Result[Unit, String] {
  try {
    put_recipe_raw(self.conn, record, false)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::update_recipe(
  self : MachineStore,
  record : @contracts.RecipeRecord,
) -> Result[Unit, String] {
  try {
    update_recipe_state_raw(self.conn, record)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_recipe(
  self : MachineStore,
  recipe_id : String,
) -> Result[Option[@contracts.RecipeRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM recipes WHERE id=?1 AND tombstoned=0",
    )
    stmt.bind(index=1, recipe_id)
    let mut found : Option[@contracts.RecipeRecord] = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = recipe_from_row(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_recipe_by_identity(
  self : MachineStore,
  name : String,
  version : String,
) -> Result[Option[@contracts.RecipeRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM recipes WHERE name=?1 AND version=?2 " +
      "AND tombstoned=0",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    let mut found : Option[@contracts.RecipeRecord] = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = recipe_from_row(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_recipes(
  self : MachineStore,
) -> Result[Array[@contracts.RecipeRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM recipes WHERE tombstoned=0 " +
      "ORDER BY created_at, id",
    )
    let out : Array[@contracts.RecipeRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match recipe_from_row(text) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Recipe trust
// ---------------------------------------------------------------------------

///|
fn put_trust_key_raw(
  conn : @sqlite3.Connection,
  key_id : String,
  public_key : String,
  added_at : String,
  revoked_at : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO recipe_trust (key_id,public_key,added_at,revoked_at) " +
    "VALUES (?1,?2,?3,?4) ON CONFLICT(key_id) DO UPDATE SET " +
    "public_key=excluded.public_key,added_at=excluded.added_at," +
    "revoked_at=excluded.revoked_at",
  )
  stmt.bind(index=1, key_id)
  stmt.bind(index=2, public_key)
  stmt.bind(index=3, added_at)
  stmt.bind(index=4, revoked_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
pub(all) struct TrustKeyRow {
  key_id : String
  public_key : String
  added_at : String
  revoked_at : String
}

///|
pub fn MachineStore::put_trust_key(
  self : MachineStore,
  key : TrustKeyRow,
) -> Result[Unit, String] {
  try {
    put_trust_key_raw(
      self.conn,
      key.key_id,
      key.public_key,
      key.added_at,
      key.revoked_at,
    )
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_trust_keys(
  self : MachineStore,
) -> Result[Array[TrustKeyRow], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT key_id,public_key,added_at,revoked_at FROM recipe_trust " +
      "ORDER BY key_id",
    )
    let out : Array[TrustKeyRow] = []
    while stmt.step() {
      out.push({
        key_id: stmt.column(index=0),
        public_key: stmt.column(index=1),
        added_at: stmt.column(index=2),
        revoked_at: stmt.column(index=3),
      })
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::revoke_trust_key(
  self : MachineStore,
  key_id : String,
  revoked_at : String,
) -> Result[Bool, String] {
  try {
    let stmt = self.conn.prepare(
      "UPDATE recipe_trust SET revoked_at=?2 WHERE key_id=?1",
    )
    stmt.bind(index=1, key_id)
    stmt.bind(index=2, revoked_at)
    let _ = stmt.step()
    let changed = self.conn.changes() > 0L
    stmt.finalize()
    Ok(changed)
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Environments
// ---------------------------------------------------------------------------

///|
fn put_environment_raw(
  conn : @sqlite3.Connection,
  record : @contracts.EnvironmentRecord,
  tombstoned : Bool,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO environments (" +
    "id,workspace_id,worktree_id,machine_id,state,recipe_hash," +
    "container_name,plan_digest,client_request_id,record_json," +
    "tombstoned,created_at,updated_at" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) " +
    "ON CONFLICT(id) DO UPDATE SET " +
    "workspace_id=excluded.workspace_id,worktree_id=excluded.worktree_id," +
    "machine_id=excluded.machine_id,state=excluded.state," +
    "recipe_hash=excluded.recipe_hash," +
    "container_name=excluded.container_name," +
    "plan_digest=excluded.plan_digest," +
    "client_request_id=excluded.client_request_id," +
    "record_json=excluded.record_json,tombstoned=excluded.tombstoned," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.workspace_id)
  stmt.bind(index=3, record.worktree_id)
  stmt.bind(index=4, record.machine_id)
  stmt.bind(index=5, record.state)
  stmt.bind(index=6, record.recipe_hash)
  stmt.bind(index=7, record.container_name)
  stmt.bind(index=8, record.plan_digest)
  stmt.bind(index=9, record.client_request_id)
  stmt.bind(index=10, record.to_json().stringify())
  stmt.bind(index=11, if tombstoned { 1L } else { 0L })
  stmt.bind(index=12, record.created_at)
  stmt.bind(index=13, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn tombstone_environment_raw(
  conn : @sqlite3.Connection,
  environment_id : String,
  updated_at : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "UPDATE environments SET tombstoned=1, updated_at=?2 WHERE id=?1",
  )
  stmt.bind(index=1, environment_id)
  stmt.bind(index=2, updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn environment_from_row(record_json : String) -> Option[@contracts.EnvironmentRecord] {
  let json = @json.parse(record_json) catch { _ => @json.Json::null() }
  @contracts.environment_record_from_json(json)
}

///|
pub fn MachineStore::put_environment(
  self : MachineStore,
  record : @contracts.EnvironmentRecord,
) -> Result[Unit, String] {
  try {
    put_environment_raw(self.conn, record, false)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_environment(
  self : MachineStore,
  environment_id : String,
) -> Result[Option[@contracts.EnvironmentRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM environments WHERE id=?1 AND tombstoned=0",
    )
    stmt.bind(index=1, environment_id)
    let mut found : Option[@contracts.EnvironmentRecord] = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = environment_from_row(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Look up a record even when it is tombstoned. Create retries must return the
/// original (possibly destroyed) record instead of creating a second
/// container.
pub fn MachineStore::get_environment_any(
  self : MachineStore,
  environment_id : String,
) -> Result[Option[@contracts.EnvironmentRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM environments WHERE id=?1",
    )
    stmt.bind(index=1, environment_id)
    let mut found : Option[@contracts.EnvironmentRecord] = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = environment_from_row(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::find_environment_by_request(
  self : MachineStore,
  client_request_id : String,
) -> Result[Option[@contracts.EnvironmentRecord], String] {
  if client_request_id == "" {
    return Ok(None)
  }
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM environments WHERE client_request_id=?1",
    )
    stmt.bind(index=1, client_request_id)
    let mut found : Option[@contracts.EnvironmentRecord] = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = environment_from_row(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::find_environment_for_target(
  self : MachineStore,
  workspace_id : String,
  worktree_id : String,
) -> Result[Option[@contracts.EnvironmentRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM environments WHERE workspace_id=?1 " +
      "AND worktree_id=?2 AND tombstoned=0 " +
      "ORDER BY created_at DESC, id DESC LIMIT 1",
    )
    stmt.bind(index=1, workspace_id)
    stmt.bind(index=2, worktree_id)
    let mut found : Option[@contracts.EnvironmentRecord] = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = environment_from_row(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_environments(
  self : MachineStore,
) -> Result[Array[@contracts.EnvironmentRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM environments WHERE tombstoned=0 " +
      "ORDER BY created_at, id",
    )
    let out : Array[@contracts.EnvironmentRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match environment_from_row(text) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Event + projection transaction
// ---------------------------------------------------------------------------

///|
pub fn MachineStore::record_recipe_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : Option[@contracts.RecipeRecord],
  refused : Bool,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match record {
      Some(value) => {
        if refused {
          // Refused imports are audit-only; they are never trusted and never
          // enter the projection as usable recipes.
          let _ = value
        } else {
          put_recipe_raw(self.conn, value, false)
        }
      }
      None => ()
    }
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try {
        exec_raise(self.conn, "ROLLBACK")
      } catch {
        _ => ()
      }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::record_environment_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : Option[@contracts.EnvironmentRecord],
  removed_id : String?,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match record {
      Some(value) => put_environment_raw(self.conn, value, false)
      None => ()
    }
    match removed_id {
      Some(value) => tombstone_environment_raw(self.conn, value, event.ts)
      None => ()
    }
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try {
        exec_raise(self.conn, "ROLLBACK")
      } catch {
        _ => ()
      }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::load_environment_events(
  self : MachineStore,
) -> Result[Array[@contracts.EventEnvelope], String] {
  try {
    Ok(
      load_events_impl(
        self.conn,
        "SELECT seq,id,org_id,type,subject,ts,causation_id,correlation_id," +
        "idempotency_key,payload_json FROM events " +
        "WHERE type LIKE 'environment.%' OR type LIKE 'recipe.%' ORDER BY seq ASC",
      ),
    )
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Rebuild the environment/recipe projections from the event log. Trust keys
/// are owner configuration loaded from the trust file, not replayable events,
/// so they are intentionally untouched.
pub fn MachineStore::reconcile_environment_projection(
  self : MachineStore,
) -> Result[Unit, String] {
  let events = match self.load_environment_events() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    exec_raise(self.conn, "DELETE FROM environments")
    exec_raise(self.conn, "DELETE FROM recipes")
    for event in events {
      if event.event_type == @contracts.EVENT_ENVIRONMENT_DESTROYED {
        match @contracts.environment_destroyed_id(event) {
          Some(environment_id) => {
            match @contracts.environment_event_record(event) {
              Some(record) =>
                put_environment_raw(self.conn, record, true)
              None => ()
            }
            tombstone_environment_raw(self.conn, environment_id, event.ts)
          }
          None => ()
        }
        continue
      }
      if event.event_type == @contracts.EVENT_RECIPE_REFUSED {
        continue
      }
      if event.event_type.has_prefix("environment.") {
        match @contracts.environment_event_record(event) {
          Some(record) => put_environment_raw(self.conn, record, false)
          None => ()
        }
        continue
      }
      if event.event_type.has_prefix("recipe.") {
        match @contracts.recipe_event_record(event) {
          Some(record) => put_recipe_raw(self.conn, record, false)
          None => ()
        }
      }
    }
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try {
        exec_raise(self.conn, "ROLLBACK")
      } catch {
        _ => ()
      }
      Err(sqlite_text(error))
    }
  }
}
