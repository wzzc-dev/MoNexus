///|
/// Skill store (ADR-0015 §11).
///
/// Additive tables only: `skills` (imported bundle index), `skill_allowlist`
/// (exact owner trust tuples), `skill_keys` (Ed25519 public keys),
/// `skill_bindings` (agent/task/session enablement), `skill_invocations`
/// (idempotency/audit projection) and `agent_skill_permissions` (the per-agent
/// permission ceiling). Events remain in the existing `events` table; no skill
/// body, invocation output or gateway token is stored in any column here.

///|
pub(all) struct SkillRow {
  id : String
  name : String
  version : String
  content_hash : String
  key_id : String
  state : String
  manifest_json : String
  signature : String
  source : String
  created_at : String
  updated_at : String
}

///|
pub(all) struct SkillAllowRow {
  name : String
  version : String
  content_hash : String
  key_id : String
  state : String
  reason : String
  added_at : String
  revoked_at : String
}

///|
pub(all) struct SkillBindingRow {
  scope : String
  scope_ref : String
  name : String
  version : String
  content_hash : String
  mode : String
  enabled_at : String
}

///|
pub(all) struct SkillKeyRow {
  key_id : String
  public_key : String
  revoked : Bool
}

///|
pub(all) struct SkillInvocationRow {
  id : String
  request_id : String
  session_id : String
  name : String
  version : String
  content_hash : String
  entry_id : String
  argv_hash : String
  status : String
  exit_code : Int
  decision_id : String
  run_id : String
  output_bytes : Int
  created_at : String
}

///|
fn skill_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS skills (" +
    "id TEXT PRIMARY KEY, " +
    "name TEXT NOT NULL, " +
    "version TEXT NOT NULL, " +
    "content_hash TEXT NOT NULL, " +
    "key_id TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "manifest_json TEXT NOT NULL, " +
    "signature TEXT NOT NULL, " +
    "source TEXT NOT NULL, " +
    "tombstoned INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(name,version,content_hash)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS skills_identity_idx " +
    "ON skills(name,version)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS skill_allowlist (" +
    "name TEXT NOT NULL, " +
    "version TEXT NOT NULL, " +
    "content_hash TEXT NOT NULL, " +
    "key_id TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "reason TEXT NOT NULL, " +
    "added_at TEXT NOT NULL, " +
    "revoked_at TEXT NOT NULL, " +
    "PRIMARY KEY(name,version,content_hash)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS skill_keys (" +
    "key_id TEXT PRIMARY KEY, " +
    "public_key TEXT NOT NULL, " +
    "added_at TEXT NOT NULL, " +
    "revoked_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS skill_bindings (" +
    "scope TEXT NOT NULL, " +
    "scope_ref TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "version TEXT NOT NULL, " +
    "content_hash TEXT NOT NULL, " +
    "mode TEXT NOT NULL, " +
    "enabled_at TEXT NOT NULL, " +
    "PRIMARY KEY(scope,scope_ref,name)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS skill_invocations (" +
    "id TEXT PRIMARY KEY, " +
    "request_id TEXT NOT NULL UNIQUE, " +
    "session_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "version TEXT NOT NULL, " +
    "content_hash TEXT NOT NULL, " +
    "entry_id TEXT NOT NULL, " +
    "argv_hash TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "exit_code INTEGER NOT NULL, " +
    "decision_id TEXT NOT NULL, " +
    "run_id TEXT NOT NULL, " +
    "output_bytes INTEGER NOT NULL, " +
    "created_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS skill_invocations_session_idx " +
    "ON skill_invocations(session_id)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS agent_skill_permissions (" +
    "agent_id TEXT PRIMARY KEY, " +
    "permissions TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
}

// ---------------------------------------------------------------------------
// Skill bundle index
// ---------------------------------------------------------------------------

///|
fn put_skill_row_raw(
  conn : @sqlite3.Connection,
  row : SkillRow,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO skills (id,name,version,content_hash,key_id,state," +
    "manifest_json,signature,source,created_at,updated_at) " +
    "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) " +
    "ON CONFLICT(name,version,content_hash) DO UPDATE SET " +
    "state=excluded.state,manifest_json=excluded.manifest_json," +
    "signature=excluded.signature,source=excluded.source," +
    "updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, row.id)
  stmt.bind(index=2, row.name)
  stmt.bind(index=3, row.version)
  stmt.bind(index=4, row.content_hash)
  stmt.bind(index=5, row.key_id)
  stmt.bind(index=6, row.state)
  stmt.bind(index=7, row.manifest_json)
  stmt.bind(index=8, row.signature)
  stmt.bind(index=9, row.source)
  stmt.bind(index=10, row.created_at)
  stmt.bind(index=11, row.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn row_text(stmt : @sqlite3.Statement, index : Int) -> String raise @sqlite3.SqliteError {
  stmt.column(index=index)
}

///|
fn row_int(stmt : @sqlite3.Statement, index : Int) -> Int raise @sqlite3.SqliteError {
  let value : Int64 = stmt.column(index=index)
  value.to_int()
}

///|
fn skill_row_from_stmt(stmt : @sqlite3.Statement) -> SkillRow raise @sqlite3.SqliteError {
  {
    id: row_text(stmt, 0),
    name: row_text(stmt, 1),
    version: row_text(stmt, 2),
    content_hash: row_text(stmt, 3),
    key_id: row_text(stmt, 4),
    state: row_text(stmt, 5),
    manifest_json: row_text(stmt, 6),
    signature: row_text(stmt, 7),
    source: row_text(stmt, 8),
    created_at: row_text(stmt, 9),
    updated_at: row_text(stmt, 10),
  }
}

///|
pub fn MachineStore::put_skill_row(
  self : MachineStore,
  row : SkillRow,
) -> Result[Unit, String] {
  try {
    put_skill_row_raw(self.conn, row)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_skill_row(
  self : MachineStore,
  name : String,
  version : String,
  content_hash : String,
) -> Result[SkillRow?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,name,version,content_hash,key_id,state,manifest_json," +
      "signature,source,created_at,updated_at FROM skills " +
      "WHERE name=?1 AND version=?2 AND content_hash=?3 AND tombstoned=0",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    stmt.bind(index=3, content_hash)
    let mut found : SkillRow? = None
    if stmt.step() {
      found = Some(skill_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_skill_rows(self : MachineStore) -> SkillRowsResult {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,name,version,content_hash,key_id,state,manifest_json," +
      "signature,source,created_at,updated_at FROM skills " +
      "WHERE tombstoned=0 ORDER BY name ASC,version ASC,created_at ASC",
    )
    let out : Array[SkillRow] = []
    while stmt.step() {
      out.push(skill_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::set_skill_row_state(
  self : MachineStore,
  name : String,
  version : String,
  content_hash : String,
  state : String,
  updated_at : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "UPDATE skills SET state=?4,updated_at=?5 " +
      "WHERE name=?1 AND version=?2 AND content_hash=?3",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    stmt.bind(index=3, content_hash)
    stmt.bind(index=4, state)
    stmt.bind(index=5, updated_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::remove_skill_row(
  self : MachineStore,
  name : String,
  version : String,
  content_hash : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "DELETE FROM skills WHERE name=?1 AND version=?2 AND content_hash=?3",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    stmt.bind(index=3, content_hash)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Allowlist and keys
// ---------------------------------------------------------------------------

///|
pub fn MachineStore::allow_skill(
  self : MachineStore,
  row : SkillAllowRow,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO skill_allowlist " +
      "(name,version,content_hash,key_id,state,reason,added_at,revoked_at) " +
      "VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
      "ON CONFLICT(name,version,content_hash) DO UPDATE SET " +
      "key_id=excluded.key_id,state=excluded.state,reason=excluded.reason," +
      "added_at=excluded.added_at,revoked_at=excluded.revoked_at",
    )
    stmt.bind(index=1, row.name)
    stmt.bind(index=2, row.version)
    stmt.bind(index=3, row.content_hash)
    stmt.bind(index=4, row.key_id)
    stmt.bind(index=5, row.state)
    stmt.bind(index=6, row.reason)
    stmt.bind(index=7, row.added_at)
    stmt.bind(index=8, row.revoked_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
fn allow_row_from_stmt(stmt : @sqlite3.Statement) -> SkillAllowRow raise @sqlite3.SqliteError {
  {
    name: row_text(stmt, 0),
    version: row_text(stmt, 1),
    content_hash: row_text(stmt, 2),
    key_id: row_text(stmt, 3),
    state: row_text(stmt, 4),
    reason: row_text(stmt, 5),
    added_at: row_text(stmt, 6),
    revoked_at: row_text(stmt, 7),
  }
}

///|
pub fn MachineStore::get_skill_allow(
  self : MachineStore,
  name : String,
  version : String,
  content_hash : String,
) -> Result[SkillAllowRow?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT name,version,content_hash,key_id,state,reason,added_at," +
      "revoked_at FROM skill_allowlist " +
      "WHERE name=?1 AND version=?2 AND content_hash=?3",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    stmt.bind(index=3, content_hash)
    let mut found : SkillAllowRow? = None
    if stmt.step() {
      found = Some(allow_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_skill_allows(self : MachineStore) -> SkillAllowsResult {
  try {
    let stmt = self.conn.prepare(
      "SELECT name,version,content_hash,key_id,state,reason,added_at," +
      "revoked_at FROM skill_allowlist ORDER BY name ASC,version ASC",
    )
    let out : Array[SkillAllowRow] = []
    while stmt.step() {
      out.push(allow_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::revoke_skill_allow(
  self : MachineStore,
  name : String,
  version : String,
  content_hash : String,
  reason : String,
  revoked_at : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "UPDATE skill_allowlist SET state=?4,reason=?5,revoked_at=?6 " +
      "WHERE name=?1 AND version=?2 AND content_hash=?3",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    stmt.bind(index=3, content_hash)
    stmt.bind(index=4, @contracts.SKILL_STATUS_REVOKED)
    stmt.bind(index=5, reason)
    stmt.bind(index=6, revoked_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::put_skill_key(
  self : MachineStore,
  key_id : String,
  public_key : String,
  added_at : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO skill_keys (key_id,public_key,added_at,revoked_at) " +
      "VALUES (?1,?2,?3,'') ON CONFLICT(key_id) DO UPDATE SET " +
      "public_key=excluded.public_key,added_at=excluded.added_at," +
      "revoked_at=''",
    )
    stmt.bind(index=1, key_id)
    stmt.bind(index=2, public_key)
    stmt.bind(index=3, added_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::revoke_skill_key(
  self : MachineStore,
  key_id : String,
  revoked_at : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "UPDATE skill_keys SET revoked_at=?2 WHERE key_id=?1",
    )
    stmt.bind(index=1, key_id)
    stmt.bind(index=2, revoked_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_skill_keys(self : MachineStore) -> SkillKeysResult {
  try {
    let stmt = self.conn.prepare(
      "SELECT key_id,public_key,revoked_at FROM skill_keys ORDER BY key_id ASC",
    )
    let out : Array[SkillKeyRow] = []
    while stmt.step() {
      out.push(
        {
          key_id: row_text(stmt, 0),
          public_key: row_text(stmt, 1),
          revoked: row_text(stmt, 2) != "",
        },
      )
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Bindings and per-agent permission ceiling
// ---------------------------------------------------------------------------

///|
fn binding_row_from_stmt(stmt : @sqlite3.Statement) -> SkillBindingRow raise @sqlite3.SqliteError {
  {
    scope: row_text(stmt, 0),
    scope_ref: row_text(stmt, 1),
    name: row_text(stmt, 2),
    version: row_text(stmt, 3),
    content_hash: row_text(stmt, 4),
    mode: row_text(stmt, 5),
    enabled_at: row_text(stmt, 6),
  }
}

///|
pub fn MachineStore::put_skill_binding(
  self : MachineStore,
  row : SkillBindingRow,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO skill_bindings " +
      "(scope,scope_ref,name,version,content_hash,mode,enabled_at) " +
      "VALUES (?1,?2,?3,?4,?5,?6,?7) " +
      "ON CONFLICT(scope,scope_ref,name) DO UPDATE SET " +
      "version=excluded.version,content_hash=excluded.content_hash," +
      "mode=excluded.mode,enabled_at=excluded.enabled_at",
    )
    stmt.bind(index=1, row.scope)
    stmt.bind(index=2, row.scope_ref)
    stmt.bind(index=3, row.name)
    stmt.bind(index=4, row.version)
    stmt.bind(index=5, row.content_hash)
    stmt.bind(index=6, row.mode)
    stmt.bind(index=7, row.enabled_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_skill_binding(
  self : MachineStore,
  scope : String,
  scope_ref : String,
  name : String,
) -> Result[SkillBindingRow?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT scope,scope_ref,name,version,content_hash,mode,enabled_at " +
      "FROM skill_bindings WHERE scope=?1 AND scope_ref=?2 AND name=?3",
    )
    stmt.bind(index=1, scope)
    stmt.bind(index=2, scope_ref)
    stmt.bind(index=3, name)
    let mut found : SkillBindingRow? = None
    if stmt.step() {
      found = Some(binding_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_skill_bindings(
  self : MachineStore,
  scope : String,
  scope_ref : String,
) -> SkillBindingsResult {
  try {
    let stmt = self.conn.prepare(
      "SELECT scope,scope_ref,name,version,content_hash,mode,enabled_at " +
      "FROM skill_bindings WHERE scope=?1 AND scope_ref=?2 " +
      "ORDER BY name ASC",
    )
    stmt.bind(index=1, scope)
    stmt.bind(index=2, scope_ref)
    let out : Array[SkillBindingRow] = []
    while stmt.step() {
      out.push(binding_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_all_skill_bindings(
  self : MachineStore,
) -> SkillBindingsResult {
  try {
    let stmt = self.conn.prepare(
      "SELECT scope,scope_ref,name,version,content_hash,mode,enabled_at " +
      "FROM skill_bindings ORDER BY scope ASC,scope_ref ASC,name ASC",
    )
    let out : Array[SkillBindingRow] = []
    while stmt.step() {
      out.push(binding_row_from_stmt(stmt))
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::remove_skill_binding(
  self : MachineStore,
  scope : String,
  scope_ref : String,
  name : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "DELETE FROM skill_bindings WHERE scope=?1 AND scope_ref=?2 AND name=?3",
    )
    stmt.bind(index=1, scope)
    stmt.bind(index=2, scope_ref)
    stmt.bind(index=3, name)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::remove_skill_bindings_for(
  self : MachineStore,
  name : String,
  version : String,
  content_hash : String,
) -> Result[Int, String] {
  try {
    let stmt = self.conn.prepare(
      "DELETE FROM skill_bindings WHERE name=?1 AND version=?2 AND content_hash=?3",
    )
    stmt.bind(index=1, name)
    stmt.bind(index=2, version)
    stmt.bind(index=3, content_hash)
    let _ = stmt.step()
    let changes = self.conn.changes()
    stmt.finalize()
    Ok(changes.to_int())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_agent_skill_permissions(
  self : MachineStore,
  agent_id : String,
) -> SkillPermissionsResult {
  try {
    let stmt = self.conn.prepare(
      "SELECT permissions FROM agent_skill_permissions WHERE agent_id=?1",
    )
    stmt.bind(index=1, agent_id)
    let mut found : Array[String]? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let permissions : Array[String] = []
      for item in text.split(",") {
        let value = item.trim().to_owned()
        if value != "" {
          permissions.push(value)
        }
      }
      found = Some(permissions)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::set_agent_skill_permissions(
  self : MachineStore,
  agent_id : String,
  permissions : Array[String],
  updated_at : String,
) -> Result[Unit, String] {
  try {
    let joined = StringBuilder()
    let mut first = true
    for permission in permissions {
      if !first {
        joined.write_char(',')
      }
      first = false
      joined.write_string(permission)
    }
    let stmt = self.conn.prepare(
      "INSERT INTO agent_skill_permissions (agent_id,permissions,updated_at) " +
      "VALUES (?1,?2,?3) ON CONFLICT(agent_id) DO UPDATE SET " +
      "permissions=excluded.permissions,updated_at=excluded.updated_at",
    )
    stmt.bind(index=1, agent_id)
    stmt.bind(index=2, joined.to_string())
    stmt.bind(index=3, updated_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Invocation projection
// ---------------------------------------------------------------------------

///|
pub fn MachineStore::record_skill_invocation(
  self : MachineStore,
  row : SkillInvocationRow,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO skill_invocations " +
      "(id,request_id,session_id,name,version,content_hash,entry_id," +
      "argv_hash,status,exit_code,decision_id,run_id,output_bytes,created_at) " +
      "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14) " +
      "ON CONFLICT(request_id) DO UPDATE SET status=excluded.status," +
      "exit_code=excluded.exit_code,decision_id=excluded.decision_id," +
      "run_id=excluded.run_id,output_bytes=excluded.output_bytes",
    )
    stmt.bind(index=1, row.id)
    stmt.bind(index=2, row.request_id)
    stmt.bind(index=3, row.session_id)
    stmt.bind(index=4, row.name)
    stmt.bind(index=5, row.version)
    stmt.bind(index=6, row.content_hash)
    stmt.bind(index=7, row.entry_id)
    stmt.bind(index=8, row.argv_hash)
    stmt.bind(index=9, row.status)
    stmt.bind(index=10, row.exit_code)
    stmt.bind(index=11, row.decision_id)
    stmt.bind(index=12, row.run_id)
    stmt.bind(index=13, row.output_bytes)
    stmt.bind(index=14, row.created_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_skill_invocation(
  self : MachineStore,
  request_id : String,
) -> Result[SkillInvocationRow?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,request_id,session_id,name,version,content_hash,entry_id," +
      "argv_hash,status,exit_code,decision_id,run_id,output_bytes,created_at " +
      "FROM skill_invocations WHERE request_id=?1",
    )
    stmt.bind(index=1, request_id)
    let mut found : SkillInvocationRow? = None
    if stmt.step() {
      found = Some(
        {
          id: row_text(stmt, 0),
          request_id: row_text(stmt, 1),
          session_id: row_text(stmt, 2),
          name: row_text(stmt, 3),
          version: row_text(stmt, 4),
          content_hash: row_text(stmt, 5),
          entry_id: row_text(stmt, 6),
          argv_hash: row_text(stmt, 7),
          status: row_text(stmt, 8),
          exit_code: row_int(stmt, 9),
          decision_id: row_text(stmt, 10),
          run_id: row_text(stmt, 11),
          output_bytes: row_int(stmt, 12),
          created_at: row_text(stmt, 13),
        },
      )
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_skill_invocations(
  self : MachineStore,
  session_id : String,
) -> SkillInvocationsResult {
  try {
    let stmt = if session_id == "" {
      self.conn.prepare(
        "SELECT id,request_id,session_id,name,version,content_hash,entry_id," +
        "argv_hash,status,exit_code,decision_id,run_id,output_bytes,created_at " +
        "FROM skill_invocations ORDER BY created_at ASC,id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT id,request_id,session_id,name,version,content_hash,entry_id," +
        "argv_hash,status,exit_code,decision_id,run_id,output_bytes,created_at " +
        "FROM skill_invocations WHERE session_id=?1 " +
        "ORDER BY created_at ASC,id ASC",
      )
      prepared.bind(index=1, session_id)
      prepared
    }
    let out : Array[SkillInvocationRow] = []
    while stmt.step() {
      out.push(
        {
          id: row_text(stmt, 0),
          request_id: row_text(stmt, 1),
          session_id: row_text(stmt, 2),
          name: row_text(stmt, 3),
          version: row_text(stmt, 4),
          content_hash: row_text(stmt, 5),
          entry_id: row_text(stmt, 6),
          argv_hash: row_text(stmt, 7),
          status: row_text(stmt, 8),
          exit_code: row_int(stmt, 9),
          decision_id: row_text(stmt, 10),
          run_id: row_text(stmt, 11),
          output_bytes: row_int(stmt, 12),
          created_at: row_text(stmt, 13),
        },
      )
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}
