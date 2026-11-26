///|
/// A3.1 store tests: bounded due scan, the schedule CAS claim, webhook
/// exactly-once (nonce + fire key), rejected key/trigger states, nonce
/// pruning and projection reconcile preserving `next_fire_at`.

///|
const SW_BASE_MS : Int64 = 1_767_225_600_000L

///|
fn sw_schedule_record(
  id : String,
  next_fire_at : String,
  expires_at : String,
) -> @contracts.TriggerRecord {
  let source = @contracts.TriggerSource::new(
    schedule_kind="every",
    interval_minutes=60,
    timezone="UTC",
    jitter_s=0,
    missed="skip",
  )
  let target = @contracts.TriggerTarget::new(
    title_template="Scheduled {{trigger_id}}",
    goal_template="scheduled run",
  )
  @contracts.TriggerRecord::new(
    id~,
    org_id=@contracts.ORG_LOCAL,
    name="scheduled-" + id,
    kind=@contracts.TRIGGER_TYPE_SCHEDULE,
    target~,
    source~,
    config_hash="hash-" + id,
    created_by="owner",
    created_at="2026-01-01T00:00:00.000Z",
    active_from_seq=0L,
    next_fire_at~,
    expires_at~,
    resolved_tz="UTC",
    anchor_ms=SW_BASE_MS,
  )
}

///|
fn sw_webhook_record(id : String, expires_at : String) -> @contracts.TriggerRecord {
  let source = @contracts.TriggerSource::new(
    payload_fields=["title"],
  )
  let target = @contracts.TriggerTarget::new(
    title_template="Webhook {{title}}",
    goal_template="webhook run",
  )
  @contracts.TriggerRecord::new(
    id~,
    org_id=@contracts.ORG_LOCAL,
    name="webhook-" + id,
    kind=@contracts.TRIGGER_TYPE_WEBHOOK,
    target~,
    source~,
    config_hash="hash-" + id,
    created_by="owner",
    created_at="2026-01-01T00:00:00.000Z",
    active_from_seq=0L,
    expires_at~,
  )
}

///|
fn sw_key(
  store : MachineStore,
  key_id : String,
  trigger_id : String,
  revoked_at : String,
  expires_at : String,
) -> Unit raise {
  let record = @contracts.WebhookKeyRecord::new(
    key_id~,
    trigger_id~,
    org_id=@contracts.ORG_LOCAL,
    name="key-" + key_id,
    secret_path=@contracts.webhook_secret_relative_path(key_id),
    created_at="2026-01-01T00:00:00.000Z",
    revoked_at~,
    expires_at~,
  )
  match store.put_webhook_key(record) {
    Ok(_) => ()
    Err(message) => fail("cannot put webhook key: " + message)
  }
}

///|
fn sw_task(
  record : @contracts.TriggerRecord,
  source : String,
  fire_key : String,
  task_id : String,
) -> @contracts.TaskRecord {
  let origin = @contracts.TriggerOrigin::new(
    trigger_id=record.id,
    fire_key~,
    root_trigger_id=record.id,
    depth=1,
    source~,
  )
  @contracts.TaskRecord::new(
    id=task_id,
    title="Triggered task",
    goal="triggered",
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
fn sw_fire(
  record : @contracts.TriggerRecord,
  source : String,
  fire_key : String,
  task_id : String,
) -> @contracts.TriggerFire {
  @contracts.TriggerFire::new(
    id="trf_" + fire_key,
    trigger_id=record.id,
    source~,
    fire_key~,
    created_at="2026-01-01T00:00:00.000Z",
    task_id~,
    depth=1,
  )
}

///|
fn sw_task_event(
  seq : Int64,
  task : @contracts.TaskRecord,
  trigger_id : String,
  fire_key : String,
) -> @contracts.EventEnvelope {
  trigger_test_envelope(
    seq,
    @contracts.EVENT_TASK_CREATED,
    task.id,
    task.to_json(),
    @contracts.trigger_task_event_idempotency(trigger_id, fire_key),
  )
}

///|
fn sw_fired_event(
  seq : Int64,
  fire : @contracts.TriggerFire,
  record_after : @contracts.TriggerRecord,
) -> @contracts.EventEnvelope {
  trigger_test_envelope(
    seq,
    @contracts.EVENT_TRIGGER_FIRED,
    "trigger/" + fire.trigger_id,
    @contracts.trigger_fired_payload(fire, record_after),
    "trigger/" + fire.trigger_id + "/" + fire.fire_key + "/fired",
  )
}

///|
fn sw_schedule_claim(
  store : MachineStore,
  record : @contracts.TriggerRecord,
  fire_key : String,
  task_id : String,
  seq : Int64,
  expected : String,
  new_next : String,
  now_ms : Int64,
) -> @contracts.TriggerWriteOutcome raise {
  let source = @contracts.TRIGGER_SOURCE_SCHEDULE
  let task = sw_task(record, source, fire_key, task_id)
  let fire = sw_fire(record, source, fire_key, task_id)
  let record_after = {
    ..record,
    next_fire_at: new_next,
    last_fired_at: @contracts.format_rfc3339(now_ms),
    updated_at: @contracts.format_rfc3339(now_ms),
  }
  match store.record_trigger_schedule_event(
    [sw_task_event(seq, task, record.id, fire_key)],
    sw_fired_event(seq + 1L, fire, record_after),
    task,
    fire,
    record_after,
    expected,
    new_next,
    now_ms,
  ) {
    Ok(outcome) => outcome
    Err(message) => fail("schedule claim failed: " + message)
  }
}

///|
fn sw_webhook_claim(
  store : MachineStore,
  record : @contracts.TriggerRecord,
  key_id : String,
  nonce : String,
  body_hash : String,
  fire_key : String,
  task_id : String,
  seq : Int64,
  now_ms : Int64,
) -> WebhookFireOutcome raise {
  let source = @contracts.TRIGGER_SOURCE_WEBHOOK
  let task = sw_task(record, source, fire_key, task_id)
  let fire = {
    ..sw_fire(record, source, fire_key, task_id),
    event_id: fire_key,
    key_id,
  }
  let record_after = {
    ..record,
    last_fired_at: @contracts.format_rfc3339(now_ms),
    updated_at: @contracts.format_rfc3339(now_ms),
  }
  match store.record_trigger_webhook_event(
    [sw_task_event(seq, task, record.id, fire_key)],
    sw_fired_event(seq + 1L, fire, record_after),
    task,
    fire,
    record_after,
    key_id,
    nonce,
    body_hash,
    now_ms + 900_000L + 120_000L,
    now_ms,
    now_ms,
  ) {
    Ok(outcome) => outcome
    Err(message) => fail("webhook claim failed: " + message)
  }
}

///|
fn sw_count_tasks(store : MachineStore) -> Int raise {
  match store.list_tasks("", "") {
    Ok(value) => value.length()
    Err(message) => fail("cannot list tasks: " + message)
  }
}

///|
fn sw_assert_applied(outcome : @contracts.TriggerWriteOutcome) -> Unit raise {
  match outcome {
    @contracts.TriggerApplied => ()
    _ => fail("expected TriggerApplied, got a different outcome")
  }
}

///|
fn sw_assert_webhook_applied(outcome : WebhookFireOutcome) -> Unit raise {
  match outcome {
    WebhookFireApplied => ()
    _ => fail("expected WebhookFireApplied")
  }
}

///|
test "due schedule scan is bounded, ordered and excludes disabled/future/expired" {
  let store = trigger_test_store()
  let due_a = sw_schedule_record("trg_a", @contracts.format_rfc3339(SW_BASE_MS), "")
  let due_b = sw_schedule_record(
    "trg_b",
    @contracts.format_rfc3339(SW_BASE_MS + 1_000L),
    "",
  )
  let future = sw_schedule_record(
    "trg_future",
    @contracts.format_rfc3339(SW_BASE_MS + 3_600_000L),
    "",
  )
  let disabled = {
    ..sw_schedule_record("trg_off", @contracts.format_rfc3339(SW_BASE_MS), ""),
    enabled: false,
  }
  let expired = sw_schedule_record(
    "trg_exp",
    @contracts.format_rfc3339(SW_BASE_MS),
    @contracts.format_rfc3339(SW_BASE_MS - 1_000L),
  )
  let event_trigger = trigger_test_record("trg_event", "event", "")
  trigger_test_create(store, due_a, 1L)
  trigger_test_create(store, due_b, 2L)
  trigger_test_create(store, future, 3L)
  trigger_test_create(store, disabled, 4L)
  trigger_test_create(store, expired, 5L)
  trigger_test_create(store, event_trigger, 6L)
  let due = match store.list_due_schedules(SW_BASE_MS + 2_000L, 10) {
    Ok(value) => value
    Err(message) => fail("due scan failed: " + message)
  }
  assert_eq(due.length(), 2)
  assert_eq(due[0].id, "trg_a")
  assert_eq(due[1].id, "trg_b")
  let first = match store.list_due_schedules(SW_BASE_MS + 2_000L, 1) {
    Ok(value) => value
    Err(message) => fail("due scan failed: " + message)
  }
  assert_eq(first.length(), 1)
  // A non-positive limit still scans one row rather than failing the tick.
  let clamped = match store.list_due_schedules(SW_BASE_MS + 2_000L, 0) {
    Ok(value) => value
    Err(message) => fail("due scan failed: " + message)
  }
  assert_eq(clamped.length(), 1)
}

///|
test "schedule claim CAS creates one Task and a stale claim writes nothing" {
  let store = trigger_test_store()
  let next = @contracts.format_rfc3339(SW_BASE_MS)
  let after = @contracts.format_rfc3339(SW_BASE_MS + 60_000L)
  let record = sw_schedule_record("trg_s", next, "")
  trigger_test_create(store, record, 1L)
  let slot_key = "slot:" + SW_BASE_MS.to_string()
  sw_assert_applied(
    sw_schedule_claim(store, record, slot_key, "tsk_1", 10L, next, after, SW_BASE_MS),
  )
  assert_eq(sw_count_tasks(store), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
  let loaded = match store.get_trigger("trg_s") {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("trigger missing")
  }
  assert_eq(loaded.next_fire_at, after)
  // A second ticker that read the old slot loses the CAS; it must not create
  // a Task or a second fired event.
  let conflict = sw_schedule_claim(
    store,
    record,
    slot_key,
    "tsk_stale",
    20L,
    next,
    after,
    SW_BASE_MS + 1L,
  )
  assert_eq(conflict, @contracts.TriggerVersionConflict)
  assert_eq(sw_count_tasks(store), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TASK_CREATED), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
  // A replayed slot whose CAS succeeds hits the fire ledger instead and
  // answers Duplicate while still advancing the projection.
  let further = @contracts.format_rfc3339(SW_BASE_MS + 120_000L)
  let duplicate = sw_schedule_claim(
    store,
    loaded,
    slot_key,
    "tsk_dup",
    30L,
    after,
    further,
    SW_BASE_MS + 2L,
  )
  assert_eq(duplicate, @contracts.TriggerDuplicate)
  assert_eq(sw_count_tasks(store), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
  let advanced = match store.get_trigger("trg_s") {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("trigger missing")
  }
  assert_eq(advanced.next_fire_at, further)
  assert_eq(advanced.dedupe_hits, 1)
}

///|
test "schedule claim re-checks disabled and expiry inside the transaction" {
  let store = trigger_test_store()
  let next = @contracts.format_rfc3339(SW_BASE_MS)
  let disabled = {
    ..sw_schedule_record("trg_off", next, ""),
    enabled: false,
  }
  trigger_test_create(store, disabled, 1L)
  let off = sw_schedule_claim(
    store,
    disabled,
    "slot:off",
    "tsk_off",
    10L,
    next,
    @contracts.format_rfc3339(SW_BASE_MS + 60_000L),
    SW_BASE_MS,
  )
  assert_eq(off, @contracts.TriggerDisabled)
  let expiring = sw_schedule_record(
    "trg_exp",
    next,
    @contracts.format_rfc3339(SW_BASE_MS),
  )
  trigger_test_create(store, expiring, 20L)
  let expired = sw_schedule_claim(
    store,
    expiring,
    "slot:exp",
    "tsk_exp",
    30L,
    next,
    @contracts.format_rfc3339(SW_BASE_MS + 60_000L),
    SW_BASE_MS + 1L,
  )
  assert_eq(expired, @contracts.TriggerExpired)
  assert_eq(sw_count_tasks(store), 0)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TASK_CREATED), 0)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 0)
}

///|
test "webhook nonce and delivery keys make delivery exactly-once" {
  let store = trigger_test_store()
  let record = sw_webhook_record("trg_w", "")
  trigger_test_create(store, record, 1L)
  sw_key(store, "whk_a", "trg_w", "", "")
  let first = sw_webhook_claim(
    store,
    record,
    "whk_a",
    "nonce_one",
    "hash_one",
    "delivery:d1",
    "tsk_1",
    10L,
    SW_BASE_MS,
  )
  sw_assert_webhook_applied(first)
  assert_eq(sw_count_tasks(store), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
  // Same nonce + same body: duplicate with the original Task id, no writes.
  let same = sw_webhook_claim(
    store,
    record,
    "whk_a",
    "nonce_one",
    "hash_one",
    "delivery:different",
    "tsk_2",
    20L,
    SW_BASE_MS + 1L,
  )
  match same {
    WebhookFireDuplicate(task_id~) => assert_eq(task_id, "tsk_1")
    _ => fail("same nonce/same body must be a duplicate")
  }
  assert_eq(sw_count_tasks(store), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TASK_CREATED), 1)
  // Same nonce + different body: replay attempt, no Task.
  let reused = sw_webhook_claim(
    store,
    record,
    "whk_a",
    "nonce_one",
    "hash_two",
    "delivery:d3",
    "tsk_3",
    30L,
    SW_BASE_MS + 2L,
  )
  match reused {
    WebhookFireNonceReuse => ()
    _ => fail("same nonce with a different body must be nonce_reuse")
  }
  assert_eq(sw_count_tasks(store), 1)
  // Same delivery id with a fresh nonce: the fire key dedupes it too.
  let redelivered = sw_webhook_claim(
    store,
    record,
    "whk_a",
    "nonce_two",
    "hash_three",
    "delivery:d1",
    "tsk_4",
    40L,
    SW_BASE_MS + 3L,
  )
  match redelivered {
    WebhookFireDuplicate(task_id~) => assert_eq(task_id, "tsk_1")
    _ => fail("same delivery id must be a duplicate")
  }
  assert_eq(sw_count_tasks(store), 1)
  // A genuinely new delivery creates the second Task.
  sw_assert_webhook_applied(
    sw_webhook_claim(
      store,
      record,
      "whk_a",
      "nonce_final",
      "hash_four",
      "delivery:d2",
      "tsk_5",
      50L,
      SW_BASE_MS + 4L,
    ),
  )
  assert_eq(sw_count_tasks(store), 2)
  let ledger = match store.get_trigger_fire_row("trg_w", "delivery:d2") {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(ledger.task_id, "tsk_5")
  let updated = match store.get_trigger("trg_w") {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("trigger missing")
  }
  assert_eq(updated.dedupe_hits, 2)
}

///|
test "webhook rejects inactive keys and disabled/expired/unknown triggers" {
  let store = trigger_test_store()
  let record = sw_webhook_record("trg_w", "")
  trigger_test_create(store, record, 1L)
  sw_key(store, "whk_active", "trg_w", "", "")
  sw_key(store, "whk_revoked", "trg_w", "2025-12-31T00:00:00.000Z", "")
  sw_key(store, "whk_expired", "trg_w", "", "2025-12-31T00:00:00.000Z")
  sw_key(store, "whk_other", "trg_other", "", "")
  let revoked = sw_webhook_claim(
    store,
    record,
    "whk_revoked",
    "nonce_revoked",
    "hash",
    "delivery:revoked",
    "tsk_r",
    10L,
    SW_BASE_MS,
  )
  match revoked {
    WebhookFireKeyInactive => ()
    _ => fail("revoked key must be inactive")
  }
  let expired_key = sw_webhook_claim(
    store,
    record,
    "whk_expired",
    "nonce_expired",
    "hash",
    "delivery:expired",
    "tsk_e",
    20L,
    SW_BASE_MS,
  )
  match expired_key {
    WebhookFireKeyInactive => ()
    _ => fail("expired key must be inactive")
  }
  let unknown_key = sw_webhook_claim(
    store,
    record,
    "whk_missing",
    "nonce_missing",
    "hash",
    "delivery:missing",
    "tsk_m",
    30L,
    SW_BASE_MS,
  )
  match unknown_key {
    WebhookFireKeyInactive => ()
    _ => fail("unknown key must be inactive")
  }
  // A key bound to another trigger cannot be used across triggers.
  let wrong_binding = sw_webhook_claim(
    store,
    record,
    "whk_other",
    "nonce_other",
    "hash",
    "delivery:other",
    "tsk_o",
    40L,
    SW_BASE_MS,
  )
  match wrong_binding {
    WebhookFireKeyInactive => ()
    _ => fail("cross-trigger key must be inactive")
  }
  let disabled = { ..record, enabled: false, version: 2 }
  let disabled_event = trigger_test_envelope(
    50L,
    @contracts.EVENT_TRIGGER_DISABLED,
    "trigger/trg_w",
    @contracts.trigger_disabled_payload(disabled, "owner", "test"),
    "trigger/trg_w/disabled/2",
  )
  match store.record_trigger_event(disabled_event, disabled) {
    Ok(_) => ()
    Err(message) => fail(message)
  }
  let off = sw_webhook_claim(
    store,
    disabled,
    "whk_active",
    "nonce_off",
    "hash",
    "delivery:off",
    "tsk_off",
    60L,
    SW_BASE_MS,
  )
  match off {
    WebhookFireDisabled => ()
    _ => fail("disabled trigger must be rejected")
  }
  let expiring = sw_webhook_record(
    "trg_exp",
    @contracts.format_rfc3339(SW_BASE_MS),
  )
  trigger_test_create(store, expiring, 70L)
  sw_key(store, "whk_expiring", "trg_exp", "", "")
  let expired_trigger = sw_webhook_claim(
    store,
    expiring,
    "whk_expiring",
    "nonce_exp",
    "hash",
    "delivery:exp",
    "tsk_exp",
    80L,
    SW_BASE_MS + 1L,
  )
  match expired_trigger {
    WebhookFireExpired => ()
    _ => fail("expired trigger must be rejected")
  }
  let missing = sw_webhook_claim(
    store,
    sw_webhook_record("trg_absent", ""),
    "whk_active",
    "nonce_absent",
    "hash",
    "delivery:absent",
    "tsk_absent",
    90L,
    SW_BASE_MS,
  )
  match missing {
    WebhookFireNotFound => ()
    _ => fail("missing trigger must be not_found")
  }
  assert_eq(sw_count_tasks(store), 0)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 0)
}

///|
test "nonce pruning and last-tick metadata round-trip" {
  let store = trigger_test_store()
  let record = sw_webhook_record("trg_w", "")
  trigger_test_create(store, record, 1L)
  sw_key(store, "whk_a", "trg_w", "", "")
  sw_assert_webhook_applied(
    sw_webhook_claim(
      store,
      record,
      "whk_a",
      "nonce_prune",
      "hash",
      "delivery:prune",
      "tsk_1",
      10L,
      SW_BASE_MS,
    ),
  )
  let removed = match store.prune_webhook_nonces(SW_BASE_MS + 1_020_000L) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(removed, 1)
  let removed_again = match store.prune_webhook_nonces(SW_BASE_MS + 1_020_000L) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(removed_again, 0)
  let initial_tick = match store.trigger_last_tick_ms() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(initial_tick, None)
  match store.set_trigger_last_tick_ms(SW_BASE_MS) {
    Ok(_) => ()
    Err(message) => fail(message)
  }
  let tick = match store.trigger_last_tick_ms() {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("last tick was not persisted")
  }
  assert_eq(tick, SW_BASE_MS)
}

///|
test "reconcile replays a schedule fire and keeps the advanced next slot" {
  let store = trigger_test_store()
  let next = @contracts.format_rfc3339(SW_BASE_MS)
  let after = @contracts.format_rfc3339(SW_BASE_MS + 60_000L)
  let record = sw_schedule_record("trg_s", next, "")
  trigger_test_create(store, record, 1L)
  sw_assert_applied(
    sw_schedule_claim(store, record, "slot:1", "tsk_1", 10L, next, after, SW_BASE_MS),
  )
  match store.set_trigger_event_cursor(0L) {
    Ok(_) => ()
    Err(message) => fail(message)
  }
  match store.reconcile_trigger_projection() {
    Ok(_) => ()
    Err(message) => fail(message)
  }
  let reconciled = match store.get_trigger("trg_s") {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("trigger lost in reconcile")
  }
  assert_eq(reconciled.next_fire_at, after)
  assert_eq(sw_count_tasks(store), 1)
  assert_eq(trigger_test_count_events(store, @contracts.EVENT_TRIGGER_FIRED), 1)
}
