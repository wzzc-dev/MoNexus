///|
/// Duplex session channel (A1.2b).
///
/// A1.2 fixed the connection direction: the node dials the primary. A1.2b
/// needs the primary to *send* runtime requests (exec/fs/PTY/git) over that
/// same connection, so the session is full duplex over one TLS stream:
///
/// - either side may send a JSON-RPC request frame; the response comes back
///   on the same stream with the same `id`.
/// - all writes are serialized by one mutex, because heartbeats, event acks,
///   drain notifications, handler responses and outbound requests can all be
///   produced by different tasks.
/// - outstanding requests are bounded (`MAX_PENDING_REQUESTS`); each has its
///   own one-slot queue, so a late or duplicate response is dropped rather
///   than mis-delivered.
/// - `close()` marks the channel closed, fails every outstanding request and
///   wakes the connection read loop (which polls `is_closed`). Revocation uses
///   this path, so a revoked runtime cannot be used even if its socket is
///   still open for a few milliseconds.
///
/// The channel never touches the TLS object from a task other than the
/// connection read loop; `close()` only sets flags and drains queues. The read
/// loop owns the stream lifetime.

///|
pub const MAX_PENDING_REQUESTS : Int = 64

///|
/// Bound on one primary→node request. Runtime methods return promptly
/// (`exec.start` spawns and returns; PTY input/resize are immediate), so a
/// missing response is a dead or wedged node, not a slow operation.
pub const CHANNEL_REQUEST_TIMEOUT_MS : Int64 = 30_000

///|
pub suberror ChannelClosed {
  ChannelClosed
}

///|
pub struct SessionChannel {
  runtime_id : String
  session_id : String
  stream : TlsStream
  write_mutex : @async.Mutex
  pending : Map[String, @aqueue.Queue[@contracts.RpcResponse]]
  next_id : Ref[Int]
  /// Terminal: the connection is gone; no writes at all.
  closed : Ref[Bool]
  /// Revoked: outstanding requests fail and no new requests may be issued, but
  /// the connection may still write a final error frame so the peer learns why
  /// it was dropped. A sealed channel is never returned by `channel_for`.
  sealed : Ref[Bool]
}

///|
pub fn SessionChannel::new(
  runtime_id : String,
  session_id : String,
  stream : TlsStream,
) -> SessionChannel {
  {
    runtime_id,
    session_id,
    stream,
    write_mutex: @async.Mutex::Mutex(),
    pending: Map([]),
    next_id: Ref(0),
    closed: Ref(false),
    sealed: Ref(false),
  }
}

///|
pub fn SessionChannel::runtime_id(self : SessionChannel) -> String {
  self.runtime_id
}

///|
pub fn SessionChannel::session_id(self : SessionChannel) -> String {
  self.session_id
}

///|
pub fn SessionChannel::is_closed(self : SessionChannel) -> Bool {
  self.closed.val
}

///|
pub fn SessionChannel::is_sealed(self : SessionChannel) -> Bool {
  self.sealed.val || self.closed.val
}

///|
fn channel_closed_error() -> @contracts.RpcError {
  @contracts.RpcError::new(ERR_REVOKED, "runtime session is not connected")
}

///|
pub async fn SessionChannel::send(
  self : SessionChannel,
  value : @json.Json,
) -> Result[Unit, String] {
  if self.closed.val {
    return Err("runtime session is closed")
  }
  self.write_mutex.acquire()
  defer self.write_mutex.release()
  if self.closed.val {
    return Err("runtime session is closed")
  }
  self.stream.write(value) catch {
    error => return Err(safe_error(error))
  }
  Ok(())
}

///|
pub async fn SessionChannel::notify(
  self : SessionChannel,
  rpc_method : String,
  params : Map[String, @json.Json],
) -> Result[Unit, String] {
  let notification = @contracts.RpcNotification::new(rpc_method, params)
  self.send(notification.to_json())
}

///|
async fn SessionChannel::request_with_timeout(
  self : SessionChannel,
  rpc_method : String,
  params : Map[String, @json.Json],
  timeout_ms : Int64,
) -> Result[@json.Json, @contracts.RpcError] {
  if self.closed.val || self.sealed.val {
    return Err(channel_closed_error())
  }
  if self.pending.length() >= MAX_PENDING_REQUESTS {
    return Err(
      @contracts.RpcError::new(ERR_BUSY, "too many outstanding runtime requests"),
    )
  }
  self.next_id.val = self.next_id.val + 1
  let id = "srv-" + self.next_id.val.to_string()
  let queue : @aqueue.Queue[@contracts.RpcResponse] = @aqueue.Queue(
    kind=@aqueue.Blocking(1),
  )
  self.pending.set(id, queue)
  let request = @contracts.RpcRequest::new(id, rpc_method, params)
  match self.send(request.to_json()) {
    Ok(_) => ()
    Err(_) => {
      self.pending.remove(id)
      return Err(channel_closed_error())
    }
  }
  let attempt : Result[@contracts.RpcResponse, String]? = @async.with_timeout_opt(
    timeout_ms_of(timeout_ms),
    () => {
      let response = queue.get() catch {
        error => return Err(safe_error(error))
      }
      Ok(response)
    },
  )
  match attempt {
    None => {
      self.pending.remove(id)
      Err(
        @contracts.RpcError::new(
          ERR_BUSY,
          "runtime did not answer " + clamp_text(rpc_method, MAX_CAPABILITY_LEN),
        ),
      )
    }
    Some(Err(message)) => Err(
      @contracts.RpcError::new(ERR_BUSY, safe_detail(message)),
    )
    Some(Ok(response)) => match response.error {
      Some(error) => Err(error)
      None =>
        match response.result {
          Some(value) => Ok(value)
          None => Err(
            @contracts.RpcError::new(
              @contracts.ERR_INTERNAL,
              "runtime response has no result",
            ),
          )
        }
    }
  }
}

///|
/// Send one runtime request to the node and await its response. This is the
/// exact seam the primary-side MachineProvider uses.
pub async fn SessionChannel::request(
  self : SessionChannel,
  rpc_method : String,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  self.request_with_timeout(rpc_method, params, CHANNEL_REQUEST_TIMEOUT_MS)
}

///|
/// Answer a request that arrived from the node. A closed channel drops the
/// write; the node times out its own request and reports a lost connection.
pub async fn SessionChannel::respond(
  self : SessionChannel,
  id : String,
  result : @json.Json,
) -> Unit {
  let response : @contracts.RpcResponse = { id, result: Some(result), error: None }
  let _ = self.send(response.to_json())
}

///|
pub async fn SessionChannel::respond_error(
  self : SessionChannel,
  id : String,
  error : @contracts.RpcError,
) -> Unit {
  let response : @contracts.RpcResponse = { id, result: None, error: Some(error) }
  let _ = self.send(response.to_json())
}

///|
/// Deliver a response frame to the task waiting on it. Returns `false` for an
/// unknown, late or duplicate response id; the frame is then ignored rather
/// than corrupting another request's result.
pub fn SessionChannel::deliver(
  self : SessionChannel,
  response : @contracts.RpcResponse,
) -> Bool {
  if self.closed.val {
    return false
  }
  let queue = match self.pending.get(response.id) {
    Some(value) => value
    None => return false
  }
  let _ = self.pending.remove(response.id)
  let _ = queue.try_put(response) catch {
    _ => return false
  }
  true
}

///|
/// Close the channel: fail every outstanding request and mark it unusable.
/// Idempotent. The connection loop observes `is_closed` and closes the TLS
/// stream from its own task.
pub fn SessionChannel::seal(self : SessionChannel) -> Unit {
  if self.sealed.val {
    return
  }
  self.sealed.val = true
  for _id, queue in self.pending {
    queue.close(error=ChannelClosed)
  }
  self.pending.clear()
}

///|
/// Close the channel permanently. Idempotent. The connection read loop owns
/// the TLS stream and closes it after this returns.
pub fn SessionChannel::close(self : SessionChannel) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  self.seal()
}
