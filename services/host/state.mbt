///|
/// Runtime options for `monexus-host serve`.
pub(all) struct HostOptions {
  state_dir : String
  heartbeat_ms : Int
  port : Int
  version : String
}

///|
pub fn HostOptions::new(
  state_dir~ : String,
  heartbeat_ms~ : Int = 1_000,
  port~ : Int = 0,
  version~ : String = HOST_VERSION,
) -> HostOptions {
  { state_dir, heartbeat_ms: heartbeat_ms.max(50), port, version, }
}

///|
/// One connected WebSocket client that may be subscribed to events.
struct Sink {
  queue : @aqueue.Queue[String]
  subscribed : Ref[Bool]
  closed : Ref[Bool]
}

///|
/// Host-wide mutable state, guarded by `mutex`. All fields that change at
/// runtime live here so connection handlers can share them safely.
pub struct HostState {
  host_id : String
  version : String
  started_at_ms : Int64
  state_dir : String
  heartbeat_ms : Int
  port : Int
  token : String
  ws_url : String
  mutex : @async.Mutex
  mut next_seq : Int64
  ring : Array[@contracts.EventEnvelope]
  sinks : Array[Sink]
  cache : Map[String, String]
  store : @machines.MachineStore
}

///|
fn random_token() -> String {
  let rand = @random.Rand::chacha8()
  let bytes : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  for index in 0..<32 {
    bytes.set(index, rand.int(limit=256).to_byte())
  }
  @hex.encode(Bytes::from_fixedarray(bytes).exact_view())
}

///|
fn HostState::new(
  options : HostOptions,
  port : Int,
  store : @machines.MachineStore,
) -> HostState {
  let now = @async.now()
  let token = random_token()
  // Continue the event sequence where the previous run stopped. Persisted
  // machine events are also loaded into the ring so a reconnecting subscriber
  // can replay them after a restart.
  let last_seq = match store.last_seq() {
    Ok(value) => value
    Err(message) => {
      println("monexus-host: cannot read event sequence: " + message)
      0L
    }
  }
  let ring = match store.load_recent_events(RING_CAPACITY) {
    Ok(value) => value
    Err(message) => {
      println("monexus-host: cannot load recent events: " + message)
      []
    }
  }
  {
    host_id: @contracts.new_id("host", now),
    version: options.version,
    started_at_ms: now,
    state_dir: options.state_dir,
    heartbeat_ms: options.heartbeat_ms,
    port,
    token,
    ws_url: "ws://127.0.0.1:" + port.to_string() + "/ws",
    mutex: @async.Mutex::Mutex(),
    next_seq: last_seq + 1L,
    ring,
    sinks: [],
    cache: Map([]),
    store,
  }
}

///|
fn HostState::event_seq(self : HostState) -> Int64 {
  self.next_seq - 1L
}

///|
fn HostState::uptime_ms(self : HostState) -> Int64 {
  @async.now() - self.started_at_ms
}

///|
fn HostState::status(self : HostState) -> @contracts.HostStatus {
  @contracts.HostStatus::new(
    host_id=self.host_id,
    version=self.version,
    status=@contracts.HOST_STATUS_ONLINE,
    pid=0,
    started_at=@contracts.format_rfc3339(self.started_at_ms),
    uptime_ms=self.uptime_ms(),
    event_seq=self.event_seq(),
    state_dir=self.state_dir,
    protocol_version=1,
  )
}

///|
fn HostState::host_info(self : HostState) -> @contracts.HostInfo {
  @contracts.HostInfo::new(
    schema_version=@contracts.DISCOVERY_SCHEMA_VERSION,
    host_id=self.host_id,
    version=self.version,
    pid=0,
    port=self.port,
    token=self.token,
    ws_url=self.ws_url,
    started_at=@contracts.format_rfc3339(self.started_at_ms),
    state_dir=self.state_dir,
  )
}

///|
/// Build the next event envelope while the caller holds `mutex`. Seq
/// allocation and the envelope fields are shared by every event path.
fn HostState::next_envelope(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
) -> @contracts.EventEnvelope {
  let now = @async.now()
  let seq = self.next_seq
  self.next_seq = seq + 1L
  @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", now),
    org_id=@contracts.ORG_LOCAL,
    event_type~,
    ts=@contracts.format_rfc3339(now),
    subject~,
    seq~,
    payload~,
    causation_id="",
    correlation_id=self.host_id,
    idempotency_key="evt/" + seq.to_string(),
  )
}

///|
/// Push an event into the ring and fan it out to subscribed connections.
/// Caller holds `mutex`.
fn HostState::publish(self : HostState, event : @contracts.EventEnvelope) -> Unit {
  self.ring.push(event)
  while self.ring.length() > RING_CAPACITY {
    ignore(self.ring.remove(0))
  }
  let text = event_notification_text(event)
  for sink in self.sinks {
    if sink.subscribed.val {
      sink.send(text)
    }
  }
}

///|
/// Append an event while the caller holds `mutex`. The event is persisted
/// before it is published, so the log stays the authority if the host exits
/// right after acknowledging an RPC.
fn HostState::append_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
) -> @contracts.EventEnvelope {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.append_event(event) {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot persist event " + event.event_type + ": " + message)
  }
  self.publish(event)
  event
}

///|
/// Append a machine event and its projection row in one transaction. On a
/// store failure the event is not published, so subscribers never see a
/// state the database does not have.
fn HostState::append_machine_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.MachineRecord?,
  removed_id : String?,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_machine_event(event, record, removed_id) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
const RING_CAPACITY : Int = 256

///|
const CACHE_CAPACITY : Int = 512

///|
/// Serialize an event as an `events.event` JSON-RPC notification.
fn event_notification_text(event : @contracts.EventEnvelope) -> String {
  let params : Map[String, @json.Json] = Map([
    ("event", event.to_json()),
  ])
  @contracts.RpcNotification::new(
    @contracts.NOTIFICATION_EVENTS_EVENT,
    params,
  ).to_json().stringify()
}

///|
/// Enqueue a frame on a connection. A closed queue only means the writer
/// task has already gone away, so the failure is intentionally ignored.
fn Sink::send(self : Sink, text : String) -> Unit {
  if self.closed.val {
    return
  }
  ignore(self.queue.try_put(text) catch { _ => false })
}

///|
fn HostState::register_sink(self : HostState, queue : @aqueue.Queue[String]) -> Sink {
  let sink = {
    queue,
    subscribed: Ref(false),
    closed: Ref(false),
  }
  // Drop sinks whose connections are gone so a long-lived host does not
  // accumulate queues across reconnects.
  let live : Array[Sink] = []
  for existing in self.sinks {
    if !existing.closed.val {
      live.push(existing)
    }
  }
  live.push(sink)
  self.sinks.clear()
  for existing in live {
    self.sinks.push(existing)
  }
  sink
}

///|
fn HostState::replay_after(self : HostState, since : Int64) -> Array[@contracts.EventEnvelope] {
  let out : Array[@contracts.EventEnvelope] = []
  for event in self.ring {
    if event.seq > since {
      out.push(event)
    }
  }
  out
}
