///|
/// Small JSON-RPC / ACP helpers.
///
/// Shape source: MoUI `examples/mo_workbench/acp_native_transport`
/// (`acp_protocol.mbt`), Apache-2.0. This spike builds JSON through the
/// public `Json::object` / `Json::string` / ... constructors of the bundled
/// core-json, so it does not rely on the literal syntax or on enum
/// constructors being writable.
pub fn json_object(pairs : Array[(String, Json)]) -> Json {
  let fields : Map[String, Json] = Map([])
  for pair in pairs {
    fields.set(pair.0, pair.1)
  }
  Json::object(fields)
}

///|
pub fn json_string_field(
  fields : Map[String, Json],
  key : String,
) -> String? {
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
pub fn json_id_to_key(id : Json) -> String {
  match id {
    Json::String(value) => value
    Json::Number(value, ..) => value.to_string()
    _ => ""
  }
}

///|
pub fn acp_rpc_request(
  id : String,
  method_name : String,
  params : Json,
) -> Json {
  json_object([
    ("jsonrpc", Json::string("2.0")),
    ("id", Json::string(id)),
    ("method", Json::string(method_name)),
    ("params", params),
  ])
}

///|
pub fn acp_rpc_result(id : Json, result : Json) -> Json {
  json_object([
    ("jsonrpc", Json::string("2.0")),
    ("id", id),
    ("result", result),
  ])
}

///|
pub fn acp_rpc_error(id : Json, code : Int, message : String) -> Json {
  json_object([
    ("jsonrpc", Json::string("2.0")),
    ("id", id),
    ("error",
     json_object([
       ("code", Json::number(code.to_double())),
       ("message", Json::string(message)),
     ])),
  ])
}

///|
/// ACP `initialize` params. The spike advertises no client-side fs or
/// terminal capability: the host owns tool execution, not the editor
/// (architecture §6.3).
pub fn acp_initialize_params() -> Json {
  json_object([
    ("protocolVersion", Json::number(1.0)),
    (
      "clientInfo",
      json_object([
        ("name", Json::string("monexus-host-m0")),
        ("version", Json::string("0.0.1-m0")),
      ]),
    ),
    (
      "clientCapabilities",
      json_object([
        (
          "fs",
          json_object([
            ("readTextFile", Json::boolean(false)),
            ("writeTextFile", Json::boolean(false)),
          ]),
        ),
        ("terminal", Json::boolean(false)),
      ]),
    ),
  ])
}

///|
pub fn acp_new_session_params(cwd : String) -> Json {
  json_object([
    ("cwd", Json::string(cwd)),
    ("mcpServers", Json::array([])),
    ("additionalDirectories", Json::array([])),
  ])
}

///|
pub fn acp_prompt_params(session_id : String, prompt : String) -> Json {
  json_object([
    ("sessionId", Json::string(session_id)),
    (
      "prompt",
      Json::array([
        json_object([
          ("type", Json::string("text")),
          ("text", Json::string(prompt)),
        ]),
      ]),
    ),
  ])
}

///|
/// Text of one ACP content block. Non-text blocks are stringified so the
/// spike log still shows what arrived instead of silently dropping it.
pub fn json_content_text(value : Json) -> String {
  match value {
    Json::Object(fields) =>
      match json_string_field(fields, "type") {
        Some("text") =>
          match fields.get("text") {
            Some(Json::String(text)) => text
            _ => ""
          }
        _ => value.stringify()
      }
    _ => value.stringify()
  }
}
