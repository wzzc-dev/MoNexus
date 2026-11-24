///|
/// SQLite-backed machine registry and event log (architecture §12).
///
/// Two tables:
/// - `machines`: the projection (explicit host/port/user/identity columns plus
///   the full record snapshot as JSON);
/// - `events`: the append-only log. Machine events are kept indefinitely so
///   startup replay can rebuild the projection; host heartbeats are pruned at
///   startup because they are pure liveness noise.
///
/// The store is synchronous (the sqlite3 package is a thin C binding). The
/// host guards every call with its async mutex and never awaits while it is
/// inside the store, so the single connection cannot interleave.

///|
pub struct MachineStore {
  conn : @sqlite3.Connection
  path : String
}

///|
fn sqlite_text(error : Error) -> String {
  error.to_string()
}

///|
fn exec_raise(
  conn : @sqlite3.Connection,
  sql : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(sql)
  let mut more = true
  while more {
    more = stmt.step()
  }
  stmt.finalize()
}

///|
fn machine_store_pragmas(conn : @sqlite3.Connection) -> Unit raise @sqlite3.SqliteError {
  exec_raise(conn, "PRAGMA journal_mode=WAL")
  exec_raise(conn, "PRAGMA synchronous=NORMAL")
  exec_raise(conn, "PRAGMA busy_timeout=5000")
  exec_raise(conn, "PRAGMA foreign_keys=ON")
}

///|
fn machine_store_migrate(conn : @sqlite3.Connection) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS machines (" +
    "id TEXT PRIMARY KEY, " +
    "name TEXT NOT NULL, " +
    "host TEXT NOT NULL, " +
    "port INTEGER NOT NULL, " +
    "user TEXT NOT NULL, " +
    "identity TEXT NOT NULL, " +
    "use_ssh_config INTEGER NOT NULL, " +
    "host_key_policy TEXT NOT NULL, " +
    "known_hosts_file TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "tombstoned INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS events (" +
    "seq INTEGER PRIMARY KEY, " +
    "id TEXT NOT NULL UNIQUE, " +
    "org_id TEXT NOT NULL, " +
    "type TEXT NOT NULL, " +
    "subject TEXT NOT NULL, " +
    "ts TEXT NOT NULL, " +
    "causation_id TEXT NOT NULL, " +
    "correlation_id TEXT NOT NULL, " +
    "idempotency_key TEXT NOT NULL UNIQUE, " +
    "payload_json TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS events_type_idx ON events(type)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS events_subject_idx ON events(subject)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS meta (" +
    "key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  )
}

///|
pub fn MachineStore::open(path : String) -> Result[MachineStore, String] {
  let conn = @sqlite3.Connection::open(path) catch {
    error => return Err("cannot open sqlite database " + path + ": " + sqlite_text(error))
  }
  let store = { conn, path }
  try {
    machine_store_pragmas(conn)
    machine_store_migrate(conn)
    workspace_store_migrate(conn)
    agent_store_migrate(conn)
  } catch {
    error => {
      conn.close() catch { _ => () }
      return Err("cannot initialize sqlite database: " + sqlite_text(error))
    }
  }
  Ok(store)
}

///|
pub fn MachineStore::path(self : MachineStore) -> String {
  self.path
}

///|
pub fn MachineStore::close(self : MachineStore) -> Unit {
  self.conn.close() catch { _ => () }
}

///|
fn put_machine_raw(
  conn : @sqlite3.Connection,
  record : @contracts.MachineRecord,
  tombstoned : Bool,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO machines (" +
    "id,name,host,port,user,identity,use_ssh_config,host_key_policy," +
    "known_hosts_file,status,record_json,tombstoned,created_at,updated_at" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14) " +
    "ON CONFLICT(id) DO UPDATE SET " +
    "name=excluded.name,host=excluded.host,port=excluded.port," +
    "user=excluded.user,identity=excluded.identity," +
    "use_ssh_config=excluded.use_ssh_config," +
    "host_key_policy=excluded.host_key_policy," +
    "known_hosts_file=excluded.known_hosts_file,status=excluded.status," +
    "record_json=excluded.record_json,tombstoned=excluded.tombstoned," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.name)
  stmt.bind(index=3, record.host)
  stmt.bind(index=4, record.port.to_int64())
  stmt.bind(index=5, record.user)
  stmt.bind(index=6, record.identity)
  stmt.bind(index=7, if record.use_ssh_config { 1L } else { 0L })
  stmt.bind(index=8, record.host_key_policy)
  stmt.bind(index=9, record.known_hosts_file)
  stmt.bind(index=10, record.status)
  stmt.bind(index=11, record.to_json().stringify())
  stmt.bind(index=12, if tombstoned { 1L } else { 0L })
  stmt.bind(index=13, record.created_at)
  stmt.bind(index=14, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn tombstone_raw(
  conn : @sqlite3.Connection,
  machine_id : String,
  updated_at : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "UPDATE machines SET tombstoned=1, status=?2, updated_at=?3 WHERE id=?1",
  )
  stmt.bind(index=1, machine_id)
  stmt.bind(index=2, @contracts.MACHINE_STATUS_OFFLINE)
  stmt.bind(index=3, updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn insert_event_raw(
  conn : @sqlite3.Connection,
  event : @contracts.EventEnvelope,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO events (" +
    "seq,id,org_id,type,subject,ts,causation_id,correlation_id," +
    "idempotency_key,payload_json" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " +
    "ON CONFLICT DO NOTHING",
  )
  stmt.bind(index=1, event.seq)
  stmt.bind(index=2, event.id)
  stmt.bind(index=3, event.org_id)
  stmt.bind(index=4, event.event_type)
  stmt.bind(index=5, event.subject)
  stmt.bind(index=6, event.ts)
  stmt.bind(index=7, event.causation_id)
  stmt.bind(index=8, event.correlation_id)
  stmt.bind(index=9, event.idempotency_key)
  stmt.bind(index=10, event.payload.stringify())
  let _ = stmt.step()
  stmt.finalize()
}

///|
/// Remember the highest allocated seq. Heartbeat rows are pruned at startup,
/// so `MAX(seq)` alone could move backwards; `meta.last_seq` keeps the
/// global sequence monotonic across restarts.
fn bump_last_seq_raw(
  conn : @sqlite3.Connection,
  seq : Int64,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO meta(key,value) VALUES('last_seq',?1) " +
    "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
  )
  stmt.bind(index=1, seq.to_string())
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn read_meta_raw(
  conn : @sqlite3.Connection,
  key : String,
) -> String? raise @sqlite3.SqliteError {
  let stmt = conn.prepare("SELECT value FROM meta WHERE key=?1")
  stmt.bind(index=1, key)
  let mut found : String? = None
  if stmt.step() {
    let value : String = stmt.column(index=0)
    found = Some(value)
  }
  stmt.finalize()
  found
}

///|
/// Append one event. Returns `false` when the idempotency key was already
/// present (duplicate delivery is dropped, architecture §5.1).
pub fn MachineStore::append_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
) -> Result[Bool, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    let inserted = (self.conn.changes() > 0L)
    exec_raise(self.conn, "COMMIT")
    Ok(inserted)
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
/// Write the projection row for a live machine.
pub fn MachineStore::put_machine(
  self : MachineStore,
  record : @contracts.MachineRecord,
) -> Result[Unit, String] {
  try {
    put_machine_raw(self.conn, record, false)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Tombstone a machine row (R4: no physical cascade delete).
pub fn MachineStore::tombstone_machine(
  self : MachineStore,
  machine_id : String,
  updated_at : String,
) -> Result[Bool, String] {
  try {
    tombstone_raw(self.conn, machine_id, updated_at)
    Ok(self.conn.changes() > 0L)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_machine(
  self : MachineStore,
  machine_id : String,
) -> Result[@contracts.MachineRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json,tombstoned FROM machines WHERE id=?1",
    )
    stmt.bind(index=1, machine_id)
    let mut found : @contracts.MachineRecord? = None
    if stmt.step() {
      let record_json : String = stmt.column(index=0)
      let tombstoned : Int64 = stmt.column(index=1)
      if tombstoned == 0L {
        let json = @json.parse(record_json) catch { _ => @json.Json::null() }
        match @contracts.MachineRecord::from_json(json) {
          Some(record) => found = Some(record)
          None => ()
        }
      }
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_machines(
  self : MachineStore,
) -> Result[Array[@contracts.MachineRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM machines WHERE tombstoned=0 " +
      "ORDER BY created_at, id",
    )
    let out : Array[@contracts.MachineRecord] = []
    while stmt.step() {
      let record_json : String = stmt.column(index=0)
      let json = @json.parse(record_json) catch { _ => @json.Json::null() }
      match @contracts.MachineRecord::from_json(json) {
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
pub fn MachineStore::max_event_seq(self : MachineStore) -> Result[Int64, String] {
  try {
    let stmt = self.conn.prepare("SELECT COALESCE(MAX(seq),0) FROM events")
    let mut value = 0L
    if stmt.step() {
      let column : Int64 = stmt.column(index=0)
      value = column
    }
    stmt.finalize()
    Ok(value)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Highest allocated event seq, even if heartbeat rows were pruned. The host
/// continues numbering from `last_seq + 1` so subscribers never see a seq go
/// backwards across a restart.
pub fn MachineStore::last_seq(self : MachineStore) -> Result[Int64, String] {
  try {
    let mut value = 0L
    match read_meta_raw(self.conn, "last_seq") {
      Some(text) => {
        let parsed = @string.parse_int64(text) catch { _ => 0L }
        value = parsed
      }
      None => ()
    }
    let max_row = self.conn.prepare("SELECT COALESCE(MAX(seq),0) FROM events")
    if max_row.step() {
      let max_seq : Int64 = max_row.column(index=0)
      if max_seq > value {
        value = max_seq
      }
    }
    max_row.finalize()
    Ok(value)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
fn load_events_impl(
  conn : @sqlite3.Connection,
  sql : String,
) -> Array[@contracts.EventEnvelope] raise @sqlite3.SqliteError {
  let stmt = conn.prepare(sql)
  let out : Array[@contracts.EventEnvelope] = []
  while stmt.step() {
    let seq : Int64 = stmt.column(index=0)
    let id : String = stmt.column(index=1)
    let org_id : String = stmt.column(index=2)
    let event_type : String = stmt.column(index=3)
    let subject : String = stmt.column(index=4)
    let ts : String = stmt.column(index=5)
    let causation_id : String = stmt.column(index=6)
    let correlation_id : String = stmt.column(index=7)
    let idempotency_key : String = stmt.column(index=8)
    let payload_json : String = stmt.column(index=9)
    let payload = @json.parse(payload_json) catch { _ => @json.Json::empty_object() }
    out.push(
      @contracts.EventEnvelope::new(
        id~,
        org_id~,
        event_type~,
        ts~,
        subject~,
        seq~,
        payload~,
        causation_id~,
        correlation_id~,
        idempotency_key~,
      ),
    )
  }
  stmt.finalize()
  out
}

///|
/// Most recent events, oldest first. Used to seed the in-memory ring at
/// startup so subscribers can replay machine history across a host restart.
pub fn MachineStore::load_recent_events(
  self : MachineStore,
  limit : Int,
) -> Result[Array[@contracts.EventEnvelope], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT seq,id,org_id,type,subject,ts,causation_id,correlation_id," +
      "idempotency_key,payload_json FROM events ORDER BY seq DESC LIMIT ?1",
    )
    stmt.bind(index=1, limit.max(0).to_int64())
    let out : Array[@contracts.EventEnvelope] = []
    while stmt.step() {
      let seq : Int64 = stmt.column(index=0)
      let id : String = stmt.column(index=1)
      let org_id : String = stmt.column(index=2)
      let event_type : String = stmt.column(index=3)
      let subject : String = stmt.column(index=4)
      let ts : String = stmt.column(index=5)
      let causation_id : String = stmt.column(index=6)
      let correlation_id : String = stmt.column(index=7)
      let idempotency_key : String = stmt.column(index=8)
      let payload_json : String = stmt.column(index=9)
      let payload = @json.parse(payload_json) catch { _ => @json.Json::empty_object() }
      out.push(
        @contracts.EventEnvelope::new(
          id~,
          org_id~,
          event_type~,
          ts~,
          subject~,
          seq~,
          payload~,
          causation_id~,
          correlation_id~,
          idempotency_key~,
        ),
      )
    }
    stmt.finalize()
    // SQL returned newest first; the ring wants oldest first.
    let ordered : Array[@contracts.EventEnvelope] = []
    let mut index = out.length() - 1
    while index >= 0 {
      ordered.push(out[index])
      index = index - 1
    }
    Ok(ordered)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Every machine event, oldest first, for projection rebuild.
pub fn MachineStore::load_machine_events(
  self : MachineStore,
) -> Result[Array[@contracts.EventEnvelope], String] {
  try {
    Ok(
      load_events_impl(
        self.conn,
        "SELECT seq,id,org_id,type,subject,ts,causation_id,correlation_id," +
        "idempotency_key,payload_json FROM events " +
        "WHERE type LIKE 'machine.%' ORDER BY seq ASC",
      ),
    )
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Drop heartbeat rows from previous runs. They are liveness noise and would
/// otherwise grow without bound; machine events stay for replay.
pub fn MachineStore::prune_heartbeats(self : MachineStore) -> Result[Int, String] {
  try {
    exec_raise(self.conn, "DELETE FROM events WHERE type='host.heartbeat'")
    Ok(self.conn.changes().to_int())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Apply one event and its projection change in a single transaction. This is
/// the "event + projection in one transaction" rule from architecture §3.3.
pub fn MachineStore::record_machine_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.MachineRecord?,
  removed_id : String?,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match record {
      Some(value) => put_machine_raw(self.conn, value, false)
      None => ()
    }
    match removed_id {
      Some(value) => tombstone_raw(self.conn, value, event.ts)
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
/// Rebuild the `machines` table from the event log. Called once at host start,
/// so a crash between event append and row write cannot leave a stale
/// projection (architecture R3: replay wins over the projection).
pub fn MachineStore::reconcile_projection(
  self : MachineStore,
) -> Result[(Int, Int), String] {
  let events = match self.load_machine_events() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let projection = replay(events)
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    exec_raise(self.conn, "DELETE FROM machines")
    for record in projection.all_records() {
      let removed = match projection.tombstoned.get(record.id) {
        Some(value) => value
        None => false
      }
      put_machine_raw(self.conn, record, removed)
    }
    exec_raise(self.conn, "COMMIT")
    Ok((projection.live_records().length(), projection.tombstoned_ids().length()))
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
/// A compact summary for logs and smoke tests.
pub fn MachineStore::describe(self : MachineStore) -> String {
  let count = match self.list_machines() {
    Ok(machines) => machines.length()
    Err(_) => -1
  }
  let seq = match self.max_event_seq() {
    Ok(value) => value
    Err(_) => -1L
  }
  "sqlite=" + self.path + " machines=" + count.to_string() +
  " max_seq=" + seq.to_string()
}
