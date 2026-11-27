///|
/// Runtime-node adapter for environment lifecycle (ADR-0013 §5, A2.2).
///
/// The lifecycle engine is unchanged: it builds the same docker argv, uses the
/// same env-file hand-off and the same cleanup matrix. This module translates
/// the runner's operations into `runtime.exec.*`, `runtime.fs.*` and
/// `runtime.pty.*` calls on the paired node. The node holds no environment
/// table, recipe library or approval state; it only enforces the A1.3b policy
/// snapshot and one-time grants minted by the primary.
///
/// The primary is the sole authority. The host validates the A2.1
/// `environment_approval` Decision (plan digest, machine, recipe hash) before
/// this adapter is used; the decision id rides along as the grant's Decision
/// binding. When the plan needs no Decision, the primary authorizes the
/// operation directly (an empty decision id), exactly as A2.1 does for local
/// and SSH machines.

///|
const RUNTIME_ENV_ROOT_SUFFIX : String = "/.monexus/environments"

///|
const RUNTIME_EXEC_POLL_MS : Int = 100

///|
const RUNTIME_PTY_EVENT_POLL_MS : Int = 50

///|
const RUNTIME_PTY_STATUS_POLL_MS : Int = 250

///|
const RUNTIME_READ_SLICE_BYTES : Int = 32_768

///|
const RUNTIME_EVENT_PTY_OUTPUT : String = "runtime.pty.output"

///|
const RUNTIME_EVENT_PTY_EXITED : String = "runtime.pty.exited"

///|
fn runtime_environment_failure(
  code : String,
  action : String,
  detail : String,
) -> EnvFailure {
  EnvFailure::new(code, "runtime " + action + " failed").with_detail(detail)
}

///|
fn runtime_rpc_failure(
  error : @contracts.RpcError,
  action : String,
) -> EnvFailure {
  let code = if error.code == @contracts.ERR_HOST ||
    error.code == @transport.ERR_REVOKED ||
    error.code == @transport.ERR_POLICY_STALE {
    @contracts.ENVIRONMENT_ERR_UNREACHABLE
  } else if error.code == @transport.ERR_PATH_DENIED {
    @contracts.ENVIRONMENT_ERR_INVALID
  } else {
    @contracts.ENVIRONMENT_ERR_INTERNAL
  }
  runtime_environment_failure(code, action, error.message)
}

///|
fn runtime_approval_failure(
  failure : @runtime.ApprovalFailure,
  action : String,
) -> EnvFailure {
  match failure {
    @runtime.ApprovalFailure::Denied(decision_id) =>
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED,
        "the owner denied the runtime operation",
      ).with_detail("decision " + decision_id)
    @runtime.ApprovalFailure::Expired(decision_id) =>
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED,
        "the approval expired before the runtime operation started",
      ).with_detail("decision " + decision_id)
    @runtime.ApprovalFailure::Pending(decision_id) =>
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED,
        "the owner has not answered the runtime approval yet",
      ).with_detail("decision " + decision_id)
    @runtime.ApprovalFailure::Unavailable(reason) =>
      runtime_environment_failure(
        @contracts.ENVIRONMENT_ERR_UNREACHABLE,
        action,
        reason,
      )
    @runtime.ApprovalFailure::Rejected(code, label) =>
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED,
        "the runtime policy did not authorize the operation",
      ).with_detail(label + " (" + code.to_string() + ")")
    @runtime.ApprovalFailure::Rpc(error) => runtime_rpc_failure(error, action)
  }
}

///|
/// Locate an absolute environment path under one of the node's two rooted
/// filesystems. The environment root is preferred: env directories, env files
/// and the scratch directory live under `~/.monexus/environments`; only a
/// path outside it may fall back to the registered workspace root.
fn runtime_fs_locate(
  environment_root : String,
  workspace_root : String,
  path : String,
) -> Result[(String, String), EnvFailure] {
  if !@recipes.is_valid_host_path(path) {
    return Err(
      runtime_environment_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "filesystem operation",
        "path is not an absolute normalised host path",
      ),
    )
  }
  let inside_env = path == environment_root ||
    path.has_prefix(environment_root + "/")
  let inside_workspace = path == workspace_root ||
    path.has_prefix(workspace_root + "/")
  let (selector, root) = if inside_env && path != environment_root {
    (@contracts.RUNTIME_FS_ROOT_ENVIRONMENTS, environment_root)
  } else if !inside_env && inside_workspace && path != workspace_root {
    (@contracts.RUNTIME_FS_ROOT_WORKSPACE, workspace_root)
  } else {
    return Err(
      runtime_environment_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "filesystem operation",
        "path is a root directory or outside the node's registered roots",
      ),
    )
  }
  let relative = path[root.length() + 1:].to_owned()
  Ok((selector, relative))
}

///|
fn runtime_fs_params(
  selector : String,
  relative : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("root", @contracts.json_string(selector))
  params.set("path", @contracts.json_string(relative))
  params
}

///|
/// Read one stream of a finished run. The node's slice is bounded; the loop
/// advances by the byte count the node reports. A read failure means the
/// primary cannot verify the command's output, so it is an error, never a
/// fabricated success.
async fn runtime_read_log(
  machine : @runtime.RuntimeMachine,
  run_id : String,
  stream : String,
) -> Result[String, EnvFailure] {
  let out = StringBuilder()
  let mut offset = 0L
  for ;; {
    let slice = match
      machine.exec_read(
        run_id~,
        stream~,
        offset~,
        max_bytes=RUNTIME_READ_SLICE_BYTES,
      ) {
      Ok(value) => value
      Err(error) => return Err(runtime_rpc_failure(error, "exec.read"))
    }
    let written = out.to_string()
    if slice.data != "" && written.length() < DOCKER_OUTPUT_CAP {
      let remaining = DOCKER_OUTPUT_CAP - written.length()
      if slice.data.length() > remaining {
        out.write_string(slice.data[:remaining].to_owned())
      } else {
        out.write_string(slice.data)
      }
    }
    let next = offset + slice.bytes
    if next <= offset {
      break
    }
    offset = next
    if slice.eof || out.to_string().length() >= DOCKER_OUTPUT_CAP {
      break
    }
  }
  Ok(out.to_string())
}

///|
/// Run one docker argv on the paired node and wait for its exit. The run id is
/// fresh per invocation and the grant is minted per command; a denial, expiry
/// or unverifiable channel is always an `Err`. A timeout cancels the run and
/// reports `timeout`; it never reports a successful exit.
async fn runtime_invoke_docker(
  machine : @runtime.RuntimeMachine,
  approval : @runtime.ApprovalContext,
  argv : Array[String],
  timeout_s : Int,
) -> Result[DockerOutput, EnvFailure] {
  // The lifecycle builders produce `docker`-less argv (`pull ...`,
  // `exec ...`); the local and SSH runners prepend the program, so the runtime
  // adapter does the same and the node resolves `docker` on its PATH.
  let full_argv : Array[String] = ["docker"]
  for item in argv {
    full_argv.push(item)
  }
  if full_argv.length() < 2 {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "docker argv is empty",
      ),
    )
  }
  let seconds = if timeout_s < 1 { 1 } else { timeout_s }
  let run_id = @contracts.new_id("run", @async.now())
  let started = match
    machine.exec_start_approved(
      run_id~,
      client_request_id=run_id,
      argv=full_argv,
      approval~,
    ) {
    Ok(value) => value.0
    Err(failure) => {
      return Err(runtime_approval_failure(failure, "exec.start"))
    }
  }
  let deadline = @async.now() + seconds.to_int64() * 1_000L
  let mut run = started
  for ;; {
    if run.is_terminal() {
      break
    }
    if @async.now() >= deadline {
      let cancel_id = @contracts.new_id("cancel", @async.now())
      match machine.exec_cancel(run_id, client_request_id=cancel_id) {
        _ => ()
      }
      return Err(timeout_failure(seconds, ""))
    }
    @async.sleep(RUNTIME_EXEC_POLL_MS)
    run = match machine.exec_status(run_id) {
      Ok(Some(value)) => value
      Ok(None) =>
        // The node lost the run record: never treat that as success.
        return Err(
          runtime_environment_failure(
            @contracts.ENVIRONMENT_ERR_UNREACHABLE,
            "exec.status",
            "the runtime no longer reports the run",
          ),
        )
      Err(error) => return Err(runtime_rpc_failure(error, "exec.status"))
    }
  }
  let stdout = match runtime_read_log(machine, run_id, "stdout") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stderr = match runtime_read_log(machine, run_id, "stderr") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if run.timed_out {
    return Err(timeout_failure(seconds, stderr))
  }
  let exit_code = match run.exit_code {
    Some(value) => value
    None =>
      return Err(
        runtime_environment_failure(
          @contracts.ENVIRONMENT_ERR_UNREACHABLE,
          "exec.status",
          "the runtime reported a terminal run without an exit code",
        ),
      )
  }
  Ok({ exit_code, stdout, stderr })
}

///|
async fn runtime_fs_stat_entry(
  machine : @runtime.RuntimeMachine,
  selector : String,
  relative : String,
) -> Result[(String, Int), EnvFailure] {
  let json = match machine.fs_stat(path=relative, root=selector) {
    Ok(value) => value
    Err(error) => return Err(runtime_rpc_failure(error, "fs.stat"))
  }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None =>
      return Err(
        runtime_environment_failure(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "fs.stat",
          "fs.stat returned a non-object",
        ),
      )
  }
  Ok((
    @contracts.string_field_or(object, "kind", "unknown"),
    @contracts.int_field_or(object, "mode", 0) & 0o777,
  ))
}

///|
async fn runtime_make_dir_locked(
  machine : @runtime.RuntimeMachine,
  approval : @runtime.ApprovalContext,
  selector : String,
  relative : String,
) -> Result[Unit, EnvFailure] {
  let params = runtime_fs_params(selector, relative)
  params.set("recursive", @contracts.json_bool(true))
  let client_request_id = @contracts.new_id("mkdir", @async.now())
  let command : Array[String] = ["mkdir", selector + ":" + relative]
  let _ = match
    machine.mutate_with_approval(
      rpc_method=@contracts.METHOD_RUNTIME_FS_MKDIR,
      params~,
      binding_run_id=client_request_id,
      client_request_id~,
      command~,
      approval~,
    ) {
    Ok(value) => value
    Err(failure) => {
      return Err(runtime_approval_failure(failure, "fs.mkdir"))
    }
  }
  match runtime_fs_stat_entry(machine, selector, relative) {
    Ok(("dir", mode)) =>
      if mode != 0o700 {
        Err(
          runtime_environment_failure(
            @contracts.ENVIRONMENT_ERR_INTERNAL,
            "fs.mkdir",
            "environment directory mode is not owner-only",
          ),
        )
      } else {
        Ok(())
      }
    Ok(_) =>
      Err(
        runtime_environment_failure(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "fs.mkdir",
          "environment path is not a directory",
        ),
      )
    Err(error) => Err(error)
  }
}

///|
async fn runtime_remove_entry(
  machine : @runtime.RuntimeMachine,
  approval : @runtime.ApprovalContext,
  selector : String,
  relative : String,
  recursive : Bool,
  action : String,
) -> Result[Unit, EnvFailure] {
  let params = runtime_fs_params(selector, relative)
  if recursive {
    params.set("recursive", @contracts.json_bool(true))
  }
  let client_request_id = @contracts.new_id("remove", @async.now())
  let command : Array[String] = if recursive {
    ["remove", selector + ":" + relative, "recursive"]
  } else {
    ["remove", selector + ":" + relative]
  }
  match
    machine.mutate_with_approval(
      rpc_method=@contracts.METHOD_RUNTIME_FS_REMOVE,
      params~,
      binding_run_id=client_request_id,
      client_request_id~,
      command~,
      approval~,
    ) {
    Ok(_) => Ok(())
    Err(failure) => Err(runtime_approval_failure(failure, action))
  }
}

///|
/// Build the five filesystem/exec operations and the PTY transport for one
/// paired node. `environment_root` is `<home>/.monexus/environments`; it is
/// the only subtree `runtime.fs.*` addresses with `root=environments`.
pub fn runtime_ops_for_machine(
  machine~ : @runtime.RuntimeMachine,
  home~ : String,
  workspace_root~ : String,
  ttl_ms~ : Int64 = 300_000L,
  wait_ms~ : Int64 = 5_000L,
) -> Result[RuntimeOps, EnvFailure] {
  let trimmed_home = home.trim().to_owned()
  if trimmed_home == "" || !@recipes.is_valid_host_path(trimmed_home) {
    return Err(
      runtime_environment_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "environment root",
        "the runtime reported no usable home directory",
      ),
    )
  }
  let environment_root = trimmed_home + RUNTIME_ENV_ROOT_SUFFIX
  let trimmed_workspace = workspace_root.trim().to_owned()
  let workspace_root = if trimmed_workspace == "" {
    environment_root
  } else if @recipes.is_valid_host_path(trimmed_workspace) {
    trimmed_workspace
  } else {
    return Err(
      runtime_environment_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "workspace root",
        "the runtime workspace root is not an absolute normalised path",
      ),
    )
  }
  let make_approval = fn(decision_id : String) -> @runtime.ApprovalContext {
    let port : @runtime.ApprovalPort = fn(request) {
      // The primary already validated the A2.1 environment Decision (or the
      // plan needs no Decision). This is the same owner approval; the node
      // still verifies the resulting one-time grant against its snapshot.
      ignore(request)
      @runtime.ApprovalOutcome::Approved(decision_id)
    }
    @runtime.ApprovalContext::new(port~, ttl_ms~, wait_ms~)
  }
  let invoke = async fn(
    argv : Array[String],
    timeout_s : Int,
    decision_id : String,
  ) -> Result[DockerOutput, EnvFailure] {
    runtime_invoke_docker(machine, make_approval(decision_id), argv, timeout_s)
  }
  let make_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    let (selector, relative) = match
      runtime_fs_locate(environment_root, workspace_root, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    runtime_make_dir_locked(
      machine,
      make_approval(decision_id),
      selector,
      relative,
    )
  }
  let write_env = async fn(
    dir : String,
    variables : Array[@docker.EnvironmentVariable],
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    let (selector, relative) = match
      runtime_fs_locate(environment_root, workspace_root, dir) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    // The directory must exist and be owner-only before the secret is written.
    match
      runtime_make_dir_locked(
        machine,
        make_approval(decision_id),
        selector,
        relative,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let content = match @docker.env_file_content(variables) {
      Ok(value) => value
      Err(error) => return Err(env_failure_from_docker(error))
    }
    let env_relative = relative + "/env"
    let params = runtime_fs_params(selector, env_relative)
    params.set("content", @contracts.json_string(content))
    let client_request_id = @contracts.new_id("envfile", @async.now())
    let command : Array[String] = [selector + ":" + env_relative]
    let _ = match
      machine.mutate_with_approval(
        rpc_method=@contracts.METHOD_RUNTIME_FS_WRITE,
        params~,
        binding_run_id=client_request_id,
        client_request_id~,
        command~,
        approval=make_approval(decision_id),
      ) {
      Ok(value) => value
      Err(failure) => {
        return Err(runtime_approval_failure(failure, "fs.write"))
      }
    }
    // Verify the secret stayed owner-only. Any mismatch removes it and is a
    // refused hand-off, exactly like the SSH verify script.
    match runtime_fs_stat_entry(machine, selector, env_relative) {
      Ok(("file", mode)) =>
        if (mode & 0o777) == 0o600 {
          Ok(())
        } else {
          let _ = runtime_remove_entry(
            machine,
            make_approval(decision_id),
            selector,
            env_relative,
            false,
            "env file cleanup",
          )
          Err(
            EnvFailure::new(
              @contracts.ENVIRONMENT_ERR_SECRET_REJECTED,
              "runtime env file mode is not owner-only",
            ),
          )
        }
      Ok(_) =>
        Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_SECRET_REJECTED,
            "runtime env file is not a regular file",
          ),
        )
      Err(error) => Err(error)
    }
  }
  let remove_file = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    let (selector, relative) = match
      runtime_fs_locate(environment_root, workspace_root, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    runtime_remove_entry(
      machine,
      make_approval(decision_id),
      selector,
      relative,
      false,
      "env file removal",
    )
  }
  let remove_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    let (selector, relative) = match
      runtime_fs_locate(environment_root, workspace_root, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    runtime_remove_entry(
      machine,
      make_approval(decision_id),
      selector,
      relative,
      true,
      "environment directory removal",
    )
  }
  let terminal = async fn(
    argv : Array[String],
    rows : Int32,
    cols : Int32,
    input : @aqueue.Queue[@workspace.TerminalInput],
    output : @aqueue.Queue[@workspace.TerminalEvent],
    decision_id : String,
  ) -> Unit {
    runtime_terminal(
      machine,
      make_approval(decision_id),
      argv,
      rows,
      cols,
      input,
      output,
    )
  }
  Ok({
    invoke,
    make_dir,
    write_env,
    remove_file,
    remove_dir,
    terminal,
  })
}

///|
async fn runtime_terminal_emit(
  output : @aqueue.Queue[@workspace.TerminalEvent],
  text : String,
) -> Unit {
  if text != "" {
    output.put(@workspace.TerminalEvent::Data(text)) catch { _ => () }
  }
}

///|
/// Stream a node PTY terminal. Output arrives as durable
/// `runtime.pty.output` events (the node exposes no `pty.read` method); input
/// and close are forwarded as mutating PTY calls. A close or an observed exit
/// ends the pump, and the terminal always ends with exactly one Eof.
async fn runtime_terminal(
  machine : @runtime.RuntimeMachine,
  approval : @runtime.ApprovalContext,
  docker_argv : Array[String],
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[@workspace.TerminalInput],
  output : @aqueue.Queue[@workspace.TerminalEvent],
) -> Unit {
  if docker_argv.is_empty() {
    runtime_terminal_emit(output, "terminal: the runtime docker argv is empty\n")
    output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
    output.close()
    return
  }
  // The terminal transport receives `docker`-less argv, matching the local and
  // SSH branches; the program is prepended here for node PATH resolution.
  let argv : Array[String] = ["docker"]
  for item in docker_argv {
    argv.push(item)
  }
  let session_id = @contracts.new_id("pty", @async.now())
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("argv", @contracts.json_string_array(argv))
  params.set("rows", @contracts.json_int(rows.to_int()))
  params.set("cols", @contracts.json_int(cols.to_int()))
  match
    machine.mutate_with_approval(
      rpc_method=@contracts.METHOD_RUNTIME_PTY_OPEN,
      params~,
      binding_run_id=session_id,
      client_request_id=session_id,
      command=argv,
      approval~,
    ) {
    Ok(_) => ()
    Err(failure) => {
      runtime_terminal_emit(
        output,
        "terminal: " +
        runtime_approval_failure(failure, "pty.open").to_string() +
        "\n",
      )
      output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
      output.close()
      return
    }
  }
  let runtime_id = machine.runtime_id()
  let state = machine.state()
  let exited : Ref[Bool] = Ref(false)
  let closed : Ref[Bool] = Ref(false)
  @async.with_task_group(async fn(group) {
    // Durable PTY output events, resuming from the local cursor.
    group.spawn_bg(() => {
      let cursor : Ref[Int64] = Ref(0L)
      while !exited.val && !closed.val {
        let events = state.events_since(runtime_id, cursor.val)
        for event in events {
          if event.seq > cursor.val {
            cursor.val = event.seq
          }
          if event.run_id == session_id {
            if event.kind == RUNTIME_EVENT_PTY_OUTPUT {
              match @contracts.as_object(event.payload) {
                Some(object) =>
                  runtime_terminal_emit(
                    output,
                    sanitize_terminal(
                      @contracts.string_field_or(object, "data", ""),
                    ),
                  )
                None => ()
              }
            } else if event.kind == RUNTIME_EVENT_PTY_EXITED {
              exited.val = true
            }
          }
        }
        if !exited.val && !closed.val {
          @async.sleep(RUNTIME_PTY_EVENT_POLL_MS)
        }
      }
      group.return_immediately(())
    })
    // Status poll: catches an exit whose event has not been pumped yet.
    group.spawn_bg(() => {
      let mut failures = 0
      while !exited.val && !closed.val {
        @async.sleep(RUNTIME_PTY_STATUS_POLL_MS)
        if exited.val || closed.val {
          break
        }
        match machine.pty_status(session_id) {
          Ok(status) =>
            if !status.running {
              exited.val = true
            }
          Err(_) => failures = failures + 1
        }
        if failures >= 20 {
          runtime_terminal_emit(
            output,
            "terminal: the runtime session status is not reachable\n",
          )
          closed.val = true
        }
      }
      group.return_immediately(())
    })
    // Input forwarding and close.
    for ;; {
      if exited.val || closed.val {
        break
      }
      let item = input.get() catch { _ => break }
      match item {
        @workspace.TerminalInput::Data(text) => {
          let input_id = @contracts.new_id("ptyin", @async.now())
          match machine.pty_input(
            session_id~,
            data=text,
            client_request_id=input_id,
          ) {
            _ => ()
          }
        }
        @workspace.TerminalInput::Resize(rows, cols) => {
          let resize_id = @contracts.new_id("ptyresize", @async.now())
          match machine.pty_resize(
            session_id~,
            rows=rows.to_int(),
            cols=cols.to_int(),
            client_request_id=resize_id,
          ) {
            _ => ()
          }
        }
        @workspace.TerminalInput::Close => break
      }
    }
    if !exited.val {
      let close_id = @contracts.new_id("ptyclose", @async.now())
      match machine.pty_close(session_id, client_request_id=close_id) {
        _ => ()
      }
    }
    closed.val = true
    group.return_immediately(())
  })
  output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
  output.close()
}
