///|
/// Bounded node-side idempotency cache.
///
/// The primary has a durable `(runtime_id, client_request_id)` result cache,
/// but a response can be lost when the connection drops after the node
/// executed the request. The node therefore keeps its own small cache:
/// a replay with the same `client_request_id` returns the recorded result
/// without touching the runtime core again.
///
/// Only results that fit the transport frame comfortably are cached; a large
/// listing result is re-read instead of pinning megabytes in memory. The
/// runtime's own durable `(client_request_id -> run_id)` mapping is the
/// authority for exec starts and PTY opens, so eviction here is safe.

///|
pub const MAX_CACHED_RESULTS : Int = 64

///|
pub const MAX_CACHED_RESULT_CHARS : Int = 16_384

///|
pub struct IdempotencyCache {
  entries : Map[String, @json.Json]
  order : Array[String]
}

///|
pub fn IdempotencyCache::new() -> IdempotencyCache {
  { entries: Map([]), order: [], }
}

///|
fn cache_key(rpc_method : String, client_request_id : String) -> String {
  rpc_method + "|" + client_request_id
}

///|
pub fn IdempotencyCache::lookup(
  self : IdempotencyCache,
  rpc_method : String,
  client_request_id : String,
) -> @json.Json? {
  if client_request_id == "" {
    return None
  }
  self.entries.get(cache_key(rpc_method, client_request_id))
}

///|
pub fn IdempotencyCache::remember(
  self : IdempotencyCache,
  rpc_method : String,
  client_request_id : String,
  value : @json.Json,
) -> Unit {
  if client_request_id == "" {
    return
  }
  if value.stringify().length() > MAX_CACHED_RESULT_CHARS {
    return
  }
  let key = cache_key(rpc_method, client_request_id)
  if self.entries.contains(key) {
    self.entries.set(key, value)
    return
  }
  while self.order.length() >= MAX_CACHED_RESULTS {
    let oldest = self.order.remove(0)
    self.entries.remove(oldest)
  }
  self.order.push(key)
  self.entries.set(key, value)
}

///|
pub fn IdempotencyCache::length(self : IdempotencyCache) -> Int {
  self.entries.length()
}
