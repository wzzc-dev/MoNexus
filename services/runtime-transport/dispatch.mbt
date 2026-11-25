///|
/// Handler registration for methods layered on top of the transport.
///
/// A1.2 does not implement exec/fs/PTY/git; A1.2b (or the host) registers those
/// methods here. The transport owns the reserved `runtime.*` methods and
/// refuses to let a handler replace them. Unknown methods always return the
/// stable JSON-RPC `-32601` code.
///
/// Handlers are registered once at startup, before the server begins accepting
/// connections; the registry itself is not synchronized. Dispatch is
/// serialized by the server.

///|
pub(all) struct HandlerRequest {
  runtime_id : String
  session_id : String
  rpc_method : String
  params : Map[String, @json.Json]
  client_request_id : String
}

///|
/// The signature every registered handler implements. Returning `Err` maps
/// directly onto a JSON-RPC error response; `Ok` is cached under
/// `(runtime_id, client_request_id)` when the request carries one, so a retry
/// returns the original result without re-executing.
pub struct HandlerRegistry {
  handlers : Map[
    String,
    async (HandlerRequest) -> Result[@json.Json, @contracts.RpcError],
  ]
}

///|
pub fn HandlerRegistry::new() -> HandlerRegistry {
  { handlers: Map([]) }
}

///|
pub fn HandlerRegistry::register(
  self : HandlerRegistry,
  rpc_method : String,
  handler : async (HandlerRequest) -> Result[@json.Json, @contracts.RpcError],
) -> Result[Unit, String] {
  if rpc_method == "" || rpc_method.length() > MAX_CAPABILITY_LEN {
    return Err("invalid method name")
  }
  if reserved_method(rpc_method) {
    return Err("method is reserved by the transport")
  }
  if self.handlers.contains(rpc_method) {
    return Err("method is already registered")
  }
  self.handlers.set(rpc_method, handler)
  Ok(())
}

///|
pub fn HandlerRegistry::has_handler(self : HandlerRegistry, rpc_method : String) -> Bool {
  self.handlers.contains(rpc_method)
}

///|
pub fn HandlerRegistry::methods(self : HandlerRegistry) -> Array[String] {
  self.handlers.keys().collect()
}

///|
/// The handler function for `method`, if registered. Reserved methods never
/// appear here.
pub fn HandlerRegistry::lookup(
  self : HandlerRegistry,
  rpc_method : String,
) -> Option[
  async (HandlerRequest) -> Result[@json.Json, @contracts.RpcError],
] {
  self.handlers.get(rpc_method)
}

///|
pub fn method_not_found_error(method : String) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_METHOD_NOT_FOUND,
    "method not found: " + clamp_text(method, MAX_CAPABILITY_LEN),
  )
}

///|
pub fn invalid_params_error(message : String) -> @contracts.RpcError {
  @contracts.RpcError::new(@contracts.ERR_INVALID_PARAMS, safe_detail(message))
}
