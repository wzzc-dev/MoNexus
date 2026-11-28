///|
fn smoke_request_id(prefix : String) -> String {
  @contracts.new_id(prefix, @async.now())
}

///|
async fn rpc_call(
  client : @client.RpcClient,
  prefix : String,
  method_name : String,
  params : Map[String, @json.Json],
) -> Result[@json.Json, String] {
  let id = smoke_request_id(prefix)
  client.call_json(id, method_name, params)
}

///|
fn ack_ok(json : @json.Json) -> Bool {
  match @contracts.as_object(json) {
    Some(object) => @contracts.bool_field_or(object, "ok", false)
    None => false
  }
}

///|
async fn rpc_ack(
  client : @client.RpcClient,
  prefix : String,
  method_name : String,
  params : Map[String, @json.Json],
) -> Result[Unit, String] {
  match rpc_call(client, prefix, method_name, params) {
    Ok(json) =>
      if ack_ok(json) {
        Ok(())
      } else {
        Err("acknowledgement was not ok: " + json.stringify())
      }
    Err(message) => Err(message)
  }
}

///|
async fn open_workspace(
  client : @client.RpcClient,
  machine_id : String,
  root : String,
) -> Result[@contracts.WorkspaceRecord, String] {
  let id = smoke_request_id("open")
  let result = client.call_json(
    id,
    @contracts.METHOD_WORKSPACE_OPEN,
    @contracts.workspace_open_params(id, machine_id, root),
  ) catch {
    error => return Err(error.to_string())
  }
  let json = match result {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  @contracts.workspace_result_record(json)
}

///|
async fn list_workspaces(
  client : @client.RpcClient,
) -> Result[Array[@contracts.WorkspaceRecord], String] {
  let id = smoke_request_id("list")
  match rpc_call(
    client,
    "list",
    @contracts.METHOD_WORKSPACE_LIST,
    @contracts.workspace_registry_list_params(id),
  ) {
    Ok(json) => @contracts.workspace_list_from_json(json)
    Err(message) => Err(message)
  }
}

///|
async fn list_files(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Result[Array[@contracts.WorkspaceEntry], String] {
  let id = smoke_request_id("listfiles")
  match rpc_call(
    client,
    "listfiles",
    @contracts.METHOD_WORKSPACE_LIST_FILES,
    @contracts.workspace_list_params(id, workspace_id, path),
  ) {
    Ok(json) => @contracts.workspace_entries_from_json(json)
    Err(message) => Err(message)
  }
}

///|
async fn read_workspace_file(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Result[String, String] {
  let id = smoke_request_id("read")
  match rpc_call(
    client,
    "read",
    @contracts.METHOD_WORKSPACE_READ,
    @contracts.workspace_read_params(id, workspace_id, path),
  ) {
    Ok(json) => @contracts.workspace_text_from_json(json)
    Err(message) => Err(message)
  }
}

///|
async fn write_workspace_file(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
  content : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("write")
  rpc_ack(
    client,
    "write",
    @contracts.METHOD_WORKSPACE_WRITE,
    @contracts.workspace_write_params(id, workspace_id, path, content),
  )
}

///|
async fn move_workspace_path(
  client : @client.RpcClient,
  workspace_id : String,
  from_path : String,
  to_path : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("move")
  rpc_ack(
    client,
    "move",
    @contracts.METHOD_WORKSPACE_MOVE,
    @contracts.workspace_move_params(id, workspace_id, from_path, to_path),
  )
}

///|
async fn remove_workspace_path(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("remove")
  rpc_ack(
    client,
    "remove",
    @contracts.METHOD_WORKSPACE_REMOVE,
    @contracts.workspace_remove_params(id, workspace_id, path),
  )
}

///|
async fn stat_workspace_path(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Result[@contracts.WorkspaceStat, String] {
  let id = smoke_request_id("stat")
  match rpc_call(
    client,
    "stat",
    @contracts.METHOD_WORKSPACE_STAT,
    @contracts.workspace_list_params(id, workspace_id, path),
  ) {
    Ok(json) => @contracts.workspace_stat_result_value(json)
    Err(message) => Err(message)
  }
}

///|
async fn git_status(
  client : @client.RpcClient,
  workspace_id : String,
) -> Result[@contracts.GitStatus, String] {
  let id = smoke_request_id("gitstatus")
  match rpc_call(
    client,
    "gitstatus",
    @contracts.METHOD_WORKSPACE_GIT_STATUS,
    @contracts.workspace_git_status_params(id, workspace_id),
  ) {
    Ok(json) => @contracts.git_status_result_value(json)
    Err(message) => Err(message)
  }
}

///|
async fn git_diff(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Result[@contracts.GitDiff, String] {
  let id = smoke_request_id("gitdiff")
  match rpc_call(
    client,
    "gitdiff",
    @contracts.METHOD_WORKSPACE_GIT_DIFF,
    @contracts.workspace_git_diff_params(id, workspace_id, path, false, ""),
  ) {
    Ok(json) => @contracts.git_diff_result_value(json)
    Err(message) => Err(message)
  }
}

///|
async fn create_worktree(
  client : @client.RpcClient,
  workspace_id : String,
  branch : String,
  path : String,
) -> Result[@contracts.WorktreeRecord, String] {
  let id = smoke_request_id("worktree")
  match rpc_call(
    client,
    "worktree",
    @contracts.METHOD_WORKTREE_CREATE,
    @contracts.worktree_create_params(id, workspace_id, branch, path, ""),
  ) {
    Ok(json) => @contracts.worktree_result_record(json)
    Err(message) => Err(message)
  }
}

///|
async fn list_worktrees(
  client : @client.RpcClient,
  workspace_id : String,
) -> Result[Array[@contracts.WorktreeRecord], String] {
  let id = smoke_request_id("worktrees")
  match rpc_call(
    client,
    "worktrees",
    @contracts.METHOD_WORKTREE_LIST,
    @contracts.worktree_list_params(id, workspace_id),
  ) {
    Ok(json) => @contracts.worktree_list_from_json(json)
    Err(message) => Err(message)
  }
}

///|
async fn remove_worktree(
  client : @client.RpcClient,
  worktree_id : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("worktreeremove")
  rpc_ack(
    client,
    "worktreeremove",
    @contracts.METHOD_WORKTREE_REMOVE,
    @contracts.worktree_remove_params(id, worktree_id, true),
  )
}

///|
async fn acquire_lease(
  client : @client.RpcClient,
  target_kind : String,
  target_id : String,
  holder : String,
) -> Result[@contracts.LeaseRecord, String] {
  let id = smoke_request_id("lease")
  match rpc_call(
    client,
    "lease",
    @contracts.METHOD_LEASE_ACQUIRE,
    @contracts.lease_acquire_params(id, target_kind, target_id, holder),
  ) {
    Ok(json) => @contracts.lease_result_record(json)
    Err(message) => Err(message)
  }
}

///|
async fn list_leases(
  client : @client.RpcClient,
) -> Result[Array[@contracts.LeaseRecord], String] {
  let id = smoke_request_id("leases")
  match rpc_call(
    client,
    "leases",
    @contracts.METHOD_LEASE_LIST,
    @contracts.lease_list_params(id),
  ) {
    Ok(json) => @contracts.lease_list_from_json(json)
    Err(message) => Err(message)
  }
}

///|
async fn release_lease(
  client : @client.RpcClient,
  lease_id : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("leaserelease")
  rpc_ack(
    client,
    "leaserelease",
    @contracts.METHOD_LEASE_RELEASE,
    @contracts.lease_release_params(id, lease_id),
  )
}

///|
async fn open_terminal(
  client : @client.RpcClient,
  workspace_id : String,
  command : String,
  rows : Int,
  cols : Int,
) -> Result[@contracts.TerminalOpenResult, String] {
  let id = smoke_request_id("termopen")
  match rpc_call(
    client,
    "termopen",
    @contracts.METHOD_TERMINAL_OPEN,
    @contracts.terminal_open_params(id, workspace_id, command, rows, cols),
  ) {
    Ok(json) =>
      match @contracts.terminal_open_from_json(json) {
        Some(value) => Ok(value)
        None => Err("terminal.open returned a malformed result")
      }
    Err(message) => Err(message)
  }
}

///|
async fn read_terminal(
  client : @client.RpcClient,
  session_id : String,
  cursor : Int64,
) -> Result[@contracts.TerminalRead, String] {
  let id = smoke_request_id("termread")
  match rpc_call(
    client,
    "termread",
    @contracts.METHOD_TERMINAL_READ,
    @contracts.terminal_read_params(id, session_id, cursor),
  ) {
    Ok(json) =>
      match @contracts.terminal_read_from_json(json) {
        Some(value) => Ok(value)
        None => Err("terminal.read returned a malformed result")
      }
    Err(message) => Err(message)
  }
}

///|
async fn write_terminal(
  client : @client.RpcClient,
  session_id : String,
  data : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("termwrite")
  rpc_ack(
    client,
    "termwrite",
    @contracts.METHOD_TERMINAL_WRITE,
    @contracts.terminal_write_params(id, session_id, data),
  )
}

///|
async fn resize_terminal(
  client : @client.RpcClient,
  session_id : String,
  rows : Int,
  cols : Int,
) -> Result[@contracts.TerminalResizeResult, String] {
  let id = smoke_request_id("termresize")
  match rpc_call(
    client,
    "termresize",
    @contracts.METHOD_TERMINAL_RESIZE,
    @contracts.terminal_resize_params(id, session_id, rows, cols),
  ) {
    Ok(json) =>
      match @contracts.terminal_resize_from_json(json) {
        Some(value) => Ok(value)
        None => Err("terminal.resize returned a malformed result")
      }
    Err(message) => Err(message)
  }
}

///|
async fn close_terminal(
  client : @client.RpcClient,
  session_id : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("termclose")
  rpc_ack(
    client,
    "termclose",
    @contracts.METHOD_TERMINAL_CLOSE,
    @contracts.terminal_close_params(id, session_id),
  )
}

///|
async fn close_workspace(
  client : @client.RpcClient,
  workspace_id : String,
) -> Result[Unit, String] {
  let id = smoke_request_id("close")
  let params = @contracts.workspace_registry_list_params(id)
  params.set("workspace_id", @contracts.json_string(workspace_id))
  rpc_ack(
    client,
    "close",
    @contracts.METHOD_WORKSPACE_CLOSE,
    params,
  )
}

///|
async fn list_events(
  client : @client.RpcClient,
  since : Int64,
  limit : Int,
) -> Result[Array[@contracts.EventEnvelope], String] {
  let params : Map[String, @json.Json] = Map([
    ("since", @contracts.json_int64(since)),
    ("limit", @contracts.json_int(limit)),
  ])
  let json = match
    rpc_call(client, "events", @contracts.METHOD_EVENTS_LIST, params) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err("events.list result is not an object")
  }
  let items = match object.get("events") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("events.list result has no events array")
  }
  let events : Array[@contracts.EventEnvelope] = []
  for item in items {
    match @contracts.EventEnvelope::from_json(item) {
      Some(event) => events.push(event)
      None => return Err("events.list contains a malformed event")
    }
  }
  Ok(events)
}

///|
struct TextPoll {
  cursor : Int64
}

///|
struct SizePoll {
  cursor : Int64
  rows : Int
  cols : Int
}

///|
async fn poll_terminal_text(
  client : @client.RpcClient,
  session_id : String,
  start_cursor : Int64,
  needle : String,
  timeout_seconds : Int,
) -> Result[TextPoll, String] {
  let deadline = @async.now() + timeout_seconds.to_int64() * 1_000L
  let mut cursor = start_cursor
  let mut collected = ""
  let mut last_error = ""
  while @async.now() < deadline {
    match read_terminal(client, session_id, cursor) {
      Ok(payload) => {
        cursor = payload.cursor
        if payload.text != "" {
          collected = collected + payload.text
          if collected.contains(needle) {
            return Ok({ cursor, })
          }
        }
      }
      Err(message) => last_error = message
    }
    @async.sleep(200)
  }
  if last_error != "" {
    Err(last_error)
  } else {
    Err("timeout after " + timeout_seconds.to_string() + "s")
  }
}

///|
async fn retry_terminal_write(
  client : @client.RpcClient,
  session_id : String,
  start_cursor : Int64,
  data : String,
  needle : String,
  timeout_seconds : Int,
) -> Result[TextPoll, String] {
  let deadline = @async.now() + timeout_seconds.to_int64() * 1_000L
  let mut cursor = start_cursor
  let mut last_error = ""
  while @async.now() < deadline {
    match write_terminal(client, session_id, data) {
      Ok(_) => ()
      Err(message) => last_error = message
    }
    let attempt_deadline = (@async.now() + 2_000L).min(deadline)
    let mut collected = ""
    while @async.now() < attempt_deadline && @async.now() < deadline {
      match read_terminal(client, session_id, cursor) {
        Ok(payload) => {
          cursor = payload.cursor
          if payload.text != "" {
            collected = collected + payload.text
            if collected.contains(needle) {
              return Ok({ cursor, })
            }
          }
        }
        Err(message) => last_error = message
      }
      @async.sleep(200)
    }
  }
  if last_error != "" {
    Err(last_error)
  } else {
    Err("timeout after " + timeout_seconds.to_string() + "s")
  }
}

///|
fn parse_size_line(line : String, marker : String) -> (Int, Int)? {
  let index = match line.find(marker) {
    Some(value) => value
    None => return None
  }
  let rest = line[index + marker.length():].to_owned()
  let numbers : Array[Int] = []
  for piece in rest.split(" ") {
    let token = piece.trim().to_owned()
    if token != "" {
      let value = @string.parse_int(token) catch { _ => -1 }
      if value >= 0 {
        numbers.push(value)
      }
    }
  }
  if numbers.length() >= 2 {
    Some((numbers[0], numbers[1]))
  } else {
    None
  }
}

///|
fn last_size_in(text : String, marker : String) -> (Int, Int)? {
  let mut found : (Int, Int)? = None
  for line in text.split("\n") {
    match parse_size_line(line.to_owned(), marker) {
      Some(size) => found = Some(size)
      None => ()
    }
  }
  found
}

///|
async fn poll_tmux_size(
  client : @client.RpcClient,
  session_id : String,
  start_cursor : Int64,
  marker : String,
  timeout_seconds : Int,
) -> Result[SizePoll, String] {
  let deadline = @async.now() + timeout_seconds.to_int64() * 1_000L
  let mut cursor = start_cursor
  let mut collected = ""
  let mut last_error = ""
  while @async.now() < deadline {
    match read_terminal(client, session_id, cursor) {
      Ok(payload) => {
        cursor = payload.cursor
        if payload.text != "" {
          collected = collected + payload.text
          match last_size_in(collected, marker) {
            Some((rows, cols)) =>
              return Ok({ cursor, rows, cols })
            None => ()
          }
        }
      }
      Err(message) => last_error = message
    }
    @async.sleep(200)
  }
  if last_error != "" {
    Err(last_error)
  } else {
    Err("timeout after " + timeout_seconds.to_string() + "s")
  }
}
