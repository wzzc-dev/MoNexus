///|
/// JSON-RPC 2.0 framing shared by the host and every client.
///
/// MoNexus keeps the envelope small: request IDs are strings, `params` is
/// always an object, and every request carries `client_request_id` inside
/// `params` for idempotent retries (architecture §7.3).
pub const JSONRPC_VERSION : String = "2.0"

///|
pub const ERR_PARSE : Int = -32700

///|
pub const ERR_INVALID_REQUEST : Int = -32600

///|
pub const ERR_METHOD_NOT_FOUND : Int = -32601

///|
pub const ERR_INVALID_PARAMS : Int = -32602

///|
pub const ERR_INTERNAL : Int = -32603

///|
pub const ERR_HOST : Int = -32000

///|
pub(all) struct RpcError {
  code : Int
  message : String
  data : @json.Json?
}

///|
pub fn RpcError::new(
  code : Int,
  message : String,
  data? : @json.Json,
) -> RpcError {
  { code, message, data, }
}

///|
pub fn RpcError::to_json(self : RpcError) -> @json.Json {
  let entries : Array[(String, @json.Json)] = [
    ("code", json_int(self.code)),
    ("message", json_string(self.message)),
  ]
  match self.data {
    Some(value) => entries.push(("data", value))
    None => ()
  }
  json_object(entries)
}

///|
/// Decode an error object. Unknown extra fields are ignored.
pub fn RpcError::from_json(json : @json.Json) -> RpcError? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let code = match int_field(object, "code") {
    Some(value) => value
    None => return None
  }
  let message = match string_field(object, "message") {
    Some(value) => value
    None => return None
  }
  Some({ code, message, data: object.get("data"), })
}

///|
pub(all) struct RpcRequest {
  id : String
  method : String
  params : Map[String, @json.Json]
}

///|
pub fn RpcRequest::new(
  id : String,
  method : String,
  params : Map[String, @json.Json],
) -> RpcRequest {
  { id, method, params, }
}

///|
pub fn RpcRequest::to_json(self : RpcRequest) -> @json.Json {
  json_object([
    ("jsonrpc", json_string(JSONRPC_VERSION)),
    ("id", json_string(self.id)),
    ("method", json_string(self.method)),
    ("params", @json.Json::object(self.params)),
  ])
}

///|
pub(all) struct RpcNotification {
  method : String
  params : Map[String, @json.Json]
}

///|
pub fn RpcNotification::new(
  method : String,
  params : Map[String, @json.Json],
) -> RpcNotification {
  { method, params, }
}

///|
pub fn RpcNotification::to_json(self : RpcNotification) -> @json.Json {
  json_object([
    ("jsonrpc", json_string(JSONRPC_VERSION)),
    ("method", json_string(self.method)),
    ("params", @json.Json::object(self.params)),
  ])
}

///|
pub(all) struct RpcResponse {
  id : String
  result : @json.Json?
  error : RpcError?
}

///|
pub fn RpcResponse::to_json(self : RpcResponse) -> @json.Json {
  let entries : Array[(String, @json.Json)] = [
    ("jsonrpc", json_string(JSONRPC_VERSION)),
    ("id", json_string(self.id)),
  ]
  match self.error {
    Some(error) => entries.push(("error", error.to_json()))
    None =>
      match self.result {
        Some(result) => entries.push(("result", result))
        None => entries.push(("result", @json.Json::empty_object()))
      }
  }
  json_object(entries)
}

///|
/// Parse a request object. Notifications (no `id`) are not requests and are
/// reported as an error here; the server uses `parse_notification` for them.
pub fn parse_request(json : @json.Json) -> Result[RpcRequest, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("request is not a JSON object")
  }
  match string_field(object, "jsonrpc") {
    Some(version) if version == JSONRPC_VERSION => ()
    Some(version) => return Err("unsupported JSON-RPC version: " + version)
    None => return Err("missing jsonrpc version")
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return Err("request id must be a string")
  }
  let method = match string_field(object, "method") {
    Some(value) => value
    None => return Err("missing method")
  }
  let params = match parse_params(object) {
    Some(value) => value
    None => return Err("params must be an object")
  }
  Ok({ id, method, params, })
}

///|
pub fn parse_notification(json : @json.Json) -> Result[RpcNotification, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("notification is not a JSON object")
  }
  match string_field(object, "jsonrpc") {
    Some(version) if version == JSONRPC_VERSION => ()
    Some(version) => return Err("unsupported JSON-RPC version: " + version)
    None => return Err("missing jsonrpc version")
  }
  if object.contains("id") {
    return Err("notification must not carry an id")
  }
  let method = match string_field(object, "method") {
    Some(value) => value
    None => return Err("missing method")
  }
  let params = match parse_params(object) {
    Some(value) => value
    None => return Err("params must be an object")
  }
  Ok({ method, params, })
}

///|
pub fn parse_response(json : @json.Json) -> Result[RpcResponse, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("response is not a JSON object")
  }
  match string_field(object, "jsonrpc") {
    Some(version) if version == JSONRPC_VERSION => ()
    Some(version) => return Err("unsupported JSON-RPC version: " + version)
    None => return Err("missing jsonrpc version")
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return Err("response id must be a string")
  }
  let error = match object.get("error") {
    Some(value) => match RpcError::from_json(value) {
      Some(error) => Some(error)
      None => return Err("malformed error object")
    }
    None => None
  }
  let result = object.get("result")
  Ok({ id, result, error, })
}

///|
fn parse_params(
  object : Map[String, @json.Json],
) -> Map[String, @json.Json]? {
  match object.get("params") {
    None => Some(Map([]))
    Some(value) => as_object(value)
  }
}

///|
/// True when a parsed JSON value is a JSON-RPC notification frame.
pub fn is_notification(json : @json.Json) -> Bool {
  let object = match as_object(json) {
    Some(value) => value
    None => return false
  }
  object.contains("method") && !object.contains("id")
}

///|
/// Return the idempotency key carried by a request's `params`.
pub fn client_request_id(
  params : Map[String, @json.Json],
) -> String? {
  match string_field(params, "client_request_id") {
    Some(value) if value != "" => Some(value)
    _ => None
  }
}

///|
/// Add the mandatory idempotency key to a params object.
pub fn with_client_request_id(
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Map[String, @json.Json] {
  params.set("client_request_id", json_string(client_request_id))
  params
}

///|
pub fn method_not_found_error(method : String) -> RpcError {
  RpcError::new(ERR_METHOD_NOT_FOUND, "method not found: " + method)
}

///|
pub fn invalid_params_error(message : String) -> RpcError {
  RpcError::new(ERR_INVALID_PARAMS, message)
}
