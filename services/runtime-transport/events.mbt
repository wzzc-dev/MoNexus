///|
/// The JSON-level event/ack contract shared with A1.1b.
///
/// A node publishes one `runtime.event` frame per stored outbox event. The
/// dedupe identity is `(runtime_id, run_id, run_seq)` — exactly the A1.1a
/// outbox idempotency key — while `seq` is the outbox's monotonic global
/// sequence used as the acknowledgement cursor. The primary acks by sending
/// `runtime.ack {cursor}`; the node feeds that cursor back into
/// `Outbox::ack_through`.
///
/// `hash` is `sha256:` + lowercase hex of the canonical JSON encoding
/// (object keys sorted) of `runtime_id`, `run_id`, `run_seq`, `seq`, `kind`
/// and `payload`. The primary recomputes it and rejects a mismatch, so a
/// corrupted or spliced payload is not acknowledged.

///|
pub(all) struct WireEvent {
  seq : Int64
  run_id : String
  run_seq : Int64
  kind : String
  ts : String
  payload : @json.Json
  hash : String
}

///|
/// Deterministic JSON encoding with object keys in lexicographic order.
pub fn canonical_json(value : @json.Json) -> String {
  match value {
    @json.Json::Object(map) => {
      let entries = map.to_array()
      entries.sort_by_key(entry => entry.0)
      let parts : Array[String] = []
      for entry in entries {
        let key = @json.Json::string(entry.0).stringify()
        parts.push(key + ":" + canonical_json(entry.1))
      }
      "{" + parts.join(",") + "}"
    }
    @json.Json::Array(items) => {
      let parts : Array[String] = []
      for item in items {
        parts.push(canonical_json(item))
      }
      "[" + parts.join(",") + "]"
    }
    other => other.stringify()
  }
}

///|
fn event_hash_object(runtime_id : String, event : WireEvent) -> @json.Json {
  @contracts.json_object([
    ("kind", @contracts.json_string(event.kind)),
    ("payload", event.payload),
    ("run_id", @contracts.json_string(event.run_id)),
    ("run_seq", @contracts.json_int64(event.run_seq)),
    ("runtime_id", @contracts.json_string(runtime_id)),
    ("seq", @contracts.json_int64(event.seq)),
  ])
}

///|
pub fn event_hash(runtime_id : String, event : WireEvent) -> String {
  let canonical = canonical_json(event_hash_object(runtime_id, event))
  "sha256:" + sha256_text(canonical)
}

///|
pub fn WireEvent::compute_hash(self : WireEvent, runtime_id : String) -> String {
  event_hash(runtime_id, self)
}

///|
/// Encode an event as `runtime.event` params. The `hash` field is recomputed
/// so a stored outbox event and a freshly built event hash identically.
pub fn WireEvent::to_params(self : WireEvent, runtime_id : String) -> Map[String, @json.Json] {
  let hash = self.compute_hash(runtime_id)
  let map : Map[String, @json.Json] = Map([])
  map.set("runtime_id", @contracts.json_string(runtime_id))
  map.set("run_id", @contracts.json_string(self.run_id))
  map.set("run_seq", @contracts.json_int64(self.run_seq))
  map.set("seq", @contracts.json_int64(self.seq))
  map.set("kind", @contracts.json_string(self.kind))
  map.set("ts", @contracts.json_string(self.ts))
  map.set("payload", self.payload)
  map.set("hash", @contracts.json_string(hash))
  map
}

///|
/// Decode `runtime.event` params. Every field is length-checked before it can
/// reach state; the payload must serialize within the event bound.
pub fn WireEvent::from_params(
  params : Map[String, @json.Json],
) -> Result[WireEvent, String] {
  let run_id = match @contracts.string_field(params, "run_id") {
    Some(value) => value
    None => return Err("missing run_id")
  }
  if !is_safe_id(run_id) {
    return Err("invalid run_id")
  }
  let run_seq = match @contracts.int64_field(params, "run_seq") {
    Some(value) =>
      if value > 0L {
        value
      } else {
        return Err("run_seq must be positive")
      }
    None => return Err("missing run_seq")
  }
  let seq = match @contracts.int64_field(params, "seq") {
    Some(value) =>
      if value > 0L {
        value
      } else {
        return Err("seq must be positive")
      }
    None => return Err("missing seq")
  }
  let kind = match @contracts.string_field(params, "kind") {
    Some(value) =>
      if is_safe_token_text(value, MAX_CAPABILITY_LEN) {
        value
      } else {
        return Err("invalid kind")
      }
    None => return Err("missing kind")
  }
  let ts = match @contracts.string_field(params, "ts") {
    Some(value) =>
      if value.length() <= 64 {
        value
      } else {
        return Err("ts is too long")
      }
    None => return Err("missing ts")
  }
  let payload = match params.get("payload") {
    Some(value) => value
    None => return Err("missing payload")
  }
  if payload.stringify().length() > MAX_EVENT_PAYLOAD_BYTES {
    return Err("payload is too large")
  }
  let hash = match @contracts.string_field(params, "hash") {
    Some(value) => value
    None => return Err("missing hash")
  }
  Ok({ seq, run_id, run_seq, kind, ts, payload, hash })
}

///|
/// Result of accepting one event: the durable ack cursor after this event and
/// whether it was a duplicate.
pub(all) struct EventAck {
  cursor : Int64
  duplicate : Bool
}

///|
pub fn EventAck::to_json(self : EventAck) -> @json.Json {
  @contracts.json_object([
    ("cursor", @contracts.json_int64(self.cursor)),
    ("duplicate", @contracts.json_bool(self.duplicate)),
  ])
}
