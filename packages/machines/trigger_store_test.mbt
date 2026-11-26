///|
/// A3.0 trigger store tests: lifecycle writes, optimistic concurrency, the
/// exactly-once fire transaction, replay across a reopened database, expiry
/// and migration from a pre-A3 file.

///|
fn trigger_test_store() -> MachineStore raise {
  match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
}

///|
fn trigger_test_envelope(
  seq : Int64,
  event_type : String,
  subject : String,
  payload : @json.Json,
  idempotency_key : String,
) -> @contracts.EventEnvelope {
  @contracts.EventEnvelope::new(
    id="evt-" + seq.to_string(),
    org_id=@contracts.ORG_LOCAL,
    event_type~,
    ts="2026-01-01T00:00:00.000Z",
    subject~,
    seq~,
    payload~,
    idempotency_key~,
  )
}

///|
fn trigger_test_record(
  id : String,
  name : String,
  expires_at : String,
) -> @contracts.TriggerRecord {
  let target = @contracts.TriggerTarget::new(
    title_template="Notify {{payload}}",
    goal_template="created from trigger",
  )
  let source = @contracts.TriggerSource::new(
    event_type="task.created",
    payload_fields=["payload"],
  )
  @contracts.TriggerRecord::new(
    id~,
    org_id=@contracts.ORG_LOCAL,
    name~,
    kind=@contracts.TRIGGER_TYPE_EVENT,
    target~,
    source~,
    config_hash=@contracts.trigger_config_hash(
      name,
      @contracts.TRIGGER_TYPE_EVENT,
      true,
      expires_at,
      target,
      source,
    ),
    created_by="owner",
    created_at="2026-01-01T00:00:00.000Z",
    active_from_seq=0L,
    expires_at~,
  )
}

///|
fn trigger_test_create(
  store : MachineStore,
  record : @contracts.TriggerRecord,
  seq : Int64,
) -> Unit raise {
  let event = trigger_test_envelope(
    seq,
    @contracts.EVENT_TRIGGER_CREATED,
    "trigger/" + record.id,
    @contracts.trigger_created_payload(record),
    "trigger/" + record.id + "/created",
  )
  match store.record_trigger_event(event, record) {
    Ok(_) => ()
    Err(message) => fail("cannot record trigger.create: " + message)
  }
}

///|
fn trigger_test_task(
  record : @contracts.TriggerRecord,
  fire_key : String,
  task_id : String,
) -> @contracts.TaskRecord {
  let origin = @contracts.TriggerOrigin::new(
    trigger_id=record.id,
    fire_key~,
    root_trigger_id=record.id,
    depth=1,
    source=@contracts.TRIGGER_SOURCE_EVENT,
  )
  @contracts.TaskRecord::new(
    id=task_id,
    title="Notify event",
    goal="created from trigger",
    parent_id="",
    project_id="",
    agent_id="",
    workspace_id="",
    verify=[],
    created_at="2026-01-01T00:00:00.000Z",
    status=@contracts.TASK_STATUS_PLANNED,
    origin=Some(origin),
  )
}

///|
fn trigger_test_fire(
  store : MachineStore,
  record : @contracts.TriggerRecord,
  fire_key : String,
  event_id : String,
  task_id : String,
  seq_base : Int64,
  now_ms : Int64,
  run_intent~ : Bool = true,
) -> @contracts.TriggerWriteOutcome raise {
  let task = trigger_test_task(record, fire_key, task_id)
  let task_event = trigger_test_envelope(
    seq_base,
    @contracts.EVENT_TASK_CREATED,
    task.id,
    task.to_json(),
    @contracts.trigger_task_event_idempotency(record.id, fire_key),
  )
  let fire = @contracts.TriggerFire::new(
    id="trf_" + fire_key,
    trigger_id=record.id,
    source=@contracts.TRIGGER_SOURCE_EVENT,
    fire_key~,
    event_id~,
    task_id=task.id,
    run_intent~,
    created_at="2026-01-01T00:00:00.000Z",
  )
  let record_after = { ..record, last_fired_at: "2026-01-01T00:00:00.000Z" }
  let fired_event = trigger_test_envelope(
    seq_base + 1L,
    @contracts.EVENT_TRIGGER_FIRED,
    "trigger/" + record.id,
    @contracts.trigger_fired_payload(fire, record_after),
    "trigger/" + record.id + "/" + fire_key + "/fired",
  )
  match store.record_trigger_task_event(
    [task_event],
    fired_event,
    task,
    fire,
    record_after,
    now_ms,
  ) {
    Ok(outcome) => outcome
    Err(message) => fail("cannot record trigger fire: " + message)
  }
}

///|
fn trigger_test_count_events(store : MachineStore, event_type : String) -> Int raise {
  let events = match store.load_events_since(0L, 2000) {
    Ok(value) => value
    Err(message) => fail("cannot load events: " + message)
  }
  let mut count = 0
  for event in events {
    if event.event_type == event_type {
      count = count + 1
    }
  }
  count
}

///|
test "trigger lifecycle: create, list, update, version conflict, disable" {
  let store = trigger_test_store()
  let record = trigger_test_record("trg_1", "demo", "")
  trigger_test_create(store, record, 1L)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_CREATED), 1)
  let loaded = match store.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger was not persisted")
  }
  assert_eq(loaded.name, "demo")
  assert_eq(loaded.version, 1)
  assert_eq(loaded.kind, @contracts.TRIGGER_TYPE_EVENT)
  let listed = match store.list_triggers() {
    Ok(value) => value
    _ => fail("cannot list triggers")
  }
  assert_eq(listed.length(), 1)

  // Update with the wrong expected version must not write an event or a row.
  let updated = {
    ..loaded,
    name: "demo2",
    version: 2,
    updated_at: "2026-01-02T00:00:00.000Z",
  }
  let update_event = trigger_test_envelope(
    2L,
    @contracts.EVENT_TRIGGER_UPDATED,
    "trigger/trg_1",
    @contracts.trigger_updated_payload(updated, ["name"], "owner"),
    "trigger/trg_1/updated/2",
  )
  let conflict = match store.record_trigger_update_event(update_event, updated, 99) {
    Ok(value) => value
    Err(message) => fail("update failed: " + message)
  }
  assert_eq(conflict, @contracts.TriggerVersionConflict)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_UPDATED), 0)
  let still = match store.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger disappeared")
  }
  assert_eq(still.name, "demo")
  assert_eq(still.version, 1)

  let applied = match store.record_trigger_update_event(update_event, updated, 1) {
    Ok(value) => value
    Err(message) => fail("update failed: " + message)
  }
  assert_eq(applied, @contracts.TriggerApplied)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_UPDATED), 1)

  let disabled = { ..updated, enabled: false, version: 3 }
  let disable_event = trigger_test_envelope(
    3L,
    @contracts.EVENT_TRIGGER_DISABLED,
    "trigger/trg_1",
    @contracts.trigger_disabled_payload(disabled, "owner", "test"),
    "trigger/trg_1/disabled/3",
  )
  match store.record_trigger_event(disable_event, disabled) {
    Ok(_) => ()
    Err(message) => fail("disable failed: " + message)
  }
  let off = match store.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger disappeared")
  }
  assert_eq(off.enabled, false)
  assert_eq(off.version, 3)
}

///|
test "duplicate fire creates exactly one Task and one fired event" {
  let store = trigger_test_store()
  let record = trigger_test_record("trg_1", "once", "")
  trigger_test_create(store, record, 1L)
  let first = trigger_test_fire(
    store,
    record,
    "event:evt_a",
    "evt_a",
    "tsk_1",
    10L,
    1_700_000_000_000L,
  )
  assert_eq(first, @contracts.TriggerApplied)
  // A redelivered event (same fire key, new Task id allocated by the caller)
  // must be dropped: no second Task and no second trigger.fired event.
  let second = trigger_test_fire(
    store,
    record,
    "event:evt_a",
    "evt_a",
    "tsk_2",
    20L,
    1_700_000_000_001L,
  )
  assert_eq(second, @contracts.TriggerDuplicate)
  let tasks = match store.list_tasks("", "") {
    Ok(value) => value
    _ => fail("cannot list tasks")
  }
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].id, "tsk_1")
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TASK_CREATED), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
  // The dropped delivery is counted, never logged per drop.
  let updated = match store.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger disappeared")
  }
  assert_eq(updated.dedupe_hits, 1)
  // The ledger lookup returns the original Task for an idempotent retry.
  let ledger = match store.get_trigger_fire_row("trg_1", "event:evt_a") {
    Ok(value) => value
    _ => fail("cannot read fire ledger")
  }
  assert_eq(ledger.id != "", true)
  assert_eq(ledger.task_id, "tsk_1")
}

///|
test "fire re-checks disabled in the transaction and writes nothing" {
  let store = trigger_test_store()
  let record = trigger_test_record("trg_1", "stopped", "")
  trigger_test_create(store, record, 1L)
  let disabled = { ..record, enabled: false, version: 2 }
  let event = trigger_test_envelope(
    2L,
    @contracts.EVENT_TRIGGER_DISABLED,
    "trigger/trg_1",
    @contracts.trigger_disabled_payload(disabled, "owner", "test"),
    "trigger/trg_1/disabled/2",
  )
  match store.record_trigger_event(event, disabled) {
    Ok(_) => ()
    Err(message) => fail("disable failed: " + message)
  }
  let outcome = trigger_test_fire(
    store,
    disabled,
    "event:evt_b",
    "evt_b",
    "tsk_blocked",
    10L,
    1_700_000_000_000L,
  )
  assert_eq(outcome, @contracts.TriggerDisabled)
  let tasks = match store.list_tasks("", "") {
    Ok(value) => value
    _ => fail("cannot list tasks")
  }
  assert_eq(tasks.length(), 0)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 0)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TASK_CREATED), 0)
}

///|
test "expiry fires once and blocks new Tasks" {
  let store = trigger_test_store()
  let record = trigger_test_record(
    "trg_1",
    "expiring",
    "2023-11-14T22:13:20.123Z",
  )
  trigger_test_create(store, record, 1L)
  let expired = {
    ..record,
    expired_at: "2023-11-14T22:13:21.000Z",
    updated_at: "2023-11-14T22:13:21.000Z",
  }
  let event = trigger_test_envelope(
    2L,
    @contracts.EVENT_TRIGGER_EXPIRED,
    "trigger/trg_1",
    @contracts.trigger_expired_payload(expired),
    "trigger/trg_1/expired/2023-11-14T22:13:20.123Z",
  )
  let first = match store.record_trigger_expired_event(event, expired) {
    Ok(value) => value
    Err(message) => fail("expire failed: " + message)
  }
  assert_eq(first, true)
  // A second sweep sees expired_at set and writes no duplicate audit event.
  let second_event = trigger_test_envelope(
    3L,
    @contracts.EVENT_TRIGGER_EXPIRED,
    "trigger/trg_1",
    @contracts.trigger_expired_payload(expired),
    "trigger/trg_1/expired/retry",
  )
  let second = match store.record_trigger_expired_event(second_event, expired) {
    Ok(value) => value
    Err(message) => fail("second expire failed: " + message)
  }
  assert_eq(second, false)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_EXPIRED), 1)

  let after_expiry = match store.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger disappeared")
  }
  let outcome = trigger_test_fire(
    store,
    after_expiry,
    "event:evt_c",
    "evt_c",
    "tsk_expired",
    10L,
    1_700_000_000_123L,
  )
  assert_eq(outcome, @contracts.TriggerExpired)
  let tasks = match store.list_tasks("", "") {
    Ok(value) => value
    _ => fail("cannot list tasks")
  }
  assert_eq(tasks.length(), 0)
}

///|
test "cursor persists and reconcile preserves the trigger and dedupe counter" {
  let store = trigger_test_store()
  let record = trigger_test_record("trg_1", "replay", "")
  trigger_test_create(store, record, 1L)
  let _ = trigger_test_fire(
    store,
    record,
    "event:evt_d",
    "evt_d",
    "tsk_1",
    10L,
    1_700_000_000_000L,
  )
  let _ = trigger_test_fire(
    store,
    record,
    "event:evt_d",
    "evt_d",
    "tsk_dup",
    20L,
    1_700_000_000_001L,
  )
  match store.set_trigger_event_cursor(0L) {
    Ok(_) => ()
    Err(message) => fail("cannot set cursor: " + message)
  }
  let cursor = match store.trigger_event_cursor() {
    Ok(Some(value)) => value
    _ => fail("cursor missing")
  }
  assert_eq(cursor, 0L)
  match store.reconcile_trigger_projection() {
    Ok(_) => ()
    Err(message) => fail("reconcile failed: " + message)
  }
  let reconciled = match store.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger lost in reconcile")
  }
  assert_eq(reconciled.name, "replay")
  // Replay must not resurrect a second Task or reset the dedupe counter.
  assert_eq(reconciled.dedupe_hits, 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TASK_CREATED), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
}

///|
fn trigger_test_sqlite_text(error : Error) -> String {
  error.to_string()
}

///|
fn reset_trigger_db(path : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path) catch {
    error => fail("cannot open test database: " + trigger_test_sqlite_text(error))
  }
  try {
    for table in [
      "search_fts", "search_docs", "webhook_nonces", "webhook_keys",
      "trigger_fires", "triggers", "leases", "decisions", "artifacts",
      "evidence", "runs", "tasks", "projects", "worktrees", "workspaces",
      "agent_sessions", "machines", "events", "meta",
    ] {
      let stmt = conn.prepare("DROP TABLE IF EXISTS " + table)
      let _ = stmt.step()
      stmt.finalize()
    }
  } catch {
    error => {
      conn.close() catch { _ => () }
      fail("cannot reset test database: " + trigger_test_sqlite_text(error))
    }
  }
  conn.close() catch { _ => () }
}

///|
test "a reopened store replays without creating a second Task" {
  let path = "/tmp/monexus-trigger-reopen-test.db"
  reset_trigger_db(path)
  let first_store = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot open file store: " + message)
  }
  let record = trigger_test_record("trg_1", "reopen", "")
  trigger_test_create(first_store, record, 1L)
  let first = trigger_test_fire(
    first_store,
    record,
    "event:evt_e",
    "evt_e",
    "tsk_1",
    10L,
    1_700_000_000_000L,
  )
  assert_eq(first, @contracts.TriggerApplied)
  first_store.close()

  let reopened = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot reopen file store: " + message)
  }
  // The event log replays the fire; the unique ledger drops the delivery.
  let replay = trigger_test_fire(
    reopened,
    record,
    "event:evt_e",
    "evt_e",
    "tsk_replay",
    30L,
    1_700_000_000_500L,
  )
  assert_eq(replay, @contracts.TriggerDuplicate)
  let tasks = match reopened.list_tasks("", "") {
    Ok(value) => value
    _ => fail("cannot list tasks after reopen")
  }
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].id, "tsk_1")
  assert_eq(
    trigger_test_count_events(reopened, @contracts.EVENT_TRIGGER_FIRED),
    1,
  )
  let persisted = match reopened.get_trigger("trg_1") {
    Ok(Some(value)) => value
    _ => fail("trigger lost after reopen")
  }
  assert_eq(persisted.dedupe_hits, 1)
  reopened.close()
}

///|
test "pending run catch-up drains a batch larger than five and skips no-run fires" {
  let store = trigger_test_store()
  let record = trigger_test_record("trg_1", "batch", "")
  trigger_test_create(store, record, 1L)
  // Seven fires from one batch: the old five-row read would strand the rest
  // until another Task created a later batch.
  for i in 0..<7 {
    let n = i.to_string()
    let outcome = trigger_test_fire(
      store,
      record,
      "event:evt_" + n,
      "evt_" + n,
      "tsk_" + n,
      10L + (i * 2).to_int64(),
      1_700_000_000_000L + i.to_int64(),
    )
    assert_eq(outcome, @contracts.TriggerApplied)
  }
  let pending = match store.get_trigger_fires_missing_run("trg_1", 100) {
    Ok(value) => value
    Err(message) => fail("cannot read pending fires: " + message)
  }
  assert_eq(pending.length(), 7)
  for fire in pending {
    assert_true(fire.run_intent)
    let linked = match
      store.set_trigger_fire_run_id("trg_1", fire.fire_key, "run_" + fire.task_id) {
      Ok(value) => value
      Err(message) => fail("cannot link a run: " + message)
    }
    assert_true(linked)
  }
  let drained = match store.get_trigger_fires_missing_run("trg_1", 100) {
    Ok(value) => value
    Err(message) => fail("cannot re-read pending fires: " + message)
  }
  assert_eq(drained.length(), 0)

  // A fire created while start_run=false is not a catch-up candidate, even
  // after the trigger is flipped to start_run=true.
  let no_run = trigger_test_fire(
    store,
    record,
    "event:evt_old",
    "evt_old",
    "tsk_old",
    40L,
    1_700_000_001_000L,
    run_intent=false,
  )
  assert_eq(no_run, @contracts.TriggerApplied)
  let still_pending = match store.get_trigger_fires_missing_run("trg_1", 100) {
    Ok(value) => value
    Err(message) => fail("cannot read no-run fire: " + message)
  }
  assert_eq(still_pending.length(), 0)
  let old = match store.get_trigger_fire_row("trg_1", "event:evt_old") {
    Ok(value) => value
    Err(message) => fail("cannot read no-run row: " + message)
  }
  assert_true(!old.run_intent)
  assert_eq(old.run_id, "")
  let linked_old = match
    store.set_trigger_fire_run_id("trg_1", "event:evt_old", "run_old") {
    Ok(value) => value
    Err(message) => fail("cannot reject a no-run link: " + message)
  }
  assert_true(!linked_old)
}

///|
test "opening a pre-A3 database creates the trigger tables" {
  let path = "/tmp/monexus-trigger-migrate-test.db"
  reset_trigger_db(path)
  let conn = @sqlite3.Connection::open(path) catch {
    error => fail("cannot create pre-A3 database: " + trigger_test_sqlite_text(error))
  }
  try {
    let create_events = conn.prepare(
      "CREATE TABLE events (seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, " +
      "org_id TEXT NOT NULL, type TEXT NOT NULL, subject TEXT NOT NULL, " +
      "ts TEXT NOT NULL, causation_id TEXT NOT NULL, " +
      "correlation_id TEXT NOT NULL, idempotency_key TEXT NOT NULL UNIQUE, " +
      "payload_json TEXT NOT NULL)",
    )
    let _ = create_events.step()
    create_events.finalize()
    let create_meta = conn.prepare(
      "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    )
    let _ = create_meta.step()
    create_meta.finalize()
  } catch {
    error => {
      conn.close() catch { _ => () }
      fail("cannot prepare pre-A3 database: " + trigger_test_sqlite_text(error))
    }
  }
  conn.close() catch { _ => () }

  let store = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot migrate pre-A3 database: " + message)
  }
  let record = trigger_test_record("trg_migrated", "migrated", "")
  trigger_test_create(store, record, 1L)
  let loaded = match store.get_trigger("trg_migrated") {
    Ok(Some(value)) => value
    _ => fail("trigger tables were not created by migration")
  }
  assert_eq(loaded.name, "migrated")
  store.close()
}
