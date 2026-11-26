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
    @contracts.METHOD_ENVIRONMENT_CREATE => {
      state.mutex.release()
      handle_environment_create(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_START => {
      state.mutex.release()
      handle_environment_start(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_STOP => {
      state.mutex.release()
      handle_environment_stop(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_DESTROY => {
      state.mutex.release()
      handle_environment_destroy(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_EXEC => {
      state.mutex.release()
      handle_environment_exec(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_DOCTOR => {
      state.mutex.release()
      handle_environment_doctor(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_LIST => {
      state.mutex.release()
      handle_environment_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ENVIRONMENT_GET => {
      state.mutex.release()
      handle_environment_get(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RECIPE_IMPORT => {
      state.mutex.release()
      handle_recipe_import(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RECIPE_LIST => {
      state.mutex.release()
      handle_recipe_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RECIPE_SHOW => {
      state.mutex.release()
      handle_recipe_show(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RECIPE_REVOKE => {
      state.mutex.release()
      handle_recipe_revoke(state, sink, request, client_request_id)
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
    @contracts.METHOD_AGENT_PROBE => {
      state.mutex.release()
      handle_agent_probe(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_START => {
      state.mutex.release()
      handle_agent_start(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_SEND => {
      state.mutex.release()
      handle_agent_send(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_STOP => {
      state.mutex.release()
      handle_agent_stop(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_READ => {
      state.mutex.release()
      handle_agent_read(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_LIST => {
      state.mutex.release()
      handle_agent_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_RESUME => {
      state.mutex.release()
      handle_agent_resume(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_MEMORY_READ => {
      state.mutex.release()
      handle_agent_memory_read(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AGENT_MEMORY_WRITE => {
      state.mutex.release()
      handle_agent_memory_write(state, sink, request, client_request_id)
    }
    @contracts.METHOD_DECISION_LIST => {
      state.mutex.release()
      handle_decision_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_DECISION_RESPOND => {
      state.mutex.release()
      handle_decision_respond(state, sink, request, client_request_id)
    }
    @contracts.METHOD_PROJECT_CREATE => {
      state.mutex.release()
      handle_project_create(state, sink, request, client_request_id)
    }
    @contracts.METHOD_PROJECT_LIST => {
      state.mutex.release()
      handle_project_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TASK_CREATE => {
      state.mutex.release()
      handle_task_create(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TASK_LIST => {
      state.mutex.release()
      handle_task_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TASK_GET => {
      state.mutex.release()
      handle_task_get(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TASK_CANCEL => {
      state.mutex.release()
      handle_task_cancel(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUN_CREATE => {
      state.mutex.release()
      handle_run_create(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUN_LIST => {
      state.mutex.release()
      handle_run_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUN_GET => {
      state.mutex.release()
      handle_run_get(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUN_CANCEL => {
      state.mutex.release()
      handle_run_cancel(state, sink, request, client_request_id)
    }
    @contracts.METHOD_ARTIFACT_READ => {
      state.mutex.release()
      handle_artifact_read(state, sink, request, client_request_id)
    }
    @contracts.METHOD_EVENTS_LIST => {
      state.mutex.release()
      handle_events_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SEARCH_SESSIONS => {
      state.mutex.release()
      handle_search_sessions(state, sink, request, client_request_id)
    }
    @contracts.METHOD_AUDIT_LIST => {
      state.mutex.release()
      handle_audit_list(state, sink, request, client_request_id)
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
    // Registered unconditionally so a flag-off host answers `unsupported`
    // rather than `method_not_found` (ADR-0014 §8 gap note).
    @contracts.METHOD_SKILL_IMPORT => {
      state.mutex.release()
      handle_skill_import(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_KEY_REGISTER => {
      state.mutex.release()
      handle_skill_key_register(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_KEY_REVOKE => {
      state.mutex.release()
      handle_skill_key_revoke(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_ALLOW => {
      state.mutex.release()
      handle_skill_allow(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_ALLOWLIST_REVOKE => {
      state.mutex.release()
      handle_skill_allowlist_revoke(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_ENABLE => {
      state.mutex.release()
      handle_skill_enable(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_DISABLE => {
      state.mutex.release()
      handle_skill_disable(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_UPGRADE => {
      state.mutex.release()
      handle_skill_upgrade(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_UNINSTALL => {
      state.mutex.release()
      handle_skill_uninstall(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_LIST => {
      state.mutex.release()
      handle_skill_list(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_GET => {
      state.mutex.release()
      handle_skill_get(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_DOCTOR => {
      state.mutex.release()
      handle_skill_doctor(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_PERMISSIONS_SET => {
      state.mutex.release()
      handle_skill_permissions_set(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_PERMISSIONS_GET => {
      state.mutex.release()
      handle_skill_permissions_get(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_INVOKE => {
      state.mutex.release()
      handle_skill_invoke(state, sink, request, client_request_id)
    }
    @contracts.METHOD_SKILL_TOOLS => {
      state.mutex.release()
      handle_skill_tools(state, sink, request, client_request_id)
    }
    @contracts.METHOD_TRIGGER_CREATE
    | @contracts.METHOD_TRIGGER_LIST
    | @contracts.METHOD_TRIGGER_GET
    | @contracts.METHOD_TRIGGER_UPDATE
    | @contracts.METHOD_TRIGGER_DISABLE
    | @contracts.METHOD_TRIGGER_FIRE
    | @contracts.METHOD_TRIGGER_SOURCE_ADD
    | @contracts.METHOD_TRIGGER_SOURCE_REVOKE => {
      state.mutex.release()
      handle_trigger_rpc(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUNTIME_PAIRING_CREATE => {
      state.mutex.release()
      handle_runtime_pairing_create(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUNTIME_REVOKE => {
      state.mutex.release()
      handle_runtime_revoke(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUNTIME_DRAIN => {
      state.mutex.release()
      handle_runtime_drain(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUNTIME_STATUS => {
      state.mutex.release()
      handle_runtime_status(state, sink, request, client_request_id)
    }
    @contracts.METHOD_RUNTIME_AUDIT => {
      state.mutex.release()
      handle_runtime_audit(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_EXEC => {
      state.mutex.release()
      handle_machine_exec(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_EXEC_STATUS => {
      state.mutex.release()
      handle_machine_exec_status(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_FS => {
      state.mutex.release()
      handle_machine_fs(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_PTY => {
      state.mutex.release()
      handle_machine_pty(state, sink, request, client_request_id)
    }
    @contracts.METHOD_MACHINE_GIT => {
      state.mutex.release()
      handle_machine_git(state, sink, request, client_request_id)
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
  // Path split happens before the `/ws` bearer check (ADR-0014 §4.1): webhook
  // callers authenticate with HMAC headers, never with the owner's WS token.
  // No other path is served, so this stays loopback-only.
  if request.path.has_prefix(@contracts.TRIGGER_WEBHOOK_PATH_PREFIX) {
    handle_trigger_webhook(state, request, conn)
    return
  }
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
