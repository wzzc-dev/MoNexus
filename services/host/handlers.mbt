///|
/// Build a JSON-RPC error response frame for a known request id.
fn error_response_text(id : String, error : @contracts.RpcError) -> String {
  let response : @contracts.RpcResponse = {
    id,
    result: None,
    error: Some(error),
  }
  response.to_json().stringify()
}

///|
/// Cache a response under the request's idempotency key. Caller holds the
/// state mutex.
fn HostState::cache_response(
  self : HostState,
  key : String,
  text : String,
) -> Unit {
  if self.cache.size() >= CACHE_CAPACITY {
    self.cache.clear()
  }
  self.cache.set(key, text)
}

///|
async fn handle_request(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
) -> Unit {
  let client_request_id = match @contracts.client_request_id(request.params) {
    Some(value) => value
    None => {
      sink.send(
        error_response_text(
          request.id,
          @contracts.invalid_params_error("missing client_request_id"),
        ),
      )
      return
    }
  }
  state.mutex.acquire()
  let cached = state.cache.get(client_request_id)
  match cached {
    Some(text) => {
      state.mutex.release()
      sink.send(text)
      return
    }
    None => ()
  }
  match request.method {
    @contracts.METHOD_HOST_STATUS => {
      let status = state.status()
      let response : @contracts.RpcResponse = {
        id: request.id,
        result: Some(status.to_json()),
        error: None,
      }
      let text = response.to_json().stringify()
      state.cache_response(client_request_id, text)
      state.mutex.release()
      sink.send(text)
    }
    @contracts.METHOD_MACHINE_ADD => {
      // Machine handlers manage their own locking: probe releases the mutex
      // around ssh I/O and add releases it around `ssh -G`.
      state.mutex.release()
      handle_machine_add(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_PROBE => {
      state.mutex.release()
      handle_machine_probe(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_REMOVE => {
      state.mutex.release()
      handle_machine_remove(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_LIST => {
      state.mutex.release()
      handle_machine_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_OPEN => {
      state.mutex.release()
      handle_workspace_open(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_LIST => {
      state.mutex.release()
      handle_workspace_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_LIST_FILES => {
      state.mutex.release()
      handle_workspace_list_files(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_STAT => {
      state.mutex.release()
      handle_workspace_stat(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_READ => {
      state.mutex.release()
      handle_workspace_read(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_WRITE => {
      state.mutex.release()
      handle_workspace_write(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_MOVE => {
      state.mutex.release()
      handle_workspace_move(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_REMOVE => {
      state.mutex.release()
      handle_workspace_remove_file(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_GIT_STATUS => {
      state.mutex.release()
      handle_workspace_git_status(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_GIT_DIFF => {
      state.mutex.release()
      handle_workspace_git_diff(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKSPACE_CLOSE => {
      state.mutex.release()
      handle_workspace_close(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKTREE_CREATE => {
      state.mutex.release()
      handle_worktree_create(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKTREE_REMOVE => {
      state.mutex.release()
      handle_worktree_remove(state, sink, request, client_request_id)
    }
    @contracts.METHOD_WORKTREE_LIST => {
      state.mutex.release()
      handle_worktree_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_LEASE_ACQUIRE => {
      state.mutex.release()
      handle_lease_acquire(state, sink, request, client_request_id)
    }
    @contracts.METHOD_LEASE_RELEASE => {
      state.mutex.release()
      handle_lease_release(state, sink, request, client_request_id)
    }
    @contracts.METHOD_LEASE_LIST => {
      state.mutex.release()
      handle_lease_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TERMINAL_OPEN => {
      state.mutex.release()
      handle_terminal_open(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TERMINAL_WRITE => {
      state.mutex.release()
      handle_terminal_write(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TERMINAL_READ => {
      state.mutex.release()
      handle_terminal_read(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TERMINAL_CLOSE => {
      state.mutex.release()
      handle_terminal_close(state, sink, request, client_request_id)
    }
    @contracts.METHOD_EVENTS_SUBSCRIBE => {
      let since = @contracts.subscribe_since(request.params)
      let replay = match since {
        Some(value) => state.replay_after(value)
        None => []
      }
      let from_seq = match since {
        Some(value) => value
        None => state.event_seq()
      }
      sink.subscribed.val = true
      let result = @contracts.SubscribeResult::new(
        subscribed=true,
        replayed=replay.length(),
        from_seq~,
        next_seq=state.next_seq,
      )
      let response : @contracts.RpcResponse = {
        id: request.id,
        result: Some(result.to_json()),
        error: None,
      }
      let text = response.to_json().stringify()
      state.cache_response(client_request_id, text)
      // The response must precede replayed notifications on the same socket.
      sink.send(text)
      for event in replay {
        sink.send(event_notification_text(event))
      }
      state.mutex.release()
    }
    _ => {
      let text = error_response_text(
        request.id,
        @contracts.method_not_found_error(request.method),
      )
      state.cache_response(client_request_id, text)
      state.mutex.release()
      sink.send(text)
    }
  }
}

///|
async fn handle_text_frame(
  state : HostState,
  sink : Sink,
  text : String,
) -> Unit {
  let json = @json.parse(text) catch {
    _ => {
      sink.send(
        error_response_text(
          "",
          @contracts.RpcError::new(
            @contracts.ERR_PARSE,
            "invalid JSON frame",
          ),
        ),
      )
      return
    }
  }
  match @contracts.parse_request(json) {
    Ok(request) => handle_request(state, sink, request)
    Err(message) =>
      if @contracts.is_notification(json) {
        // Client-to-host notifications are not part of M1; ignore them.
        ()
      } else {
        sink.send(
          error_response_text(
            "",
            @contracts.RpcError::new(
              @contracts.ERR_INVALID_REQUEST,
              message,
            ),
          ),
        )
      }
  }
}

///|
async fn writer_loop(sink : Sink, ws : @websocket.Conn) -> Unit {
  for ;; {
    let text = sink.queue.get() catch { _ => return }
    ws.send_text(text) catch { _ => return }
  }
}

///|
async fn reader_loop(
  state : HostState,
  sink : Sink,
  ws : @websocket.Conn,
) -> Unit {
  for ;; {
    let message = ws.recv() catch { _ => break }
    match message.kind {
      Text => {
        let text = message.read_all().text() catch { _ => continue }
        handle_text_frame(state, sink, text)
      }
      Binary => ()
    }
  }
  state.mutex.acquire()
  sink.closed.val = true
  sink.subscribed.val = false
  state.mutex.release()
}

///|
async fn handle_socket(
  state : HostState,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let ws = @websocket.from_http_server(request, conn)
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  state.mutex.acquire()
  let sink = state.register_sink(queue)
  state.mutex.release()
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() { writer_loop(sink, ws) },
    )
    reader_loop(state, sink, ws)
  })
  ws.close()
}

///|
fn authorized(request : @http.Request, token : String) -> Bool {
  let header = request.headers.get(
    @http.CaseInsensitiveString("Authorization"),
  )
  match header {
    Some(value) => value == "Bearer " + token
    None => false
  }
}

///|
async fn handle_connection(
  state : HostState,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  if request.path != "/ws" {
    conn.send_response(404, "Not Found")
    conn.end_response()
    return
  }
  if !authorized(request, state.token) {
    conn.send_response(401, "Unauthorized")
    conn.end_response()
    return
  }
  handle_socket(state, request, conn)
}

///|
/// Background heartbeat: appends `host.heartbeat` to the ring and fans it
/// out to every subscribed connection.
async fn heartbeat_loop(state : HostState) -> Unit {
  for ;; {
    @async.sleep(state.heartbeat_ms)
    state.mutex.acquire()
    let payload = @contracts.json_object([
      ("host_id", @contracts.json_string(state.host_id)),
      ("status", @contracts.json_string(@contracts.HOST_STATUS_ONLINE)),
      ("uptime_ms", @contracts.json_int64(state.uptime_ms())),
    ])
    let _ = state.append_event(
      @contracts.EVENT_HOST_HEARTBEAT,
      "host/" + state.host_id,
      payload,
    )
    state.mutex.release()
  }
}
