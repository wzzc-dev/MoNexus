///|
/// Durable runtime outbox event kinds (ADR-0012 §5). Streams never carry
/// output bytes: a chunk event references `(stream, offset, length)` in the
/// run's append-only log, so event payloads stay bounded.
pub const EVENT_EXEC_STARTED : String = "runtime.exec.started"

///|
pub const EVENT_EXEC_STDOUT : String = "runtime.exec.stdout"

///|
pub const EVENT_EXEC_STDERR : String = "runtime.exec.stderr"

///|
pub const EVENT_EXEC_TRUNCATED : String = "runtime.exec.truncated"

///|
pub const EVENT_EXEC_EXITED : String = "runtime.exec.exited"

///|
pub const EVENT_OUTBOX_ACK : String = "runtime.outbox.ack"

///|
/// One persisted outbox event, decoded from the shared event log.
pub(all) struct StoredEvent {
  seq : Int64
  run_seq : Int64
  run_id : String
  kind : String
  ts : String
  payload : @json.Json
}

///|
/// The node-local durable outbox.
///
/// This deliberately reuses `@machines.MachineStore` (the existing SQLite
/// event log with a unique idempotency key and a monotonic global seq) rather
/// than adding a second durable store: the outbox *is* an append-only event
/// log, and the store already provides the exact append/dedupe/read semantics
/// ADR-0012 needs. Each runtime state root gets its own `outbox.db`, so the
/// runtime never shares a database with the host or another runtime.
///
/// Every event's idempotency key is `(runtime_id, run_id, run_seq)`, matching
/// the ADR-0012 dedupe key. The ack cursor is itself an event
/// (`runtime.outbox.ack` with `{"cursor": <global seq>}`), so acknowledgement
/// and event appends share one atomic, crash-safe log.
pub struct Outbox {
  store : @machines.MachineStore
  runtime_id : String
  mutex : @async.Mutex
  cursor : Ref[Int64]
  next_run_seq : Map[String, Int64]
}

///|
fn outbox_idempotency_key(
  runtime_id : String,
  run_id : String,
  run_seq : Int64,
) -> String {
  runtime_id + "/" + run_id + "/" + run_seq.to_string()
}

///|
fn decode_stored_event(event : @contracts.EventEnvelope) -> StoredEvent? {
  let object = match @contracts.as_object(event.payload) {
    Some(value) => value
    None => return None
  }
  let run_id = match @contracts.string_field(object, "run_id") {
    Some(value) => value
    None => ""
  }
  let run_seq = @contracts.int64_field_or(object, "run_seq", 0L)
  Some({
    seq: event.seq,
    run_seq,
    run_id,
    kind: event.event_type,
    ts: event.ts,
    payload: event.payload,
  })
}

///|
fn is_runtime_event(event : @contracts.EventEnvelope) -> Bool {
  event.event_type.has_prefix("runtime.")
}

///|
/// Read every runtime event, oldest first. The underlying store caps one call
/// at 2000 rows, so this pages until exhausted.
fn scan_runtime_events(
  store : @machines.MachineStore,
) -> Result[Array[@contracts.EventEnvelope], String] {
  let out : Array[@contracts.EventEnvelope] = []
  let mut since = 0L
  while true {
    let page = match store.load_events_since(since, 2_000) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    if page.is_empty() {
      break
    }
    for event in page {
      since = event.seq
      if is_runtime_event(event) {
        out.push(event)
      }
    }
  }
  Ok(out)
}

///|
/// Open (or create) the outbox under a runtime state root and replay the log.
/// Returns the outbox plus every persisted event so the executor can rebuild
/// run state without a second read.
pub async fn Outbox::open(
  state : RuntimeState,
  runtime_id : String,
) -> Result[(Outbox, Array[StoredEvent]), String] {
  match validate_resource_id(runtime_id, "runtime_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let store = match @machines.MachineStore::open(state.outbox_path()) {
    Ok(value) => value
    Err(message) => return Err("cannot open runtime outbox: " + message)
  }
  // Defense in depth: the state root is already 0700, and the outbox may hold
  // redacted output previews. Keep the database itself private too.
  @fs.chmod(state.outbox_path(), 0o600) catch {
    _ => ()
  }
  let envelopes = match scan_runtime_events(store) {
    Ok(value) => value
    Err(message) => {
      store.close()
      return Err(message)
    }
  }
  let events : Array[StoredEvent] = []
  let mut ack_cursor = 0L
  let next_run_seq : Map[String, Int64] = Map([])
  for envelope in envelopes {
    match decode_stored_event(envelope) {
      Some(event) =>
        if event.kind == EVENT_OUTBOX_ACK {
          let object = @contracts.as_object(event.payload)
          let cursor = match object {
            Some(value) => @contracts.int64_field_or(value, "cursor", 0L)
            None => 0L
          }
          if cursor > ack_cursor {
            ack_cursor = cursor
          }
        } else {
          events.push(event)
          if event.run_id != "" {
            let next = event.run_seq + 1
            let current = match next_run_seq.get(event.run_id) {
              Some(value) => value
              None => 0L
            }
            if next > current {
              next_run_seq.set(event.run_id, next)
            }
          }
        }
      None => ()
    }
  }
  let outbox = {
    store,
    runtime_id,
    mutex: @async.Mutex::Mutex(),
    cursor: Ref(ack_cursor),
    next_run_seq,
  }
  Ok((outbox, events))
}

///|
pub fn Outbox::runtime_id(self : Outbox) -> String {
  self.runtime_id
}

///|
pub fn Outbox::cursor(self : Outbox) -> Int64 {
  self.cursor.val
}

///|
fn Outbox::allocate_run_seq(self : Outbox, run_id : String) -> Int64 {
  let current = match self.next_run_seq.get(run_id) {
    Some(value) => value
    None => 0L
  }
  self.next_run_seq.set(run_id, current + 1)
  current
}

///|
/// Append one run event. The event is durable before the caller reports it.
/// Payload entries are merged with the standard `run_id` / `run_seq` fields.
async fn Outbox::append(
  self : Outbox,
  run_id : String,
  kind : String,
  entries : Array[(String, @json.Json)],
) -> Result[StoredEvent, String] {
  match validate_resource_id(run_id, "run_id") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  self.mutex.acquire()
  defer self.mutex.release()
  let last = match self.store.last_seq() {
    Ok(value) => value
    Err(message) => return Err("cannot read outbox seq: " + message)
  }
  let run_seq = Outbox::allocate_run_seq(self, run_id)
  let seq = last + 1
  let ts = @contracts.format_rfc3339(@async.now())
  let all_entries : Array[(String, @json.Json)] = [
    ("run_id", @contracts.json_string(run_id)),
    ("run_seq", @contracts.json_int64(run_seq)),
    ("kind", @contracts.json_string(kind)),
  ]
  for entry in entries {
    all_entries.push(entry)
  }
  let event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", @async.now()),
    org_id=@contracts.ORG_LOCAL,
    event_type=kind,
    ts~,
    subject="run/" + run_id,
    seq~,
    payload=@contracts.json_object(all_entries),
    causation_id=run_id,
    correlation_id=self.runtime_id,
    idempotency_key=outbox_idempotency_key(self.runtime_id, run_id, run_seq),
  )
  let inserted = match self.store.append_event(event) {
    Ok(value) => value
    Err(message) => return Err("cannot append outbox event: " + message)
  }
  if !inserted {
    return Err("duplicate outbox event key for run " + run_id)
  }
  Ok({
    seq,
    run_seq,
    run_id,
    kind,
    ts,
    payload: @contracts.json_object(all_entries),
  })
}

///|
/// Publish every event whose `seq` is `<= cursor`. The cursor is persisted as
/// an event itself and only moves forward, so a reconnect can resume from it
/// without re-delivering an already acknowledged event.
async fn Outbox::ack(self : Outbox, cursor : Int64) -> Result[Unit, String] {
  self.mutex.acquire()
  defer self.mutex.release()
  if cursor <= self.cursor.val {
    return Ok(())
  }
  let last = match self.store.last_seq() {
    Ok(value) => value
    Err(message) => return Err("cannot read outbox seq: " + message)
  }
  let seq = last + 1
  let ts = @contracts.format_rfc3339(@async.now())
  let payload = @contracts.json_object([
    ("kind", @contracts.json_string(EVENT_OUTBOX_ACK)),
    ("cursor", @contracts.json_int64(cursor)),
  ])
  let event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", @async.now()),
    org_id=@contracts.ORG_LOCAL,
    event_type=EVENT_OUTBOX_ACK,
    ts~,
    subject="outbox/" + self.runtime_id,
    seq~,
    payload~,
    correlation_id=self.runtime_id,
    idempotency_key=self.runtime_id + "/ack/" + cursor.to_string(),
  )
  let inserted = match self.store.append_event(event) {
    Ok(value) => value
    Err(message) => return Err("cannot append outbox ack: " + message)
  }
  if !inserted {
    return Err("duplicate outbox ack for cursor " + cursor.to_string())
  }
  if cursor > self.cursor.val {
    self.cursor.val = cursor
  }
  Ok(())
}

///|
/// Events that have not been acknowledged yet, oldest first. The cursor
/// advances only through `ack`, so a restarted reader sees the same pending
/// set until it explicitly acks.
async fn Outbox::pending(
  self : Outbox,
  limit : Int32,
) -> Result[Array[StoredEvent], String] {
  self.mutex.acquire()
  defer self.mutex.release()
  let since = self.cursor.val
  let out : Array[StoredEvent] = []
  let mut scan = since
  while out.length() < limit {
    let page = match self.store.load_events_since(scan, 2_000) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    if page.is_empty() {
      break
    }
    for envelope in page {
      scan = envelope.seq
      if !is_runtime_event(envelope) || envelope.event_type == EVENT_OUTBOX_ACK {
        continue
      }
      match decode_stored_event(envelope) {
        Some(event) => if out.length() < limit { out.push(event) }
        None => ()
      }
    }
  }
  Ok(out)
}

///|
pub fn Outbox::close(self : Outbox) -> Unit {
  self.store.close()
}
