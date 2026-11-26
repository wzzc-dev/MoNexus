///|
/// Agent runtime provider: one ACP stdio sidecar per session (ADR-0005).
///
/// The provider owns the process and the stdio pipes. It deliberately does
/// not own session metadata, permissions or memory: the host records those
/// (architecture §6.3). The ACP shape follows the M0 spike
/// (`spikes/m0/services/acp_client`, Apache-2.0 MoUI reference): initialize →
/// session/new (or session/load when the adapter declares `loadSession`), then
/// one `session/prompt` per user turn. A line-oriented stdout adapter is kept
/// as an explicit fallback; it has no protocol-level readiness handshake.

///|
pub const DEFAULT_ACP_PACKAGE : String = "@zed-industries/claude-code-acp@0.16.2"

///|
/// Timeout applied to the ACP handshake (initialize + session/new). `npx` may
/// need to download the adapter on first use, so the default is generous.
pub fn agent_timeout_ms() -> Int {
  match @env.get_env_var("MONEXUS_ACP_TIMEOUT_MS") {
    Some(value) => {
      let parsed = @string.parse_int(value.trim()) catch { _ => 0 }
      if parsed > 0 { parsed } else { 60_000 }
    }
    None => 60_000
  }
}

///|
pub fn default_acp_command() -> String {
  "npx"
}

///|
pub fn default_acp_args() -> Array[String] {
  ["-y", DEFAULT_ACP_PACKAGE]
}

///|
pub(all) struct AgentSpec {
  agent_id : String
  mode : String
  command : String
  args : Array[String]
  cwd : String
  env : Map[String, String]
  /// Non-secret node-local credential identity for a runtime launch. `env`
  /// carries proxy coordinates only; the real upstream credential stays in the
  /// platform store (local) or on the node (remote).
  credential : RemoteCredential?
}

///|
pub fn AgentSpec::new(
  agent_id~ : String,
  mode~ : String = @contracts.AGENT_MODE_ACP,
  command~ : String = "",
  args~ : Array[String] = [],
  cwd~ : String = "",
  env~ : Map[String, String] = Map([]),
  credential~ : RemoteCredential? = None,
) -> AgentSpec {
  { agent_id, mode, command, args, cwd, env, credential, }
}

///|
/// The fixed host environment an agent child may inherit. Everything else —
/// model keys, cloud credentials, SSH agent sockets — is absent by
/// construction; scoped values (`MONEXUS_CREDENTIAL_PROXY_*`) are passed
/// explicitly in `AgentSpec::env`. `CLAUDECODE` is intentionally absent.
pub fn local_agent_base_env() -> Map[String, String] {
  let env : Map[String, String] = Map([])
  for name in [
    "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL", "TERM",
  ] {
    match @env.get_env_var(name) {
      Some(value) => env.set(name, value)
      None => ()
    }
  }
  env
}

///|
/// Resolve the configured command against PATH. `@process.spawn` does not
/// search PATH on Linux, so the host must resolve `npx` (or any bare name)
/// before spawning. Commands containing `/` are used as-is when they exist.
pub async fn resolve_command(command : String) -> String? {
  let name = command.trim().to_owned()
  if name == "" {
    return None
  }
  if name.contains("/") {
    let found = @fs.exists(name) catch { _ => false }
    if found { Some(name) } else { None }
  } else {
    let path = match @env.get_env_var("PATH") {
      Some(value) => value
      None => return None
    }
    for raw in path.split(":") {
      let dir = raw.trim()
      if dir == "" {
        continue
      }
      let candidate = if dir.ends_with("/") {
        dir.to_owned() + name
      } else {
        dir.to_owned() + "/" + name
      }
      let found = @fs.exists(candidate) catch { _ => false }
      if found {
        return Some(candidate)
      }
    }
    None
  }
}

///|
/// The executable and argv a local spawn actually uses. `env -u CLAUDECODE`
/// strips the variable the Claude Code adapter uses to detect a nested
/// invocation; M0 found the real adapter refuses to run with it set. The
/// launcher owns the remote variant; this entry point stays local-only for
/// readiness probes and for callers that predate the ProcessLauncher split.
pub async fn spawn_command(
  mode : String,
  command : String,
  args : Array[String],
) -> Result[(String, Array[String]), String] {
  local_agent_argv(mode, command, args)
}

///|
pub(all) enum RuntimeMessage {
  JsonMessage(@json.Json)
  Line(String)
  Eof
}

///|
/// A spawned ACP/stdout process. The writer is shared with the host's RPC
/// handlers; `write_lock` keeps two replies from interleaving in one pipe
/// write. The pump owns `reader`; the host owns the session metadata. The
/// launcher is retained so an EOF can be classified without asking the caller
/// which transport it used.
pub struct AgentProcess {
  transport : AgentTransport
  launcher : ProcessLauncher
  write_lock : @async.Mutex
  next_id : Ref[Int]
  closed : Ref[Bool]
}

///|
/// Bounded, offset-addressed remote stdio reader. Bytes are accumulated until
/// a newline so a UTF-8 sequence split across chunks is never decoded
/// mid-codepoint; an evicted ring range (`gap`/`dropped`) or an oversized line
/// is a permanent protocol error, never silently skipped.
struct RemoteByteReader {
  offset : Ref[Int64]
  buffer : Array[Byte]
  eof : Ref[Bool]
  total_bytes : Ref[Int64]
  broken : Ref[String]
}

///|
fn remote_reader() -> RemoteByteReader {
  {
    offset: Ref(0L),
    buffer: [],
    eof: Ref(false),
    total_bytes: Ref(0L),
    broken: Ref(""),
  }
}

///|
/// One streaming process on a paired runtime node.
struct RemoteProcess {
  api : RemoteApi
  run_id : String
  pid : Int
  stdout : RemoteByteReader
  stderr : RemoteByteReader
  cancel_sent : Ref[Bool]
}

///|
/// The transport behind one ACP stdio session. Local and SSH launches use OS
/// pipes; a runtime launch polls `runtime.process.stdout|stderr` by offset.
/// Everything above this enum still sees only `AgentProcess`.
pub(all) enum AgentTransport {
  Local(@process.WriteToProcess, @process.ReadFromProcess, @process.Process)
  Remote(RemoteProcess)
}

///|
/// A single stdout/stderr line is bounded. ACP frames are far smaller; this is
/// a safety ceiling against a misbehaving adapter, not a protocol limit.
pub const MAX_REMOTE_AGENT_LINE_BYTES : Int = 1_048_576

///|
pub fn AgentProcess::pid(self : AgentProcess) -> Int {
  match self.transport {
    AgentTransport::Local(_, _, process) => process.pid.to_int()
    AgentTransport::Remote(remote) => remote.pid
  }
}

///|
/// Which transport spawned this process. Used by the session pump to apply the
/// ADR-0011 remote EOF semantics to SSH launches only; local launches keep
/// their existing EOF behavior.
pub fn AgentProcess::is_ssh(self : AgentProcess) -> Bool {
  match self.launcher {
    ProcessLauncher::Ssh(_) => true
    ProcessLauncher::Local | ProcessLauncher::Runtime(_) => false
  }
}

///|
/// True when the process runs on a paired runtime node. The pump applies
/// ADR-0011 semantics to runtime EOFs: no reattach exists in A1, a lost
/// transport or missing exit record is `lost`, and a node-observed non-lost
/// exit mid-turn is `interrupted`. No runtime EOF is ever success.
pub fn AgentProcess::is_runtime(self : AgentProcess) -> Bool {
  match self.launcher {
    ProcessLauncher::Runtime(_) => true
    ProcessLauncher::Local | ProcessLauncher::Ssh(_) => false
  }
}

///|
/// Bounded observation of the child's exit status after EOF. `try_wait` never
/// blocks; if the status is not ready yet, retry for about 2 s, then report
/// "unknown" (`None`) so a broken transport can never park the host forever.
/// A process killed by a signal returns the negative signal number.
pub async fn AgentProcess::exit_status(self : AgentProcess) -> Int? {
  let process = match self.transport {
    AgentTransport::Local(_, _, process) => process
    AgentTransport::Remote(_) => return None
  }
  let mut attempts = 0
  while attempts < 40 {
    let observed = process.try_wait() catch { _ => return None }
    match observed {
      Some(value) => return Some(value.to_int())
      None => ()
    }
    attempts = attempts + 1
    @async.sleep(50)
  }
  None
}

///|
/// One bounded observation of a remote process's terminal record. `None` means
/// the node had no live record (lost); an `Err` means the transport could not
/// answer, which the pump also treats as lost. Never retries with a second
/// start: A1 has no reattach.
pub async fn AgentProcess::remote_exit(self : AgentProcess) -> RemoteExit? {
  match self.transport {
    AgentTransport::Remote(remote) => {
      match (remote.api.exit)() {
        Ok(Some(value)) => Some(value)
        Ok(None) | Err(_) => None
      }
    }
    _ => None
  }
}

///|
/// The first unrecoverable remote stdout condition (`gap`, `dropped`, an
/// oversized line or a transport error), or "" when the stream is intact. A
/// non-empty value always settles the session lost.
pub fn AgentProcess::stream_error(self : AgentProcess) -> String {
  match self.transport {
    AgentTransport::Remote(remote) => remote.stdout.broken.val
    _ => ""
  }
}

///|
pub fn AgentProcess::run_id(self : AgentProcess) -> String {
  match self.transport {
    AgentTransport::Remote(remote) => remote.run_id
    _ => ""
  }
}

///|
pub async fn AgentProcess::write_line(
  self : AgentProcess,
  line : String,
) -> Bool {
  self.write_lock.acquire()
  defer self.write_lock.release()
  if self.closed.val {
    return false
  }
  match self.transport {
    AgentTransport::Local(writer, _, _) =>
      writer.write(line + "\n") catch {
        _ => {
          self.closed.val = true
          return false
        }
      }
    AgentTransport::Remote(remote) =>
      match (remote.api.write_stdin)(@utf8.encode(line + "\n")) {
        Ok(_) => ()
        Err(_) => {
          self.closed.val = true
          return false
        }
      }
  }
  true
}

///|
pub async fn AgentProcess::write_json(
  self : AgentProcess,
  value : @json.Json,
) -> Bool {
  self.write_line(value.stringify())
}

///|
pub fn AgentProcess::next_id(self : AgentProcess, prefix : String) -> String {
  let next = self.next_id.val + 1
  self.next_id.val = next
  prefix + "-" + next.to_string()
}

///|
/// One raw stdout line, parsed when it is valid JSON. Malformed lines are
/// returned as `Line` so a stdout adapter (or a stray log line) still reaches
/// the transcript instead of vanishing.
pub async fn AgentProcess::next_message(self : AgentProcess) -> RuntimeMessage {
  match self.transport {
    AgentTransport::Local(_, reader, _) =>
      while true {
        let line = reader.read_until("\n") catch {
          _ => return RuntimeMessage::Eof
        }
        let text = match line {
          Some(value) => value
          None => return RuntimeMessage::Eof
        }
        match parse_agent_line(text) {
          Some(message) => return message
          None => continue
        }
      } nobreak {
        RuntimeMessage::Eof
      }
    AgentTransport::Remote(remote) => self.remote_next_message(remote)
  }
}

///|
/// Parse one raw stdout line, dropping blank lines. Kept separate so both the
/// pipe and remote readers use exactly the same JSON/line rules.
fn parse_agent_line(text : String) -> RuntimeMessage? {
  let clean = text.trim().to_owned()
  if clean == "" {
    return None
  }
  let parsed = @json.parse(clean) catch {
    _ => return Some(RuntimeMessage::Line(clean))
  }
  Some(RuntimeMessage::JsonMessage(parsed))
}

///|
async fn AgentProcess::remote_next_message(
  self : AgentProcess,
  remote : RemoteProcess,
) -> RuntimeMessage {
  while true {
    match remote_take_line(remote.stdout) {
      Some(text) =>
        match parse_agent_line(text) {
          Some(message) => return message
          None => ()
        }
      None => {
        if remote.stdout.broken.val != "" || remote.stdout.eof.val {
          return RuntimeMessage::Eof
        }
        let chunk = match (remote.api.read_stdout)(remote.stdout.offset.val) {
          Ok(value) => value
          Err(message) => {
            remote_mark_broken(remote.stdout, "stdout read failed: " + message)
            return RuntimeMessage::Eof
          }
        }
        let had_data = chunk.data.length() > 0
        remote_append_chunk(remote.stdout, chunk)
        if !had_data && !remote.stdout.eof.val {
          @async.sleep(5)
        }
      }
    }
  } nobreak {
    RuntimeMessage::Eof
  }
}

///|
fn remote_mark_broken(reader : RemoteByteReader, reason : String) -> Unit {
  if reader.broken.val == "" {
    reader.broken.val = reason
  }
  reader.eof.val = true
}

///|
/// Append one chunk to a bounded line reader. A gap/dropped/offset mismatch is
/// unrecoverable (no reattach in A1); an oversized line is capped instead of
/// growing without bound.
fn remote_append_chunk(reader : RemoteByteReader, chunk : RemoteChunk) -> Unit {
  if chunk.gap {
    remote_mark_broken(reader, "stdout ring gap")
    return
  }
  if chunk.dropped {
    remote_mark_broken(reader, "stdout bytes dropped")
    return
  }
  if chunk.offset != reader.offset.val {
    remote_mark_broken(reader, "stdout offset mismatch")
    return
  }
  reader.total_bytes.val = chunk.total_bytes
  reader.offset.val = chunk.next_offset
  if reader.buffer.length() + chunk.data.length() > MAX_REMOTE_AGENT_LINE_BYTES {
    remote_mark_broken(reader, "agent output line exceeds the cap")
    return
  }
  for index in 0..<chunk.data.length() {
    reader.buffer.push(chunk.data[index])
  }
  if chunk.eof {
    reader.eof.val = true
  }
}

///|
/// Take one newline-terminated line, or the final partial line once EOF is
/// observed. Bytes are decoded only after a complete line is available, so a
/// multi-byte UTF-8 character split across chunks stays intact.
fn remote_take_line(reader : RemoteByteReader) -> String? {
  let mut newline = -1
  for index in 0..<reader.buffer.length() {
    if reader.buffer[index].to_int() == 10 {
      newline = index
      break
    }
  }
  if newline < 0 {
    if reader.eof.val && reader.buffer.length() > 0 {
      let line = reader.buffer[:].to_owned()
      reader.buffer.clear()
      return Some(decode_agent_bytes(line))
    }
    return None
  }
  let line : Array[Byte] = []
  for index in 0..<newline {
    line.push(reader.buffer[index])
  }
  let tail : Array[Byte] = []
  for index in (newline + 1)..<reader.buffer.length() {
    tail.push(reader.buffer[index])
  }
  reader.buffer.clear()
  for byte in tail {
    reader.buffer.push(byte)
  }
  Some(decode_agent_bytes(line))
}

///|
fn decode_agent_bytes(bytes : Array[Byte]) -> String {
  @utf8.decode_lossy(Bytes::from_array(bytes[:])[:], ignore_bom=false)
}

///|
/// Stop the child and close the pipes. Safe to call more than once.
pub async fn AgentProcess::interrupt(self : AgentProcess) -> Unit {
  self.closed.val = true
  match self.transport {
    AgentTransport::Local(writer, reader, process) => {
      writer.close()
      process.cancel()
      reader.close()
    }
    AgentTransport::Remote(remote) => {
      if !remote.cancel_sent.val {
        remote.cancel_sent.val = true
        let _ = (remote.api.cancel)()
      }
    }
  }
}

///|
fn json_id_to_key(id : @json.Json) -> String {
  match id {
    @json.Json::String(value) => value
    @json.Json::Number(value, ..) => value.to_string()
    _ => ""
  }
}

///|
pub fn acp_rpc_request(
  id : String,
  method_name : String,
  params : @json.Json,
) -> @json.Json {
  @contracts.json_object([
    ("jsonrpc", @contracts.json_string("2.0")),
    ("id", @contracts.json_string(id)),
    ("method", @contracts.json_string(method_name)),
    ("params", params),
  ])
}

///|
pub fn acp_rpc_result(id : @json.Json, result : @json.Json) -> @json.Json {
  @contracts.json_object([
    ("jsonrpc", @contracts.json_string("2.0")),
    ("id", id),
    ("result", result),
  ])
}

///|
pub fn acp_rpc_error(
  id : @json.Json,
  code : Int,
  message : String,
) -> @json.Json {
  @contracts.json_object([
    ("jsonrpc", @contracts.json_string("2.0")),
    ("id", id),
    ("error",
     @contracts.json_object([
       ("code", @contracts.json_int(code)),
       ("message", @contracts.json_string(message)),
     ])),
  ])
}

///|
pub fn acp_initialize_params() -> @json.Json {
  @contracts.json_object([
    ("protocolVersion", @contracts.json_int(1)),
    (
      "clientInfo",
      @contracts.json_object([
        ("name", @contracts.json_string("monexus-host")),
        ("version", @contracts.json_string("0.4.0-m4")),
      ]),
    ),
    (
      "clientCapabilities",
      @contracts.json_object([
        (
          "fs",
          @contracts.json_object([
            ("readTextFile", @contracts.json_bool(false)),
            ("writeTextFile", @contracts.json_bool(false)),
          ]),
        ),
        ("terminal", @contracts.json_bool(false)),
      ]),
    ),
  ])
}

///|
pub fn acp_new_session_params(cwd : String) -> @json.Json {
  acp_new_session_params_with(cwd, @contracts.json_array([]))
}

///|
/// Same `session/new` parameters with an explicit MCP server list. The host
/// passes only its own stdio skill gateway; skill-provided servers are never
/// registered.
pub fn acp_new_session_params_with(
  cwd : String,
  mcp_servers : @json.Json,
) -> @json.Json {
  @contracts.json_object([
    ("cwd", @contracts.json_string(cwd)),
    ("mcpServers", mcp_servers),
    ("additionalDirectories", @contracts.json_array([])),
  ])
}

///|
pub fn acp_load_session_params(session_id : String, cwd : String) -> @json.Json {
  @contracts.json_object([
    ("sessionId", @contracts.json_string(session_id)),
    ("cwd", @contracts.json_string(cwd)),
    ("mcpServers", @contracts.json_array([])),
  ])
}

///|
pub fn acp_prompt_params(session_id : String, text : String) -> @json.Json {
  @contracts.json_object([
    ("sessionId", @contracts.json_string(session_id)),
    (
      "prompt",
      @contracts.json_array([
        @contracts.json_object([
          ("type", @contracts.json_string("text")),
          ("text", @contracts.json_string(text)),
        ]),
      ]),
    ),
  ])
}

///|
pub fn acp_permission_result(option_id : String) -> @json.Json {
  @contracts.json_object([
    (
      "outcome",
      @contracts.json_object([
        ("outcome", @contracts.json_string("selected")),
        ("optionId", @contracts.json_string(option_id)),
      ]),
    ),
  ])
}

///|
/// `session/cancel` is a client→agent notification (no id): it asks the
/// adapter to abandon the current turn. Sending it before closing the process
/// is what makes `agent.stop` a cooperative cancel rather than a silent kill.
pub fn acp_cancel_params(session_id : String) -> @json.Json {
  @contracts.json_object([("sessionId", @contracts.json_string(session_id))])
}

///|
pub fn acp_cancel_notification(session_id : String) -> @json.Json {
  @contracts.json_object([
    ("jsonrpc", @contracts.json_string("2.0")),
    ("method", @contracts.json_string("session/cancel")),
    ("params", acp_cancel_params(session_id)),
  ])
}

///|
pub fn acp_cancelled_result() -> @json.Json {
  @contracts.json_object([
    ("outcome",
     @contracts.json_object([("outcome", @contracts.json_string("cancelled"))])),
  ])
}

///|
/// Text of one ACP content block. Non-text blocks are JSON-stringified so the
/// transcript shows something meaningful rather than silently dropping them.
pub fn json_content_text(value : @json.Json) -> String {
  match value {
    @json.Json::Object(fields) =>
      match @contracts.string_field(fields, "type") {
        Some("text") =>
          match fields.get("text") {
            Some(@json.Json::String(text)) => text
            _ => ""
          }
        _ => value.stringify()
      }
    _ => value.stringify()
  }
}

///|
/// Send one request and read until its response. Notifications are ignored
/// (the handshake has no state to update); agent→client requests are answered
/// with "unsupported" or "cancelled" so the adapter never hangs. The caller
/// wraps this in a timeout.
pub async fn AgentProcess::request(
  self : AgentProcess,
  method_name : String,
  params : @json.Json,
) -> Result[@json.Json, String] {
  let request_id = self.next_id("m4")
  if !self.write_json(acp_rpc_request(request_id, method_name, params)) {
    return Err("cannot write " + method_name + " to agent")
  }
  while true {
    match self.next_message() {
      RuntimeMessage::Eof =>
        return Err("agent closed stdout before responding to " + method_name)
      RuntimeMessage::Line(_) => ()
      RuntimeMessage::JsonMessage(value) => {
        let fields = match @contracts.as_object(value) {
          Some(object) => object
          None => continue
        }
        match fields.get("method") {
          Some(@json.Json::String(incoming)) => {
            let id = match fields.get("id") {
              Some(value) => value
              None => continue
            }
            let reply = if incoming == "session/request_permission" {
              acp_rpc_result(id, acp_cancelled_result())
            } else {
              acp_rpc_error(
                id,
                -32601,
                "unsupported ACP client method: " + incoming,
              )
            }
            ignore(self.write_json(reply))
            continue
          }
          _ => ()
        }
        let id = match fields.get("id") {
          Some(value) => json_id_to_key(value)
          None => continue
        }
        if id != request_id {
          continue
        }
        match fields.get("error") {
          Some(error) => return Err("ACP error response: " + error.stringify())
          None => ()
        }
        match fields.get("result") {
          Some(result) => return Ok(result)
          None => return Err("ACP response has no result")
        }
      }
    }
  } nobreak {
    Err("ACP request loop ended")
  }
}

///|
pub(all) struct AcpSessionInfo {
  acp_session_id : String
  agent_name : String
  agent_version : String
  protocol_version : Int
  load_session : Bool
  auth : String
  auth_methods : Int
}

///|
pub async fn acp_initialize(
  process : AgentProcess,
) -> Result[AcpSessionInfo, String] {
  let result = match process.request("initialize", acp_initialize_params()) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let object = match @contracts.as_object(result) {
    Some(value) => value
    None => return Err("initialize result is not an object")
  }
  let agent_info = match object.get("agentInfo") {
    Some(@json.Json::Object(fields)) => fields
    _ => Map([])
  }
  let capabilities = match object.get("agentCapabilities") {
    Some(@json.Json::Object(fields)) => fields
    _ => Map([])
  }
  let auth_count = match object.get("authMethods") {
    Some(@json.Json::Array(items)) => items.length()
    _ => 0
  }
  Ok({
    acp_session_id: "",
    agent_name: @contracts.string_field_or(agent_info, "name", "unknown"),
    agent_version: @contracts.string_field_or(agent_info, "version", ""),
    protocol_version: @contracts.int_field_or(object, "protocolVersion", 1),
    load_session: @contracts.bool_field_or(capabilities, "loadSession", false),
    auth: if auth_count > 0 { "available" } else { "local-account" },
    auth_methods: auth_count,
  })
}

///|
pub async fn acp_new_session(
  process : AgentProcess,
  cwd : String,
) -> Result[String, String] {
  acp_new_session_with(process, cwd, @contracts.json_array([]))
}

///|
/// `session/new` with the host-owned MCP gateway list. Default callers keep
/// the historical empty list.
pub async fn acp_new_session_with(
  process : AgentProcess,
  cwd : String,
  mcp_servers : @json.Json,
) -> Result[String, String] {
  let result = match
    process.request("session/new", acp_new_session_params_with(cwd, mcp_servers)) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let object = match @contracts.as_object(result) {
    Some(value) => value
    None => return Err("session/new result is not an object")
  }
  match @contracts.string_field(object, "sessionId") {
    Some(id) if id != "" => Ok(id)
    _ => Err("session/new response has no sessionId")
  }
}

///|
pub async fn acp_load_session(
  process : AgentProcess,
  session_id : String,
  cwd : String,
) -> Result[Unit, String] {
  match
    process.request(
      "session/load",
      acp_load_session_params(session_id, cwd),
    ) {
    Ok(_) => Ok(())
    Err(message) => Err(message)
  }
}

///|
fn looks_like_auth_failure(text : String) -> Bool {
  let lower = text.to_lower()
  lower.contains("authentication") ||
  lower.contains("auth required") ||
  lower.contains("unauthorized") ||
  lower.contains("login") ||
  lower.contains("api key") ||
  lower.contains("credentials")
}

///|
pub fn classify_readiness_failure(message : String) -> String {
  if looks_like_auth_failure(message) {
    "required"
  } else {
    "unknown"
  }
}

///|
async fn drain_stderr(
  reader : @process.ReadFromProcess,
  on_line : async (String) -> Unit,
) -> Unit {
  defer reader.close()
  while true {
    let line = reader.read_until("\n") catch { _ => return }
    let text = match line {
      Some(value) => value
      None => break
    }
    let clean = text.trim(chars="\r\n").to_owned()
    if clean != "" {
      on_line(clean)
    }
  }
}

///|
/// Drain a remote process's stderr by offset. A broken/evicted stderr stream
/// only stops the drain: stderr is diagnostic and never settles the session.
/// Lines are passed through the same host redaction callback as SSH/local.
async fn drain_remote_stderr(
  remote : RemoteProcess,
  on_line : async (String) -> Unit,
) -> Unit {
  while true {
    match remote_take_line(remote.stderr) {
      Some(text) => {
        let clean = text.trim(chars="\r\n").to_owned()
        if clean != "" {
          on_line(clean)
        }
      }
      None => {
        if remote.stderr.broken.val != "" || remote.stderr.eof.val {
          return
        }
        let chunk = match (remote.api.read_stderr)(remote.stderr.offset.val) {
          Ok(value) => value
          Err(message) => {
            remote_mark_broken(
              remote.stderr,
              "stderr read failed: " + message,
            )
            return
          }
        }
        let had_data = chunk.data.length() > 0
        remote_append_chunk(remote.stderr, chunk)
        if !had_data && !remote.stderr.eof.val {
          @async.sleep(20)
        }
      }
    }
  } nobreak {
    ()
  }
}

///|
/// Spawn one agent process inside `group` through `launcher`. The caller keeps
/// the task group alive for as long as the session should live; `no_wait=false`
/// ties the process lifetime to that group.
///
/// The ACP code above this boundary sees the same `AgentProcess` either way:
/// local launches exec the adapter directly; SSH launches a local `ssh -T`
/// client whose stdin/stdout carry the protocol and whose stderr stays a
/// separate pipe. Only a local launch receives `spec.env`: an SSH launch must
/// let the remote machine use its own login/runtime, and the host never copies
/// credentials to it.
pub async fn[G] spawn_agent(
  group : @async.TaskGroup[G],
  spec : AgentSpec,
  on_stderr : async (String) -> Unit,
  launcher~ : ProcessLauncher = ProcessLauncher::Local,
) -> Result[AgentProcess, String] {
  match launcher {
    ProcessLauncher::Runtime(remote) => {
      // A runtime launch sends only argv and a node-rooted cwd. `spec.env` is
      // deliberately ignored: the node supplies its own minimal environment
      // and login credentials, and the primary ships no model keys, private
      // keys or ~/.ssh. CLAUDECODE is absent from the node allowlist, so the
      // nested-invocation rule holds without an `env -u` wrapper.
      let (command, effective_args) = match
        effective_agent_command(spec.mode, spec.command, spec.args) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      let argv : Array[String] = [command]
      for arg in effective_args {
        argv.push(arg)
      }
      let started = match
        (remote.start)(
          RemoteStartSpec::new(
            argv~,
            cwd=spec.cwd.trim().to_owned(),
            risk="",
            credential=spec.credential,
          ),
        ) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      let remote_process : RemoteProcess = {
        api: started.api,
        run_id: started.run_id,
        pid: started.pid,
        stdout: remote_reader(),
        stderr: remote_reader(),
        cancel_sent: Ref(false),
      }
      ignore(
        group.spawn(no_wait=true, allow_failure=true) <| () => {
          drain_remote_stderr(remote_process, on_line => on_stderr(on_line))
        },
      )
      return Ok({
        transport: AgentTransport::Remote(remote_process),
        launcher,
        write_lock: @async.Mutex::Mutex(),
        next_id: Ref(0),
        closed: Ref(false),
      })
    }
    _ => ()
  }
  let (argv0, argv, cwd) = match
    launch_argv(launcher, spec.mode, spec.command, spec.args, spec.cwd) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let is_ssh = match launcher {
    ProcessLauncher::Ssh(_) => true
    ProcessLauncher::Local | ProcessLauncher::Runtime(_) => false
  }
  // Never inherit the host's whole environment: a model key or an SSH agent
  // socket in the host process must not reach the child. Only a fixed base
  // allowlist is read from the host; `spec.env` adds the scoped proxy
  // coordinates (local) and is deliberately dropped for an SSH launch.
  let extra_env = local_agent_base_env()
  if !is_ssh {
    for name, value in spec.env {
      extra_env.set(name, value)
    }
  }
  let stdin_pair = @process.write_to_process() catch {
    _ => return Err("cannot create stdin pipe")
  }
  let (stdin_input, writer) = stdin_pair
  let stdout_pair = @process.read_from_process() catch {
    _ => return Err("cannot create stdout pipe")
  }
  let (reader, stdout_output) = stdout_pair
  let stderr_pair = @process.read_from_process() catch {
    _ => return Err("cannot create stderr pipe")
  }
  let (stderr_reader, stderr_output) = stderr_pair
  let process = if cwd == "" {
    @process.spawn(
      group,
      argv0,
      argv,
      extra_env=extra_env,
      inherit_env=false,
      stdin=stdin_input,
      stdout=stdout_output,
      stderr=stderr_output,
    )
  } else {
    @process.spawn(
      group,
      argv0,
      argv,
      extra_env=extra_env,
      inherit_env=false,
      stdin=stdin_input,
      stdout=stdout_output,
      stderr=stderr_output,
      cwd=cwd,
    )
  }
  ignore(
    group.spawn(no_wait=true, allow_failure=true) <| () => {
      drain_stderr(stderr_reader, on_line => on_stderr(on_line))
    },
  )
  Ok({
    transport: AgentTransport::Local(writer, reader, process),
    launcher,
    write_lock: @async.Mutex::Mutex(),
    next_id: Ref(0),
    closed: Ref(false),
  })
}

///|
/// Build a failed readiness record from a base record.
fn readiness_failure(
  base : @contracts.AgentReadiness,
  error : String,
  auth : String,
  detail : String,
) -> @contracts.AgentReadiness {
  {
    ..base,
    ok: false,
    error,
    auth,
    detail,
    checked_at: @contracts.format_rfc3339(@async.now()),
  }
}

///|
async fn probe_handshake(
  process : AgentProcess,
  cwd : String,
) -> Result[AcpSessionInfo, String] {
  let info = match acp_initialize(process) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let effective_cwd = if cwd.trim() == "" {
    match @env.current_dir() {
      Some(value) => value
      None => "."
    }
  } else {
    cwd.trim().to_owned()
  }
  let session_id = match acp_new_session(process, effective_cwd) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({ ..info, acp_session_id: session_id })
}

///|
async fn probe_acp(base : @contracts.AgentReadiness, spec : AgentSpec) -> @contracts.AgentReadiness {
  let timeout_ms = agent_timeout_ms()
  @async.with_task_group(async fn(group) {
    let process = match spawn_agent(group, spec, async fn(_line) { () }) {
      Ok(value) => value
      Err(message) =>
        return readiness_failure(base, "SpawnFailed", "unknown", message)
    }
    let handshake = @async.with_timeout_opt(timeout_ms, async fn() {
      probe_handshake(process, spec.cwd)
    })
    process.interrupt()
    match handshake {
      Some(Ok(info)) => {
        {
          ..base,
          ok: true,
          acp_version: info.protocol_version.to_string(),
          agent_name: info.agent_name,
          agent_version: info.agent_version,
          load_session: info.load_session,
          auth: info.auth,
          detail: "ACP initialize + session/new ok; auth methods: " +
          info.auth_methods.to_string(),
          checked_at: @contracts.format_rfc3339(@async.now()),
        }
      }
      Some(Err(message)) => {
        let auth = classify_readiness_failure(message)
        readiness_failure(base, message, auth, "ACP handshake failed")
      }
      None =>
        readiness_failure(
          base,
          "handshake timed out after " + timeout_ms.to_string() + "ms",
          "unknown",
          "initialize/session-new did not complete",
        )
    }
  })
}

///|
/// Readiness for one agent spec. ACP mode performs a real initialize +
/// session/new handshake; stdout mode only verifies that the executable
/// resolves, because a line-oriented CLI has no handshake to speak of.
pub async fn probe_agent(spec : AgentSpec) -> @contracts.AgentReadiness {
  let mode = if spec.mode == "" {
    @contracts.AGENT_MODE_ACP
  } else {
    spec.mode
  }
  let configured = if spec.command.trim() == "" && mode == @contracts.AGENT_MODE_ACP {
    default_acp_command()
  } else {
    spec.command
  }
  let base = @contracts.AgentReadiness::new(
    ok=false,
    agent_id=spec.agent_id,
    mode=mode,
    command=configured,
  )
  if mode != @contracts.AGENT_MODE_ACP && mode != @contracts.AGENT_MODE_STDOUT {
    return readiness_failure(
      base,
      "unsupported agent mode: " + mode,
      "unknown",
      "supported modes: acp, stdout",
    )
  }
  let resolved = match
    spawn_command(mode, spec.command, spec.args) {
    Ok((_argv0, _argv)) => {
      let name = if configured.trim() == "" {
        default_acp_command()
      } else {
        configured.trim().to_owned()
      }
      match resolve_command(name) {
        Some(value) => value
        None =>
          return readiness_failure(
            base,
            "executable not found: " + name,
            "unknown",
            "check PATH or set an absolute command",
          )
      }
    }
    Err(message) =>
      return readiness_failure(base, message, "unknown", "spawn setup failed")
  }
  let with_resolved = {
    ..base,
    resolved_command: resolved,
    checked_at: @contracts.format_rfc3339(@async.now()),
  }
  if mode == @contracts.AGENT_MODE_STDOUT {
    return {
      ..with_resolved,
      ok: true,
      auth: "unknown",
      detail: "stdout adapter: executable found (no ACP handshake)",
      checked_at: @contracts.format_rfc3339(@async.now()),
    }
  }
  let spec_with_resolved = { ..spec, mode, }
  probe_acp(with_resolved, spec_with_resolved)
}
