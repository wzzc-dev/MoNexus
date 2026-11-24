///|
/// RPC methods implemented in M1. Adding methods is additive; clients should
/// treat unknown methods as `-32601`.
pub const METHOD_HOST_STATUS : String = "host.status"

///|
pub const METHOD_EVENTS_SUBSCRIBE : String = "events.subscribe"

///|
/// Server-to-client notification carrying one event envelope in `params`.
pub const NOTIFICATION_EVENTS_EVENT : String = "events.event"

///|
pub const EVENT_HOST_HEARTBEAT : String = "host.heartbeat"

///|
pub const ORG_LOCAL : String = "org_local"

///|
pub const HOST_STATUS_ONLINE : String = "online"

///|
/// Result of `host.status`.
pub(all) struct HostStatus {
  host_id : String
  version : String
  status : String
  pid : Int
  started_at : String
  uptime_ms : Int64
  event_seq : Int64
  state_dir : String
  protocol_version : Int
}

///|
pub fn HostStatus::new(
  host_id~ : String,
  version~ : String,
  status~ : String,
  pid~ : Int,
  started_at~ : String,
  uptime_ms~ : Int64,
  event_seq~ : Int64,
  state_dir~ : String,
  protocol_version~ : Int = 1,
) -> HostStatus {
  {
    host_id,
    version,
    status,
    pid,
    started_at,
    uptime_ms,
    event_seq,
    state_dir,
    protocol_version,
  }
}

///|
pub fn HostStatus::to_json(self : HostStatus) -> @json.Json {
  json_object([
    ("host_id", json_string(self.host_id)),
    ("version", json_string(self.version)),
    ("status", json_string(self.status)),
    ("pid", json_int(self.pid)),
    ("started_at", json_string(self.started_at)),
    ("uptime_ms", json_int64(self.uptime_ms)),
    ("event_seq", json_int64(self.event_seq)),
    ("state_dir", json_string(self.state_dir)),
    ("protocol_version", json_int(self.protocol_version)),
  ])
}

///|
pub fn HostStatus::from_json(json : @json.Json) -> HostStatus? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let host_id = match string_field(object, "host_id") {
    Some(value) => value
    None => return None
  }
  let status = match string_field(object, "status") {
    Some(value) => value
    None => return None
  }
  Some({
    host_id,
    version: string_field_or(object, "version", ""),
    status,
    pid: int_field_or(object, "pid", 0),
    started_at: string_field_or(object, "started_at", ""),
    uptime_ms: int64_field_or(object, "uptime_ms", 0),
    event_seq: int64_field_or(object, "event_seq", 0),
    state_dir: string_field_or(object, "state_dir", ""),
    protocol_version: int_field_or(object, "protocol_version", 1),
  })
}

///|
/// Result of `events.subscribe`.
pub(all) struct SubscribeResult {
  subscribed : Bool
  replayed : Int
  from_seq : Int64
  next_seq : Int64
}

///|
pub fn SubscribeResult::new(
  subscribed~ : Bool,
  replayed~ : Int,
  from_seq~ : Int64,
  next_seq~ : Int64,
) -> SubscribeResult {
  { subscribed, replayed, from_seq, next_seq }
}

///|
pub fn SubscribeResult::to_json(self : SubscribeResult) -> @json.Json {
  json_object([
    ("subscribed", json_bool(self.subscribed)),
    ("replayed", json_int(self.replayed)),
    ("from_seq", json_int64(self.from_seq)),
    ("next_seq", json_int64(self.next_seq)),
  ])
}

///|
pub fn SubscribeResult::from_json(json : @json.Json) -> SubscribeResult? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    subscribed: bool_field_or(object, "subscribed", false),
    replayed: int_field_or(object, "replayed", 0),
    from_seq: int64_field_or(object, "from_seq", 0),
    next_seq: int64_field_or(object, "next_seq", 0),
  })
}

///|
pub fn status_params(client_request_id : String) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", json_string(client_request_id))
  params
}

///|
/// `since` is the last sequence the client already saw; the host replays
/// events with `seq > since`. Omit it to start with future events only.
pub fn subscribe_params(
  client_request_id : String,
  since : Int64?,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", json_string(client_request_id))
  match since {
    Some(value) => params.set("since", json_int64(value))
    None => ()
  }
  params
}

///|
pub fn subscribe_since(
  params : Map[String, @json.Json],
) -> Int64? {
  int64_field(params, "since")
}
