///|
/// Replay tests for the machine projection: the event log is the authority,
/// so replaying it must produce exactly the live machine set, including
/// tombstones from `machine.removed` (architecture R3/R4).
fn sample_machine(id : String, status : String) -> @contracts.MachineRecord {
  {
    id,
    kind: @contracts.MACHINE_KIND_SSH,
    name: "test-" + id,
    host: "127.0.0.1",
    port: 2222,
    user: "tester",
    identity: "/tmp/test-key",
    use_ssh_config: false,
    host_key_policy: @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file: "",
    status,
    profile: None,
    ssh_effective: Map([]),
    ssh_effective_error: "",
    last_seen: "",
    last_error: "",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
fn machine_event(
  seq : Int64,
  event_type : String,
  record : @contracts.MachineRecord,
) -> @contracts.EventEnvelope {
  @contracts.EventEnvelope::new(
    id="evt-" + seq.to_string(),
    org_id=@contracts.ORG_LOCAL,
    event_type~,
    ts="2026-01-01T00:00:00Z",
    subject="machine/" + record.id,
    seq~,
    payload=@contracts.machine_event_payload(record),
    idempotency_key="evt/" + seq.to_string(),
  )
}

///|
fn removed_event(
  seq : Int64,
  machine_id : String,
) -> @contracts.EventEnvelope {
  @contracts.EventEnvelope::new(
    id="evt-" + seq.to_string(),
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_MACHINE_REMOVED,
    ts="2026-01-01T00:00:01Z",
    subject="machine/" + machine_id,
    seq~,
    payload=@contracts.machine_removed_payload(machine_id),
    idempotency_key="evt/" + seq.to_string(),
  )
}

///|
test "replay keeps the last record per machine" {
  let first = sample_machine("mch_a", @contracts.MACHINE_STATUS_UNKNOWN)
  let second = sample_machine("mch_a", @contracts.MACHINE_STATUS_ONLINE)
  let projection = replay([
    machine_event(1L, @contracts.EVENT_MACHINE_REGISTERED, first),
    machine_event(2L, @contracts.EVENT_MACHINE_PROBED, second),
  ])
  let live = projection.live_records()
  assert_eq(live.length(), 1)
  assert_eq(live[0].status, @contracts.MACHINE_STATUS_ONLINE)
}

///|
test "machine.removed tombstones the record" {
  let record = sample_machine("mch_b", @contracts.MACHINE_STATUS_ONLINE)
  let projection = replay([
    machine_event(1L, @contracts.EVENT_MACHINE_REGISTERED, record),
    removed_event(2L, record.id),
  ])
  assert_eq(projection.live_records().length(), 0)
  let tombstoned = projection.tombstoned_ids()
  assert_eq(tombstoned.length(), 1)
  assert_eq(tombstoned[0], record.id)
  // The record itself is retained; only the tombstone hides it.
  assert_eq(projection.all_records().length(), 1)
}

///|
test "replay ignores non-machine events" {
  let record = sample_machine("mch_c", @contracts.MACHINE_STATUS_DEGRADED)
  let heartbeat = @contracts.EventEnvelope::new(
    id="evt-heartbeat",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_HOST_HEARTBEAT,
    ts="2026-01-01T00:00:00Z",
    subject="host/x",
    seq=9L,
    payload=@contracts.json_object([]),
    idempotency_key="evt/9",
  )
  let projection = replay([
    machine_event(1L, @contracts.EVENT_MACHINE_REGISTERED, record),
    heartbeat,
  ])
  assert_eq(projection.live_records().length(), 1)
  assert_eq(projection.live_records()[0].status, @contracts.MACHINE_STATUS_DEGRADED)
}

///|
test "replay is deterministic and sorted by id" {
  let projection = replay([
    machine_event(
      1L,
      @contracts.EVENT_MACHINE_REGISTERED,
      sample_machine("mch_z", @contracts.MACHINE_STATUS_UNKNOWN),
    ),
    machine_event(
      2L,
      @contracts.EVENT_MACHINE_REGISTERED,
      sample_machine("mch_a", @contracts.MACHINE_STATUS_UNKNOWN),
    ),
  ])
  let live = projection.live_records()
  assert_eq(live[0].id, "mch_a")
  assert_eq(live[1].id, "mch_z")
}
