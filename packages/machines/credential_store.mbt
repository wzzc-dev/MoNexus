///|
/// Credential metadata persistence (A5.0, ADR-0016 §12).
///
/// Only metadata is stored here: ids, kind, storage backend, state, version,
/// fingerprint, binding tuples and lease timestamps. There is deliberately no
/// `secret` column anywhere in this schema, and the migration is purely
/// additive so an older database keeps working. Secrets live in the platform
/// store (`packages/credentials`), never in SQLite.
///
/// A remote binding row is a metadata mirror: the node registers and stores
/// the secret locally, then reports fingerprint/version/state. The primary
/// never receives the secret.

///|
fn credential_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS credentials (" +
    "id TEXT PRIMARY KEY, " +
    "kind TEXT NOT NULL, " +
    "storage TEXT NOT NULL, " +
    "owner TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "version INTEGER NOT NULL, " +
    "fingerprint TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "rotated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn, "CREATE INDEX IF NOT EXISTS credentials_state_idx ON credentials(state)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS credentials_fingerprint_idx " +
    "ON credentials(fingerprint)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS credential_bindings (" +
    "id TEXT PRIMARY KEY, " +
    "credential_id TEXT NOT NULL, " +
    "machine_id TEXT NOT NULL, " +
    "agent_id TEXT NOT NULL, " +
    "profile TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "version INTEGER NOT NULL, " +
    "fingerprint TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  // One live binding per (machine, agent, profile). Partial indexes are
  // supported by the bundled SQLite; the host also checks this in code so a
  // second binding gets a fixed `credential_reused` reason instead of a raw
  // constraint error.
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS credential_bindings_live_idx " +
    "ON credential_bindings(machine_id, agent_id, profile) " +
    "WHERE state='active'",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS credential_bindings_machine_idx " +
    "ON credential_bindings(machine_id)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS credential_deliveries (" +
    "binding_id TEXT PRIMARY KEY, " +
    "credential_id TEXT NOT NULL, " +
    "machine_id TEXT NOT NULL, " +
    "version INTEGER NOT NULL, " +
    "state TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS credential_requests (" +
    "client_request_id TEXT PRIMARY KEY, " +
    "method TEXT NOT NULL, " +
    "result_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS credential_profiles (" +
    "name TEXT PRIMARY KEY, " +
    "profile_json TEXT NOT NULL" +
    ")",
  )
}

///|
fn put_credential_raw(
  conn : @sqlite3.Connection,
  record : @contracts.CredentialRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO credentials (id,kind,storage,owner,state,version,fingerprint," +
    "record_json,created_at,rotated_at) " +
    "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " +
    "ON CONFLICT(id) DO UPDATE SET kind=excluded.kind," +
    "storage=excluded.storage,owner=excluded.owner,state=excluded.state," +
    "version=excluded.version,fingerprint=excluded.fingerprint," +
    "record_json=excluded.record_json,created_at=excluded.created_at," +
    "rotated_at=excluded.rotated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.kind)
  stmt.bind(index=3, record.storage)
  stmt.bind(index=4, record.owner)
  stmt.bind(index=5, record.state)
  stmt.bind(index=6, record.version.to_int64())
  stmt.bind(index=7, record.fingerprint)
  stmt.bind(index=8, record.to_json().stringify())
  stmt.bind(index=9, record.created_at)
  stmt.bind(index=10, record.rotated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn put_credential_binding_raw(
  conn : @sqlite3.Connection,
  record : @contracts.CredentialBinding,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO credential_bindings (id,credential_id,machine_id,agent_id," +
    "profile,state,version,fingerprint,record_json,created_at,updated_at) " +
    "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) " +
    "ON CONFLICT(id) DO UPDATE SET credential_id=excluded.credential_id," +
    "machine_id=excluded.machine_id,agent_id=excluded.agent_id," +
    "profile=excluded.profile,state=excluded.state,version=excluded.version," +
    "fingerprint=excluded.fingerprint,record_json=excluded.record_json," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.credential_id)
  stmt.bind(index=3, record.machine_id)
  stmt.bind(index=4, record.agent_id)
  stmt.bind(index=5, record.profile)
  stmt.bind(index=6, record.state)
  stmt.bind(index=7, record.version.to_int64())
  stmt.bind(index=8, record.fingerprint)
  stmt.bind(index=9, record.to_json().stringify())
  stmt.bind(index=10, record.created_at)
  stmt.bind(index=11, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
pub fn MachineStore::put_credential(
  self : MachineStore,
  record : @contracts.CredentialRecord,
) -> Result[Unit, String] {
  try {
    put_credential_raw(self.conn, record)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::record_credential_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  credential : @contracts.CredentialRecord?,
  binding : @contracts.CredentialBinding?,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match credential {
      Some(record) => put_credential_raw(self.conn, record)
      None => ()
    }
    match binding {
      Some(record) => put_credential_binding_raw(self.conn, record)
      None => ()
    }
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = exec_raise(self.conn, "ROLLBACK") catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::put_credential_binding(
  self : MachineStore,
  record : @contracts.CredentialBinding,
) -> Result[Unit, String] {
  try {
    put_credential_binding_raw(self.conn, record)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_credential(
  self : MachineStore,
  credential_id : String,
) -> Result[@contracts.CredentialRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM credentials WHERE id=?1",
    )
    stmt.bind(index=1, credential_id)
    let mut found : @contracts.CredentialRecord? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let json = @json.parse(text) catch { _ => @json.Json::null() }
      found = @contracts.credential_record_from_json(json)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_credentials(
  self : MachineStore,
) -> Result[Array[@contracts.CredentialRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM credentials ORDER BY created_at ASC",
    )
    let out : Array[@contracts.CredentialRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let json = @json.parse(text) catch { _ => @json.Json::null() }
      match @contracts.credential_record_from_json(json) {
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

///|
pub fn MachineStore::get_credential_binding(
  self : MachineStore,
  binding_id : String,
) -> Result[@contracts.CredentialBinding?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM credential_bindings WHERE id=?1",
    )
    stmt.bind(index=1, binding_id)
    let mut found : @contracts.CredentialBinding? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let json = @json.parse(text) catch { _ => @json.Json::null() }
      found = @contracts.credential_binding_from_json(json)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::find_credential_binding(
  self : MachineStore,
  machine_id : String,
  agent_id : String,
  profile : String,
) -> Result[@contracts.CredentialBinding?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM credential_bindings " +
      "WHERE machine_id=?1 AND agent_id=?2 AND profile=?3 " +
      "AND state='active' LIMIT 1",
    )
    stmt.bind(index=1, machine_id)
    stmt.bind(index=2, agent_id)
    stmt.bind(index=3, profile)
    let mut found : @contracts.CredentialBinding? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let json = @json.parse(text) catch { _ => @json.Json::null() }
      found = @contracts.credential_binding_from_json(json)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_credential_bindings(
  self : MachineStore,
) -> Result[Array[@contracts.CredentialBinding], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM credential_bindings ORDER BY created_at ASC",
    )
    let out : Array[@contracts.CredentialBinding] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let json = @json.parse(text) catch { _ => @json.Json::null() }
      match @contracts.credential_binding_from_json(json) {
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

///|
/// Durable idempotency for `credential.*` mutations. The result JSON is the
/// exact RPC result a retry returns; it never contains a secret.
pub fn MachineStore::get_credential_request(
  self : MachineStore,
  client_request_id : String,
) -> Result[String?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT result_json FROM credential_requests WHERE client_request_id=?1",
    )
    stmt.bind(index=1, client_request_id)
    let mut found : String? = None
    if stmt.step() {
      found = Some(stmt.column(index=0))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::record_credential_request(
  self : MachineStore,
  client_request_id : String,
  method_name : String,
  result_json : String,
  created_at : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO credential_requests (client_request_id,method,result_json," +
      "created_at) VALUES (?1,?2,?3,?4) " +
      "ON CONFLICT(client_request_id) DO NOTHING",
    )
    stmt.bind(index=1, client_request_id)
    stmt.bind(index=2, method_name)
    stmt.bind(index=3, result_json)
    stmt.bind(index=4, created_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::put_credential_profile(
  self : MachineStore,
  profile : @contracts.CredentialProfile,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO credential_profiles (name,profile_json) " +
      "VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET " +
      "profile_json=excluded.profile_json",
    )
    stmt.bind(index=1, profile.name)
    stmt.bind(index=2, profile.to_json().stringify())
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_credential_profile(
  self : MachineStore,
  name : String,
) -> Result[@contracts.CredentialProfile?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT profile_json FROM credential_profiles WHERE name=?1",
    )
    stmt.bind(index=1, name)
    let mut found : @contracts.CredentialProfile? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let json = @json.parse(text) catch { _ => @json.Json::null() }
      found = @contracts.credential_profile_from_json(json)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}
