///|
/// ACP stdio client for the M0 spike: initialize → session/new →
/// session/prompt, with `session/update` notifications streamed to a
/// callback.
///
/// Shape source: MoUI `examples/mo_workbench/acp_native_transport`
/// (`acp_worker.mbt`), Apache-2.0. The spike is deliberately sequential —
/// one request in flight — because it only has to prove the Linux stdio
/// transport; the UI-facing worker in M4 needs the queued/background shape
/// from MoUI, not this one.
pub(all) struct AcpConfig {
  command : String
  args : Array[String]
  cwd : String
  workspace : String
}

///|
pub fn AcpConfig::new(
  command~ : String,
  args~ : Array[String] = [],
  cwd~ : String = "",
  workspace~ : String = ".",
) -> AcpConfig {
  { command, args, cwd, workspace, }
}

///|
pub(all) struct AcpOutcome {
  ok : Bool
  stop_reason : String
  error : String
  session_id : String
  agent_name : String
  streamed_chunks : Int
  updates : Int
  permission_requests : Int
  agent_text : String
}

///|
priv struct AcpSession {
  writer : @process.WriteToProcess
  reader : @process.ReadFromProcess
  process : @process.Process
  on_text : (String) -> Unit
  mut next_id : Int
  mut session_id : String
  mut error : String
  mut chunks : Int
  mut updates : Int
  mut permissions : Int
  mut text : String
  mut agent_name : String
}

///|
fn acp_failure(message : String) -> AcpOutcome {
  {
    ok: false,
    stop_reason: "error",
    error: message,
    session_id: "",
    agent_name: "",
    streamed_chunks: 0,
    updates: 0,
    permission_requests: 0,
    agent_text: "",
  }
}

///|
fn acp_failure_of(session : AcpSession) -> AcpOutcome {
  let error = if session.error == "" {
    "ACP session failed"
  } else {
    session.error
  }
  {
    ok: false,
    stop_reason: "error",
    error,
    session_id: session.session_id,
    agent_name: session.agent_name,
    streamed_chunks: session.chunks,
    updates: session.updates,
    permission_requests: session.permissions,
    agent_text: session.text,
  }
}

///|
fn acp_success_of(
  session : AcpSession,
  stop_reason : String,
) -> AcpOutcome {
  {
    ok: true,
    stop_reason,
    error: "",
    session_id: session.session_id,
    agent_name: session.agent_name,
    streamed_chunks: session.chunks,
    updates: session.updates,
    permission_requests: session.permissions,
    agent_text: session.text,
  }
}

///|
/// Run one full ACP turn. Returns an outcome instead of raising: the caller
/// is a process entry point that needs a printable result either way, and
/// ACP agents fail in many ordinary ways (missing CLI, not logged in,
/// protocol mismatch) that are data, not panics.
pub async fn run_prompt(
  config : AcpConfig,
  prompt : String,
  on_text : (String) -> Unit,
) -> AcpOutcome {
  @async.with_task_group(group => {
    let stdin_pipe = @process.write_to_process() catch {
      _ => return acp_failure("cannot create stdin pipe")
    }
    let (stdin_input, writer) = stdin_pipe
    let stdout_pipe = @process.read_from_process() catch {
      _ => return acp_failure("cannot create stdout pipe")
    }
    let (stdout_reader, stdout_output) = stdout_pipe
    let stderr_pipe = @process.read_from_process() catch {
      _ => return acp_failure("cannot create stderr pipe")
    }
    let (stderr_reader, stderr_output) = stderr_pipe
    let cwd = config.cwd.trim().to_owned()
    let process = if cwd == "" {
      @process.spawn(
        group,
        config.command,
        config.args,
        stdin=stdin_input,
        stdout=stdout_output,
        stderr=stderr_output,
      )
    } else {
      @process.spawn(
        group,
        config.command,
        config.args,
        stdin=stdin_input,
        stdout=stdout_output,
        stderr=stderr_output,
        cwd=cwd,
      )
    }
    ignore(
      group.spawn(no_wait=true, allow_failure=true) <| () => {
        acp_drain_stderr(stderr_reader)
      },
    )
    let session : AcpSession = {
      writer,
      reader: stdout_reader,
      process,
      on_text,
      next_id: 0,
      session_id: "",
      error: "",
      chunks: 0,
      updates: 0,
      permissions: 0,
      text: "",
      agent_name: "",
    }
    let outcome = acp_flow(session, config, prompt)
    session.writer.close()
    session.process.cancel()
    outcome
  })
}

///|
async fn acp_flow(
  session : AcpSession,
  config : AcpConfig,
  prompt : String,
) -> AcpOutcome {
  // 1. initialize
  let initialize_id = acp_next_id(session)
  acp_send(
    session,
    acp_rpc_request(initialize_id, "initialize", acp_initialize_params()),
  )
  let initialize_result = match acp_await(session, initialize_id) {
    Some(result) => result
    None => return acp_failure_of(session)
  }
  match initialize_result {
    Json::Object(fields) =>
      match fields.get("agentInfo") {
        Some(Json::Object(agent)) =>
          match json_string_field(agent, "name") {
            Some(name) => session.agent_name = name
            None => ()
          }
        _ => ()
      }
    _ => ()
  }
  // 2. session/new
  let new_session_id = acp_next_id(session)
  acp_send(
    session,
    acp_rpc_request(
      new_session_id,
      "session/new",
      acp_new_session_params(acp_absolute_dir(config.workspace)),
    ),
  )
  let new_session_result = match acp_await(session, new_session_id) {
    Some(result) => result
    None => return acp_failure_of(session)
  }
  let agent_session_id = match new_session_result {
    Json::Object(fields) =>
      match json_string_field(fields, "sessionId") {
        Some(id) => id
        None => {
          session.error = "session/new response has no sessionId"
          return acp_failure_of(session)
        }
      }
    _ => {
      session.error = "session/new response is not an object"
      return acp_failure_of(session)
    }
  }
  session.session_id = agent_session_id
  // 3. session/prompt — stream updates until the response arrives.
  let prompt_id = acp_next_id(session)
  acp_send(
    session,
    acp_rpc_request(
      prompt_id,
      "session/prompt",
      acp_prompt_params(agent_session_id, prompt),
    ),
  )
  let prompt_result = match acp_await(session, prompt_id) {
    Some(result) => result
    None => return acp_failure_of(session)
  }
  let stop_reason = match prompt_result {
    Json::Object(fields) =>
      match json_string_field(fields, "stopReason") {
        Some(reason) => reason
        None => "unknown"
      }
    _ => "unknown"
  }
  acp_success_of(session, stop_reason)
}

///|
fn acp_next_id(session : AcpSession) -> String {
  session.next_id = session.next_id + 1
  "m0-" + session.next_id.to_string()
}

///|
async fn acp_send(session : AcpSession, message : Json) -> Unit {
  acp_write_line(session, message.stringify())
}

///|
async fn acp_write_line(session : AcpSession, line : String) -> Unit {
  session.writer.write(line + "\n") catch { _ => () }
}

///|
async fn acp_read_message(session : AcpSession) -> Json? {
  while true {
    let line = session.reader.read_until("\n") catch { _ => return None }
    guard line is Some(text) else { return None }
    let clean = text.trim().to_owned()
    if clean == "" {
      continue
    }
    let parsed = @json.parse(clean) catch { _ => continue }
    return Some(parsed)
  } nobreak {
    None
  }
}

///|
/// Read until the response whose id matches `wanted_id`, dispatching
/// notifications and agent→client requests on the way.
async fn acp_await(session : AcpSession, wanted_id : String) -> Json? {
  while true {
    let message = match acp_read_message(session) {
      Some(message) => message
      None => {
        if session.error == "" {
          session.error =
            "agent closed stdout before responding to " + wanted_id
        }
        return None
      }
    }
    guard message is Json::Object(fields) else { continue }
    match fields.get("method") {
      Some(Json::String(method_name)) =>
        acp_handle_incoming(session, method_name, fields)
      _ => {
        let id = match fields.get("id") {
          Some(value) => json_id_to_key(value)
          None => ""
        }
        if id == wanted_id {
          match fields.get("error") {
            Some(error) => {
              session.error = "ACP error response: " + error.stringify()
              return None
            }
            None =>
              match fields.get("result") {
                Some(result) => return Some(result)
                None => {
                  session.error = "ACP response has no result"
                  return None
                }
              }
          }
        }
      }
    }
  } nobreak {
    None
  }
}

///|
async fn acp_handle_incoming(
  session : AcpSession,
  method_name : String,
  fields : Map[String, Json],
) -> Unit {
  let id = match fields.get("id") {
    Some(value) => value
    None => @json.null
  }
  match method_name {
    "session/update" =>
      match fields.get("params") {
        Some(Json::Object(params)) =>
          match params.get("update") {
            Some(Json::Object(update)) => acp_handle_update(session, update)
            _ => ()
          }
        _ => ()
      }
    "session/request_permission" => {
      session.permissions = session.permissions + 1
      // No Decision/收件箱 channel exists in the M0 spike yet
      // (architecture §6.3, §11.2). Refusing is the honest answer: the
      // spike must not silently grant a permission the user never saw.
      let cancelled = json_object([
        ("outcome", json_object([("outcome", Json::string("cancelled"))])),
      ])
      acp_write_line(session, acp_rpc_result(id, cancelled).stringify())
    }
    _ =>
      if json_id_to_key(id) != "" {
        acp_write_line(
          session,
          acp_rpc_error(
            id,
            -32601,
            "unsupported ACP client method: " + method_name,
          ).stringify(),
        )
      }
  }
}

///|
fn acp_handle_update(
  session : AcpSession,
  update : Map[String, Json],
) -> Unit {
  session.updates = session.updates + 1
  match json_string_field(update, "sessionUpdate") {
    Some("agent_message_chunk") => {
      let text = match update.get("content") {
        Some(content) => json_content_text(content)
        None => ""
      }
      session.chunks = session.chunks + 1
      session.text = session.text + text
      (session.on_text)(text)
    }
    Some("agent_thought_chunk") => {
      let text = match update.get("content") {
        Some(content) => json_content_text(content)
        None => ""
      }
      (session.on_text)("[thought] " + text)
    }
    _ => ()
  }
}

///|
async fn acp_drain_stderr(reader : @process.ReadFromProcess) -> Unit {
  defer reader.close()
  while true {
    let line = reader.read_until("\n") catch { _ => return }
    guard line is Some(text) else { break }
    let clean = text.trim(chars="\r\n").to_owned()
    if clean != "" {
      println("[acp stderr] " + clean)
    }
  }
}

///|
fn acp_absolute_dir(path : String) -> String {
  let clean = path.trim().to_owned()
  if clean == "" {
    return @env.current_dir().unwrap_or(".")
  }
  if clean.has_prefix("/") {
    clean
  } else {
    let cwd = @env.current_dir().unwrap_or(".")
    if cwd.has_suffix("/") {
      cwd + clean
    } else {
      cwd + "/" + clean
    }
  }
}
