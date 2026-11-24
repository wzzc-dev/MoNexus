///|
/// SQLite store tests: persistence, idempotency, monotonic seq and the
/// replay-based projection rebuild the host performs at startup.
test "store round-trips a machine record" {
  let store = match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
  let record = sample_machine("mch_1", @contracts.MACHINE_STATUS_ONLINE)
  match store.put_machine(record) {
    Ok(_) => ()
    Err(message) => fail("put_machine failed: " + message)
  }
  let listed = match store.list_machines() {
    Ok(value) => value
    Err(message) => fail("list_machines failed: " + message)
  }
  assert_eq(listed.length(), 1)
  assert_eq(listed[0].id, "mch_1")
  assert_eq(listed[0].status, @contracts.MACHINE_STATUS_ONLINE)
  let fetched = match store.get_machine("mch_1") {
    Ok(value) => value
    Err(message) => fail("get_machine failed: " + message)
  }
  match fetched {
    Some(value) => assert_eq(value.host, "127.0.0.1")
    None => fail("machine was not found")
  }
  store.close()
}

///|
test "event append is idempotent and seq continues" {
  let store = match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
  let record = sample_machine("mch_2", @contracts.MACHINE_STATUS_UNKNOWN)
  let event = machine_event(5L, @contracts.EVENT_MACHINE_REGISTERED, record)
  let first = match store.append_event(event) {
    Ok(value) => value
    Err(message) => fail("append_event failed: " + message)
  }
  assert_true(first)
  let duplicate = match store.append_event(event) {
    Ok(value) => value
    Err(message) => fail("duplicate append failed: " + message)
  }
  assert_true(!duplicate)
  let seq = match store.last_seq() {
    Ok(value) => value
    Err(message) => fail("last_seq failed: " + message)
  }
  assert_eq(seq, 5L)
  let recent = match store.load_recent_events(10) {
    Ok(value) => value
    Err(message) => fail("load_recent_events failed: " + message)
  }
  assert_eq(recent.length(), 1)
  assert_eq(recent[0].id, "evt-5")
  store.close()
}

///|
test "record_machine_event writes projection and tombstone atomically" {
  let store = match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
  let record = sample_machine("mch_3", @contracts.MACHINE_STATUS_ONLINE)
  let registered = machine_event(
    1L,
    @contracts.EVENT_MACHINE_REGISTERED,
    record,
  )
  match store.record_machine_event(registered, Some(record), None) {
    Ok(_) => ()
    Err(message) => fail("record_machine_event failed: " + message)
  }
  let listed = match store.list_machines() {
    Ok(value) => value
    Err(message) => fail("list_machines failed: " + message)
  }
  assert_eq(listed.length(), 1)
  let removed = removed_event(2L, record.id)
  match store.record_machine_event(removed, None, Some(record.id)) {
    Ok(_) => ()
    Err(message) => fail("tombstone failed: " + message)
  }
  let after = match store.list_machines() {
    Ok(value) => value
    Err(message) => fail("list_machines failed: " + message)
  }
  assert_eq(after.length(), 0)
  // The tombstoned row still exists, so a machine id cannot be reused into a
  // silently different record.
  let fetched = match store.get_machine(record.id) {
    Ok(value) => value
    Err(message) => fail("get_machine failed: " + message)
  }
  match fetched {
    Some(_) => fail("tombstoned machine must not be returned as live")
    None => ()
  }
  store.close()
}

///|
test "reconcile rebuilds the projection from the event log" {
  let store = match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
  // Simulate the crash case: the event is in the log but no projection row
  // was written (the host appends then dies before the row write).
  let record = sample_machine("mch_4", @contracts.MACHINE_STATUS_ONLINE)
  let event = machine_event(7L, @contracts.EVENT_MACHINE_REGISTERED, record)
  match store.append_event(event) {
    Ok(_) => ()
    Err(message) => fail("append_event failed: " + message)
  }
  let before = match store.list_machines() {
    Ok(value) => value
    Err(message) => fail("list_machines failed: " + message)
  }
  assert_eq(before.length(), 0)
  let counts = match store.reconcile_projection() {
    Ok(value) => value
    Err(message) => fail("reconcile failed: " + message)
  }
  assert_eq(counts.0, 1)
  assert_eq(counts.1, 0)
  let after = match store.list_machines() {
    Ok(value) => value
    Err(message) => fail("list_machines failed: " + message)
  }
  assert_eq(after.length(), 1)
  assert_eq(after[0].id, "mch_4")
  store.close()
}

///|
test "prune drops heartbeats but keeps machine events" {
  let store = match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
  let record = sample_machine("mch_5", @contracts.MACHINE_STATUS_UNKNOWN)
  let machine = machine_event(1L, @contracts.EVENT_MACHINE_REGISTERED, record)
  match store.append_event(machine) {
    Ok(_) => ()
    Err(message) => fail("append_event failed: " + message)
  }
  let heartbeat = @contracts.EventEnvelope::new(
    id="evt-heartbeat",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_HOST_HEARTBEAT,
    ts="2026-01-01T00:00:00Z",
    subject="host/x",
    seq=2L,
    payload=@contracts.json_object([]),
    idempotency_key="evt/2",
  )
  match store.append_event(heartbeat) {
    Ok(_) => ()
    Err(message) => fail("append_event failed: " + message)
  }
  let pruned = match store.prune_heartbeats() {
    Ok(value) => value
    Err(message) => fail("prune failed: " + message)
  }
  assert_eq(pruned, 1)
  let events = match store.load_machine_events() {
    Ok(value) => value
    Err(message) => fail("load_machine_events failed: " + message)
  }
  assert_eq(events.length(), 1)
  // last_seq survives the prune, so the host never reuses a seq.
  let seq = match store.last_seq() {
    Ok(value) => value
    Err(message) => fail("last_seq failed: " + message)
  }
  assert_eq(seq, 2L)
  store.close()
}
