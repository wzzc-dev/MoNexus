///|
/// Workspace / Worktree / lease persistence (M3).
///
/// Tables mirror the machine store's shape: a projection row plus the full
/// record JSON, both rebuilt from the event log at startup. Leases have a
/// unique active-target index, so two runs can never hold the same worktree
/// or non-git workspace at the same time (architecture §3.2).

///|
fn workspace_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS workspaces (" +
    "id TEXT PRIMARY KEY, " +
    "machine_id TEXT NOT NULL, " +
    "kind TEXT NOT NULL, " +
    "root TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "tombstoned INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS worktrees (" +
    "id TEXT PRIMARY KEY, " +
    "workspace_id TEXT NOT NULL, " +
    "machine_id TEXT NOT NULL, " +
    "path TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "tombstoned INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS leases (" +
    "id TEXT PRIMARY KEY, " +
    "target_kind TEXT NOT NULL, " +
    "target_id TEXT NOT NULL, " +
    "holder TEXT NOT NULL, " +
    "created_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS leases_target_idx " +
    "ON leases(target_kind,target_id)",
  )
}

///|
fn put_workspace_raw(
  conn : @sqlite3.Connection,
  record : @contracts.WorkspaceRecord,
  tombstoned : Bool,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO workspaces (id,machine_id,kind,root,record_json,tombstoned," +
    "created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(id) DO UPDATE SET machine_id=excluded.machine_id," +
    "kind=excluded.kind,root=excluded.root,record_json=excluded.record_json," +
    "tombstoned=excluded.tombstoned,created_at=excluded.created_at," +
    "updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.machine_id)
  stmt.bind(index=3, record.kind)
  stmt.bind(index=4, record.root)
  stmt.bind(index=5, record.to_json().stringify())
  stmt.bind(index=6, if tombstoned { 1L } else { 0L })
  stmt.bind(index=7, record.created_at)
  stmt.bind(index=8, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn tombstone_workspace_raw(
  conn : @sqlite3.Connection,
  workspace_id : String,
  updated_at : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "UPDATE workspaces SET tombstoned=1, updated_at=?2 WHERE id=?1",
  )
  stmt.bind(index=1, workspace_id)
  stmt.bind(index=2, updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn put_worktree_raw(
  conn : @sqlite3.Connection,
  record : @contracts.WorktreeRecord,
  tombstoned : Bool,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO worktrees (id,workspace_id,machine_id,path,state,record_json," +
    "tombstoned,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9) " +
    "ON CONFLICT(id) DO UPDATE SET workspace_id=excluded.workspace_id," +
    "machine_id=excluded.machine_id,path=excluded.path,state=excluded.state," +
    "record_json=excluded.record_json,tombstoned=excluded.tombstoned," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.workspace_id)
  stmt.bind(index=3, record.machine_id)
  stmt.bind(index=4, record.path)
  stmt.bind(index=5, record.state)
  stmt.bind(index=6, record.to_json().stringify())
  stmt.bind(index=7, if tombstoned { 1L } else { 0L })
  stmt.bind(index=8, record.created_at)
  stmt.bind(index=9, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn tombstone_worktree_raw(
  conn : @sqlite3.Connection,
  worktree_id : String,
  updated_at : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "UPDATE worktrees SET tombstoned=1, state=?2, updated_at=?3 WHERE id=?1",
  )
  stmt.bind(index=1, worktree_id)
  stmt.bind(index=2, @contracts.WORKTREE_STATE_ARCHIVED)
  stmt.bind(index=3, updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn put_lease_raw(
  conn : @sqlite3.Connection,
  record : @contracts.LeaseRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO leases (id,target_kind,target_id,holder,created_at) " +
    "VALUES (?1,?2,?3,?4,?5) " +
    "ON CONFLICT(id) DO UPDATE SET target_kind=excluded.target_kind," +
    "target_id=excluded.target_id,holder=excluded.holder," +
    "created_at=excluded.created_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.target_kind)
  stmt.bind(index=3, record.target_id)
  stmt.bind(index=4, record.holder)
  stmt.bind(index=5, record.created_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn delete_lease_raw(
  conn : @sqlite3.Connection,
  lease_id : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare("DELETE FROM leases WHERE id=?1")
  stmt.bind(index=1, lease_id)
  let _ = stmt.step()
  stmt.finalize()
}

///|
pub fn MachineStore::put_workspace(
  self : MachineStore,
  record : @contracts.WorkspaceRecord,
) -> Result[Unit, String] {
  try {
    put_workspace_raw(self.conn, record, false)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_workspace(
  self : MachineStore,
  workspace_id : String,
) -> Result[@contracts.WorkspaceRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM workspaces WHERE id=?1 AND tombstoned=0",
    )
    stmt.bind(index=1, workspace_id)
    let mut found : @contracts.WorkspaceRecord? = None
    if stmt.step() {
      let record_json : String = stmt.column(index=0)
      let json = @json.parse(record_json) catch { _ => @json.Json::null() }
      match @contracts.workspace_record_from_json(json) {
        Some(record) => found = Some(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_workspaces(
  self : MachineStore,
) -> Result[Array[@contracts.WorkspaceRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM workspaces WHERE tombstoned=0 " +
      "ORDER BY created_at, id",
    )
    let out : Array[@contracts.WorkspaceRecord] = []
    while stmt.step() {
      let record_json : String = stmt.column(index=0)
      let json = @json.parse(record_json) catch { _ => @json.Json::null() }
      match @contracts.workspace_record_from_json(json) {
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
pub fn MachineStore::put_worktree(
  self : MachineStore,
  record : @contracts.WorktreeRecord,
) -> Result[Unit, String] {
  try {
    put_worktree_raw(self.conn, record, false)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_worktree(
  self : MachineStore,
  worktree_id : String,
) -> Result[@contracts.WorktreeRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM worktrees WHERE id=?1 AND tombstoned=0",
    )
    stmt.bind(index=1, worktree_id)
    let mut found : @contracts.WorktreeRecord? = None
    if stmt.step() {
      let record_json : String = stmt.column(index=0)
      let json = @json.parse(record_json) catch { _ => @json.Json::null() }
      match @contracts.worktree_record_from_json(json) {
        Some(record) => found = Some(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_worktrees(
  self : MachineStore,
) -> Result[Array[@contracts.WorktreeRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM worktrees WHERE tombstoned=0 " +
      "ORDER BY created_at, id",
    )
    let out : Array[@contracts.WorktreeRecord] = []
    while stmt.step() {
      let record_json : String = stmt.column(index=0)
      let json = @json.parse(record_json) catch { _ => @json.Json::null() }
      match @contracts.worktree_record_from_json(json) {
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
pub fn MachineStore::put_lease(
  self : MachineStore,
  record : @contracts.LeaseRecord,
) -> Result[Unit, String] {
  try {
    put_lease_raw(self.conn, record)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Find the active lease for a target. The unique index makes this the
/// single source of truth for the "one active Run per Worktree" rule.
pub fn MachineStore::find_lease(
  self : MachineStore,
  target_kind : String,
  target_id : String,
) -> Result[@contracts.LeaseRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,target_kind,target_id,holder,created_at FROM leases " +
      "WHERE target_kind=?1 AND target_id=?2",
    )
    stmt.bind(index=1, target_kind)
    stmt.bind(index=2, target_id)
    let mut found : @contracts.LeaseRecord? = None
    if stmt.step() {
      found = Some({
        id: stmt.column(index=0),
        target_kind: stmt.column(index=1),
        target_id: stmt.column(index=2),
        holder: stmt.column(index=3),
        created_at: stmt.column(index=4),
      })
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_leases(
  self : MachineStore,
) -> Result[Array[@contracts.LeaseRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,target_kind,target_id,holder,created_at FROM leases " +
      "ORDER BY created_at, id",
    )
    let out : Array[@contracts.LeaseRecord] = []
    while stmt.step() {
      out.push({
        id: stmt.column(index=0),
        target_kind: stmt.column(index=1),
        target_id: stmt.column(index=2),
        holder: stmt.column(index=3),
        created_at: stmt.column(index=4),
      })
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::delete_lease(
  self : MachineStore,
  lease_id : String,
) -> Result[Bool, String] {
  try {
    delete_lease_raw(self.conn, lease_id)
    Ok(self.conn.changes() > 0L)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::record_workspace_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.WorkspaceRecord?,
  removed_id : String?,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match record {
      Some(value) => put_workspace_raw(self.conn, value, false)
      None => ()
    }
    match removed_id {
      Some(value) => tombstone_workspace_raw(self.conn, value, event.ts)
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
pub fn MachineStore::record_worktree_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.WorktreeRecord?,
  removed_id : String?,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match record {
      Some(value) => put_worktree_raw(self.conn, value, false)
      None => ()
    }
    match removed_id {
      Some(value) => tombstone_worktree_raw(self.conn, value, event.ts)
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
pub fn MachineStore::record_lease_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.LeaseRecord?,
  released_id : String?,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match record {
      Some(value) => put_lease_raw(self.conn, value)
      None => ()
    }
    match released_id {
      Some(value) => delete_lease_raw(self.conn, value)
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
pub fn MachineStore::load_workspace_events(
  self : MachineStore,
) -> Result[Array[@contracts.EventEnvelope], String] {
  try {
    Ok(
      load_events_impl(
        self.conn,
        "SELECT seq,id,org_id,type,subject,ts,causation_id,correlation_id," +
        "idempotency_key,payload_json FROM events WHERE type LIKE 'workspace.%' " +
        "OR type LIKE 'worktree.%' OR type LIKE 'lease.%' ORDER BY seq ASC",
      ),
    )
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Rebuild workspace/worktree/lease projections from the event log.
pub fn MachineStore::reconcile_workspace_projection(
  self : MachineStore,
) -> Result[Unit, String] {
  let events = match self.load_workspace_events() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    exec_raise(self.conn, "DELETE FROM workspaces")
    exec_raise(self.conn, "DELETE FROM worktrees")
    exec_raise(self.conn, "DELETE FROM leases")
    for event in events {
      if event.event_type == @contracts.EVENT_WORKSPACE_CLOSED {
        match @contracts.workspace_closed_id(event) {
          Some(workspace_id) =>
            tombstone_workspace_raw(self.conn, workspace_id, event.ts)
          None => ()
        }
        continue
      }
      if event.event_type == @contracts.EVENT_WORKTREE_ARCHIVED {
        match @contracts.worktree_archived_id(event) {
          Some(worktree_id) =>
            tombstone_worktree_raw(self.conn, worktree_id, event.ts)
          None => ()
        }
        continue
      }
      if event.event_type == @contracts.EVENT_LEASE_RELEASED {
        match @contracts.lease_released_id(event) {
          Some(lease_id) => delete_lease_raw(self.conn, lease_id)
          None => ()
        }
        continue
      }
      if event.event_type.has_prefix("worktree.") {
        match @contracts.worktree_event_record(event) {
          Some(record) => put_worktree_raw(self.conn, record, false)
          None => ()
        }
        continue
      }
      if event.event_type.has_prefix("lease.") {
        match @contracts.lease_event_record(event) {
          Some(record) => put_lease_raw(self.conn, record)
          None => ()
        }
        continue
      }
      if event.event_type.has_prefix("workspace.") {
        match @contracts.workspace_event_record(event) {
          Some(record) => put_workspace_raw(self.conn, record, false)
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
