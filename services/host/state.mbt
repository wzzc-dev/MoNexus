///|
/// Runtime options for `monexus-host serve`.
pub(all) struct HostOptions {
  state_dir : String
  heartbeat_ms : Int32
  port : Int32
  version : String
  /// Trigger feature flag (ADR-0014 §7). Default off: every `trigger.*`
  /// method answers `unsupported`, `/hooks/*` answers the uniform 401, and no
  /// dispatcher or scheduler is started.
  trigger_enabled : Bool
  /// Paired-runtime primary endpoint (A1.5). Empty disables the runtime
  /// listener; there is no plaintext fallback when it is enabled.
  runtime_listen : String
  runtime_cert : String
  runtime_key : String
  /// Transport state dir (0700). Empty uses `<state_dir>/runtime`.
  runtime_state_dir : String
  /// Optional policy snapshot JSON to publish at startup and after restart.
  runtime_policy : String
  /// Primary-side workspace roots mapped onto node workspaces. An absolute
  /// agent cwd below one of these is passed to the node as a relative path.
  runtime_workspace_roots : Array[String]
  /// How long an operation waits for a live runtime channel before ending
  /// unverifiable. Zero means fail immediately.
  runtime_wait_ms : Int64
  /// How long a runtime high-risk approval Decision stays answerable. The
  /// provider caps this at the policy core's grant ceiling.
  runtime_approval_ttl_ms : Int64
  /// Skill packs feature flag (ADR-0015 §4). Default off: every `skill.*`
  /// method answers `unsupported`, `agent.start` rejects `skills`, ACP
  /// `mcpServers` stays `[]` and no skill block is injected.
  skill_enabled : Bool
  /// Absolute path of this host binary, used as the stdio MCP gateway command
  /// for local agent sessions. Empty means the gateway is unavailable; the
  /// session then gets declarative injection only and is marked not invocable.
  host_exe : String
  /// Managed account credentials (ADR-0016). Off by default so V0.1 behavior
  /// is untouched: no proxy env, no credential RPC, no credential events.
  credential_enabled : Bool
  /// `credential.storage`: empty/auto (Keychain on macOS, file elsewhere) or
  /// an explicit `file`/`keychain` request.
  credential_storage : String
  /// Lease bound for a remote binding. Offline beyond it fails closed.
  credential_lease_ttl_ms : Int64
  /// Suppression window for repeated credential readiness failures.
  credential_cooldown_ms : Int64
}

///|
pub fn HostOptions::new(
  state_dir~ : String,
  heartbeat_ms~ : Int32 = 1_000,
  port~ : Int32 = 0,
  version~ : String = HOST_VERSION,
  trigger_enabled~ : Bool = false,
  runtime_listen~ : String = "",
  runtime_cert~ : String = "",
  runtime_key~ : String = "",
  runtime_state_dir~ : String = "",
  runtime_policy~ : String = "",
  runtime_workspace_roots~ : Array[String] = [],
  runtime_wait_ms~ : Int64 = 2_000L,
  runtime_approval_ttl_ms~ : Int64 = 60_000L,
  skill_enabled~ : Bool = false,
  host_exe~ : String = "",
  credential_enabled~ : Bool = false,
  credential_storage~ : String = "",
  credential_lease_ttl_ms~ : Int64 = @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS,
  credential_cooldown_ms~ : Int64 = @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS,
) -> HostOptions {
  {
    state_dir,
    heartbeat_ms: heartbeat_ms.max(50),
    port,
    version,
    trigger_enabled,
    runtime_listen,
    runtime_cert,
    runtime_key,
    runtime_state_dir,
    runtime_policy,
    runtime_workspace_roots,
    runtime_wait_ms: runtime_wait_ms.max(0L),
    runtime_approval_ttl_ms: runtime_approval_ttl_ms.max(1_000L),
    skill_enabled,
    host_exe,
    credential_enabled,
    credential_storage,
    credential_lease_ttl_ms: if credential_lease_ttl_ms > 0L {
      credential_lease_ttl_ms
    } else {
      @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS
    },
    credential_cooldown_ms: if credential_cooldown_ms > 0L {
      credential_cooldown_ms
    } else {
      @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS
    },
  }
}

///|
/// One connected WebSocket client that may be subscribed to events.
struct Sink {
  queue : @aqueue.Queue[String]
  subscribed : Ref[Bool]
  closed : Ref[Bool]
}

///|
/// One in-flight `environment.exec`, tracked so stop/destroy can cancel the
/// underlying Docker/SSH invocation. The result lands in `env_exec_cache` so a
/// repeated `exec_id` never runs twice.
pub struct EnvironmentExecTask {
  environment_id : String
  exec_id : String
  task : @async.Task[Unit]
}

///|
/// Host-wide mutable state, guarded by `mutex`. All fields that change at
/// runtime live here so connection handlers can share them safely.

///|
/// Coalescing state for webhook `rate_limited` audit events: at most one per
/// trigger per minute, with `suppressed_count` for the rest (§4.5).
struct TriggerWebhookAuditState {
  last_ms : Int64
  suppressed : Int32
}

///|
pub struct HostState {
  host_id : String
  version : String
  started_at_ms : Int64
  state_dir : String
  heartbeat_ms : Int32
  port : Int32
  token : String
  ws_url : String
  mutex : @async.Mutex
  mut next_seq : Int64
  ring : Array[@contracts.EventEnvelope]
  sinks : Array[Sink]
  cache : Map[String, String]
  store : @machines.MachineStore
  group : Ref[@async.TaskGroup[Unit]?]
  terminals : Map[String, TerminalSession]
  agent_sessions : Map[String, AgentSessionRuntime]
  agent_transcripts : Map[String, AgentTranscript]
  /// Runtime session id -> canonical Chat AgentSession id. Present only for
  /// sessions started by the Chat bridge; used to key durable transcripts.
  chat_runtime_sessions : Map[String, String]
  /// Registered paired-runtime launchers, keyed by runtime machine id. The
  /// transport attach layer (or a test harness) fills this; an empty entry
  /// fails `agent.start` honestly instead of pretending the machine is local.
  runtime_agent_launchers : Map[String, @agent.RemoteLauncher]
  /// Primary-side paired-runtime state, when the runtime listener is enabled.
  /// It owns live channels and the durable transport store.
  runtime_primary : Ref[@transport.PrimaryState?]
  /// Decoded policy snapshot published by this primary. It is re-announced
  /// whenever a new runtime channel attaches, because the node only learns
  /// policy from `runtime.policy.update` notifications and a publication made
  /// before the session existed reaches nobody.
  runtime_policy_snapshot : Ref[@policy.PolicySnapshot?]
  /// The running TLS listener. Kept so `runtime.status` can report its port
  /// and shutdown can close it.
  runtime_server : Ref[@transport.PrimaryServer?]
  /// Attached runtime providers keyed by host machine id. The provider holds
  /// pending approval bindings across reconnects, so it is created once per
  /// live machine rather than per request.
  runtime_machines : Map[String, @provider_runtime.RuntimeMachine]
  runtime_workspace_roots : Array[String]
  runtime_wait_ms : Int64
  runtime_approval_ttl_ms : Int64
  dispatching : Ref[Bool]
  trigger_enabled : Bool
  trigger_buckets : Map[String, @contracts.TriggerRateBucket]
  // A5: credential manager. The platform store owns secrets; SQLite (via
  // `store`) owns metadata only. Proxies are keyed by agent session id and
  // stopped on session stop or revoke. `credential_cooldowns` suppresses a
  // repeated readiness Decision for the same binding+reason.
  credential_enabled : Bool
  credential_store : @credentials.CredentialStore
  credential_lease_ttl_ms : Int64
  credential_cooldown_ms : Int64
  credential_proxies : Map[String, @credentials.CredentialProxy]
  credential_cooldowns : Map[String, Int64]
  credential_ports : Map[String, @credentials.RemoteCredentialPort]
  webhook_inflight : Map[String, Int32]
  webhook_audit : Map[String, TriggerWebhookAuditState]
  // A2.1: owner trust store and its verifier probe. Both are loaded once at
  // host start; recipe signatures are re-verified against them before use.
  trust : @recipes.TrustStore
  verifier : @recipes.VerifierProbe
  // A4: skill packs. The key store is loaded from `skill_keys`; capability
  // tokens live only in memory and are never persisted. Waiters are keyed by
  // Decision id and carry the owner's option id (or a fixed expired marker).
  skill_enabled : Bool
  host_exe : String
  mut skill_keys : @skills.SkillKeyStore
  skill_capabilities : Map[String, SkillCapability]
  skill_waiters : Map[String, @aqueue.Queue[String]]
  skill_rate : Map[String, @contracts.TriggerRateBucket]
  // Lifecycle mutations are serialized separately from `mutex` so a long
  // Docker pull never blocks event fan-out or read-only RPCs.
  environment_mutex : @async.Mutex
  env_exec_cache : Map[String, @json.Json]
  env_exec_tasks : Map[String, EnvironmentExecTask]
  env_create_started : Map[String, Int64]
  // Whitebox test seam: production never sets this. It makes the durable
  // approval-consumption append fail so the fail-closed path can be tested
  // without corrupting the database.
  test_fail_approval_consumption : Ref[Bool]
  // A2.2: paired runtime nodes attached to this primary, keyed by machine id.
  // A runtime-kind machine without a live link reports `unreachable` instead
  // of falling back to SSH or local execution.
  runtimes : Map[String, RuntimeLink]
}

///|
/// Bounded transcript for one agent session. `base` is the absolute cursor of
/// `text[0]`; trimming the head advances `base`, so a polling client cursor
/// keeps meaning even after the buffer wraps.
pub struct AgentTranscript {
  base : Int64
  text : String
}

///|
/// A permission request that has been turned into a Decision and is waiting
/// for the owner's answer. `acp_id` is the JSON-RPC id of the agent request,
/// needed to reply on the same stdio pipe.
pub struct PendingPermission {
  acp_id : @json.Json
}

///|
/// Live agent session. `process` is owned here; the ACP pump reads it and the
/// send/decision handlers write through its internal write lock. Everything
/// else is guarded by the host mutex.
pub struct AgentSessionRuntime {
  id : String
  agent_id : String
  acp_session_id : String
  process : @agent.AgentProcess
  transcript : Ref[AgentTranscript]
  pending : Map[String, PendingPermission]
  active_prompts : Map[String, Int32]
  turn_text : Ref[String]
  /// Assistant-visible ACP text for the current turn; thought chunks and
  /// raw stdout never enter it.
  chat_text : Ref[String]
  home : String
  memory_before : String
  /// Capability token for this session's stdio skill gateway ("" when skills
  /// are off, unavailable or the session is remote). Never persisted.
  skill_token : String
  stderr_tail : Ref[String]
  finalized : Ref[Bool]
}

///|
/// One frozen snapshot entry as the gateway needs it. `resource_root` is the
/// materialised session directory (entry + resources only).
pub struct SkillCapabilityEntry {
  name : String
  version : String
  content_hash : String
  scope : String
  scope_ref : String
  mode : String
  entry_ids : Array[String]
  resource_root : String
}

///|
/// Session-scoped capability behind the stdio MCP gateway. The token is a
/// bearer secret: it is never written to an event, audit record or session
/// projection. `remote` sessions have no local gateway and are marked not
/// invocable; the snapshot is still injected declaratively.
pub struct SkillCapability {
  token : String
  session_id : String
  agent_id : String
  cwd : String
  workspace_id : String
  /// Session skill root (`<agent home>/sessions/<session>/skills`), used as the
  /// only HOME for invoked commands. Never a shared or system home.
  home : String
  remote : Bool
  entries : Map[String, SkillCapabilityEntry]
}

///|
/// One open terminal transcript. The provider task pumps PTY/SSH output into
/// `output`; the host appends it to `transcript` so `terminal.read` can
/// return everything after a client cursor. All fields except `input` and
/// `output` are guarded by the host mutex.
pub struct TerminalSession {
  id : String
  workspace_id : String
  input : @aqueue.Queue[@workspace.TerminalInput]
  output : @aqueue.Queue[@workspace.TerminalEvent]
  transcript : Ref[String]
  cursor : Ref[Int32]
  eof : Ref[Bool]
  task : @async.Task[Unit]
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
  port : Int32,
  store : @machines.MachineStore,
  trust : @recipes.TrustStore,
  verifier : @recipes.VerifierProbe,
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
    group: Ref(None),
    terminals: Map([]),
    agent_sessions: Map([]),
    agent_transcripts: Map([]),
    chat_runtime_sessions: Map([]),
    runtime_agent_launchers: Map([]),
    runtime_primary: Ref(None),
    runtime_policy_snapshot: Ref(None),
    runtime_server: Ref(None),
    runtime_machines: Map([]),
    runtime_workspace_roots: options.runtime_workspace_roots,
    runtime_wait_ms: options.runtime_wait_ms,
    runtime_approval_ttl_ms: options.runtime_approval_ttl_ms,
    dispatching: Ref(false),
    trigger_enabled: options.trigger_enabled,
    trigger_buckets: Map([]),
    credential_enabled: options.credential_enabled,
    credential_store: @credentials.CredentialStore::open(
      options.state_dir + "/credentials",
      requested=options.credential_storage,
    ),
    credential_lease_ttl_ms: options.credential_lease_ttl_ms,
    credential_cooldown_ms: options.credential_cooldown_ms,
    credential_proxies: Map([]),
    credential_cooldowns: Map([]),
    credential_ports: Map([]),
    webhook_inflight: Map([]),
    webhook_audit: Map([]),
    trust,
    verifier,
    skill_enabled: options.skill_enabled,
    host_exe: options.host_exe,
    skill_keys: @skills.SkillKeyStore::empty(),
    skill_capabilities: Map([]),
    skill_waiters: Map([]),
    skill_rate: Map([]),
    environment_mutex: @async.Mutex::Mutex(),
    env_exec_cache: Map([]),
    env_exec_tasks: Map([]),
    env_create_started: Map([]),
    test_fail_approval_consumption: Ref(false),
    runtimes: Map([]),
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
fn HostState::publish(
  self : HostState,
  event : @contracts.EventEnvelope,
) -> Unit {
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
      println(
        "monexus-host: cannot persist event " +
        event.event_type +
        ": " +
        message,
      )
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
/// Append a credential event and its metadata projection in one transaction.
/// The payload and both records are secret-free by construction: the platform
/// store owns secrets, SQLite only mirrors ids, versions and fingerprints.
/// Caller holds `mutex`.
fn HostState::append_credential_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  credential : @contracts.CredentialRecord?,
  binding : @contracts.CredentialBinding?,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_credential_event(event, credential, binding) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append a workspace event and its projection in one transaction.
fn HostState::append_workspace_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.WorkspaceRecord?,
  removed_id : String?,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_workspace_event(event, record, removed_id) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
fn HostState::append_worktree_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.WorktreeRecord?,
  removed_id : String?,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_worktree_event(event, record, removed_id) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
fn HostState::append_lease_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.LeaseRecord?,
  released_id : String?,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_lease_event(event, record, released_id) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append an agent session event and its projection in one transaction.
fn HostState::append_agent_session_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.AgentSessionRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_agent_session_event(event, record) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append a Decision event and its projection in one transaction.
fn HostState::append_decision_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.DecisionRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_decision_event(event, record) {
    Ok(_) => {
      let _ = self.store.search_index(
        "decision/" + record.id,
        "decision",
        record.id,
        record.title,
        record.title + "\n" + record.detail + "\n" + record.answer_text,
        record.created_at,
      )
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append an Artifact event and its projection in one transaction.
fn HostState::append_artifact_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.ArtifactRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_artifact_event(event, record) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|

///|
/// Append an environment event and its projection in one transaction. A
/// destroyed record is passed with `removed_id = Some(id)` so the projection
/// is tombstoned; create retries still find the original record.
fn HostState::append_environment_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.EnvironmentRecord?,
  removed_id : String?,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_environment_event(event, record, removed_id) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append a recipe event and its projection in one transaction. Refused
/// imports are audit-only (`record = None`); they never become usable.
fn HostState::append_recipe_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.RecipeRecord?,
  refused : Bool,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_recipe_event(event, record, refused) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
const RING_CAPACITY : Int32 = 256

///|
const CACHE_CAPACITY : Int32 = 512

///|
/// Serialize an event as an `events.event` JSON-RPC notification.
fn event_notification_text(event : @contracts.EventEnvelope) -> String {
  let params : Map[String, @json.Json] = Map([("event", event.to_json())])
  @contracts.RpcNotification::new(@contracts.NOTIFICATION_EVENTS_EVENT, params)
  .to_json()
  .stringify()
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
fn HostState::register_sink(
  self : HostState,
  queue : @aqueue.Queue[String],
) -> Sink {
  let sink = { queue, subscribed: Ref(false), closed: Ref(false), }
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
fn HostState::replay_after(
  self : HostState,
  since : Int64,
) -> Array[@contracts.EventEnvelope] {
  let out : Array[@contracts.EventEnvelope] = []
  for event in self.ring {
    if event.seq > since {
      out.push(event)
    }
  }
  out
}

///|
/// Append a Project event and its projection in one transaction.
fn HostState::append_project_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.ProjectRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_project_event(event, record) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append a Task event and its projection in one transaction.
fn HostState::append_task_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.TaskRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_task_event(event, record) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append a Run event and its projection in one transaction.
fn HostState::append_run_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.RunRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_run_event(event, record) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}

///|
/// Append an Evidence event and its projection (evidence row + owning run)
/// in one transaction.
fn HostState::append_evidence_event(
  self : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  record : @contracts.EvidenceRecord,
  run : @contracts.RunRecord,
) -> Result[@contracts.EventEnvelope, String] {
  let event = self.next_envelope(event_type, subject, payload)
  match self.store.record_evidence_event(event, record, run) {
    Ok(_) => {
      self.publish(event)
      Ok(event)
    }
    Err(message) => Err(message)
  }
}
