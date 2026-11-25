///|
/// Trigger persistence (ADR-0014, A3.0).
///
/// Three rules keep this package honest:
/// 1. `events` stays the only event log. Trigger lifecycle and fire records
///    are appended there with subject `trigger/<trg_id>`.
/// 2. `triggers` is a projection rebuilt from those events by
///    `reconcile_trigger_projection`.
/// 3. `trigger_fires` is a dedupe/audit ledger, not a source of state. Its
///    `UNIQUE(trigger_id, fire_key)` is what makes the Task creation exactly
///    once, and it is written in the *same* transaction as the `task.created`
///    projection and the `trigger.fired` event.
///
/// A3.0 only wires event triggers. `webhook_keys` and `webhook_nonces` are
/// created empty for forward compatibility with A3.1; nothing reads them.

///|
fn trigger_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS triggers (" +
    "id TEXT PRIMARY KEY, " +
    "org_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "type TEXT NOT NULL, " +
    "enabled INTEGER NOT NULL, " +
    "expires_at TEXT NOT NULL, " +
    "expires_ms INTEGER NOT NULL DEFAULT 0, " +
    "target_json TEXT NOT NULL, " +
    "source_json TEXT NOT NULL, " +
    "config_hash TEXT NOT NULL, " +
    "created_by TEXT NOT NULL, " +
    "version INTEGER NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "expired_at TEXT NOT NULL DEFAULT '', " +
    "active_from_seq INTEGER NOT NULL DEFAULT 0, " +
    "next_fire_at TEXT NOT NULL DEFAULT '', " +
    "last_fired_at TEXT NOT NULL DEFAULT '', " +
    "dedupe_hits INTEGER NOT NULL DEFAULT 0, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS triggers_org_name_idx " +
    "ON triggers(org_id, name)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS triggers_type_idx ON triggers(type)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS trigger_fires (" +
    "id TEXT PRIMARY KEY, " +
    "trigger_id TEXT NOT NULL, " +
    "source TEXT NOT NULL, " +
    "fire_key TEXT NOT NULL, " +
    "event_id TEXT NOT NULL DEFAULT '', " +
    "scheduled_for_ms INTEGER NOT NULL DEFAULT 0, " +
    "key_id TEXT NOT NULL DEFAULT '', " +
    "task_id TEXT NOT NULL DEFAULT '', " +
    "run_id TEXT NOT NULL DEFAULT '', " +
    "coalesced INTEGER NOT NULL DEFAULT 0, " +
    "depth INTEGER NOT NULL DEFAULT 1, " +
    "created_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS trigger_fires_dedupe_idx " +
    "ON trigger_fires(trigger_id, fire_key)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS trigger_fires_trigger_idx " +
    "ON trigger_fires(trigger_id, created_at)",
  )
  // Empty forward-compatible tables for A3.1. A3.0 never reads or writes
  // them; keeping them in the migration lets A3.1 stay additive.
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS webhook_keys (" +
    "key_id TEXT PRIMARY KEY, " +
    "trigger_id TEXT NOT NULL, " +
    "org_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "secret_path TEXT NOT NULL, " +
    "enabled INTEGER NOT NULL DEFAULT 1, " +
    "created_at TEXT NOT NULL, " +
    "revoked_at TEXT NOT NULL DEFAULT ''" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS webhook_keys_trigger_idx " +
    "ON webhook_keys(trigger_id)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS webhook_nonces (" +
    "key_id TEXT NOT NULL, " +
    "nonce TEXT NOT NULL, " +
    "body_sha256 TEXT NOT NULL DEFAULT '', " +
    "first_seen_ms INTEGER NOT NULL, " +
    "expires_at_ms INTEGER NOT NULL, " +
    "PRIMARY KEY (key_id, nonce)" +
    ")",
  )
}

// ---------------------------------------------------------------------------
// Projection writes
// ---------------------------------------------------------------------------

///|
fn trigger_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.TriggerRecord,
) -> Unit raise @sqlite3.SqliteError {
  let expires_ms = match @contracts.trigger_parse_rfc3339_ms(record.expires_at) {
    Some(value) => value
    None => 0L
  }
  let stmt = conn.prepare(
    "INSERT INTO triggers (" +
    "id,org_id,name,type,enabled,expires_at,expires_ms,target_json," +
    "source_json,config_hash,created_by,version,record_json,expired_at," +
    "active_from_seq,next_fire_at,last_fired_at,dedupe_hits," +
    "created_at,updated_at" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20) " +
    "ON CONFLICT(id) DO UPDATE SET " +
    "name=excluded.name,type=excluded.type,enabled=excluded.enabled," +
    "expires_at=excluded.expires_at,expires_ms=excluded.expires_ms," +
    "target_json=excluded.target_json,source_json=excluded.source_json," +
    "config_hash=excluded.config_hash,created_by=excluded.created_by," +
    "version=excluded.version,record_json=excluded.record_json," +
    "expired_at=excluded.expired_at,active_from_seq=excluded.active_from_seq," +
    "next_fire_at=excluded.next_fire_at," +
    "last_fired_at=excluded.last_fired_at," +
    "dedupe_hits=excluded.dedupe_hits,created_at=excluded.created_at," +
    "updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.org_id)
  stmt.bind(index=3, record.name)
  stmt.bind(index=4, record.kind)
  stmt.bind(index=5, if record.enabled { 1L } else { 0L })
  stmt.bind(index=6, record.expires_at)
  stmt.bind(index=7, expires_ms)
  stmt.bind(index=8, record.target.to_json().stringify())
  stmt.bind(index=9, record.source.to_json().stringify())
  stmt.bind(index=10, record.config_hash)
  stmt.bind(index=11, record.created_by)
  stmt.bind(index=12, record.version.to_int64())
  stmt.bind(index=13, record.to_json().stringify())
  stmt.bind(index=14, record.expired_at)
  stmt.bind(index=15, record.active_from_seq)
  stmt.bind(index=16, record.next_fire_at)
  stmt.bind(index=17, record.last_fired_at)
  stmt.bind(index=18, record.dedupe_hits.to_int64())
  stmt.bind(index=19, record.created_at)
  stmt.bind(index=20, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
/// Keep the projection's dedupe counter when a record snapshot (re)writes it.
fn trigger_dedupe_hits_raw(
  conn : @sqlite3.Connection,
  trigger_id : String,
) -> Int raise @sqlite3.SqliteError {
  let stmt = conn.prepare("SELECT dedupe_hits FROM triggers WHERE id=?1")
  stmt.bind(index=1, trigger_id)
  let mut found = 0
  if stmt.step() {
    let value : Int64 = stmt.column(index=0)
    found = value.to_int()
  }
  stmt.finalize()
  found
}

///|
/// `record_trigger_event`: append one lifecycle event and upsert its
/// projection in a single transaction (ADR-0014 §6.2).
pub fn MachineStore::record_trigger_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.TriggerRecord,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    trigger_put_raw(self.conn, record)
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
/// Update with optimistic concurrency: the row is only rewritten when its
/// stored version equals `expected_version`. The event is inserted in the
/// same transaction, so a version conflict leaves no trace.
pub fn MachineStore::record_trigger_update_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.TriggerRecord,
  expected_version : Int,
) -> Result[@contracts.TriggerWriteOutcome, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let current = self.conn.prepare(
      "SELECT version FROM triggers WHERE id=?1",
    )
    current.bind(index=1, record.id)
    let mut version = -1
    if current.step() {
      let value : Int64 = current.column(index=0)
      version = value.to_int()
    }
    current.finalize()
    if version < 0 {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerNotFound)
    }
    if version != expected_version {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerVersionConflict)
    }
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    trigger_put_raw(self.conn, record)
    exec_raise(self.conn, "COMMIT")
    Ok(@contracts.TriggerApplied)
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
/// Mark a trigger expired exactly once. `expired_at` is the guard: if it is
/// already set, no event is written and `false` is returned. The host calls
/// this from its expiry sweep and from the pre-fire check.
pub fn MachineStore::record_trigger_expired_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
  record : @contracts.TriggerRecord,
) -> Result[Bool, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let stmt = self.conn.prepare(
      "UPDATE triggers SET expired_at=?2, record_json=?3, updated_at=?4 " +
      "WHERE id=?1 AND expired_at=''",
    )
    stmt.bind(index=1, record.id)
    stmt.bind(index=2, record.expired_at)
    stmt.bind(index=3, record.to_json().stringify())
    stmt.bind(index=4, record.updated_at)
    let _ = stmt.step()
    let changed = (self.conn.changes() > 0L)
    stmt.finalize()
    if !changed {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(false)
    }
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    exec_raise(self.conn, "COMMIT")
    Ok(true)
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

// ---------------------------------------------------------------------------
// Dedupe ledger and the exactly-once fire transaction
// ---------------------------------------------------------------------------

///|
fn trigger_fire_put_raw(
  conn : @sqlite3.Connection,
  fire : @contracts.TriggerFire,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO trigger_fires (" +
    "id,trigger_id,source,fire_key,event_id,scheduled_for_ms,key_id," +
    "task_id,run_id,coalesced,depth,created_at" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) " +
    "ON CONFLICT(trigger_id, fire_key) DO NOTHING",
  )
  stmt.bind(index=1, fire.id)
  stmt.bind(index=2, fire.trigger_id)
  stmt.bind(index=3, fire.source)
  stmt.bind(index=4, fire.fire_key)
  stmt.bind(index=5, fire.event_id)
  stmt.bind(index=6, fire.scheduled_for_ms)
  stmt.bind(index=7, fire.key_id)
  stmt.bind(index=8, fire.task_id)
  stmt.bind(index=9, fire.run_id)
  stmt.bind(index=10, if fire.coalesced { 1L } else { 0L })
  stmt.bind(index=11, fire.depth.to_int64())
  stmt.bind(index=12, fire.created_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn trigger_bump_dedupe_raw(
  conn : @sqlite3.Connection,
  trigger_id : String,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "UPDATE triggers SET dedupe_hits=MIN(dedupe_hits+1, ?2) WHERE id=?1",
  )
  stmt.bind(index=1, trigger_id)
  stmt.bind(index=2, @contracts.TRIGGER_DEDUPE_HITS_CAP.to_int64())
  let _ = stmt.step()
  stmt.finalize()
}

///|
/// The exactly-once commit (ADR-0014 §2.3).
///
/// One transaction:
/// 1. re-read the trigger row and reject disabled/expired ones (§6.3);
/// 2. insert the `trigger_fires` dedupe row; a unique conflict means another
///    delivery already created the Task → saturate `dedupe_hits`, no events;
/// 3. otherwise write the Task events (`task.created`, optional
///    `task.assigned`), the Task projection, and `trigger.fired`.
///
/// `task_events` are fully built envelopes whose idempotency keys are
/// deterministic; `insert_event_raw` drops duplicates as a second line of
/// defence behind the fire row.
pub fn MachineStore::record_trigger_task_event(
  self : MachineStore,
  task_events : Array[@contracts.EventEnvelope],
  fired_event : @contracts.EventEnvelope,
  task : @contracts.TaskRecord,
  fire : @contracts.TriggerFire,
  record_after : @contracts.TriggerRecord,
  now_ms : Int64,
) -> Result[@contracts.TriggerWriteOutcome, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let check = self.conn.prepare(
      "SELECT enabled, expires_ms FROM triggers WHERE id=?1",
    )
    check.bind(index=1, fire.trigger_id)
    let mut found = false
    let mut enabled = false
    let mut expires_ms = 0L
    if check.step() {
      found = true
      let enabled_col : Int64 = check.column(index=0)
      enabled = enabled_col != 0L
      let expires_col : Int64 = check.column(index=1)
      expires_ms = expires_col
    }
    check.finalize()
    if !found {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerNotFound)
    }
    if !enabled {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerDisabled)
    }
    if expires_ms > 0L && expires_ms <= now_ms {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerExpired)
    }
    trigger_fire_put_raw(self.conn, fire)
    let inserted = (self.conn.changes() > 0L)
    if !inserted {
      trigger_bump_dedupe_raw(self.conn, fire.trigger_id)
      exec_raise(self.conn, "COMMIT")
      return Ok(@contracts.TriggerDuplicate)
    }
    let mut max_seq = fired_event.seq
    for event in task_events {
      if event.seq > max_seq {
        max_seq = event.seq
      }
      insert_event_raw(self.conn, event)
    }
    bump_last_seq_raw(self.conn, max_seq)
    task_put_raw(self.conn, task)
    insert_event_raw(self.conn, fired_event)
    trigger_put_raw(self.conn, record_after)
    exec_raise(self.conn, "COMMIT")
    Ok(@contracts.TriggerApplied)
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

///|
fn trigger_from_row(
  stmt : @sqlite3.Statement,
  dedupe_index : Int32,
) -> @contracts.TriggerRecord? raise @sqlite3.SqliteError {
  let record_json : String = stmt.column(index=0)
  let dedupe_hits : Int64 = stmt.column(index=dedupe_index)
  let json = @json.parse(record_json) catch { _ => @json.Json::null() }
  match @contracts.trigger_record_from_json(json) {
    Some(record) => Some({ ..record, dedupe_hits: dedupe_hits.to_int() })
    None => None
  }
}

///|
pub fn MachineStore::get_trigger(
  self : MachineStore,
  trigger_id : String,
) -> Result[@contracts.TriggerRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json, dedupe_hits FROM triggers WHERE id=?1",
    )
    stmt.bind(index=1, trigger_id)
    let mut found : @contracts.TriggerRecord? = None
    if stmt.step() {
      found = trigger_from_row(stmt, 1)
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_triggers(
  self : MachineStore,
) -> Result[Array[@contracts.TriggerRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json, dedupe_hits FROM triggers ORDER BY created_at, id",
    )
    let out : Array[@contracts.TriggerRecord] = []
    while stmt.step() {
      match trigger_from_row(stmt, 1) {
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
/// One ledger entry by dedupe key. Used by `trigger.fire` to return the Task
/// id of an idempotent retry. An absent entry is represented by an empty `id`
/// rather than an Option, keeping the return type simple for the parser.
pub fn MachineStore::get_trigger_fire_row(
  self : MachineStore,
  trigger_id : String,
  fire_key : String,
) -> Result[@contracts.TriggerFire, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,trigger_id,source,fire_key,event_id,scheduled_for_ms," +
      "key_id,task_id,run_id,coalesced,depth,created_at " +
      "FROM trigger_fires WHERE trigger_id=?1 AND fire_key=?2",
    )
    stmt.bind(index=1, trigger_id)
    stmt.bind(index=2, fire_key)
    let mut found = @contracts.TriggerFire::new(id="", trigger_id~, source="", fire_key~, created_at="")
    if stmt.step() {
      let id : String = stmt.column(index=0)
      let row_trigger_id : String = stmt.column(index=1)
      let source : String = stmt.column(index=2)
      let row_fire_key : String = stmt.column(index=3)
      let event_id : String = stmt.column(index=4)
      let scheduled_for_ms : Int64 = stmt.column(index=5)
      let key_id : String = stmt.column(index=6)
      let task_id : String = stmt.column(index=7)
      let run_id : String = stmt.column(index=8)
      let coalesced : Int64 = stmt.column(index=9)
      let depth : Int64 = stmt.column(index=10)
      let created_at : String = stmt.column(index=11)
      found = @contracts.TriggerFire::new(
        id~,
        trigger_id=row_trigger_id,
        source~,
        fire_key=row_fire_key,
        event_id~,
        scheduled_for_ms~,
        key_id~,
        task_id~,
        run_id~,
        coalesced=coalesced != 0L,
        depth=depth.to_int(),
        created_at~,
      )
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Recent fire ledger entries for `trigger.get`, newest first. The ledger has
/// no payload beyond links, so there is nothing secret to redact.
pub fn MachineStore::get_trigger_fires(
  self : MachineStore,
  trigger_id : String,
  limit : Int,
) -> Result[Array[@contracts.TriggerFire], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,trigger_id,source,fire_key,event_id,scheduled_for_ms," +
      "key_id,task_id,run_id,coalesced,depth,created_at " +
      "FROM trigger_fires WHERE trigger_id=?1 " +
      "ORDER BY created_at DESC, id DESC LIMIT ?2",
    )
    stmt.bind(index=1, trigger_id)
    stmt.bind(index=2, limit.max(0).min(100).to_int64())
    let out : Array[@contracts.TriggerFire] = []
    while stmt.step() {
      let id : String = stmt.column(index=0)
      let trigger_id : String = stmt.column(index=1)
      let source : String = stmt.column(index=2)
      let fire_key : String = stmt.column(index=3)
      let event_id : String = stmt.column(index=4)
      let scheduled_for_ms : Int64 = stmt.column(index=5)
      let key_id : String = stmt.column(index=6)
      let task_id : String = stmt.column(index=7)
      let run_id : String = stmt.column(index=8)
      let coalesced : Int64 = stmt.column(index=9)
      let depth : Int64 = stmt.column(index=10)
      let created_at : String = stmt.column(index=11)
      out.push(
        @contracts.TriggerFire::new(
          id~,
          trigger_id~,
          source~,
          fire_key~,
          event_id~,
          scheduled_for_ms~,
          key_id~,
          task_id~,
          run_id~,
          coalesced=coalesced != 0L,
          depth=depth.to_int(),
          created_at~,
        ),
      )
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

///|
pub fn MachineStore::trigger_event_cursor(
  self : MachineStore,
) -> Result[Int64?, String] {
  try {
    match read_meta_raw(self.conn, "trigger.event_cursor") {
      Some(text) => {
        let parsed = @string.parse_int64(text) catch { _ => 0L }
        Ok(Some(parsed))
      }
      None => Ok(None)
    }
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::set_trigger_event_cursor(
  self : MachineStore,
  cursor : Int64,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO meta(key,value) VALUES('trigger.event_cursor',?1) " +
      "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    )
    stmt.bind(index=1, cursor.to_string())
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Projection replay
// ---------------------------------------------------------------------------

///|
/// Rebuild the `triggers` projection from `events`. `trigger_fires` is left
/// untouched: it is the dedupe authority and must survive restarts. The
/// `dedupe_hits` diagnostic counter is carried over from the old projection
/// because individual dedupe drops are intentionally not evented.
pub fn MachineStore::reconcile_trigger_projection(
  self : MachineStore,
) -> Result[Int, String] {
  try {
    let previous : Map[String, Int] = Map([])
    let existing = self.conn.prepare("SELECT id, dedupe_hits FROM triggers")
    while existing.step() {
      let id : String = existing.column(index=0)
      let hits : Int64 = existing.column(index=1)
      previous.set(id, hits.to_int())
    }
    existing.finalize()
    let events = self.conn.prepare(
      "SELECT payload_json FROM events " +
      "WHERE type LIKE 'trigger.%' AND type <> 'trigger.rejected' " +
      "ORDER BY seq ASC",
    )
    let records : Array[@contracts.TriggerRecord] = []
    let index_by_id : Map[String, Int] = Map([])
    while events.step() {
      let payload_text : String = events.column(index=0)
      let payload = @json.parse(payload_text) catch {
        _ => @json.Json::empty_object()
      }
      let record_json = match @contracts.as_object(payload) {
        Some(object) => object.get("record")
        None => None
      }
      match record_json {
        Some(value) =>
          match @contracts.trigger_record_from_json(value) {
            Some(record) => {
              match index_by_id.get(record.id) {
                Some(index) => records[index] = record
                None => {
                  index_by_id.set(record.id, records.length())
                  records.push(record)
                }
              }
            }
            None => ()
          }
        None => ()
      }
    }
    events.finalize()
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    exec_raise(self.conn, "DELETE FROM triggers")
    for record in records {
      let hits = match previous.get(record.id) {
        Some(value) => value
        None => record.dedupe_hits
      }
      trigger_put_raw(self.conn, { ..record, dedupe_hits: hits })
    }
    exec_raise(self.conn, "COMMIT")
    Ok(records.length())
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}
