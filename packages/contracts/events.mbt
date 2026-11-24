///|
/// Append-only event envelope (architecture §5, ADR 0005). M1 uses an
/// in-memory ring in the host; the envelope shape is already the one later
/// durable storage will write.
pub(all) struct EventEnvelope {
  id : String
  org_id : String
  event_type : String
  ts : String
  subject : String
  seq : Int64
  causation_id : String
  correlation_id : String
  idempotency_key : String
  payload : @json.Json
}

///|
pub fn EventEnvelope::new(
  id~ : String,
  org_id~ : String,
  event_type~ : String,
  ts~ : String,
  subject~ : String,
  seq~ : Int64,
  payload~ : @json.Json,
  causation_id~ : String = "",
  correlation_id~ : String = "",
  idempotency_key~ : String = "",
) -> EventEnvelope {
  {
    id,
    org_id,
    event_type,
    ts,
    subject,
    seq,
    causation_id,
    correlation_id,
    idempotency_key,
    payload,
  }
}

///|
pub fn EventEnvelope::to_json(self : EventEnvelope) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("org_id", json_string(self.org_id)),
    ("type", json_string(self.event_type)),
    ("ts", json_string(self.ts)),
    ("subject", json_string(self.subject)),
    ("seq", json_int64(self.seq)),
    ("causation_id", json_string(self.causation_id)),
    ("correlation_id", json_string(self.correlation_id)),
    ("idempotency_key", json_string(self.idempotency_key)),
    ("payload", self.payload),
  ])
}

///|
pub fn EventEnvelope::from_json(json : @json.Json) -> EventEnvelope? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let org_id = match string_field(object, "org_id") {
    Some(value) => value
    None => return None
  }
  let event_type = match string_field(object, "type") {
    Some(value) => value
    None => return None
  }
  let ts = match string_field(object, "ts") {
    Some(value) => value
    None => return None
  }
  let subject = match string_field(object, "subject") {
    Some(value) => value
    None => return None
  }
  let seq = match int64_field(object, "seq") {
    Some(value) => value
    None => return None
  }
  let payload = match object.get("payload") {
    Some(value) => value
    None => @json.Json::empty_object()
  }
  Some({
    id,
    org_id,
    event_type,
    ts,
    subject,
    seq,
    causation_id: string_field_or(object, "causation_id", ""),
    correlation_id: string_field_or(object, "correlation_id", ""),
    idempotency_key: string_field_or(object, "idempotency_key", ""),
    payload,
  })
}
