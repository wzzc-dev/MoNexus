///|
/// Project / Task / Run / Evidence persistence and session search (M5).
///
/// Same pattern as M1-M4: every row is a projection (cheap status columns)
/// plus the full contract record JSON. Each state change appends one event and
/// upserts its projection in a single transaction, so a subscriber never sees
/// a state the database does not have.

///|
fn task_store_migrate(conn : @sqlite3.Connection) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS projects (" +
    "id TEXT PRIMARY KEY, name TEXT NOT NULL, verify_json TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, created_at TEXT NOT NULL)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS tasks (" +
    "id TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL, " +
    "parent_id TEXT NOT NULL, project_id TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS tasks_status_idx ON tasks(status)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS tasks_parent_idx ON tasks(parent_id)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS runs (" +
    "id TEXT PRIMARY KEY, task_id TEXT NOT NULL, machine_id TEXT NOT NULL, " +
    "status TEXT NOT NULL, idempotency_key TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS runs_task_idx ON runs(task_id)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS runs_machine_status_idx " +
    "ON runs(machine_id,status)",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS runs_idem_idx " +
    "ON runs(idempotency_key) WHERE idempotency_key <> ''",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS evidence (" +
    "id TEXT PRIMARY KEY, run_id TEXT NOT NULL, name TEXT NOT NULL, " +
    "kind TEXT NOT NULL, passed INTEGER NOT NULL, waived INTEGER NOT NULL, " +
    "record_json TEXT NOT NULL, created_at TEXT NOT NULL)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS evidence_run_idx ON evidence(run_id)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS search_docs (" +
    "doc_id TEXT PRIMARY KEY, kind TEXT NOT NULL, ref_id TEXT NOT NULL, " +
    "title TEXT NOT NULL, text TEXT NOT NULL, ts TEXT NOT NULL)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS search_docs_kind_idx ON search_docs(kind)",
  )
}

///|
/// Try to create the FTS5 virtual table. SQLite builds without FTS5 raise
/// here; the store then falls back to LIKE over `search_docs` (ADR-0004 §7).
fn task_store_try_fts(conn : @sqlite3.Connection) -> Bool {
  let ok = try {
    exec_raise(
      conn,
      "CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(" +
      "doc_id UNINDEXED, text)",
    )
    true
  } catch {
    _ => false
  }
  ok
}

///|
fn project_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.ProjectRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO projects (id,name,verify_json,record_json,created_at) " +
    "VALUES (?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET " +
    "name=excluded.name,verify_json=excluded.verify_json," +
    "record_json=excluded.record_json,created_at=excluded.created_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.name)
  stmt.bind(index=3, @contracts.json_string_array(record.verify).stringify())
  stmt.bind(index=4, record.to_json().stringify())
  stmt.bind(index=5, record.created_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn task_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.TaskRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO tasks (id,title,status,parent_id,project_id,record_json," +
    "created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(id) DO UPDATE SET title=excluded.title," +
    "status=excluded.status,parent_id=excluded.parent_id," +
    "project_id=excluded.project_id,record_json=excluded.record_json," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.title)
  stmt.bind(index=3, record.status)
  stmt.bind(index=4, record.parent_id)
  stmt.bind(index=5, record.project_id)
  stmt.bind(index=6, record.to_json().stringify())
  stmt.bind(index=7, record.created_at)
  stmt.bind(index=8, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn run_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.RunRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO runs (id,task_id,machine_id,status,idempotency_key," +
    "record_json,created_at,updated_at) VALUES " +
    "(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(id) DO UPDATE SET " +
    "task_id=excluded.task_id,machine_id=excluded.machine_id," +
    "status=excluded.status,idempotency_key=excluded.idempotency_key," +
    "record_json=excluded.record_json,created_at=excluded.created_at," +
    "updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.task_id)
  stmt.bind(index=3, record.machine_id)
  stmt.bind(index=4, record.status)
  stmt.bind(index=5, record.idempotency_key)
  stmt.bind(index=6, record.to_json().stringify())
  stmt.bind(index=7, record.created_at)
  stmt.bind(index=8, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn evidence_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.EvidenceRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO evidence (id,run_id,name,kind,passed,waived,record_json," +
    "created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(id) DO UPDATE SET run_id=excluded.run_id," +
    "name=excluded.name,kind=excluded.kind,passed=excluded.passed," +
    "waived=excluded.waived,record_json=excluded.record_json," +
    "created_at=excluded.created_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.run_id)
  stmt.bind(index=3, record.name)
  stmt.bind(index=4, record.kind)
  stmt.bind(index=5, if record.passed { 1L } else { 0L })
  stmt.bind(index=6, if record.waived { 1L } else { 0L })
  stmt.bind(index=7, record.to_json().stringify())
  stmt.bind(index=8, record.started_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
pub fn MachineStore::record_project_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.ProjectRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    project_put_raw(self.conn, record)
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::record_task_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.TaskRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    task_put_raw(self.conn, record)
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::record_run_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.RunRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    run_put_raw(self.conn, record)
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::record_evidence_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.EvidenceRecord,
  run : @contracts.RunRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    evidence_put_raw(self.conn, record)
    run_put_raw(self.conn, run)
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
pub fn MachineStore::get_project(
  self : MachineStore,
  project_id : String,
) -> Result[@contracts.ProjectRecord?, String] {
  match self.get_record_json("projects", "id", project_id) {
    Ok(Some(text)) => {
      let parsed = @json.parse(text) catch { _ => return Ok(None) }
      Ok(@contracts.project_from_json(parsed))
    }
    Ok(None) => Ok(None)
    Err(message) => Err(message)
  }
}

///|
pub fn MachineStore::list_projects(
  self : MachineStore,
) -> Result[Array[@contracts.ProjectRecord], String] {
  let out : Array[@contracts.ProjectRecord] = []
  match self.select_record_json("projects", "created_at ASC, id ASC") {
    Ok(items) =>
      for text in items {
        let parsed = @json.parse(text) catch { _ => continue }
        match @contracts.project_from_json(parsed) {
          Some(record) => out.push(record)
          None => ()
        }
      }
    Err(message) => return Err(message)
  }
  Ok(out)
}

///|
pub fn MachineStore::get_task(
  self : MachineStore,
  task_id : String,
) -> Result[@contracts.TaskRecord?, String] {
  match self.get_record_json("tasks", "id", task_id) {
    Ok(Some(text)) => {
      let parsed = @json.parse(text) catch { _ => return Ok(None) }
      Ok(@contracts.task_from_json(parsed))
    }
    Ok(None) => Ok(None)
    Err(message) => Err(message)
  }
}

///|
pub fn MachineStore::list_tasks(
  self : MachineStore,
  status : String,
  parent_id : String,
) -> Result[Array[@contracts.TaskRecord], String] {
  let mut where_clause = ""
  let binds : Array[String] = []
  if status != "" {
    where_clause = " WHERE status=?1"
    binds.push(status)
  }
  if parent_id != "" {
    if where_clause == "" {
      where_clause = " WHERE parent_id=?1"
    } else {
      where_clause = where_clause + " AND parent_id=?2"
    }
    binds.push(parent_id)
  }
  let sql = "SELECT record_json FROM tasks" + where_clause +
    " ORDER BY created_at ASC, id ASC"
  let out : Array[@contracts.TaskRecord] = []
  try {
    let stmt = self.conn.prepare(sql)
    for index, value in binds {
      stmt.bind(index=index + 1, value)
    }
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch { _ => continue }
      match @contracts.task_from_json(parsed) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
  } catch {
    error => return Err(sqlite_text(error))
  }
  Ok(out)
}

///|
pub fn MachineStore::get_run(
  self : MachineStore,
  run_id : String,
) -> Result[@contracts.RunRecord?, String] {
  match self.get_record_json("runs", "id", run_id) {
    Ok(Some(text)) => {
      let parsed = @json.parse(text) catch { _ => return Ok(None) }
      Ok(@contracts.run_from_json(parsed))
    }
    Ok(None) => Ok(None)
    Err(message) => Err(message)
  }
}

///|
pub fn MachineStore::list_runs(
  self : MachineStore,
  task_id : String,
  status : String,
) -> Result[Array[@contracts.RunRecord], String] {
  let mut where_clause = ""
  let binds : Array[String] = []
  if task_id != "" {
    where_clause = " WHERE task_id=?1"
    binds.push(task_id)
  }
  if status != "" {
    if where_clause == "" {
      where_clause = " WHERE status=?1"
    } else {
      where_clause = where_clause + " AND status=?2"
    }
    binds.push(status)
  }
  let sql = "SELECT record_json FROM runs" + where_clause +
    " ORDER BY created_at ASC, id ASC"
  let out : Array[@contracts.RunRecord] = []
  try {
    let stmt = self.conn.prepare(sql)
    for index, value in binds {
      stmt.bind(index=index + 1, value)
    }
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch { _ => continue }
      match @contracts.run_from_json(parsed) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
  } catch {
    error => return Err(sqlite_text(error))
  }
  Ok(out)
}

///|
pub fn MachineStore::find_run_by_idempotency(
  self : MachineStore,
  key : String,
) -> Result[@contracts.RunRecord?, String] {
  if key == "" {
    return Ok(None)
  }
  match self.get_record_json("runs", "idempotency_key", key) {
    Ok(Some(text)) => {
      let parsed = @json.parse(text) catch { _ => return Ok(None) }
      Ok(@contracts.run_from_json(parsed))
    }
    Ok(None) => Ok(None)
    Err(message) => Err(message)
  }
}

///|
pub fn MachineStore::list_evidence(
  self : MachineStore,
  run_id : String,
) -> Result[Array[@contracts.EvidenceRecord], String] {
  let out : Array[@contracts.EvidenceRecord] = []
  try {
    let stmt = if run_id == "" {
      self.conn.prepare(
        "SELECT record_json FROM evidence ORDER BY created_at ASC, id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM evidence WHERE run_id=?1 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, run_id)
      prepared
    }
    while stmt.step() {
      let text : String = stmt.column(index=0)
      let parsed = @json.parse(text) catch { _ => continue }
      match @contracts.evidence_from_json(parsed) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
  } catch {
    error => return Err(sqlite_text(error))
  }
  Ok(out)
}

///|
/// Count runs that occupy a machine slot. `queued` runs do not count; they
/// wait for capacity (architecture §6.5).
pub fn MachineStore::count_slot_runs(
  self : MachineStore,
  machine_id : String,
) -> Result[Int, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT COUNT(*) FROM runs WHERE machine_id=?1 AND status IN " +
      "('running','verifying','waiting_approval','waiting_input')",
    )
    stmt.bind(index=1, machine_id)
    let mut count = 0
    if stmt.step() {
      let value : Int64 = stmt.column(index=0)
      count = value.to_int()
    }
    stmt.finalize()
    Ok(count)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
fn MachineStore::get_record_json(
  self : MachineStore,
  table : String,
  column : String,
  value : String,
) -> Result[String?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM " + table + " WHERE " + column + "=?1",
    )
    stmt.bind(index=1, value)
    let mut found : String? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = Some(text)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
fn MachineStore::select_record_json(
  self : MachineStore,
  table : String,
  order : String,
) -> Result[Array[String], String] {
  let out : Array[String] = []
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM " + table + " ORDER BY " + order,
    )
    while stmt.step() {
      let text : String = stmt.column(index=0)
      out.push(text)
    }
    stmt.finalize()
  } catch {
    error => return Err(sqlite_text(error))
  }
  Ok(out)
}

// ---------------------------------------------------------------------------
// Session / decision search (ADR-0004 §7)
// ---------------------------------------------------------------------------

///|
/// Index one searchable document. `doc_id` is stable (e.g. `decision/<id>`),
/// so a re-index replaces the previous text instead of duplicating a hit.
pub fn MachineStore::search_index(
  self : MachineStore,
  doc_id : String,
  kind : String,
  ref_id : String,
  title : String,
  text : String,
  ts : String,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let stmt = self.conn.prepare(
      "INSERT INTO search_docs (doc_id,kind,ref_id,title,text,ts) " +
      "VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(doc_id) DO UPDATE SET " +
      "kind=excluded.kind,ref_id=excluded.ref_id,title=excluded.title," +
      "text=excluded.text,ts=excluded.ts",
    )
    stmt.bind(index=1, doc_id)
    stmt.bind(index=2, kind)
    stmt.bind(index=3, ref_id)
    stmt.bind(index=4, title)
    stmt.bind(index=5, text)
    stmt.bind(index=6, ts)
    let _ = stmt.step()
    stmt.finalize()
    if self.fts5 {
      let del = self.conn.prepare("DELETE FROM search_fts WHERE doc_id=?1")
      del.bind(index=1, doc_id)
      let _ = del.step()
      del.finalize()
      let ins = self.conn.prepare(
        "INSERT INTO search_fts (doc_id,text) VALUES (?1,?2)",
      )
      ins.bind(index=1, doc_id)
      ins.bind(index=2, title + "\n" + text)
      let _ = ins.step()
      ins.finalize()
    }
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
fn search_snippet(text : String, query : String) -> String {
  let lower = text.to_lower()
  let needle = query.to_lower()
  let at = match lower.find(needle) {
    Some(value) => value
    None => 0
  }
  let start = if at > 40 { at - 40 } else { 0 }
  let end = (at + needle.length() + 60).min(text.length())
  let prefix = if start > 0 { "…" } else { "" }
  let suffix = if end < text.length() { "…" } else { "" }
  prefix + text.substring(start=start, end=end) + suffix
}

///|
/// Search indexed session and decision text. FTS5 when the SQLite build has
/// it, LIKE + time ordering otherwise; the result shape is identical.
pub fn MachineStore::search_docs(
  self : MachineStore,
  query : String,
  limit : Int,
) -> Result[Array[@contracts.SearchHit], String] {
  let trimmed = query.trim().to_string()
  if trimmed == "" {
    return Ok([])
  }
  let capped = limit.max(1).min(50)
  let hits : Array[@contracts.SearchHit] = []
  if self.fts5 {
    let escaped = trimmed.replace(old="\"", new="\"\"").to_string()
    let match_expr = "\"" + escaped + "\""
    let fts_result = try {
      let stmt = self.conn.prepare(
        "SELECT d.kind,d.ref_id,d.title,d.ts," +
        "snippet(search_fts,1,'[',']','…',16) FROM search_fts " +
        "JOIN search_docs d ON d.doc_id=search_fts.doc_id " +
        "WHERE search_fts MATCH ?1 ORDER BY d.ts DESC LIMIT ?2",
      )
      stmt.bind(index=1, match_expr)
      stmt.bind(index=2, capped.to_int64())
      while stmt.step() {
        hits.push({
          kind: stmt.column(index=0),
          ref_id: stmt.column(index=1),
          title: stmt.column(index=2),
          ts: stmt.column(index=3),
          snippet: stmt.column(index=4),
        })
      }
      stmt.finalize()
      true
    } catch {
      _ => false
    }
    if fts_result {
      return Ok(hits)
    }
  }
  // LIKE fallback: substring match over title + text.
  try {
    let stmt = self.conn.prepare(
      "SELECT kind,ref_id,title,ts,text FROM search_docs " +
      "WHERE title LIKE ?1 OR text LIKE ?1 ORDER BY ts DESC LIMIT ?2",
    )
    stmt.bind(index=1, "%" + trimmed + "%")
    stmt.bind(index=2, capped.to_int64())
    while stmt.step() {
      let text : String = stmt.column(index=4)
      hits.push({
        kind: stmt.column(index=0),
        ref_id: stmt.column(index=1),
        title: stmt.column(index=2),
        ts: stmt.column(index=3),
        snippet: search_snippet(text, trimmed),
      })
    }
    stmt.finalize()
  } catch {
    error => return Err(sqlite_text(error))
  }
  Ok(hits)
}

///|
pub fn MachineStore::search_backend(self : MachineStore) -> String {
  if self.fts5 {
    "fts5"
  } else {
    "like"
  }
}

// ---------------------------------------------------------------------------
// Events for the Activity page
// ---------------------------------------------------------------------------

///|
pub fn MachineStore::load_events_since(
  self : MachineStore,
  since : Int64,
  limit : Int,
) -> Result[Array[@contracts.EventEnvelope], String] {
  let out : Array[@contracts.EventEnvelope] = []
  try {
    let stmt = self.conn.prepare(
      "SELECT id,org_id,type,subject,ts,seq,causation_id,correlation_id," +
      "idempotency_key,payload_json FROM events WHERE seq>?1 " +
      "ORDER BY seq ASC LIMIT ?2",
    )
    stmt.bind(index=1, since)
    stmt.bind(index=2, limit.max(1).min(2000).to_int64())
    while stmt.step() {
      let payload_text : String = stmt.column(index=9)
      let payload = @json.parse(payload_text) catch {
        _ => @json.Json::empty_object()
      }
      out.push(
        @contracts.EventEnvelope::new(
          id=stmt.column(index=0),
          org_id=stmt.column(index=1),
          event_type=stmt.column(index=2),
          subject=stmt.column(index=3),
          ts=stmt.column(index=4),
          seq=stmt.column(index=5),
          payload~,
          causation_id=stmt.column(index=6),
          correlation_id=stmt.column(index=7),
          idempotency_key=stmt.column(index=8),
        ),
      )
    }
    stmt.finalize()
  } catch {
    error => return Err(sqlite_text(error))
  }
  Ok(out)
}

// ---------------------------------------------------------------------------
// Projection replay
// ---------------------------------------------------------------------------

///|
/// Rebuild project/task/run/evidence rows from the append-only event log.
/// Called at startup before serving; the event log is the authority.
pub fn MachineStore::reconcile_task_projection(
  self : MachineStore,
) -> Result[(Int, Int, Int), String] {
  let events = match self.load_events_since(0L, 100_000) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let mut projects = 0
    let mut tasks = 0
    let mut runs = 0
    for event in events {
      if event.event_type == @contracts.EVENT_PROJECT_CREATED {
        match @contracts.project_from_json(event.payload) {
          Some(record) => {
            project_put_raw(self.conn, record)
            projects = projects + 1
          }
          None => ()
        }
      } else if event.event_type.has_prefix("task.") {
        match @contracts.task_from_json(event.payload) {
          Some(record) => {
            task_put_raw(self.conn, record)
            tasks = tasks + 1
          }
          None => ()
        }
      } else if event.event_type == @contracts.EVENT_RUN_EVIDENCE {
        match @contracts.evidence_from_json(event.payload) {
          Some(record) => {
            evidence_put_raw(self.conn, record)
            runs = runs + 1
          }
          None => ()
        }
      } else if event.event_type.has_prefix("run.") {
        match @contracts.run_from_json(event.payload) {
          Some(record) => {
            run_put_raw(self.conn, record)
            runs = runs + 1
          }
          None => ()
        }
      }
    }
    exec_raise(self.conn, "COMMIT")
    Ok((projects, tasks, runs))
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}
