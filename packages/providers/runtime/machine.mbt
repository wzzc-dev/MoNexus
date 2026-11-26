///|
/// Primary-side runtime machine provider (A1.2b, `kind=runtime`).
///
/// This is the MachineProvider half of the paired-runtime path: it speaks only
/// `runtime.*` JSON-RPC over the live duplex session channel that
/// `PrimaryState::channel_for` exposes. It never opens an ACP connection and
/// never holds ACP types — the machine axis only probes and executes
/// (architecture §6.1, ADR-0012 §3, ADR-0003).
///
/// Wire shapes are the node dispatch contract:
///
/// - `runtime.probe {}` → profile (transport version, capabilities, roots,
///   platform, policy state);
/// - `runtime.exec.start|status|cancel` → `{run, existing}` / `{run}` /
///   `{runs}`;
/// - `runtime.fs.read|write|stat|list` → bounded payloads;
/// - `runtime.pty.open|input|resize|close|status` → `{session, existing}` /
///   `{session_id, accepted}` / `{session}`;
/// - `runtime.git.*` → operation result plus typed list fields.
///
/// Mutating calls always carry `client_request_id`; a replayed request is
/// answered from the primary's durable idempotency cache or the node's cache,
/// so it never re-executes. Results are bounded by the node before they reach
/// the 64 KiB frame ceiling.

///|
fn not_connected_error(runtime_id : String) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_HOST,
    "runtime is not connected to this primary: " + runtime_id,
  )
}

///|
fn invalid_machine_result(message : String) -> @contracts.RpcError {
  @contracts.RpcError::new(@contracts.ERR_INTERNAL, message)
}

///|
/// A paired runtime reachable through `PrimaryState`. Construct once per
/// runtime id; it holds no socket of its own, only the state that owns the
/// live channel, so it survives reconnects.
pub(all) struct RuntimeMachine {
  state : @transport.PrimaryState
  runtime_id : String
  /// Pending owner approvals, keyed by `method|binding id`. The primary keeps
  /// the Decision; this map only remembers the binding (nonce, decision id and
  /// policy version) so a reconnect resumes the same Decision instead of
  /// asking the owner again. It is bounded and holds no argv values.
  pending_approvals : Map[String, PendingApproval]
  pending_order : Array[String]
}

///|
pub const MAX_PENDING_APPROVALS : Int = 64

///|
pub fn RuntimeMachine::new(
  state : @transport.PrimaryState,
  runtime_id : String,
) -> RuntimeMachine {
  {
    state,
    runtime_id,
    pending_approvals: Map([]),
    pending_order: [],
  }
}

///|
pub fn RuntimeMachine::runtime_id(self : RuntimeMachine) -> String {
  self.runtime_id
}

///|
pub fn RuntimeMachine::state(self : RuntimeMachine) -> @transport.PrimaryState {
  self.state
}

///|
/// Whether the runtime currently has a live, unsealed session. Reconnect is
/// driven by the node (exponential backoff); the provider only observes that
/// a fresh channel replaced the old one.
pub fn RuntimeMachine::is_connected(self : RuntimeMachine) -> Bool {
  match self.state.channel_for(self.runtime_id) {
    Some(_) => true
    None => false
  }
}

///|
/// The primary's durable ack cursor for this runtime. A reconnect resumes
/// event delivery after this seq; the tracker resumes after its own last
/// observed seq, which is never behind the ack cursor for events it saw.
pub fn RuntimeMachine::ack_cursor(self : RuntimeMachine) -> Int64 {
  self.state.cursor_for(self.runtime_id)
}

///|
async fn RuntimeMachine::request(
  self : RuntimeMachine,
  rpc_method : String,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let channel = match self.state.channel_for(self.runtime_id) {
    Some(value) => value
    None => return Err(not_connected_error(self.runtime_id))
  }
  // Every mutating method (including PTY control continuations, exec.cancel
  // and git writes) needs the current publication installed and acked. The
  // result must also carry that publication's metadata; an operator-override
  // node therefore cannot report a verified success.
  let mutating = @contracts.runtime_method_mutates(rpc_method)
  let publication : @transport.PolicyAnnouncement? = if mutating {
    match delivered_policy(self, rpc_method) {
      Ok(value) => Some(value)
      Err(reason) =>
        return Err(
          @contracts.RpcError::new(@transport.ERR_POLICY_STALE, reason),
        )
    }
  } else {
    None
  }
  // `client_request_id` is optional at the transport layer; application
  // methods that need it validate it themselves.
  // Streaming stdout/stderr/exit reads are polled several times per second by
  // the agent layer; auditing each poll would flood the durable audit trail
  // without adding safety information. Mutating calls are always audited.
  let quiet = rpc_method == @contracts.METHOD_RUNTIME_PROCESS_STDOUT ||
    rpc_method == @contracts.METHOD_RUNTIME_PROCESS_STDERR ||
    rpc_method == @contracts.METHOD_RUNTIME_PROCESS_EXIT
  let result = channel.request(rpc_method, params)
  if !quiet {
    match result {
      Ok(_) =>
        self.state.record_audit(
          "runtime.request",
          self.runtime_id,
          "ok",
          "method=" + rpc_method,
        )
      Err(error) =>
        self.state.record_audit(
          "runtime.request",
          self.runtime_id,
          "error",
          "method=" +
          rpc_method +
          " code=" +
          error.code.to_string(),
        )
    }
  }
  match result {
    Ok(value) =>
      match publication {
        Some(announcement) =>
          match
            verified_mutation_result(self, rpc_method, value, announcement) {
            Ok(_) => ()
            Err(reason) =>
              return Err(
                @contracts.RpcError::new(@transport.ERR_POLICY_STALE, reason),
              )
          }
        None => ()
      }
    Err(_) => ()
  }
  result
}

///|
async fn RuntimeMachine::request_with_id(
  self : RuntimeMachine,
  rpc_method : String,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Result[@json.Json, @contracts.RpcError] {
  if client_request_id != "" {
    params.set(
      "client_request_id",
      @contracts.json_string(client_request_id),
    )
  }
  self.request(rpc_method, params)
}

// ---------------------------------------------------------------------------
// Probe

///|
pub(all) struct RuntimeProbe {
  runtime_id : String
  transport_version : String
  protocol_version : Int
  capabilities : Array[String]
  workspace_roots : Array[String]
  /// The node user's home. A2.2 derives `~/.monexus/environments/<id>/` from
  /// it; an empty home means the node cannot host environments.
  home : String
  /// The node-owned environment root the primary addresses with
  /// `runtime.fs.*` `root=environments` requests.
  environment_root : String
  os : String
  arch : String
  hostname : String
  policy : String
  policy_version : String
  policy_hash : String
  state_version : Int
}

///|
pub fn RuntimeProbe::to_json(self : RuntimeProbe) -> @json.Json {
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(self.runtime_id)),
    ("transport_version", @contracts.json_string(self.transport_version)),
    ("protocol_version", @contracts.json_int(self.protocol_version)),
    ("capabilities", @contracts.json_string_array(self.capabilities)),
    ("workspace_roots", @contracts.json_string_array(self.workspace_roots)),
    ("home", @contracts.json_string(self.home)),
    ("environment_root", @contracts.json_string(self.environment_root)),
    (
      "platform",
      @contracts.json_object([
        ("os", @contracts.json_string(self.os)),
        ("arch", @contracts.json_string(self.arch)),
        ("hostname", @contracts.json_string(self.hostname)),
      ]),
    ),
    ("policy", @contracts.json_string(self.policy)),
    ("policy_version", @contracts.json_string(self.policy_version)),
    ("policy_hash", @contracts.json_string(self.policy_hash)),
    ("state_version", @contracts.json_int(self.state_version)),
  ])
}

///|
/// Convert the runtime profile to the host's generic machine contract. The
/// runtime's capability list is carried in `notes` because `toolchains` means
/// executable paths on SSH/local machines; runtime capabilities are a
/// different concept.
pub fn RuntimeProbe::machine_profile(
  self : RuntimeProbe,
) -> @contracts.MachineProfile {
  let roots = if self.workspace_roots.is_empty() {
    ""
  } else {
    " workspace_roots=" + self.workspace_roots.join(",")
  }
  let notes = "runtime " +
    self.runtime_id +
    " transport=" +
    self.transport_version +
    " protocol=" +
    self.protocol_version.to_string() +
    " policy=" +
    self.policy +
    " capabilities=" +
    self.capabilities.join(",") +
    roots
  let mut has_docker = false
  for capability in self.capabilities {
    if capability == "docker" {
      has_docker = true
    }
  }
  @contracts.MachineProfile::new(
    arch=self.arch,
    os=self.os,
    hostname=self.hostname,
    shell="",
    toolchains=Map([]),
    has_docker~,
    has_gui=false,
    max_parallel=1,
    notes=notes,
  )
}

///|
fn bounded_string_array(
  object : Map[String, @json.Json],
  key : String,
  max_items : Int,
  max_len : Int,
) -> Array[String] {
  match object.get(key) {
    Some(@json.Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        if out.length() >= max_items {
          break
        }
        match @contracts.as_string(item) {
          Some(text) =>
            if text.length() > max_len {
              out.push(text[:max_len].to_owned())
            } else {
              out.push(text)
            }
          None => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
pub fn RuntimeProbe::from_json(json : @json.Json) -> RuntimeProbe? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let platform = match object.get("platform") {
    Some(value) => @contracts.as_object(value)
    None => None
  }
  let platform_object = match platform {
    Some(value) => value
    None => Map([])
  }
  let runtime_id = @contracts.string_field_or(object, "runtime_id", "")
  if runtime_id == "" {
    return None
  }
  Some({
    runtime_id,
    transport_version: @contracts.string_field_or(
      object,
      "transport_version",
      "",
    ),
    protocol_version: @contracts.int_field_or(object, "protocol_version", 0),
    capabilities: bounded_string_array(object, "capabilities", 32, 64),
    workspace_roots: bounded_string_array(object, "workspace_roots", 16, 4096),
    home: @contracts.string_field_or(object, "home", ""),
    environment_root: @contracts.string_field_or(object, "environment_root", ""),
    os: @contracts.string_field_or(platform_object, "os", ""),
    arch: @contracts.string_field_or(platform_object, "arch", ""),
    hostname: @contracts.string_field_or(platform_object, "hostname", ""),
    policy: @contracts.string_field_or(object, "policy", ""),
    policy_version: @contracts.string_field_or(object, "policy_version", ""),
    policy_hash: @contracts.string_field_or(object, "policy_hash", ""),
    state_version: @contracts.int_field_or(object, "state_version", 0),
  })
}

///|
/// `runtime.probe` — no side effects, no ACP. The node answers this from its
/// own runtime host state.
pub async fn RuntimeMachine::probe(
  self : RuntimeMachine,
) -> Result[RuntimeProbe, @contracts.RpcError] {
  let value = self.request(@transport.METHOD_PROBE, Map([]))
  let json = match value {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match RuntimeProbe::from_json(json) {
    Some(profile) => Ok(profile)
    None => Err(invalid_machine_result("runtime.probe returned an invalid profile"))
  }
}

// ---------------------------------------------------------------------------
// Exec

///|
pub(all) struct RunSnapshot {
  run_id : String
  client_request_id : String
  status : String
  exit_code : Int?
  signal : Int?
  stop_reason : String
  ended_at : String
  timed_out : Bool
  stdout_bytes : Int64
  stderr_bytes : Int64
}

///|
pub fn RunSnapshot::from_json(json : @json.Json) -> RunSnapshot? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let run_id = @contracts.string_field_or(object, "run_id", "")
  if run_id == "" {
    return None
  }
  Some({
    run_id,
    client_request_id: @contracts.string_field_or(
      object,
      "client_request_id",
      "",
    ),
    status: @contracts.string_field_or(object, "status", ""),
    exit_code: @contracts.int_field(object, "exit_code"),
    signal: @contracts.int_field(object, "signal"),
    stop_reason: @contracts.string_field_or(object, "stop_reason", ""),
    ended_at: @contracts.string_field_or(object, "ended_at", ""),
    timed_out: @contracts.bool_field_or(object, "timed_out", false),
    stdout_bytes: @contracts.int64_field_or(object, "stdout_bytes", 0L),
    stderr_bytes: @contracts.int64_field_or(object, "stderr_bytes", 0L),
  })
}

///|
pub fn RunSnapshot::is_terminal(self : RunSnapshot) -> Bool {
  @contracts.run_status_is_terminal(self.status) ||
  self.status == @contracts.RUN_STATUS_LOST
}

///|
pub async fn RuntimeMachine::exec_start(
  self : RuntimeMachine,
  run_id~ : String,
  client_request_id~ : String,
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Map[String, String] = Map([]),
  inherit_env~ : Array[String] = [],
  timeout_ms~ : Int = 0,
  risk~ : String = "",
  stdin~ : String? = None,
  max_output_bytes~ : Int = 0,
) -> Result[(RunSnapshot, Bool), @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("argv", @contracts.json_string_array(argv))
  if cwd != "" {
    params.set("cwd", @contracts.json_string(cwd))
  }
  if !env.is_empty() {
    let entries : Array[(String, @json.Json)] = []
    for name, value in env {
      entries.push((name, @contracts.json_string(value)))
    }
    params.set("env", @contracts.json_object(entries))
  }
  if !inherit_env.is_empty() {
    params.set("inherit_env", @contracts.json_string_array(inherit_env))
  }
  if timeout_ms > 0 {
    params.set("timeout_ms", @contracts.json_int(timeout_ms))
  }
  if risk != "" {
    params.set("risk", @contracts.json_string(risk))
  }
  match stdin {
    Some(value) => params.set("stdin", @contracts.json_string(value))
    None => ()
  }
  if max_output_bytes > 0 {
    params.set("max_output_bytes", @contracts.json_int(max_output_bytes))
  }
  let value = self.request_with_id(
    @contracts.METHOD_RUNTIME_EXEC_START,
    params,
    client_request_id,
  )
  let json = match value {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("exec.start returned a non-object"))
  }
  let existing = @contracts.bool_field_or(object, "existing", false)
  let run_json = match object.get("run") {
    Some(value) => value
    None => return Err(invalid_machine_result("exec.start returned no run"))
  }
  let run = match RunSnapshot::from_json(run_json) {
    Some(value) => value
    None => return Err(invalid_machine_result("exec.start returned an invalid run"))
  }
  Ok((run, existing))
}

///|
pub async fn RuntimeMachine::exec_status(
  self : RuntimeMachine,
  run_id : String,
) -> Result[RunSnapshot?, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  let json = match self.request(@contracts.METHOD_RUNTIME_EXEC_STATUS, params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("exec.status returned a non-object"))
  }
  match object.get("run") {
    Some(@json.Json::Null) => Ok(None)
    Some(value) => Ok(RunSnapshot::from_json(value))
    None => Err(invalid_machine_result("exec.status returned no run"))
  }
}

///|
pub async fn RuntimeMachine::exec_cancel(
  self : RuntimeMachine,
  run_id : String,
  client_request_id~ : String,
) -> Result[RunSnapshot, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  let json = match
    self.request_with_id(
      @contracts.METHOD_RUNTIME_EXEC_CANCEL,
      params,
      client_request_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("exec.cancel returned a non-object"))
  }
  let run = match object.get("run") {
    Some(value) => value
    None => return Err(invalid_machine_result("exec.cancel returned no run"))
  }
  match RunSnapshot::from_json(run) {
    Some(value) => Ok(value)
    None => Err(invalid_machine_result("exec.cancel returned an invalid run"))
  }
}

///|
pub(all) struct ExecOutputSlice {
  run_id : String
  stream : String
  offset : Int64
  data : String
  bytes : Int64
  eof : Bool
  log_bytes : Int64
}

///|
pub fn ExecOutputSlice::from_json(json : @json.Json) -> ExecOutputSlice? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let run_id = match @contracts.string_field(object, "run_id") {
    Some(value) => value
    None => return None
  }
  Some({
    run_id,
    stream: @contracts.string_field_or(object, "stream", "stdout"),
    offset: @contracts.int64_field_or(object, "offset", 0L),
    data: @contracts.string_field_or(object, "data", ""),
    bytes: @contracts.int64_field_or(object, "bytes", 0L),
    eof: @contracts.bool_field_or(object, "eof", true),
    log_bytes: @contracts.int64_field_or(object, "log_bytes", 0L),
  })
}

///|
/// `runtime.exec.read` — a bounded slice of a run's stdout/stderr log. The
/// primary reads output only after the run reaches a terminal status, so the
/// slice is stable.
pub async fn RuntimeMachine::exec_read(
  self : RuntimeMachine,
  run_id~ : String,
  stream~ : String = "stdout",
  offset~ : Int64 = 0L,
  max_bytes~ : Int = 0,
) -> Result[ExecOutputSlice, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("stream", @contracts.json_string(stream))
  params.set("offset", @contracts.json_int64(offset))
  if max_bytes > 0 {
    params.set("max_bytes", @contracts.json_int(max_bytes))
  }
  let json = match self.request(@contracts.METHOD_RUNTIME_EXEC_READ, params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ExecOutputSlice::from_json(json) {
    Some(value) => Ok(value)
    None => Err(invalid_machine_result("exec.read returned an invalid slice"))
  }
}

// ---------------------------------------------------------------------------
// Streaming process (A1.4)

///|
/// A streaming process as reported by `runtime.process.*`. It is not an ACP
/// type: it carries only lifecycle fields, the node-resolved cwd and byte
/// counts. The ACP layer sits above this provider and receives a stdio handle.
pub(all) struct ProcessSnapshot {
  run_id : String
  client_request_id : String
  status : String
  risk : String
  pid : Int
  cwd : String
  started_at : String
  ended_at : String
  exit_code : Int?
  signal : Int?
  stop_reason : String
  stdout_bytes : Int64
  stderr_bytes : Int64
  timed_out : Bool
  stdout_dropped : Bool
  stderr_dropped : Bool
  success : Bool
}

///|
pub fn ProcessSnapshot::from_json(json : @json.Json) -> ProcessSnapshot? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let run_id = @contracts.string_field_or(object, "run_id", "")
  if run_id == "" {
    return None
  }
  Some({
    run_id,
    client_request_id: @contracts.string_field_or(
      object,
      "client_request_id",
      "",
    ),
    status: @contracts.string_field_or(object, "status", ""),
    risk: @contracts.string_field_or(object, "risk", ""),
    pid: @contracts.int_field_or(object, "pid", 0),
    cwd: @contracts.string_field_or(object, "cwd", ""),
    started_at: @contracts.string_field_or(object, "started_at", ""),
    ended_at: @contracts.string_field_or(object, "ended_at", ""),
    exit_code: @contracts.int_field(object, "exit_code"),
    signal: @contracts.int_field(object, "signal"),
    stop_reason: @contracts.string_field_or(object, "stop_reason", ""),
    stdout_bytes: @contracts.int64_field_or(object, "stdout_bytes", 0L),
    stderr_bytes: @contracts.int64_field_or(object, "stderr_bytes", 0L),
    timed_out: @contracts.bool_field_or(object, "timed_out", false),
    stdout_dropped: @contracts.bool_field_or(object, "stdout_dropped", false),
    stderr_dropped: @contracts.bool_field_or(object, "stderr_dropped", false),
    success: @contracts.bool_field_or(object, "success", false),
  })
}

///|
pub fn ProcessSnapshot::is_terminal(self : ProcessSnapshot) -> Bool {
  @contracts.run_status_is_terminal(self.status) ||
  self.status == @contracts.RUN_STATUS_LOST
}

///|
pub(all) struct ProcessChunkSnapshot {
  run_id : String
  stream : String
  offset : Int64
  next_offset : Int64
  data_b64 : String
  eof : Bool
  gap : Bool
  dropped : Bool
  total_bytes : Int64
}

///|
pub fn ProcessChunkSnapshot::from_json(
  json : @json.Json,
) -> ProcessChunkSnapshot? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let run_id = @contracts.string_field_or(object, "run_id", "")
  if run_id == "" {
    return None
  }
  Some({
    run_id,
    stream: @contracts.string_field_or(object, "stream", ""),
    offset: @contracts.int64_field_or(object, "offset", 0L),
    next_offset: @contracts.int64_field_or(object, "next_offset", 0L),
    data_b64: @contracts.string_field_or(object, "data", ""),
    eof: @contracts.bool_field_or(object, "eof", false),
    gap: @contracts.bool_field_or(object, "gap", false),
    dropped: @contracts.bool_field_or(object, "dropped", false),
    total_bytes: @contracts.int64_field_or(object, "total_bytes", 0L),
  })
}

///|
/// Non-secret identity of one node-local credential (A5.2). The node compares
/// it with its own enrollment; the secret and session token stay on the node.
pub(all) struct ProcessCredential {
  binding_id : String
  credential_id : String
  machine_id : String
  agent_id : String
  profile : String
  version : Int
  fingerprint : String
}

///|
pub fn ProcessCredential::new(
  binding_id~ : String,
  credential_id~ : String,
  machine_id~ : String,
  agent_id~ : String,
  profile~ : String,
  version~ : Int,
  fingerprint~ : String,
) -> ProcessCredential {
  { binding_id, credential_id, machine_id, agent_id, profile, version, fingerprint, }
}

///|
fn process_credential_json(value : ProcessCredential) -> @json.Json {
  @contracts.json_object([
    ("binding_id", @contracts.json_string(value.binding_id)),
    ("credential_id", @contracts.json_string(value.credential_id)),
    ("machine_id", @contracts.json_string(value.machine_id)),
    ("agent_id", @contracts.json_string(value.agent_id)),
    ("profile", @contracts.json_string(value.profile)),
    ("version", @contracts.json_int(value.version)),
    ("fingerprint", @contracts.json_string(value.fingerprint)),
  ])
}

///|
fn process_start_params(
  run_id : String,
  argv : Array[String],
  cwd : String,
  env : Map[String, String],
  inherit_env : Array[String],
  timeout_ms : Int64,
  risk : String,
  max_output_bytes : Int64,
  credential : ProcessCredential?,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("argv", @contracts.json_string_array(argv))
  if cwd != "" {
    params.set("cwd", @contracts.json_string(cwd))
  }
  if !env.is_empty() {
    let entries : Array[(String, @json.Json)] = []
    for name, value in env {
      entries.push((name, @contracts.json_string(value)))
    }
    params.set("env", @contracts.json_object(entries))
  }
  if !inherit_env.is_empty() {
    params.set("inherit_env", @contracts.json_string_array(inherit_env))
  }
  if timeout_ms > 0L {
    params.set("timeout_ms", @contracts.json_int64(timeout_ms))
  }
  if risk != "" {
    params.set("risk", @contracts.json_string(risk))
  }
  if max_output_bytes > 0L {
    params.set("max_output_bytes", @contracts.json_int64(max_output_bytes))
  }
  match credential {
    Some(value) => params.set("credential", process_credential_json(value))
    None => ()
  }
  params
}

///|
/// Start a streaming process. The exact argv/env payload is classified by the
/// node's policy gate; a high-risk start returns the same approval-required
/// error as `exec.start`, bound to `run_id`.
pub async fn RuntimeMachine::process_start(
  self : RuntimeMachine,
  run_id~ : String,
  client_request_id~ : String,
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Map[String, String] = Map([]),
  inherit_env~ : Array[String] = [],
  timeout_ms~ : Int64 = 0L,
  risk~ : String = "",
  max_output_bytes~ : Int64 = 0L,
  credential~ : ProcessCredential? = None,
) -> Result[(ProcessSnapshot, Bool), @contracts.RpcError] {
  let params = process_start_params(
    run_id,
    argv,
    cwd,
    env,
    inherit_env,
    timeout_ms,
    risk,
    max_output_bytes,
    credential,
  )
  let json = match
    self.request_with_id(
      @contracts.METHOD_RUNTIME_PROCESS_START,
      params,
      client_request_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None =>
      return Err(invalid_machine_result("process.start returned a non-object"))
  }
  let existing = @contracts.bool_field_or(object, "existing", false)
  let process_json = match object.get("process") {
    Some(value) => value
    None => return Err(invalid_machine_result("process.start returned no process"))
  }
  let process = match ProcessSnapshot::from_json(process_json) {
    Some(value) => value
    None =>
      return Err(invalid_machine_result("process.start returned an invalid process"))
  }
  Ok((process, existing))
}

///|
/// Metadata-only lease renewal for one node-local credential (A5.2). The node
/// replies with its local version/fingerprint and a fresh lease deadline; no
/// secret or session token travels in either direction.
pub async fn RuntimeMachine::credential_lease(
  self : RuntimeMachine,
  binding_id~ : String,
  credential_id~ : String,
  machine_id~ : String,
  agent_id~ : String,
  profile~ : String,
  version~ : Int,
  fingerprint~ : String,
  lease_ttl_ms~ : Int64,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  // The node verifies a nested non-secret marker (same shape as
  // `process.start`); it never reads the secret from this frame.
  params.set(
    "credential",
    process_credential_json(
      ProcessCredential::new(
        binding_id~,
        credential_id~,
        machine_id~,
        agent_id~,
        profile~,
        version~,
        fingerprint~,
      ),
    ),
  )
  params.set("lease_ttl_ms", @contracts.json_int64(lease_ttl_ms))
  self.request_with_id(
    @contracts.METHOD_RUNTIME_CREDENTIAL_LEASE,
    params,
    client_request_id,
  )
}

///|
/// Metadata-only revocation signal. The node destroys its local copy before
/// replying; the primary never receives the secret.
pub async fn RuntimeMachine::credential_revoke(
  self : RuntimeMachine,
  binding_id~ : String,
  credential_id~ : String,
  machine_id~ : String,
  agent_id~ : String,
  profile~ : String,
  version~ : Int,
  fingerprint~ : String,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("binding_id", @contracts.json_string(binding_id))
  params.set("credential_id", @contracts.json_string(credential_id))
  params.set("machine_id", @contracts.json_string(machine_id))
  params.set("agent_id", @contracts.json_string(agent_id))
  params.set("profile", @contracts.json_string(profile))
  params.set("version", @contracts.json_int(version))
  params.set("fingerprint", @contracts.json_string(fingerprint))
  self.request_with_id(
    @contracts.METHOD_RUNTIME_CREDENTIAL_REVOKE,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::process_stdin(
  self : RuntimeMachine,
  run_id : String,
  data_b64 : String,
  client_request_id~ : String,
) -> Result[ProcessSnapshot, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("data", @contracts.json_string(data_b64))
  let json = match
    self.request_with_id(
      @contracts.METHOD_RUNTIME_PROCESS_STDIN,
      params,
      client_request_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("process.stdin returned a non-object"))
  }
  let process_json = match object.get("process") {
    Some(value) => value
    None => return Err(invalid_machine_result("process.stdin returned no process"))
  }
  match ProcessSnapshot::from_json(process_json) {
    Some(value) => Ok(value)
    None =>
      Err(invalid_machine_result("process.stdin returned an invalid process"))
  }
}

///|
async fn RuntimeMachine::process_read(
  self : RuntimeMachine,
  rpc_method : String,
  run_id : String,
  offset : Int64,
  max_bytes : Int,
) -> Result[ProcessChunkSnapshot, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("offset", @contracts.json_int64(offset))
  if max_bytes > 0 {
    params.set("max_bytes", @contracts.json_int(max_bytes))
  }
  let json = match self.request(rpc_method, params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result(rpc_method + " returned a non-object"))
  }
  let chunk_json = match object.get("chunk") {
    Some(value) => value
    None => return Err(invalid_machine_result(rpc_method + " returned no chunk"))
  }
  match ProcessChunkSnapshot::from_json(chunk_json) {
    Some(value) => Ok(value)
    None => Err(invalid_machine_result(rpc_method + " returned an invalid chunk"))
  }
}

///|
pub async fn RuntimeMachine::process_stdout(
  self : RuntimeMachine,
  run_id : String,
  offset : Int64,
  max_bytes~ : Int = 0,
) -> Result[ProcessChunkSnapshot, @contracts.RpcError] {
  self.process_read(
    @contracts.METHOD_RUNTIME_PROCESS_STDOUT,
    run_id,
    offset,
    max_bytes,
  )
}

///|
pub async fn RuntimeMachine::process_stderr(
  self : RuntimeMachine,
  run_id : String,
  offset : Int64,
  max_bytes~ : Int = 0,
) -> Result[ProcessChunkSnapshot, @contracts.RpcError] {
  self.process_read(
    @contracts.METHOD_RUNTIME_PROCESS_STDERR,
    run_id,
    offset,
    max_bytes,
  )
}

///|
pub async fn RuntimeMachine::process_exit(
  self : RuntimeMachine,
  run_id : String,
) -> Result[ProcessSnapshot?, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  let json = match self.request(@contracts.METHOD_RUNTIME_PROCESS_EXIT, params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("process.exit returned a non-object"))
  }
  match object.get("process") {
    Some(@json.Json::Null) => Ok(None)
    Some(value) => Ok(ProcessSnapshot::from_json(value))
    None => Err(invalid_machine_result("process.exit returned no process"))
  }
}

///|
pub async fn RuntimeMachine::process_cancel(
  self : RuntimeMachine,
  run_id : String,
  client_request_id~ : String,
) -> Result[ProcessSnapshot, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  let json = match
    self.request_with_id(
      @contracts.METHOD_RUNTIME_PROCESS_CANCEL,
      params,
      client_request_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("process.cancel returned a non-object"))
  }
  let process_json = match object.get("process") {
    Some(value) => value
    None => return Err(invalid_machine_result("process.cancel returned no process"))
  }
  match ProcessSnapshot::from_json(process_json) {
    Some(value) => Ok(value)
    None =>
      Err(invalid_machine_result("process.cancel returned an invalid process"))
  }
}

// ---------------------------------------------------------------------------
// Filesystem

///|
pub async fn RuntimeMachine::fs_read(
  self : RuntimeMachine,
  path~ : String,
  max_bytes~ : Int = 0,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  if max_bytes > 0 {
    params.set("max_bytes", @contracts.json_int(max_bytes))
  }
  self.request(@contracts.METHOD_RUNTIME_FS_READ, params)
}

///|
pub async fn RuntimeMachine::fs_write(
  self : RuntimeMachine,
  path~ : String,
  content~ : String,
  client_request_id~ : String,
  root~ : String = @contracts.RUNTIME_FS_ROOT_WORKSPACE,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  params.set("content", @contracts.json_string(content))
  if root != @contracts.RUNTIME_FS_ROOT_WORKSPACE {
    params.set("root", @contracts.json_string(root))
  }
  self.request_with_id(
    @contracts.METHOD_RUNTIME_FS_WRITE,
    params,
    client_request_id,
  )
}

///|
/// `runtime.fs.mkdir` under a selected root. The node enforces containment;
/// the caller names a rooted-relative path only.
pub async fn RuntimeMachine::fs_mkdir(
  self : RuntimeMachine,
  path~ : String,
  client_request_id~ : String,
  recursive~ : Bool = true,
  root~ : String = @contracts.RUNTIME_FS_ROOT_WORKSPACE,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  params.set("recursive", @contracts.json_bool(recursive))
  if root != @contracts.RUNTIME_FS_ROOT_WORKSPACE {
    params.set("root", @contracts.json_string(root))
  }
  self.request_with_id(
    @contracts.METHOD_RUNTIME_FS_MKDIR,
    params,
    client_request_id,
  )
}

///|
/// `runtime.fs.remove` under a selected root. Missing entries are a success
/// so cleanup is idempotent across a reconnect.
pub async fn RuntimeMachine::fs_remove(
  self : RuntimeMachine,
  path~ : String,
  client_request_id~ : String,
  recursive~ : Bool = false,
  root~ : String = @contracts.RUNTIME_FS_ROOT_WORKSPACE,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  params.set("recursive", @contracts.json_bool(recursive))
  if root != @contracts.RUNTIME_FS_ROOT_WORKSPACE {
    params.set("root", @contracts.json_string(root))
  }
  self.request_with_id(
    @contracts.METHOD_RUNTIME_FS_REMOVE,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::fs_stat(
  self : RuntimeMachine,
  path~ : String,
  root~ : String = @contracts.RUNTIME_FS_ROOT_WORKSPACE,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  if root != @contracts.RUNTIME_FS_ROOT_WORKSPACE {
    params.set("root", @contracts.json_string(root))
  }
  self.request(@contracts.METHOD_RUNTIME_FS_STAT, params)
}

///|
pub async fn RuntimeMachine::fs_list(
  self : RuntimeMachine,
  path~ : String = "",
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  self.request(@contracts.METHOD_RUNTIME_FS_LIST, params)
}

// ---------------------------------------------------------------------------
// PTY

///|
pub(all) struct PtySnapshot {
  session_id : String
  status : String
  running : Bool
  success : Bool
  exit_code : Int?
  output_seq : Int64
  output_dropped : Bool
  log_bytes : Int64
  pid : Int
  rows : Int
  cols : Int
}

///|
pub fn PtySnapshot::from_json(json : @json.Json) -> PtySnapshot? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let session_id = @contracts.string_field_or(object, "session_id", "")
  if session_id == "" {
    return None
  }
  Some({
    session_id,
    status: @contracts.string_field_or(object, "status", ""),
    running: @contracts.bool_field_or(object, "running", false),
    success: @contracts.bool_field_or(object, "success", false),
    exit_code: @contracts.int_field(object, "exit_code"),
    output_seq: @contracts.int64_field_or(object, "output_seq", 0L),
    output_dropped: @contracts.bool_field_or(object, "output_dropped", false),
    log_bytes: @contracts.int64_field_or(object, "log_bytes", 0L),
    pid: @contracts.int_field_or(object, "pid", 0),
    rows: @contracts.int_field_or(object, "rows", 0),
    cols: @contracts.int_field_or(object, "cols", 0),
  })
}

///|
pub async fn RuntimeMachine::pty_open(
  self : RuntimeMachine,
  session_id~ : String,
  client_request_id~ : String,
  argv~ : Array[String],
  cwd~ : String = "",
  env~ : Map[String, String] = Map([]),
  rows~ : Int = 24,
  cols~ : Int = 80,
  workspace_root~ : String = "",
) -> Result[(PtySnapshot, Bool), @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("argv", @contracts.json_string_array(argv))
  if cwd != "" {
    params.set("cwd", @contracts.json_string(cwd))
  }
  if !env.is_empty() {
    let entries : Array[(String, @json.Json)] = []
    for name, value in env {
      entries.push((name, @contracts.json_string(value)))
    }
    params.set("env", @contracts.json_object(entries))
  }
  params.set("rows", @contracts.json_int(rows))
  params.set("cols", @contracts.json_int(cols))
  if workspace_root != "" {
    params.set("workspace_root", @contracts.json_string(workspace_root))
  }
  let json = match
    self.request_with_id(
      @contracts.METHOD_RUNTIME_PTY_OPEN,
      params,
      client_request_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result("pty.open returned a non-object"))
  }
  let existing = @contracts.bool_field_or(object, "existing", false)
  let session = match object.get("session") {
    Some(value) => value
    None => return Err(invalid_machine_result("pty.open returned no session"))
  }
  let info = match PtySnapshot::from_json(session) {
    Some(value) => value
    None => return Err(invalid_machine_result("pty.open returned an invalid session"))
  }
  Ok((info, existing))
}

///|
pub async fn RuntimeMachine::pty_input(
  self : RuntimeMachine,
  session_id~ : String,
  data~ : String,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("data", @contracts.json_string(data))
  self.request_with_id(
    @contracts.METHOD_RUNTIME_PTY_INPUT,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::pty_resize(
  self : RuntimeMachine,
  session_id~ : String,
  rows~ : Int,
  cols~ : Int,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("rows", @contracts.json_int(rows))
  params.set("cols", @contracts.json_int(cols))
  self.request_with_id(
    @contracts.METHOD_RUNTIME_PTY_RESIZE,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::pty_close(
  self : RuntimeMachine,
  session_id : String,
  client_request_id~ : String,
) -> Result[PtySnapshot, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  let json = match
    self.request_with_id(
      @contracts.METHOD_RUNTIME_PTY_CLOSE,
      params,
      client_request_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  pty_session_from_result(json, "pty.close")
}

///|
pub async fn RuntimeMachine::pty_status(
  self : RuntimeMachine,
  session_id : String,
) -> Result[PtySnapshot, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  let json = match self.request(@contracts.METHOD_RUNTIME_PTY_STATUS, params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  pty_session_from_result(json, "pty.status")
}

///|
fn pty_session_from_result(
  json : @json.Json,
  method_name : String,
) -> Result[PtySnapshot, @contracts.RpcError] {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(invalid_machine_result(method_name + " returned a non-object"))
  }
  let session = match object.get("session") {
    Some(value) => value
    None => return Err(invalid_machine_result(method_name + " returned no session"))
  }
  match PtySnapshot::from_json(session) {
    Some(value) => Ok(value)
    None =>
      Err(invalid_machine_result(method_name + " returned an invalid session"))
  }
}

// ---------------------------------------------------------------------------
// Git

///|
async fn RuntimeMachine::git_call(
  self : RuntimeMachine,
  rpc_method : String,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Result[@json.Json, @contracts.RpcError] {
  self.request_with_id(rpc_method, params, client_request_id)
}

///|
pub async fn RuntimeMachine::git_status(
  self : RuntimeMachine,
) -> Result[@json.Json, @contracts.RpcError] {
  self.request(@contracts.METHOD_RUNTIME_GIT_STATUS, Map([]))
}

///|
pub async fn RuntimeMachine::git_diff(
  self : RuntimeMachine,
  path~ : String = "",
  cached~ : Bool = false,
  range~ : String = "",
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  if path != "" {
    params.set("path", @contracts.json_string(path))
  }
  if cached {
    params.set("cached", @contracts.json_bool(cached))
  }
  if range != "" {
    params.set("range", @contracts.json_string(range))
  }
  self.request(@contracts.METHOD_RUNTIME_GIT_DIFF, params)
}

///|
pub async fn RuntimeMachine::git_log(
  self : RuntimeMachine,
  rev~ : String = "",
  max_count~ : Int = 0,
  path~ : String = "",
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  if rev != "" {
    params.set("rev", @contracts.json_string(rev))
  }
  if max_count > 0 {
    params.set("max_count", @contracts.json_int(max_count))
  }
  if path != "" {
    params.set("path", @contracts.json_string(path))
  }
  self.request(@contracts.METHOD_RUNTIME_GIT_LOG, params)
}

///|
pub async fn RuntimeMachine::git_show(
  self : RuntimeMachine,
  rev~ : String,
  path~ : String = "",
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("rev", @contracts.json_string(rev))
  if path != "" {
    params.set("path", @contracts.json_string(path))
  }
  self.request(@contracts.METHOD_RUNTIME_GIT_SHOW, params)
}

///|
pub async fn RuntimeMachine::git_branches(
  self : RuntimeMachine,
) -> Result[@json.Json, @contracts.RpcError] {
  self.request(@contracts.METHOD_RUNTIME_GIT_BRANCHES, Map([]))
}

///|
pub async fn RuntimeMachine::git_branch_create(
  self : RuntimeMachine,
  name~ : String,
  start~ : String = "",
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("name", @contracts.json_string(name))
  if start != "" {
    params.set("start", @contracts.json_string(start))
  }
  self.git_call(
    @contracts.METHOD_RUNTIME_GIT_BRANCH_CREATE,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::git_checkout(
  self : RuntimeMachine,
  branch~ : String,
  create~ : Bool = false,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("branch", @contracts.json_string(branch))
  if create {
    params.set("create", @contracts.json_bool(create))
  }
  self.git_call(
    @contracts.METHOD_RUNTIME_GIT_CHECKOUT,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::git_worktrees(
  self : RuntimeMachine,
) -> Result[@json.Json, @contracts.RpcError] {
  self.request(@contracts.METHOD_RUNTIME_GIT_WORKTREES, Map([]))
}

///|
pub async fn RuntimeMachine::git_worktree_add(
  self : RuntimeMachine,
  path~ : String,
  branch~ : String = "",
  base~ : String = "",
  force~ : Bool = false,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  if branch != "" {
    params.set("branch", @contracts.json_string(branch))
  }
  if base != "" {
    params.set("base", @contracts.json_string(base))
  }
  if force {
    params.set("force", @contracts.json_bool(force))
  }
  self.git_call(
    @contracts.METHOD_RUNTIME_GIT_WORKTREE_ADD,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::git_worktree_remove(
  self : RuntimeMachine,
  path~ : String,
  force~ : Bool = false,
  expected_head~ : String = "",
  expected_branch~ : String = "",
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  if force {
    params.set("force", @contracts.json_bool(force))
  }
  if expected_head != "" {
    params.set("expected_head", @contracts.json_string(expected_head))
  }
  if expected_branch != "" {
    params.set("expected_branch", @contracts.json_string(expected_branch))
  }
  self.git_call(
    @contracts.METHOD_RUNTIME_GIT_WORKTREE_REMOVE,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::git_read_output(
  self : RuntimeMachine,
  op_id~ : String,
  stream~ : String = "stdout",
  offset~ : Int64 = 0L,
  max_bytes~ : Int = 0,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  params.set("op_id", @contracts.json_string(op_id))
  params.set("stream", @contracts.json_string(stream))
  params.set("offset", @contracts.json_int64(offset))
  if max_bytes > 0 {
    params.set("max_bytes", @contracts.json_int(max_bytes))
  }
  self.request(@contracts.METHOD_RUNTIME_GIT_READ_OUTPUT, params)
}

// ---------------------------------------------------------------------------
// Event pump and reconnect reconciliation

///|
/// Feed every accepted event newer than the tracker's cursor into it. Returns
/// the number of events that advanced state (duplicates/late events are
/// dropped). This never executes anything: replay only reads the primary's
/// accepted event tap.
pub fn RuntimeMachine::pump_events(
  self : RuntimeMachine,
  tracker : RunTracker,
) -> Int {
  let events = self.state.events_since(self.runtime_id, tracker.cursor())
  let mut advanced = 0
  for event in events {
    if tracker.observe(event) {
      advanced = advanced + 1
    }
  }
  advanced
}



///|
/// After a reconnect: mark connection restored, pump replayed events from the
/// cursor, then reconcile every run/session that is still non-terminal with a
/// fresh status query. Runs the node still reports as running continue under
/// the same `run_id`; runs without a node record become `lost`. Never settles
/// `succeeded` without a terminal event or status answer.
pub async fn RuntimeMachine::reconcile(
  self : RuntimeMachine,
  tracker : RunTracker,
) -> Result[Unit, @contracts.RpcError] {
  tracker.mark_connection_restored()
  let _ = self.pump_events(tracker)
  if !self.is_connected() {
    return Err(not_connected_error(self.runtime_id))
  }
  let pending : Array[TrackedRun] = []
  for run in tracker.runs() {
    if !run.phase.is_settled() {
      pending.push(run)
    }
  }
  for run in pending {
    if run.is_exec() {
      let snapshot = match self.exec_status(run.run_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match snapshot {
        Some(value) => {
          let _ = tracker.reconcile_status(
            run.run_id,
            value.status,
            value.exit_code,
          )
        }
        None => {
          let _ = tracker.reconcile_status(
            run.run_id,
            @contracts.RUN_STATUS_LOST,
            None,
          )
        }
      }
    } else if run.is_pty() {
      let status = match self.pty_status(run.run_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let _ = tracker.reconcile_pty_status(
        run.run_id,
        status.status,
        status.exit_code,
      )
    } else if run.is_process() {
      // A process exit answer is authoritative. A missing node record means
      // the node restarted and lost the run: settle it `lost`, never success.
      match self.process_exit(run.run_id) {
        Ok(Some(process)) => {
          let _ = tracker.reconcile_process_status(
            run.run_id,
            Some(process.status),
            process.exit_code,
          )
        }
        Ok(None) => {
          let _ = tracker.reconcile_process_status(run.run_id, None, None)
        }
        Err(error) => return Err(error)
      }
    }
  }
  Ok(())
}

///|
/// Mark the tracker interrupted when the live channel is gone. Idempotent;
/// returns the number of runs that transitioned to `interrupted`.
pub fn RuntimeMachine::mark_interrupted(
  self : RuntimeMachine,
  tracker : RunTracker,
) -> Int {
  if self.is_connected() {
    0
  } else {
    tracker.mark_connection_lost()
  }
}
