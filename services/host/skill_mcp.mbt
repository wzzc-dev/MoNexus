///|
/// Host-owned stdio MCP gateway (ADR-0015 §6.2).
///
/// `monexus-host skill-mcp --state-dir DIR --session ID` with the session
/// capability token in `MONEXUS_SKILL_TOKEN`. It exposes exactly one tool,
/// `skill.invoke`, whose only argument is `entry_id`. The host does the policy,
/// permission and Decision work; this process only relays bounded JSON-RPC.

///|
async fn mcp_write(value : @json.Json) -> Unit {
  let text = value.stringify()
  @stdio.stdout.write(text + "\n") catch { _ => () }
}

///|
fn mcp_response(id : @json.Json, result : @json.Json) -> @json.Json {
  @contracts.json_object([
    ("jsonrpc", @contracts.json_string("2.0")),
    ("id", id),
    ("result", result),
  ])
}

///|
fn mcp_error(id : @json.Json, code : Int, message : String) -> @json.Json {
  @contracts.json_object([
    ("jsonrpc", @contracts.json_string("2.0")),
    ("id", id),
    ("error", @contracts.json_object([
      ("code", @contracts.json_int(code)),
      ("message", @contracts.json_string(message)),
    ])),
  ])
}

///|
fn mcp_text_result(text : String, is_error : Bool) -> @json.Json {
  @contracts.json_object([
    ("content", @contracts.json_array([
      @contracts.json_object([
        ("type", @contracts.json_string("text")),
        ("text", @contracts.json_string(text)),
      ]),
    ])),
    ("isError", @contracts.json_bool(is_error)),
  ])
}

///|
async fn mcp_call_tools(client : @client.RpcClient, token : String) -> @json.Json {
  let params : Map[String, @json.Json] = Map([
    ("token", @contracts.json_string(token)),
  ])
  let id = @contracts.new_id("mcp", @async.now())
  match client.call_json(id, @contracts.METHOD_SKILL_TOOLS, params) {
    Ok(result) =>
      match @contracts.as_object(result) {
        Some(object) =>
          match object.get("tools") {
            Some(value) => value
            None => @contracts.json_array([])
          }
        None => @contracts.json_array([])
      }
    Err(_) => @contracts.json_array([])
  }
}

///|
async fn mcp_call_invoke(
  client : @client.RpcClient,
  token : String,
  entry_id : String,
) -> @json.Json {
  let params : Map[String, @json.Json] = Map([
    ("token", @contracts.json_string(token)),
    ("entry_id", @contracts.json_string(entry_id)),
  ])
  let id = @contracts.new_id("mcp", @async.now())
  match client.call_json(id, @contracts.METHOD_SKILL_INVOKE, params) {
    Ok(result) =>
      match @contracts.as_object(result) {
        Some(object) =>
          match object.get("invocation") {
            Some(invocation) =>
              match @contracts.as_object(invocation) {
                Some(fields) => {
                  let output = @contracts.string_field_or(fields, "output", "")
                  let exit_code = @contracts.int_field_or(fields, "exit_code", -1)
                  let truncated = @contracts.bool_field_or(fields, "truncated", false)
                  let note = if truncated {
                    "\n[output truncated]\n"
                  } else {
                    ""
                  }
                  let text = output +
                    note +
                    "\n(exit_code=" +
                    exit_code.to_string() +
                    ")"
                  mcp_text_result(text, exit_code != 0)
                }
                None => mcp_text_result("skill invocation returned a malformed result", true)
              }
            None => mcp_text_result("skill invocation returned no result", true)
          }
        None => mcp_text_result("skill invocation returned a malformed result", true)
      }
    Err(message) => mcp_text_result(message, true)
  }
}

///|
async fn mcp_handle_line(
  client : @client.RpcClient,
  token : String,
  line : String,
) -> Unit {
  let json = @json.parse(line) catch { _ => return }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return
  }
  let id = match object.get("id") {
    Some(value) => value
    None => return
  }
  let method = @contracts.string_field_or(object, "method", "")
  match method {
    "initialize" => {
      let capabilities = @contracts.json_object([
        ("tools", @contracts.json_object([])),
      ])
      let server_info = @contracts.json_object([
        ("name", @contracts.json_string("monexus-skill-gateway")),
        ("version", @contracts.json_string(@contracts.PRODUCT_VERSION)),
      ])
      mcp_write(
        mcp_response(
          id,
          @contracts.json_object([
            ("protocolVersion", @contracts.json_string("2024-11-05")),
            ("capabilities", capabilities),
            ("serverInfo", server_info),
          ]),
        ),
      )
    }
    "ping" => mcp_write(mcp_response(id, @contracts.json_object([])))
    "tools/list" => {
      let tools = mcp_call_tools(client, token)
      mcp_write(
        mcp_response(
          id,
          @contracts.json_object([("tools", tools)]),
        ),
      )
    }
    "tools/call" => {
      let params = match object.get("params") {
        Some(@json.Json::Object(fields)) => fields
        _ => Map([])
      }
      let name = @contracts.string_field_or(params, "name", "")
      let args = match params.get("arguments") {
        Some(@json.Json::Object(fields)) => fields
        _ => Map([])
      }
      let entry_id = @contracts.string_field_or(args, "entry_id", "")
      if name != @contracts.SKILL_INVOKE_TOOL || entry_id == "" {
        mcp_write(
          mcp_response(
            id,
            mcp_text_result(
              "skill.invoke accepts exactly one argument: entry_id",
              true,
            ),
          ),
        )
      } else {
        let result = mcp_call_invoke(client, token, entry_id)
        mcp_write(mcp_response(id, result))
      }
    }
    _ => mcp_write(mcp_error(id, -32601, "method not found: " + method))
  }
}

///|
async fn skill_mcp_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(
    pairs,
    "--state-dir",
    @client.default_state_dir(),
  )
  let session_id = pair_last(pairs, "--session", "")
  let token = match @env.get_env_var("MONEXUS_SKILL_TOKEN") {
    Some(value) if value != "" => value
    _ => ""
  }
  if token == "" {
    return (2, "monexus-host skill-mcp: MONEXUS_SKILL_TOKEN is required")
  }
  let info = match @client.read_host_info(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host skill-mcp: " + message)
  }
  let client = match @client.connect(info) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host skill-mcp: " + message)
  }
  // The session id is informational for logs only; authorization is the
  // capability token, which the host binds to one session.
  ignore(session_id)
  for ;; {
    let line = @stdio.stdin.read_until("\n") catch { _ => break }
    let value = match line {
      Some(text) => text
      None => break
    }
    mcp_handle_line(client, token, value)
  }
  client.close()
  (0, "")
}
