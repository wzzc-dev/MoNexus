///|
/// Agent session / Decision / Artifact persistence (M4).
///
/// Same shape as the machine and workspace stores: each row is a projection
/// (status columns for cheap filters) plus the full contract record JSON.
/// Session events and their projection are written in one transaction so a
/// subscriber never sees a session state the database does not have.

///|
fn agent_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS agent_sessions (" +
    "id TEXT PRIMARY KEY, " +
    "agent_id TEXT NOT NULL, " +
    "mode TEXT NOT NULL, " +
    "workspace_id TEXT NOT NULL, " +
    "worktree_id TEXT NOT NULL, " +
    "cwd TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "started_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS agent_sessions_agent_idx " +
    "ON agent_sessions(agent_id)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS agent_sessions_state_idx " +
    "ON agent_sessions(state)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS decisions (" +
    "id TEXT PRIMARY KEY, " +
    "kind TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "session_id TEXT NOT NULL, " +
    "agent_id TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "answered_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS decisions_status_idx ON decisions(status)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS decisions_session_idx ON decisions(session_id)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS artifacts (" +
    "id TEXT PRIMARY KEY, " +
    "session_id TEXT NOT NULL, " +
    "kind TEXT NOT NULL, " +
    "uri TEXT NOT NULL, " +
    "digest TEXT NOT NULL, " +
    "size INTEGER NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "record_json TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS artifacts_session_idx ON artifacts(session_id)",
  )
}

///|
fn put_agent_session_raw(
  conn : @sqlite3.Connection,
  record : @contracts.AgentSessionRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO agent_sessions (id,agent_id,mode,workspace_id,worktree_id," +
    "cwd,state,record_json,started_at,updated_at) " +
    "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " +
    "ON CONFLICT(id) DO UPDATE SET agent_id=excluded.agent_id," +
    "mode=excluded.mode,workspace_id=excluded.workspace_id," +
    "worktree_id=excluded.worktree_id,cwd=excluded.cwd,state=excluded.state," +
    "record_json=excluded.record_json,started_at=excluded.started_at," +
    "updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.agent_id)
  stmt.bind(index=3, record.mode)
  stmt.bind(index=4, record.workspace_id)
  stmt.bind(index=5, record.worktree_id)
  stmt.bind(index=6, record.cwd)
  stmt.bind(index=7, record.state)
  stmt.bind(index=8, record.to_json().stringify())
  stmt.bind(index=9, record.started_at)
  stmt.bind(index=10, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn put_decision_raw(
  conn : @sqlite3.Connection,
  record : @contracts.DecisionRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO decisions (id,kind,status,session_id,agent_id,record_json," +
    "created_at,answered_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,status=excluded.status," +
    "session_id=excluded.session_id,agent_id=excluded.agent_id," +
    "record_json=excluded.record_json,created_at=excluded.created_at," +
    "answered_at=excluded.answered_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.kind)
  stmt.bind(index=3, record.status)
  stmt.bind(index=4, record.session_id)
  stmt.bind(index=5, record.agent_id)
  stmt.bind(index=6, record.to_json().stringify())
  stmt.bind(index=7, record.created_at)
  stmt.bind(index=8, record.answered_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn put_artifact_raw(
  conn : @sqlite3.Connection,
  record : @contracts.ArtifactRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO artifacts (id,session_id,kind,uri,digest,size,created_at," +
    "record_json) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id," +
    "kind=excluded.kind,uri=excluded.uri,digest=excluded.digest," +
    "size=excluded.size,created_at=excluded.created_at," +
    "record_json=excluded.record_json",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.session_id)
  stmt.bind(index=3, record.kind)
  stmt.bind(index=4, record.uri)
  stmt.bind(index=5, record.digest)
  stmt.bind(index=6, record.size.to_int64())
  stmt.bind(index=7, record.created_at)
  stmt.bind(index=8, record.to_json().stringify())
  let _ = stmt.step()
  stmt.finalize()
}

///|
pub fn MachineStore::record_agent_session_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.AgentSessionRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    put_agent_session_raw(self.conn, record)
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
pub fn MachineStore::record_decision_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.DecisionRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    put_decision_raw(self.conn, record)
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
pub fn MachineStore::record_artifact_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.ArtifactRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    put_artifact_raw(self.conn, record)
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
pub fn MachineStore::get_agent_session(
  self : MachineStore,
  session_id : String,
) -> Result[@contracts.AgentSessionRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM agent_sessions WHERE id=?1",
    )
    stmt.bind(index=1, session_id)
    let mut found : @contracts.AgentSessionRecord? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch {
        _ => {
          stmt.finalize()
          return Err("corrupt agent session record JSON")
        }
      }
      found = @contracts.agent_session_from_json(parsed)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_agent_sessions(
  self : MachineStore,
  agent_id : String,
) -> Result[Array[@contracts.AgentSessionRecord], String] {
  try {
    let stmt = if agent_id == "" {
      self.conn.prepare(
        "SELECT record_json FROM agent_sessions ORDER BY started_at ASC, id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM agent_sessions WHERE agent_id=?1 " +
        "ORDER BY started_at ASC, id ASC",
      )
      prepared.bind(index=1, agent_id)
      prepared
    }
    let out : Array[@contracts.AgentSessionRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch { _ => continue }
      match @contracts.agent_session_from_json(parsed) {
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
pub fn MachineStore::get_decision(
  self : MachineStore,
  decision_id : String,
) -> Result[@contracts.DecisionRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM decisions WHERE id=?1",
    )
    stmt.bind(index=1, decision_id)
    let mut found : @contracts.DecisionRecord? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch {
        _ => {
          stmt.finalize()
          return Err("corrupt decision record JSON")
        }
      }
      found = @contracts.decision_from_json(parsed)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_decisions(
  self : MachineStore,
  status : String,
  session_id : String,
) -> Result[Array[@contracts.DecisionRecord], String] {
  try {
    // Fixed SQL fragments only; filter values are always bound, never
    // interpolated.
    let stmt = if status != "" && session_id != "" {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM decisions WHERE status=?1 AND session_id=?2 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, status)
      prepared.bind(index=2, session_id)
      prepared
    } else if status != "" {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM decisions WHERE status=?1 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, status)
      prepared
    } else if session_id != "" {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM decisions WHERE session_id=?1 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, session_id)
      prepared
    } else {
      self.conn.prepare(
        "SELECT record_json FROM decisions ORDER BY created_at ASC, id ASC",
      )
    }
    let out : Array[@contracts.DecisionRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch { _ => continue }
      match @contracts.decision_from_json(parsed) {
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
pub fn MachineStore::list_artifacts(
  self : MachineStore,
  session_id : String,
) -> Result[Array[@contracts.ArtifactRecord], String] {
  try {
    let stmt = if session_id == "" {
      self.conn.prepare(
        "SELECT record_json FROM artifacts ORDER BY created_at ASC, id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM artifacts WHERE session_id=?1 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, session_id)
      prepared
    }
    let out : Array[@contracts.ArtifactRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch { _ => continue }
      match @contracts.artifact_from_json(parsed) {
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
