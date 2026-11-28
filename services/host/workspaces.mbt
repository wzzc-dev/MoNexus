///|
/// Workspace / Worktree / lease / terminal RPC handlers (M3).
///
/// Every handler follows the same shape as the machine handlers: parse the
/// request, do provider I/O with the state mutex released, then record the
/// event and projection under the mutex and answer. Bookkeeping is host-side:
/// worktree records always come from `git worktree add`, and a lease row is
/// unique per target, so two runs cannot own one worktree (architecture §3.2).

///|
fn workspace_error_of_provider(
  error : @provider_error.ProviderError,
) -> @contracts.RpcError {
  let kind = match error.kind {
    AuthFailed => @contracts.WORKSPACE_ERR_UNAUTHORIZED
    ConnectTimeout => @contracts.WORKSPACE_ERR_TIMEOUT
    NotFound => @contracts.WORKSPACE_ERR_NOT_FOUND
    HostKey => @contracts.WORKSPACE_ERR_HOST_KEY
    RemoteExit => @contracts.WORKSPACE_ERR_REMOTE
    SpawnFailed | Transport | NotConfigured =>
      @contracts.WORKSPACE_ERR_UNREACHABLE
    PtyFailed | Cancelled | Internal => @contracts.WORKSPACE_ERR_INTERNAL
  }
  let detail = match error.detail {
    Some(value) => value
    None => ""
  }
  @contracts.workspace_error(kind, error.message, detail=detail)
}

///|
fn workspace_invalid(message : String) -> @contracts.RpcError {
  @contracts.workspace_error(@contracts.WORKSPACE_ERR_INVALID, message)
}

///|
fn workspace_not_found(message : String) -> @contracts.RpcError {
  @contracts.workspace_error(@contracts.WORKSPACE_ERR_NOT_FOUND, message)
}

///|
fn workspace_unsupported(message : String) -> @contracts.RpcError {
  @contracts.workspace_error(@contracts.WORKSPACE_ERR_UNSUPPORTED, message)
}

///|
fn workspace_row_name(root : String) -> String {
  let trimmed = root.trim_end(chars="/").to_owned()
  if trimmed == "" {
    return "/"
  }
  match trimmed.rev_split_once("/") {
    Some((_, name)) => {
      let text = name.to_owned()
      if text == "" { trimmed } else { text }
    }
    None => trimmed
  }
}

///|
/// Whether a machine id names the host's own machine. Empty and a registered
/// `local` record are equivalent for provider selection and agent locality.
async fn machine_is_local(state : HostState, machine_id : String) -> Bool {
  if machine_id == "" {
    return true
  }
  state.mutex.acquire()
  let is_local = match state.store.get_machine(machine_id) {
    Ok(Some(record)) => record.kind == @contracts.MACHINE_KIND_LOCAL
    _ => false
  }
  state.mutex.release()
  is_local
}

///|
/// Open a provider for `machine_id` (empty = local) and `root`. The machine
/// lookup happens under the mutex; the network I/O does not.
async fn open_provider(
  state : HostState,
  machine_id : String,
  root : String,
) -> Result[@workspace.WorkspaceProvider, @contracts.RpcError] {
  if machine_id == "" {
    return match @workspace.open_local(root) {
      Ok(provider) => Ok(provider)
      Err(error) => Err(workspace_error_of_provider(error))
    }
  }
  state.mutex.acquire()
  let machine = match state.store.get_machine(machine_id) {
    Ok(Some(record)) => Some(record)
    Ok(None) => None
    Err(message) => {
      state.mutex.release()
      return Err(workspace_invalid("cannot read machine: " + message))
    }
  }
  state.mutex.release()
  let record = match machine {
    Some(value) => value
    None => return Err(workspace_not_found("machine not found"))
  }
  // A registered local machine uses the same in-process provider as the empty
  // machine id; the record exists so "this machine" is visible and auditable.
  if record.kind == @contracts.MACHINE_KIND_LOCAL {
    return match @workspace.open_local(root) {
      Ok(provider) => Ok(provider)
      Err(error) => Err(workspace_error_of_provider(error))
    }
  }
  match @workspace.open_ssh(machine_target(record), root) {
    Ok(provider) => Ok(provider)
    Err(error) => Err(workspace_error_of_provider(error))
  }
}

///|
async fn provider_for_workspace(
  state : HostState,
  record : @contracts.WorkspaceRecord,
) -> Result[@workspace.WorkspaceProvider, @contracts.RpcError] {
  open_provider(state, record.machine_id, record.root)
}

///|
async fn lookup_workspace(
  state : HostState,
  workspace_id : String,
) -> Result[@contracts.WorkspaceRecord, @contracts.RpcError] {
  state.mutex.acquire()
  let record = match state.store.get_workspace(workspace_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err(workspace_not_found("workspace not found"))
    Err(message) => Err(workspace_invalid("cannot read workspace: " + message))
  }
  state.mutex.release()
  record
}

///|
async fn lookup_worktree(
  state : HostState,
  worktree_id : String,
) -> Result[@contracts.WorktreeRecord, @contracts.RpcError] {
  state.mutex.acquire()
  let record = match state.store.get_worktree(worktree_id) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err(workspace_not_found("worktree not found"))
    Err(message) => Err(workspace_invalid("cannot read worktree: " + message))
  }
  state.mutex.release()
  record
}

///|
/// Resolve a worktree for Git review. The workspace id stays the scope of the
/// request; the worktree must belong to it, be ready and live on the same
/// machine before its path can select the provider root.
async fn lookup_worktree_for_git_review(
  state : HostState,
  workspace : @contracts.WorkspaceRecord,
  worktree_id : String,
) -> Result[@contracts.WorktreeRecord, @contracts.RpcError] {
  let worktree = match lookup_worktree(state, worktree_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if worktree.workspace_id != workspace.id {
    return Err(
      @contracts.workspace_error(
        @contracts.WORKSPACE_ERR_CONFLICT,
        "worktree does not belong to the requested workspace",
      ),
    )
  }
  if worktree.state != @contracts.WORKTREE_STATE_READY {
    return Err(
      @contracts.workspace_error(
        @contracts.WORKSPACE_ERR_CONFLICT,
        "worktree is not ready: " + worktree.state,
      ),
    )
  }
  if worktree.path == "" || !worktree.path.has_prefix("/") {
    return Err(workspace_invalid("worktree path must be absolute and non-empty"))
  }
  if worktree.machine_id != workspace.machine_id {
    return Err(
      @contracts.workspace_error(
        @contracts.WORKSPACE_ERR_CONFLICT,
        "worktree machine does not match the workspace machine",
      ),
    )
  }
  Ok(worktree)
}

///|
async fn workspace_io_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  error : @contracts.RpcError,
) -> Unit {
  send_machine_error(state, sink, request, client_request_id, error)
}

// ---------------------------------------------------------------------------
// Workspace lifecycle
// ---------------------------------------------------------------------------

///|
async fn handle_workspace_open(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = @contracts.workspace_open_target(request.params)
  let root = match @contracts.workspace_root_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let provider = match open_provider(state, machine_id, root) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let kind = match provider {
    @workspace.WorkspaceProvider::Local(_) => @contracts.WORKSPACE_KIND_LOCAL
    @workspace.WorkspaceProvider::Ssh(_) => @contracts.WORKSPACE_KIND_SSH
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  state.mutex.acquire()
  let existing = match state.store.list_workspaces() {
    Ok(records) => {
      let mut found : @contracts.WorkspaceRecord? = None
      for record in records {
        if record.machine_id == machine_id && record.root == provider.root() {
          found = Some(record)
          break
        }
      }
      found
    }
    Err(message) => {
      state.mutex.release()
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("cannot list workspaces: " + message),
      )
      return
    }
  }
  let record = match existing {
    Some(value) => value
    None => {
      let made : @contracts.WorkspaceRecord = {
        id: @contracts.new_id("wsp", now),
        machine_id,
        kind,
        root: provider.root(),
        name: workspace_row_name(root),
        git_root: provider.git_root(),
        is_git: provider.is_git(),
        state: @contracts.WORKSPACE_STATE_AVAILABLE,
        created_at: timestamp,
        updated_at: timestamp,
      }
      match
        state.append_workspace_event(
          @contracts.EVENT_WORKSPACE_OPENED,
          made.id,
          @contracts.workspace_event_payload(made),
          Some(made),
          None,
        ) {
        Ok(_) => made
        Err(message) => {
          state.mutex.release()
          workspace_io_error(
            state,
            sink,
            request,
            client_request_id,
            workspace_invalid("cannot record workspace: " + message),
          )
          return
        }
      }
    }
  }
  let result = @contracts.workspace_result(record)
  state.mutex.release()
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  let result = match state.store.list_workspaces() {
    Ok(records) => Ok(@contracts.workspace_list_result(records))
    Err(message) => Err(workspace_invalid("cannot list workspaces: " + message))
  }
  state.mutex.release()
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_workspace_close(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  state.mutex.acquire()
  let outcome = match state.store.get_workspace(workspace_id) {
    Ok(None) => Err(workspace_not_found("workspace not found"))
    Err(message) =>
      Err(workspace_invalid("cannot read workspace: " + message))
    Ok(Some(_)) => {
      let leases = state.store.list_leases()
      let worktrees = state.store.list_worktrees()
      let active_lease = match leases {
        Ok(values) => {
          let mut found : @contracts.LeaseRecord? = None
          for lease in values {
            if lease.target_kind == "workspace" &&
              lease.target_id == workspace_id {
              found = Some(lease)
              break
            }
          }
          found
        }
        Err(_) => None
      }
      let live_worktree = match worktrees {
        Ok(values) => {
          let mut found : @contracts.WorktreeRecord? = None
          for tree in values {
            if tree.workspace_id == workspace_id {
              found = Some(tree)
              break
            }
          }
          found
        }
        Err(_) => None
      }
      if active_lease is Some(_) {
        Err(
          @contracts.workspace_error(
            @contracts.WORKSPACE_ERR_CONFLICT,
            "workspace is leased by an active run",
          ),
        )
      } else if live_worktree is Some(_) {
        Err(
          @contracts.workspace_error(
            @contracts.WORKSPACE_ERR_CONFLICT,
            "workspace still has live worktrees",
          ),
        )
      } else {
        match
          state.append_workspace_event(
            @contracts.EVENT_WORKSPACE_CLOSED,
            workspace_id,
            @contracts.workspace_closed_payload(workspace_id),
            None,
            Some(workspace_id),
          ) {
          Ok(_) => Ok(@contracts.workspace_ack_result(workspace_id, ""))
          Err(message) =>
            Err(workspace_invalid("cannot close workspace: " + message))
        }
      }
    }
  }
  state.mutex.release()
  match outcome {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

// ---------------------------------------------------------------------------
// File operations
// ---------------------------------------------------------------------------

///|
async fn handle_workspace_list_files(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let path = @contracts.workspace_path_param(request.params)
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let entries = match provider.list(path) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  let contract_entries : Array[@contracts.WorkspaceEntry] = []
  for entry in entries {
    contract_entries.push({
      name: entry.name,
      path: entry.path,
      kind: entry.kind,
      is_dir: entry.is_dir,
      size: entry.size,
    })
  }
  let result = @contracts.workspace_entries_result(path, contract_entries)
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_stat(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let path = @contracts.workspace_path_param(request.params)
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let info = match provider.stat(path) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  let result = @contracts.workspace_stat_result({
    path: info.path,
    kind: info.kind,
    size: info.size,
  })
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_read(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let path = @contracts.workspace_path_param(request.params)
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let text = match provider.read_text(path) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  let result = @contracts.workspace_text_result(path, text)
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_write(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let path = @contracts.workspace_path_param(request.params)
  let content = @contracts.workspace_content_param(request.params)
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match provider.write_text(path, content) {
    Ok(_) => ()
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  // Best-effort change notification; the write itself already happened.
  state.mutex.acquire()
  let _ = state.append_workspace_event(
    @contracts.EVENT_WORKSPACE_CHANGED,
    workspace_id,
    @contracts.workspace_changed_payload(workspace_id, path, "write"),
    None,
    None,
  )
  state.mutex.release()
  let result = @contracts.workspace_ack_result(workspace_id, path)
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_move(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let from_path = @contracts.string_field_or(request.params, "from", "")
  let to_path = @contracts.string_field_or(request.params, "to", "")
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match provider.move(from_path, to_path) {
    Ok(_) => ()
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  state.mutex.acquire()
  let _ = state.append_workspace_event(
    @contracts.EVENT_WORKSPACE_CHANGED,
    workspace_id,
    @contracts.workspace_changed_payload(workspace_id, from_path, "move"),
    None,
    None,
  )
  state.mutex.release()
  let result = @contracts.workspace_ack_result(workspace_id, to_path)
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_remove_file(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let path = @contracts.workspace_path_param(request.params)
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match provider.remove(path) {
    Ok(_) => ()
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  state.mutex.acquire()
  let _ = state.append_workspace_event(
    @contracts.EVENT_WORKSPACE_CHANGED,
    workspace_id,
    @contracts.workspace_changed_payload(workspace_id, path, "remove"),
    None,
    None,
  )
  state.mutex.release()
  let result = @contracts.workspace_ack_result(workspace_id, path)
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_git_status(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let worktree_id = @contracts.string_field_or(
    request.params,
    "worktree_id",
    "",
  )
  // An active environment redirects git execution into its container; the
  // workspace record keeps its original kind and file operations stay on the
  // host bind mount.
  match active_environment_for_workspace_root(state, workspace_id) {
    Some(environment) => {
      if worktree_id != "" {
        workspace_io_error(
          state,
          sink,
          request,
          client_request_id,
          workspace_unsupported(
            "worktree git review is unsupported for environment-backed workspaces (M1)",
          ),
        )
        return
      }
      let status = match environment_git_status(state, record, environment) {
        Ok(value) => value
        Err(error) => {
          workspace_io_error(state, sink, request, client_request_id, error)
          return
        }
      }
      let result = @contracts.git_status_result(status)
      send_machine_result(state, sink, request, client_request_id, result)
      return
    }
    None => ()
  }
  let provider_result = if worktree_id == "" {
    provider_for_workspace(state, record)
  } else {
    match lookup_worktree_for_git_review(state, record, worktree_id) {
      Ok(worktree) => open_provider(state, record.machine_id, worktree.path)
      Err(error) => Err(error)
    }
  }
  let provider = match provider_result {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let status = match provider.git_status() {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  let changes : Array[@contracts.GitChange] = []
  for change in status.changes {
    changes.push({
      path: change.path,
      status: change.status,
      index_status: change.index_status,
      worktree_status: change.worktree_status,
    })
  }
  let result = @contracts.git_status_result({
    is_git: status.is_git,
    branch: status.branch,
    upstream: status.upstream,
    ahead: status.ahead,
    behind: status.behind,
    changes,
  })
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_workspace_git_diff(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let path = @contracts.workspace_path_param(request.params)
  let cached = @contracts.bool_field_or(request.params, "cached", false)
  let range = @contracts.string_field_or(request.params, "range", "")
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let worktree_id = @contracts.string_field_or(
    request.params,
    "worktree_id",
    "",
  )
  match active_environment_for_workspace_root(state, workspace_id) {
    Some(environment) => {
      if worktree_id != "" {
        workspace_io_error(
          state,
          sink,
          request,
          client_request_id,
          workspace_unsupported(
            "worktree git review is unsupported for environment-backed workspaces (M1)",
          ),
        )
        return
      }
      let diff = match
        environment_git_diff(state, environment, path, cached, range) {
        Ok(value) => value
        Err(error) => {
          workspace_io_error(state, sink, request, client_request_id, error)
          return
        }
      }
      let result = @contracts.git_diff_result(diff)
      send_machine_result(state, sink, request, client_request_id, result)
      return
    }
    None => ()
  }
  let provider_result = if worktree_id == "" {
    provider_for_workspace(state, record)
  } else {
    match lookup_worktree_for_git_review(state, record, worktree_id) {
      Ok(worktree) => open_provider(state, record.machine_id, worktree.path)
      Err(error) => Err(error)
    }
  }
  let provider = match provider_result {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let diff = match provider.git_diff(path, cached, range) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  let result = @contracts.git_diff_result({
    path: diff.path,
    cached: diff.cached,
    range: diff.range,
    text: diff.text,
    truncated: diff.truncated,
  })
  send_machine_result(state, sink, request, client_request_id, result)
}

// ---------------------------------------------------------------------------
// Worktrees
// ---------------------------------------------------------------------------

///|
async fn handle_worktree_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let branch = @contracts.string_field_or(request.params, "branch", "")
  let path = @contracts.string_field_or(request.params, "path", "")
  let base = @contracts.string_field_or(request.params, "base", "")
  if path.trim() == "" {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      workspace_invalid("missing worktree path"),
    )
    return
  }
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match provider.create_worktree(path, branch, base) {
    Ok(_) => ()
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  let now = @async.now()
  let timestamp = @contracts.format_rfc3339(now)
  let made : @contracts.WorktreeRecord = {
    id: @contracts.new_id("wt", now),
    workspace_id,
    machine_id: record.machine_id,
    branch,
    path,
    base,
    state: @contracts.WORKTREE_STATE_READY,
    created_at: timestamp,
    updated_at: timestamp,
  }
  state.mutex.acquire()
  let created = state.append_worktree_event(
    @contracts.EVENT_WORKTREE_CREATED,
    made.id,
    @contracts.worktree_event_payload(made),
    Some(made),
    None,
  )
  let outcome = match created {
    Ok(_) =>
      match
        state.append_worktree_event(
          @contracts.EVENT_WORKTREE_READY,
          made.id,
          @contracts.worktree_event_payload(made),
          Some(made),
          None,
        ) {
        Ok(_) => Ok(@contracts.worktree_result(made))
        Err(message) =>
          Err(workspace_invalid("cannot record worktree ready: " + message))
      }
    Err(message) =>
      Err(workspace_invalid("cannot record worktree created: " + message))
  }
  state.mutex.release()
  match outcome {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_worktree_remove(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let worktree_id = match @contracts.string_field(request.params, "worktree_id") {
    Some(value) if value != "" => value
    _ => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing worktree_id"),
      )
      return
    }
  }
  let force = @contracts.bool_field_or(request.params, "force", false)
  let worktree = match lookup_worktree(state, worktree_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  state.mutex.acquire()
  let leased = match state.store.find_lease("worktree", worktree_id) {
    Ok(Some(_)) => true
    Ok(None) => false
    Err(message) => {
      state.mutex.release()
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("cannot read lease: " + message),
      )
      return
    }
  }
  let sessions = match state.store.list_all_bot_agent_sessions() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("cannot read Chat AgentSessions: " + message),
      )
      return
    }
  }
  let mut blocking_session = ""
  for session in sessions {
    if session.worktree_id == worktree_id &&
      @bots.agent_session_is_nonterminal(session.state) &&
      blocking_session == "" {
      blocking_session = session.id
    }
  }
  state.mutex.release()
  if leased {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.workspace_error(
        @contracts.WORKSPACE_ERR_CONFLICT,
        "worktree is leased by an active run",
      ),
    )
    return
  }
  if blocking_session != "" {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.workspace_error(
        @contracts.WORKSPACE_ERR_CONFLICT,
        "worktree has a non-terminal Chat AgentSession: " + blocking_session,
      ),
    )
    return
  }
  let workspace_record = match lookup_workspace(state, worktree.workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, workspace_record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match provider.remove_worktree(worktree.path, force) {
    Ok(_) => ()
    Err(error) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_error_of_provider(error),
      )
      return
    }
  }
  state.mutex.acquire()
  let outcome = match
    state.append_worktree_event(
      @contracts.EVENT_WORKTREE_ARCHIVED,
      worktree_id,
      @contracts.worktree_archived_payload(worktree_id),
      None,
      Some(worktree_id),
    ) {
    Ok(_) => Ok(@contracts.workspace_ack_result(worktree.workspace_id, ""))
    Err(message) =>
      Err(workspace_invalid("cannot record worktree archive: " + message))
  }
  state.mutex.release()
  match outcome {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_worktree_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = @contracts.string_field_or(request.params, "workspace_id", "")
  state.mutex.acquire()
  let result = match state.store.list_worktrees() {
    Ok(records) => {
      let filtered : Array[@contracts.WorktreeRecord] = []
      for record in records {
        if workspace_id == "" || record.workspace_id == workspace_id {
          filtered.push(record)
        }
      }
      Ok(@contracts.worktree_list_result(filtered))
    }
    Err(message) => Err(workspace_invalid("cannot list worktrees: " + message))
  }
  state.mutex.release()
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

// ---------------------------------------------------------------------------
// Leases
// ---------------------------------------------------------------------------

///|
async fn handle_lease_acquire(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let target_kind = @contracts.string_field_or(request.params, "target_kind", "")
  let target_id = @contracts.string_field_or(request.params, "target_id", "")
  let holder = @contracts.string_field_or(request.params, "holder", "run")
  if target_kind != "worktree" && target_kind != "workspace" {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      workspace_invalid("target_kind must be worktree or workspace"),
    )
    return
  }
  if target_id == "" {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      workspace_invalid("missing target_id"),
    )
    return
  }
  let now = @async.now()
  let made : @contracts.LeaseRecord = {
    id: @contracts.new_id("lse", now),
    target_kind,
    target_id,
    holder,
    created_at: @contracts.format_rfc3339(now),
  }
  state.mutex.acquire()
  let existing = match state.store.find_lease(target_kind, target_id) {
    Ok(value) => Ok(value)
    Err(message) => Err(workspace_invalid("cannot read lease: " + message))
  }
  let outcome = match existing {
    Ok(Some(_)) =>
      Err(
        @contracts.workspace_error(
          @contracts.WORKSPACE_ERR_CONFLICT,
          "target already has an active lease",
        ),
      )
    Ok(None) =>
      match
        state.append_lease_event(
          @contracts.EVENT_LEASE_ACQUIRED,
          made.id,
          @contracts.lease_event_payload(made),
          Some(made),
          None,
        ) {
        Ok(_) => Ok(@contracts.lease_result(made))
        Err(message) =>
          Err(workspace_invalid("cannot record lease: " + message))
      }
    Err(error) => Err(error)
  }
  state.mutex.release()
  match outcome {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_lease_release(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let lease_id = match @contracts.string_field(request.params, "lease_id") {
    Some(value) if value != "" => value
    _ => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing lease_id"),
      )
      return
    }
  }
  state.mutex.acquire()
  let outcome = match
    state.append_lease_event(
      @contracts.EVENT_LEASE_RELEASED,
      lease_id,
      @contracts.lease_released_payload(lease_id),
      None,
      Some(lease_id),
    ) {
    Ok(_) => Ok(@contracts.workspace_ack_result(lease_id, ""))
    Err(message) => Err(workspace_invalid("cannot release lease: " + message))
  }
  state.mutex.release()
  match outcome {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) => workspace_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_lease_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  let result = match state.store.list_leases() {
    Ok(leases) => Ok(@contracts.lease_list_result(leases))
    Err(message) => Err(workspace_invalid("cannot list leases: " + message))
  }
  state.mutex.release()
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

// ---------------------------------------------------------------------------
// Terminals
// ---------------------------------------------------------------------------

///|
async fn terminal_pump(state : HostState, session : TerminalSession) -> Unit {
  for ;; {
    let event = session.output.get() catch { _ => break }
    state.mutex.acquire()
    match event {
      @workspace.TerminalEvent::Data(text) => {
        session.transcript.val = session.transcript.val + text
        session.cursor.val = session.transcript.val.length()
      }
      @workspace.TerminalEvent::Eof => {
        session.eof.val = true
      }
    }
    let finished = session.eof.val
    state.mutex.release()
    if finished {
      break
    }
  }
  state.mutex.acquire()
  session.eof.val = true
  state.mutex.release()
}

///|
async fn handle_terminal_open(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = match @contracts.workspace_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid(message),
      )
      return
    }
  }
  let command = @contracts.string_field_or(request.params, "command", "")
  let rows = @contracts.int_field_or(request.params, "rows", 24)
  let cols = @contracts.int_field_or(request.params, "cols", 80)
  if !@contracts.terminal_size_is_valid(rows, cols) {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      workspace_invalid("rows and cols must be between 1 and 10000"),
    )
    return
  }
  let record = match lookup_workspace(state, workspace_id) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let provider = match provider_for_workspace(state, record) {
    Ok(value) => value
    Err(error) => {
      workspace_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let now = @async.now()
  let session_id = @contracts.new_id("term", now)
  let input : @aqueue.Queue[@workspace.TerminalInput] = @aqueue.Queue(
    kind=Unbounded,
  )
  let output : @aqueue.Queue[@workspace.TerminalEvent] = @aqueue.Queue(
    kind=Unbounded,
  )
  // An active environment runs the terminal in its container (local PTY in
  // front of docker exec, or an SSH TTY in front of the same argv). Only the
  // fixed docker argv is executed; no caller string is interpolated.
  let task = match active_environment_for_workspace_root(state, workspace_id) {
    Some(environment) => {
      let identity = match environment_identity_of_record(environment) {
        Ok(value) => value
        Err(error) => {
          workspace_io_error(state, sink, request, client_request_id, error)
          return
        }
      }
      let runner = match environment_runner_for_machine(state, environment.machine_id) {
        Ok(value) => value
        Err(error) => {
          workspace_io_error(state, sink, request, client_request_id, error)
          return
        }
      }
      match state.group.val {
        Some(group) =>
          group.spawn(allow_failure=true, () => {
            @environment.run_container_terminal(
              runner,
              identity,
              command,
              environment.workdir,
              record.root,
              rows.to_int(),
              cols.to_int(),
              input,
              output,
            )
          })
        None => {
          workspace_io_error(
            state,
            sink,
            request,
            client_request_id,
            workspace_invalid("host task group is not running"),
          )
          return
        }
      }
    }
    None =>
      match state.group.val {
        Some(group) =>
          group.spawn(allow_failure=true, () => {
            provider.run_terminal(
              session_id,
              command,
              rows.to_int(),
              cols.to_int(),
              input,
              output,
            )
          })
        None => {
          workspace_io_error(
            state,
            sink,
            request,
            client_request_id,
            workspace_invalid("host task group is not running"),
          )
          return
        }
      }
  }
  let session : TerminalSession = {
    id: session_id,
    workspace_id,
    input,
    output,
    transcript: Ref(""),
    cursor: Ref(0),
    eof: Ref(false),
    task,
  }
  state.mutex.acquire()
  state.terminals.set(session_id, session)
  state.mutex.release()
  match state.group.val {
    Some(group) =>
      group.spawn_bg(allow_failure=true, () => terminal_pump(state, session))
    None => ()
  }
  let open : @contracts.TerminalOpenResult = {
    session_id,
    workspace_id,
    cursor: 0L,
    text: "",
    eof: false,
  }
  let result = open.to_json()
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_terminal_write(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.string_field(request.params, "session_id") {
    Some(value) if value != "" => value
    _ => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing session_id"),
      )
      return
    }
  }
  let data = @contracts.string_field_or(request.params, "data", "")
  state.mutex.acquire()
  let session = state.terminals.get(session_id)
  state.mutex.release()
  let found = match session {
    Some(value) => value
    None => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_not_found("terminal session not found"),
      )
      return
    }
  }
  match found.input.put(@workspace.TerminalInput::Data(data)) {
    _ => ()
  }
  let result = @contracts.workspace_ack_result(session_id, "")
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_terminal_resize(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.string_field(request.params, "session_id") {
    Some(value) if value != "" => value
    _ => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing session_id"),
      )
      return
    }
  }
  let rows = match @contracts.int_field(request.params, "rows") {
    Some(value) => value
    None => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing rows"),
      )
      return
    }
  }
  let cols = match @contracts.int_field(request.params, "cols") {
    Some(value) => value
    None => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing cols"),
      )
      return
    }
  }
  if !@contracts.terminal_size_is_valid(rows, cols) {
    workspace_io_error(
      state,
      sink,
      request,
      client_request_id,
      workspace_invalid("rows and cols must be between 1 and 10000"),
    )
    return
  }
  state.mutex.acquire()
  let session = state.terminals.get(session_id)
  state.mutex.release()
  let found = match session {
    Some(value) => value
    None => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_not_found("terminal session not found"),
      )
      return
    }
  }
  match
    found.input.put(
      @workspace.TerminalInput::Resize(rows, cols),
    ) {
    _ => ()
  }
  let result = @contracts.terminal_resize_result(session_id, rows, cols)
  send_machine_result(state, sink, request, client_request_id, result)
}

///|
async fn handle_terminal_read(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.string_field(request.params, "session_id") {
    Some(value) if value != "" => value
    _ => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing session_id"),
      )
      return
    }
  }
  let requested = @contracts.int64_field_or(request.params, "cursor", 0L)
  state.mutex.acquire()
  let session = state.terminals.get(session_id)
  let outcome = match session {
    Some(value) => {
      let full = value.transcript.val
      let length = full.length()
      let cursor = if requested < 0L {
        0
      } else if requested > length.to_int64() {
        length
      } else {
        requested.to_int()
      }
      let text = if cursor >= length {
        ""
      } else {
        full.substring(start=cursor)
      }
      value.cursor.val = length
      let read : @contracts.TerminalRead = {
        session_id,
        cursor: length.to_int64(),
        text,
        eof: value.eof.val,
      }
      Ok(read)
    }
    None => Err(workspace_not_found("terminal session not found"))
  }
  state.mutex.release()
  match outcome {
    Ok(value) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        value.to_json(),
      )
    Err(error) =>
      workspace_io_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_terminal_close(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.string_field(request.params, "session_id") {
    Some(value) if value != "" => value
    _ => {
      workspace_io_error(
        state,
        sink,
        request,
        client_request_id,
        workspace_invalid("missing session_id"),
      )
      return
    }
  }
  state.mutex.acquire()
  let session = state.terminals.get(session_id)
  state.terminals.remove(session_id)
  state.mutex.release()
  match session {
    Some(value) => {
      value.task.cancel()
      value.input.close()
      value.output.close()
    }
    None => ()
  }
  let result = @contracts.workspace_ack_result(session_id, "")
  send_machine_result(state, sink, request, client_request_id, result)
}
