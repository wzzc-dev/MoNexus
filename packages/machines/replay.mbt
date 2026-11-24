///|
/// Pure machine projection replay (architecture §5.3, R3).
///
/// The event log is the authority; the `machines` table is a cache. The host
/// rebuilds the cache from events at startup, and tests use this same function
/// to prove that replay reconstructs exactly the live projection.

///|
pub struct MachineProjection {
  records : Map[String, @contracts.MachineRecord]
  tombstoned : Map[String, Bool]
}

///|
pub fn MachineProjection::new() -> MachineProjection {
  { records: Map([]), tombstoned: Map([]) }
}

///|
/// Apply one event. Non-machine events are ignored on purpose: the projection
/// only owns machine state.
pub fn MachineProjection::apply(
  self : MachineProjection,
  event : @contracts.EventEnvelope,
) -> Unit {
  if event.event_type == @contracts.EVENT_MACHINE_REMOVED {
    let machine_id = match removed_machine_id(event) {
      Some(value) => value
      None => return
    }
    self.tombstoned.set(machine_id, true)
    return
  }
  if !event.event_type.has_prefix("machine.") {
    return
  }
  match @contracts.machine_event_record(event) {
    Some(record) => {
      self.records.set(record.id, record)
      self.tombstoned.set(record.id, false)
    }
    None => ()
  }
}

///|
fn removed_machine_id(
  event : @contracts.EventEnvelope,
) -> String? {
  match event.payload {
    @json.Json::Object(object) =>
      match object.get("machine_id") {
        Some(@json.Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
pub fn replay(
  events : Array[@contracts.EventEnvelope],
) -> MachineProjection {
  let projection = MachineProjection::new()
  for event in events {
    projection.apply(event)
  }
  projection
}

///|
/// Live (non-tombstoned) records, sorted by id for a deterministic replay.
pub fn MachineProjection::live_records(
  self : MachineProjection,
) -> Array[@contracts.MachineRecord] {
  let out : Array[@contracts.MachineRecord] = []
  for machine_id, record in self.records {
    let removed = match self.tombstoned.get(machine_id) {
      Some(value) => value
      None => false
    }
    if !removed {
      out.push(record)
    }
  }
  sort_records(out)
  out
}

///|
/// Tombstoned ids, sorted for a deterministic replay.
pub fn MachineProjection::tombstoned_ids(self : MachineProjection) -> Array[String] {
  let out : Array[String] = []
  for machine_id, removed in self.tombstoned {
    if removed {
      out.push(machine_id)
    }
  }
  out.sort()
  out
}

///|
/// All records including tombstoned ones (used to rebuild the table rows).
pub fn MachineProjection::all_records(
  self : MachineProjection,
) -> Array[@contracts.MachineRecord] {
  let out : Array[@contracts.MachineRecord] = []
  for _, record in self.records {
    out.push(record)
  }
  sort_records(out)
  out
}

///|
fn sort_records(records : Array[@contracts.MachineRecord]) -> Unit {
  // Insertion sort keeps this deterministic without requiring Ord on records.
  let mut index = 1
  while index < records.length() {
    let current = records[index]
    let mut position = index
    while position > 0 && records[position - 1].id > current.id {
      records[position] = records[position - 1]
      position = position - 1
    }
    records[position] = current
    index = index + 1
  }
}
