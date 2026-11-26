///|
/// Trigger persistence (ADR-0014, A3.0 events; A3.1 schedule and webhook).
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
/// A3.1 adds the schedule CAS claim, the bounded due scan and the webhook
/// exactly-once transaction (`webhook_keys` + `webhook_nonces`). The ledger
/// rules above apply unchanged: every fire still inserts one Task and one
/// `trigger.fired` in the same transaction as its fire-key row.

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
    "run_intent INTEGER NOT NULL DEFAULT 0, " +
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
  // Webhook key metadata and nonce replay ledger (ADR-0014 §4.3–§4.4). Key
  // secrets live only under the state dir; these rows store the relative
  // secret path and never the secret itself.
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
  // A3.1 additions. The base tables above stay A3.0-compatible; each ALTER is
  // a no-op error once the column exists, which is safe to swallow.
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE triggers ADD COLUMN resolved_tz TEXT NOT NULL DEFAULT ''",
    )
  } catch {
    _ => ()
  }
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE triggers ADD COLUMN anchor_ms INTEGER NOT NULL DEFAULT 0",
    )
  } catch {
    _ => ()
  }
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE triggers ADD COLUMN next_fire_ms INTEGER NOT NULL DEFAULT 0",
    )
  } catch {
    _ => ()
  }
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS triggers_due_idx ON triggers(next_fire_ms)",
  )
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE webhook_keys ADD COLUMN last_used_at TEXT NOT NULL DEFAULT ''",
    )
  } catch {
    _ => ()
  }
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE webhook_keys ADD COLUMN expires_at TEXT NOT NULL DEFAULT ''",
    )
  } catch {
    _ => ()
  }
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE webhook_nonces ADD COLUMN task_id TEXT NOT NULL DEFAULT ''",
    )
  } catch {
    _ => ()
  }
  // A3.2: a fire records whether its Task was created with `start_run=true`.
  // Rows migrated from A3.1 default to no-run so flipping a trigger to
  // `start_run=true` cannot start Runs for historical Tasks. A fire already
  // linked to a Run keeps its intent.
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE trigger_fires ADD COLUMN " +
      "run_intent INTEGER NOT NULL DEFAULT 0",
    )
  } catch {
    _ => ()
  }
  exec_raise(
    conn,
    "UPDATE trigger_fires SET run_intent=1 WHERE run_id != ''",
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
  let next_fire_ms = match @contracts.trigger_parse_rfc3339_ms(
    record.next_fire_at,
  ) {
    Some(value) => value
    None => 0L
  }
  let stmt = conn.prepare(
    "INSERT INTO triggers (" +
    "id,org_id,name,type,enabled,expires_at,expires_ms,target_json," +
    "source_json,config_hash,created_by,version,record_json,expired_at," +
    "active_from_seq,next_fire_at,last_fired_at,dedupe_hits," +
    "created_at,updated_at,resolved_tz,anchor_ms,next_fire_ms" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) " +
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
    "updated_at=excluded.updated_at,resolved_tz=excluded.resolved_tz," +
    "anchor_ms=excluded.anchor_ms,next_fire_ms=excluded.next_fire_ms",
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
  stmt.bind(index=21, record.resolved_tz)
  stmt.bind(index=22, record.anchor_ms)
  stmt.bind(index=23, next_fire_ms)
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
    "task_id,run_id,run_intent,coalesced,depth,created_at" +
    ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) " +
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
  stmt.bind(index=10, if fire.run_intent { 1L } else { 0L })
  stmt.bind(index=11, if fire.coalesced { 1L } else { 0L })
  stmt.bind(index=12, fire.depth.to_int64())
  stmt.bind(index=13, fire.created_at)
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
      "key_id,task_id,run_id,run_intent,coalesced,depth,created_at " +
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
      let run_intent_flag : Int64 = stmt.column(index=9)
      let coalesced : Int64 = stmt.column(index=10)
      let depth : Int64 = stmt.column(index=11)
      let created_at : String = stmt.column(index=12)
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
        run_intent=run_intent_flag != 0L,
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
      "key_id,task_id,run_id,run_intent,coalesced,depth,created_at " +
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
      let run_intent_flag : Int64 = stmt.column(index=9)
      let coalesced : Int64 = stmt.column(index=10)
      let depth : Int64 = stmt.column(index=11)
      let created_at : String = stmt.column(index=12)
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
          run_intent=run_intent_flag != 0L,
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

///|
/// Link the Run created for a fire back into the dedupe/audit ledger. The
/// Task transaction and `run.create` are separate commits (ADR-0014 §5), so
/// this write closes the link after the Run is durable. A repeated call is a
/// no-op: the first non-empty `run_id` wins.
pub fn MachineStore::set_trigger_fire_run_id(
  self : MachineStore,
  trigger_id : String,
  fire_key : String,
  run_id : String,
) -> Result[Bool, String] {
  if run_id == "" {
    return Ok(false)
  }
  try {
    let stmt = self.conn.prepare(
      "UPDATE trigger_fires SET run_id=?3 " +
      "WHERE trigger_id=?1 AND fire_key=?2 AND run_id='' AND run_intent=1",
    )
    stmt.bind(index=1, trigger_id)
    stmt.bind(index=2, fire_key)
    stmt.bind(index=3, run_id)
    let _ = stmt.step()
    let changed = (self.conn.changes() > 0L)
    stmt.finalize()
    Ok(changed)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Fires whose Task was committed but whose Run was not (crash between the
/// Task transaction and `run.create`). Oldest first, bounded. The caller
/// re-invokes `run.create` with the same idempotency key, so a retry either
/// creates the Run once or observes the already-created one (ADR-0014 §5).
pub fn MachineStore::get_trigger_fires_missing_run(
  self : MachineStore,
  trigger_id : String,
  limit : Int,
) -> Result[Array[@contracts.TriggerFire], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT id,trigger_id,source,fire_key,event_id,scheduled_for_ms," +
      "key_id,task_id,run_id,run_intent,coalesced,depth,created_at " +
      "FROM trigger_fires WHERE trigger_id=?1 AND run_id='' " +
      "AND run_intent=1 " +
      "ORDER BY created_at ASC, id ASC LIMIT ?2",
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
      let run_intent_flag : Int64 = stmt.column(index=9)
      let coalesced : Int64 = stmt.column(index=10)
      let depth : Int64 = stmt.column(index=11)
      let created_at : String = stmt.column(index=12)
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
          run_intent=run_intent_flag != 0L,
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
      "WHERE type LIKE 'trigger.%' ORDER BY seq ASC",
    )
    let records : Array[@contracts.TriggerRecord] = []
    let index_by_id : Map[String, Int] = Map([])
    // A3.1 internal advances (`missed_window`, `clock_skew`) have no
    // `trigger.fired` record, so they persist `next_fire_at` on the rejection
    // event instead. Replay applies those patches after all records.
    let patches : Array[(String, String)] = []
    while events.step() {
      let payload_text : String = events.column(index=0)
      let payload = @json.parse(payload_text) catch {
        _ => @json.Json::empty_object()
      }
      let object = match @contracts.as_object(payload) {
        Some(value) => value
        None => continue
      }
      let record_json = object.get("record")
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
      let patch_id = @contracts.string_field_or(object, "trigger_id", "")
      let patch_next = @contracts.string_field_or(object, "next_fire_at", "")
      if patch_id != "" && patch_next != "" {
        patches.push((patch_id, patch_next))
      }
    }
    events.finalize()
    for patch in patches {
      let (id, next_fire_at) = patch
      match index_by_id.get(id) {
        Some(index) => {
          let record = records[index]
          records[index] = { ..record, next_fire_at }
        }
        None => ()
      }
    }
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

// ---------------------------------------------------------------------------
// A3.1: schedule claim, due scan and webhook transactions
// ---------------------------------------------------------------------------

///|
/// Outcome of the webhook exactly-once transaction. `Duplicate` carries the
/// Task id of the earlier delivery so the host can answer 202 without
/// creating anything.
pub(all) enum WebhookFireOutcome {
  WebhookFireApplied
  WebhookFireDuplicate(task_id~ : String)
  WebhookFireNonceReuse
  WebhookFireDisabled
  WebhookFireExpired
  WebhookFireNotFound
  WebhookFireKeyInactive
}

///|
/// Due schedules, oldest slot first. `next_fire_ms` is the slot's UTC
/// millisecond value (not the jittered execution time), so the host still
/// applies `schedule_is_due` per row. Bounded by `limit` so one tick cannot
/// starve the rest of the host.
pub fn MachineStore::list_due_schedules(
  self : MachineStore,
  now_ms : Int64,
  limit : Int,
) -> Result[Array[@contracts.TriggerRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json, dedupe_hits FROM triggers " +
      "WHERE type=?1 AND enabled=1 AND next_fire_ms > 0 AND next_fire_ms <= ?2 " +
      "AND (expires_ms=0 OR expires_ms > ?2) " +
      "ORDER BY next_fire_ms, id LIMIT ?3",
    )
    stmt.bind(index=1, @contracts.TRIGGER_TYPE_SCHEDULE)
    stmt.bind(index=2, now_ms)
    stmt.bind(index=3, limit.max(1).min(1_000).to_int64())
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
/// Exactly-once schedule claim (ADR-0014 §3.3): CAS `next_fire_at` from the
/// caller's expected value, then insert the slot fire row, Task events and
/// `trigger.fired` in the same transaction. A lost CAS returns
/// `TriggerVersionConflict` and writes nothing.
pub fn MachineStore::record_trigger_schedule_event(
  self : MachineStore,
  task_events : Array[@contracts.EventEnvelope],
  fired_event : @contracts.EventEnvelope,
  task : @contracts.TaskRecord,
  fire : @contracts.TriggerFire,
  record_after : @contracts.TriggerRecord,
  expected_next_fire_at : String,
  new_next_fire_at : String,
  now_ms : Int64,
) -> Result[@contracts.TriggerWriteOutcome, String] {
  let new_next_fire_ms = match @contracts.trigger_parse_rfc3339_ms(
    new_next_fire_at,
  ) {
    Some(value) => value
    None => 0L
  }
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let check = self.conn.prepare(
      "SELECT enabled, expires_ms, next_fire_at, record_json FROM triggers WHERE id=?1",
    )
    check.bind(index=1, fire.trigger_id)
    let mut found = false
    let mut enabled = false
    let mut expires_ms = 0L
    let mut stored_next = ""
    let mut stored_json = ""
    if check.step() {
      found = true
      let enabled_col : Int64 = check.column(index=0)
      enabled = enabled_col != 0L
      let expires_col : Int64 = check.column(index=1)
      expires_ms = expires_col
      stored_next = check.column(index=2)
      stored_json = check.column(index=3)
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
    // A caller's snapshot may predate previous duplicate drops. Keep the
    // projection's dedupe counter authoritative when writing its successor.
    let record_stored = {
      ..record_after,
      dedupe_hits: trigger_dedupe_hits_raw(self.conn, fire.trigger_id),
    }
    if stored_next != expected_next_fire_at {
      // Another tick advanced the slot before us; it owns this fire.
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerVersionConflict)
    }
    let cas = self.conn.prepare(
      "UPDATE triggers SET next_fire_at=?2, next_fire_ms=?3, " +
      "record_json=?4, updated_at=?5 WHERE id=?1 AND next_fire_at=?6",
    )
    cas.bind(index=1, fire.trigger_id)
    cas.bind(index=2, new_next_fire_at)
    cas.bind(index=3, new_next_fire_ms)
    cas.bind(index=4, record_stored.to_json().stringify())
    cas.bind(index=5, record_stored.updated_at)
    cas.bind(index=6, expected_next_fire_at)
    let _ = cas.step()
    let changed = (self.conn.changes() > 0L)
    cas.finalize()
    if !changed {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(@contracts.TriggerVersionConflict)
    }
    trigger_fire_put_raw(self.conn, fire)
    let inserted = (self.conn.changes() > 0L)
    if !inserted {
      // Defensive: the slot was already fenced by an earlier claim. Keep the
      // advanced projection (so the slot is not rescanned) and count the hit.
      let stored = @json.parse(stored_json) catch {
        _ => @json.Json::empty_object()
      }
      match @contracts.trigger_record_from_json(stored) {
        Some(record) => {
          let patched = { ..record, next_fire_at: new_next_fire_at }
          trigger_put_raw(self.conn, patched)
        }
        None => ()
      }
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
    trigger_put_raw(self.conn, record_stored)
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
/// Refresh the projection row only. Used when a schedule has no persisted
/// `next_fire_at` yet (for example a record written before A3.1); there is no
/// lifecycle transition to event, so this is projection-only.
pub fn MachineStore::refresh_trigger_projection(
  self : MachineStore,
  record : @contracts.TriggerRecord,
) -> Result[Unit, String] {
  try {
    trigger_put_raw(self.conn, record)
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Advance a schedule slot without creating a Task (`missed_window` skip,
/// `clock_skew`, rate limit or invalid target). The CAS and the rejection
/// event are one transaction so the persisted `next_fire_at` cannot be lost
/// on restart.
pub fn MachineStore::record_trigger_schedule_reject_event(
  self : MachineStore,
  rejected_event : @contracts.EventEnvelope,
  record_after : @contracts.TriggerRecord,
  expected_next_fire_at : String,
  new_next_fire_at : String,
) -> Result[Bool, String] {
  let new_next_fire_ms = match @contracts.trigger_parse_rfc3339_ms(
    new_next_fire_at,
  ) {
    Some(value) => value
    None => 0L
  }
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    let check = self.conn.prepare(
      "SELECT next_fire_at FROM triggers WHERE id=?1",
    )
    check.bind(index=1, record_after.id)
    let mut found = false
    let mut stored_next = ""
    if check.step() {
      found = true
      stored_next = check.column(index=0)
    }
    check.finalize()
    if !found || stored_next != expected_next_fire_at {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(false)
    }
    let record_stored = {
      ..record_after,
      dedupe_hits: trigger_dedupe_hits_raw(self.conn, record_after.id),
    }
    let cas = self.conn.prepare(
      "UPDATE triggers SET next_fire_at=?2, next_fire_ms=?3, " +
      "record_json=?4, updated_at=?5 WHERE id=?1 AND next_fire_at=?6",
    )
    cas.bind(index=1, record_after.id)
    cas.bind(index=2, new_next_fire_at)
    cas.bind(index=3, new_next_fire_ms)
    cas.bind(index=4, record_stored.to_json().stringify())
    cas.bind(index=5, record_stored.updated_at)
    cas.bind(index=6, expected_next_fire_at)
    let _ = cas.step()
    let changed = (self.conn.changes() > 0L)
    cas.finalize()
    if !changed {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(false)
    }
    insert_event_raw(self.conn, rejected_event)
    bump_last_seq_raw(self.conn, rejected_event.seq)
    exec_raise(self.conn, "COMMIT")
    Ok(true)
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
/// Exactly-once webhook commit (ADR-0014 §4.4). The nonce row and the fire row
/// are written in the same transaction:
/// - same nonce + same body hash → `Duplicate` with the earlier Task id;
/// - same nonce + different hash → `NonceReuse`, nothing written;
/// - delivery-id fire key already present → `Duplicate` with its Task id.
pub fn MachineStore::record_trigger_webhook_event(
  self : MachineStore,
  task_events : Array[@contracts.EventEnvelope],
  fired_event : @contracts.EventEnvelope,
  task : @contracts.TaskRecord,
  fire : @contracts.TriggerFire,
  record_after : @contracts.TriggerRecord,
  key_id : String,
  nonce : String,
  body_sha256 : String,
  nonce_expires_ms : Int64,
  now_ms : Int64,
  first_seen_ms : Int64,
) -> Result[WebhookFireOutcome, String] {
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
      return Ok(WebhookFireNotFound)
    }
    let key_check = self.conn.prepare(
      "SELECT enabled, revoked_at, expires_at FROM webhook_keys " +
      "WHERE key_id=?1 AND trigger_id=?2",
    )
    key_check.bind(index=1, key_id)
    key_check.bind(index=2, fire.trigger_id)
    let mut key_found = false
    let mut key_enabled = false
    let mut key_revoked = ""
    let mut key_expires = ""
    if key_check.step() {
      key_found = true
      let enabled_col : Int64 = key_check.column(index=0)
      key_enabled = enabled_col != 0L
      key_revoked = key_check.column(index=1)
      key_expires = key_check.column(index=2)
    }
    key_check.finalize()
    let key_expired = match @contracts.trigger_parse_rfc3339_ms(key_expires) {
      Some(value) => value <= now_ms
      None => key_expires != ""
    }
    if !key_found || !key_enabled || key_revoked != "" || key_expired {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(WebhookFireKeyInactive)
    }
    if !enabled {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(WebhookFireDisabled)
    }
    if expires_ms > 0L && expires_ms <= now_ms {
      exec_raise(self.conn, "ROLLBACK")
      return Ok(WebhookFireExpired)
    }
    // Preserve duplicate-drop accounting across a later successful delivery.
    let record_stored = {
      ..record_after,
      dedupe_hits: trigger_dedupe_hits_raw(self.conn, fire.trigger_id),
    }
    let nonce_stmt = self.conn.prepare(
      "SELECT body_sha256, task_id, expires_at_ms FROM webhook_nonces " +
      "WHERE key_id=?1 AND nonce=?2",
    )
    nonce_stmt.bind(index=1, key_id)
    nonce_stmt.bind(index=2, nonce)
    let mut nonce_found = false
    let mut stored_hash = ""
    let mut stored_task_id = ""
    let mut stored_expires = 0L
    if nonce_stmt.step() {
      nonce_found = true
      stored_hash = nonce_stmt.column(index=0)
      stored_task_id = nonce_stmt.column(index=1)
      stored_expires = nonce_stmt.column(index=2)
    }
    nonce_stmt.finalize()
    if nonce_found && stored_expires > now_ms {
      if stored_hash != body_sha256 {
        exec_raise(self.conn, "ROLLBACK")
        return Ok(WebhookFireNonceReuse)
      }
      trigger_bump_dedupe_raw(self.conn, fire.trigger_id)
      exec_raise(self.conn, "COMMIT")
      return Ok(WebhookFireDuplicate(task_id=stored_task_id))
    }
    if nonce_found {
      // Expired nonce row: prune it and proceed as a fresh delivery.
      let del = self.conn.prepare(
        "DELETE FROM webhook_nonces WHERE key_id=?1 AND nonce=?2",
      )
      del.bind(index=1, key_id)
      del.bind(index=2, nonce)
      let _ = del.step()
      del.finalize()
    }
    let insert_nonce = self.conn.prepare(
      "INSERT INTO webhook_nonces " +
      "(key_id,nonce,body_sha256,first_seen_ms,expires_at_ms,task_id) " +
      "VALUES (?1,?2,?3,?4,?5,'') " +
      "ON CONFLICT(key_id,nonce) DO NOTHING",
    )
    insert_nonce.bind(index=1, key_id)
    insert_nonce.bind(index=2, nonce)
    insert_nonce.bind(index=3, body_sha256)
    insert_nonce.bind(index=4, first_seen_ms)
    insert_nonce.bind(index=5, nonce_expires_ms)
    let _ = insert_nonce.step()
    let nonce_inserted = (self.conn.changes() > 0L)
    insert_nonce.finalize()
    if !nonce_inserted {
      // A concurrent writer with the same (key_id, nonce) slipped in between
      // our BEGIN and the insert; re-read it and apply the same hash rule.
      let raced = self.conn.prepare(
        "SELECT body_sha256, task_id FROM webhook_nonces " +
        "WHERE key_id=?1 AND nonce=?2",
      )
      raced.bind(index=1, key_id)
      raced.bind(index=2, nonce)
      let mut raced_hash = ""
      let mut raced_task_id = ""
      if raced.step() {
        raced_hash = raced.column(index=0)
        raced_task_id = raced.column(index=1)
      }
      raced.finalize()
      exec_raise(self.conn, "ROLLBACK")
      if raced_hash == body_sha256 {
        return Ok(WebhookFireDuplicate(task_id=raced_task_id))
      }
      return Ok(WebhookFireNonceReuse)
    }
    trigger_fire_put_raw(self.conn, fire)
    let inserted = (self.conn.changes() > 0L)
    if !inserted {
      let existing = self.conn.prepare(
        "SELECT task_id FROM trigger_fires WHERE trigger_id=?1 AND fire_key=?2",
      )
      existing.bind(index=1, fire.trigger_id)
      existing.bind(index=2, fire.fire_key)
      let mut existing_task_id = ""
      if existing.step() {
        existing_task_id = existing.column(index=0)
      }
      existing.finalize()
      let update = self.conn.prepare(
        "UPDATE webhook_nonces SET task_id=?3 WHERE key_id=?1 AND nonce=?2",
      )
      update.bind(index=1, key_id)
      update.bind(index=2, nonce)
      update.bind(index=3, existing_task_id)
      let _ = update.step()
      update.finalize()
      trigger_bump_dedupe_raw(self.conn, fire.trigger_id)
      exec_raise(self.conn, "COMMIT")
      return Ok(WebhookFireDuplicate(task_id=existing_task_id))
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
    trigger_put_raw(self.conn, record_stored)
    let link = self.conn.prepare(
      "UPDATE webhook_nonces SET task_id=?3 WHERE key_id=?1 AND nonce=?2",
    )
    link.bind(index=1, key_id)
    link.bind(index=2, nonce)
    link.bind(index=3, task.id)
    let _ = link.step()
    link.finalize()
    exec_raise(self.conn, "COMMIT")
    Ok(WebhookFireApplied)
  } catch {
    error => {
      let _ = try { exec_raise(self.conn, "ROLLBACK") } catch { _ => () }
      Err(sqlite_text(error))
    }
  }
}

///|
/// Persist `meta.trigger.last_tick_ms` for rollback detection (§3.4).
pub fn MachineStore::trigger_last_tick_ms(
  self : MachineStore,
) -> Result[Int64?, String] {
  try {
    match read_meta_raw(self.conn, "trigger.last_tick_ms") {
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
pub fn MachineStore::set_trigger_last_tick_ms(
  self : MachineStore,
  tick_ms : Int64,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO meta(key,value) VALUES('trigger.last_tick_ms',?1) " +
      "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    )
    stmt.bind(index=1, tick_ms.to_string())
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Prune expired nonce rows. Called from the schedule loop; the TTL already
/// includes the freshness window plus 120 seconds.
pub fn MachineStore::prune_webhook_nonces(
  self : MachineStore,
  now_ms : Int64,
) -> Result[Int, String] {
  try {
    let stmt = self.conn.prepare(
      "DELETE FROM webhook_nonces WHERE expires_at_ms <= ?1",
    )
    stmt.bind(index=1, now_ms)
    let _ = stmt.step()
    let removed = self.conn.changes()
    stmt.finalize()
    Ok(removed.to_int())
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Webhook keys
// ---------------------------------------------------------------------------

///|
pub fn MachineStore::put_webhook_key(
  self : MachineStore,
  record : @contracts.WebhookKeyRecord,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "INSERT INTO webhook_keys (" +
      "key_id,trigger_id,org_id,name,secret_path,enabled,created_at," +
      "revoked_at,last_used_at,expires_at" +
      ") VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " +
      "ON CONFLICT(key_id) DO UPDATE SET " +
      "trigger_id=excluded.trigger_id,org_id=excluded.org_id," +
      "name=excluded.name,secret_path=excluded.secret_path," +
      "enabled=excluded.enabled,created_at=excluded.created_at," +
      "revoked_at=excluded.revoked_at,last_used_at=excluded.last_used_at," +
      "expires_at=excluded.expires_at",
    )
    stmt.bind(index=1, record.key_id)
    stmt.bind(index=2, record.trigger_id)
    stmt.bind(index=3, record.org_id)
    stmt.bind(index=4, record.name)
    stmt.bind(index=5, record.secret_path)
    stmt.bind(index=6, if record.enabled { 1L } else { 0L })
    stmt.bind(index=7, record.created_at)
    stmt.bind(index=8, record.revoked_at)
    stmt.bind(index=9, record.last_used_at)
    stmt.bind(index=10, record.expires_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
fn webhook_key_from_row(stmt : @sqlite3.Statement) -> @contracts.WebhookKeyRecord raise @sqlite3.SqliteError {
  let key_id : String = stmt.column(index=0)
  let trigger_id : String = stmt.column(index=1)
  let org_id : String = stmt.column(index=2)
  let name : String = stmt.column(index=3)
  let secret_path : String = stmt.column(index=4)
  let enabled : Int64 = stmt.column(index=5)
  let created_at : String = stmt.column(index=6)
  let revoked_at : String = stmt.column(index=7)
  let last_used_at : String = stmt.column(index=8)
  let expires_at : String = stmt.column(index=9)
  @contracts.WebhookKeyRecord::new(
    key_id~,
    trigger_id~,
    org_id~,
    name~,
    secret_path~,
    enabled=enabled != 0L,
    created_at~,
    revoked_at~,
    last_used_at~,
    expires_at~,
  )
}

///|
pub fn MachineStore::get_webhook_key(
  self : MachineStore,
  key_id : String,
) -> Result[@contracts.WebhookKeyRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT key_id,trigger_id,org_id,name,secret_path,enabled,created_at," +
      "revoked_at,last_used_at,expires_at FROM webhook_keys WHERE key_id=?1",
    )
    stmt.bind(index=1, key_id)
    let mut found : @contracts.WebhookKeyRecord? = None
    if stmt.step() {
      found = Some(webhook_key_from_row(stmt))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_webhook_keys(
  self : MachineStore,
  trigger_id : String,
) -> Result[Array[@contracts.WebhookKeyRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT key_id,trigger_id,org_id,name,secret_path,enabled,created_at," +
      "revoked_at,last_used_at,expires_at FROM webhook_keys " +
      "WHERE trigger_id=?1 ORDER BY created_at, key_id",
    )
    stmt.bind(index=1, trigger_id)
    let out : Array[@contracts.WebhookKeyRecord] = []
    while stmt.step() {
      out.push(webhook_key_from_row(stmt))
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::revoke_webhook_key(
  self : MachineStore,
  key_id : String,
  revoked_at : String,
) -> Result[Bool, String] {
  try {
    let stmt = self.conn.prepare(
      "UPDATE webhook_keys SET revoked_at=?2, enabled=0 " +
      "WHERE key_id=?1 AND revoked_at=''",
    )
    stmt.bind(index=1, key_id)
    stmt.bind(index=2, revoked_at)
    let _ = stmt.step()
    let changed = (self.conn.changes() > 0L)
    stmt.finalize()
    Ok(changed)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::touch_webhook_key(
  self : MachineStore,
  key_id : String,
  last_used_at : String,
) -> Result[Unit, String] {
  try {
    let stmt = self.conn.prepare(
      "UPDATE webhook_keys SET last_used_at=?2 WHERE key_id=?1",
    )
    stmt.bind(index=1, key_id)
    stmt.bind(index=2, last_used_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}
