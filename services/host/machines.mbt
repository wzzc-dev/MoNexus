///|
/// Machine RPC handlers (M2).
///
/// The host is the only writer: add/remove append events and update the
/// SQLite projection in one transaction; probe performs the SSH I/O without
/// holding the state mutex, then re-checks the machine and records the
/// outcome. Every failure is mapped onto a readable `machine_error` so the
/// desktop can show Unauthorized/Timeout/NotFound instead of an ssh exit code.

///|
fn machine_target(record : @contracts.MachineRecord) -> @ssh.SshTarget {
  @ssh.SshTarget::new(
    host=record.host,
    port=record.port,
    user=record.user,
    identity=record.identity,
    use_ssh_config=record.use_ssh_config,
    host_key_policy=record.host_key_policy,
    known_hosts_file=record.known_hosts_file,
    timeout_seconds=10,
  )
}

///|
fn machine_target_of_spec(spec : @contracts.MachineAddSpec) -> @ssh.SshTarget {
  @ssh.SshTarget::new(
    host=spec.host,
    port=spec.port,
    user=spec.user,
    identity=spec.identity,
    use_ssh_config=spec.use_ssh_config,
    host_key_policy=spec.host_key_policy,
    known_hosts_file=spec.known_hosts_file,
    timeout_seconds=10,
  )
}

///|
fn machine_error_kind_of_provider(
  kind : @provider_error.ProviderErrorKind,
) -> String {
  match kind {
    AuthFailed => @contracts.MACHINE_ERR_UNAUTHORIZED
    ConnectTimeout => @contracts.MACHINE_ERR_TIMEOUT
    NotFound => @contracts.MACHINE_ERR_NOT_FOUND
    HostKey => @contracts.MACHINE_ERR_HOST_KEY
    RemoteExit => @contracts.MACHINE_ERR_REMOTE
    SpawnFailed | Transport | NotConfigured => @contracts.MACHINE_ERR_UNREACHABLE
    PtyFailed | Cancelled | Internal => @contracts.MACHINE_ERR_INTERNAL
  }
}

///|
fn contract_profile(profile : @ssh.MachineProfile) -> @contracts.MachineProfile {
  let notes = if profile.notes == "" {
    "probe ran via POSIX login shell"
  } else {
    profile.notes
  }
  @contracts.MachineProfile::new(
    arch=profile.arch,
    os=profile.os,
    hostname=profile.hostname,
    shell=profile.shell,
    toolchains=profile.tools,
    has_docker=profile.has_docker,
    has_gui=profile.has_gui,
    max_parallel=profile.max_parallel,
    notes=notes,
  )
}

///|
/// `ssh -G` values to store on the record. The error string is kept for
/// display so a broken ssh config is visible without hiding the machine.
async fn resolve_effective_for(
  target : @ssh.SshTarget,
) -> (Map[String, String], String) {
  match @ssh.resolve_effective(target, timeout_seconds=5) {
    Ok(value) => (value, "")
    Err(error) => (Map([]), error.to_string())
  }
}

///|
/// Send a machine error response and cache it under the request id, so a
/// retry after a failure is idempotent too. Caller must not hold the mutex.
async fn send_machine_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  error : @contracts.RpcError,
) -> Unit {
  state.mutex.acquire()
  let text = error_response_text(request.id, error)
  state.cache_response(client_request_id, text)
  state.mutex.release()
  sink.send(text)
}

///|
async fn send_machine_result(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  result : @json.Json,
) -> Unit {
  state.mutex.acquire()
  let response : @contracts.RpcResponse = {
    id: request.id,
    result: Some(result),
    error: None,
  }
  let text = response.to_json().stringify()
  state.cache_response(client_request_id, text)
  state.mutex.release()
  sink.send(text)
}

///|
fn live_machine(
  state : HostState,
  machine_id : String,
) -> Result[@contracts.MachineRecord?, String] {
  state.store.get_machine(machine_id)
}

///|
async fn handle_machine_add(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let spec = match @contracts.parse_machine_add(request.params) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INVALID,
          message,
        ),
      )
      return
    }
  }
  // `ssh -G` is local and fast; recording the effective values at add time
  // makes the explicit target auditable even before the first probe.
  let target = machine_target_of_spec(spec)
  let (effective, effective_error) = resolve_effective_for(target)
  let now = @async.now()
  let ts = @contracts.format_rfc3339(now)
  let record : @contracts.MachineRecord = {
    id: @contracts.new_id("mch", now),
    kind: @contracts.MACHINE_KIND_SSH,
    name: spec.name,
    host: spec.host,
    port: spec.port,
    user: spec.user,
    identity: spec.identity,
    use_ssh_config: spec.use_ssh_config,
    host_key_policy: spec.host_key_policy,
    known_hosts_file: spec.known_hosts_file,
    status: @contracts.MACHINE_STATUS_UNKNOWN,
    profile: None,
    ssh_effective: effective,
    ssh_effective_error: effective_error,
    last_seen: "",
    last_error: "",
    created_at: ts,
    updated_at: ts,
  }
  state.mutex.acquire()
  // Re-check the cache: a duplicate request may have completed while ssh -G
  // was running on another connection.
  match state.cache.get(client_request_id) {
    Some(text) => {
      state.mutex.release()
      sink.send(text)
      return
    }
    None => ()
  }
  let payload = @contracts.machine_event_payload(record)
  let appended = state.append_machine_event(
    @contracts.EVENT_MACHINE_REGISTERED,
    "machine/" + record.id,
    payload,
    Some(record),
    None,
  )
  match appended {
    Ok(_) => ()
    Err(message) => {
      let text = error_response_text(
        request.id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot persist machine: " + message,
        ),
      )
      state.cache_response(client_request_id, text)
      state.mutex.release()
      sink.send(text)
      return
    }
  }
  state.mutex.release()
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.machine_record_result(record),
  )
}

///|
async fn handle_machine_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  match state.store.list_machines() {
    Ok(machines) => {
      let text = error_or_result_text(
        request.id,
        Ok(@contracts.machine_list_result(machines)),
      )
      state.cache_response(client_request_id, text)
      state.mutex.release()
      sink.send(text)
    }
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot list machines: " + message,
        ),
      )
    }
  }
}

///|
fn error_or_result_text(
  request_id : String,
  result : Result[@json.Json, String],
) -> String {
  match result {
    Ok(value) => {
      let response : @contracts.RpcResponse = {
        id: request_id,
        result: Some(value),
        error: None,
      }
      response.to_json().stringify()
    }
    Err(message) => {
      let response : @contracts.RpcResponse = {
        id: request_id,
        result: None,
        error: Some(
          @contracts.machine_error(@contracts.MACHINE_ERR_INTERNAL, message),
        ),
      }
      response.to_json().stringify()
    }
  }
}

///|
async fn handle_machine_remove(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = match @contracts.machine_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(@contracts.MACHINE_ERR_INVALID, message),
      )
      return
    }
  }
  state.mutex.acquire()
  let existing = match live_machine(state, machine_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_NOT_FOUND,
          "machine not found: " + machine_id,
        ),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot read machine: " + message,
        ),
      )
      return
    }
  }
  let payload = @contracts.machine_removed_payload(machine_id)
  let outcome = state.append_machine_event(
    @contracts.EVENT_MACHINE_REMOVED,
    "machine/" + existing.id,
    payload,
    None,
    Some(machine_id),
  )
  match outcome {
    Ok(_) => {
      let text = {
        let response : @contracts.RpcResponse = {
          id: request.id,
          result: Some(@contracts.machine_remove_result(machine_id)),
          error: None,
        }
        response.to_json().stringify()
      }
      state.cache_response(client_request_id, text)
      state.mutex.release()
      sink.send(text)
    }
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot remove machine: " + message,
        ),
      )
    }
  }
}

///|
/// Probe one machine. SSH I/O happens with the mutex released; the record is
/// re-read afterwards so a concurrent `machine.remove` cannot resurrect it.
async fn handle_machine_probe(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let machine_id = match @contracts.machine_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(@contracts.MACHINE_ERR_INVALID, message),
      )
      return
    }
  }
  let timeout_seconds = @contracts.machine_probe_timeout(
    request.params,
    10,
  )
  state.mutex.acquire()
  let existing = match live_machine(state, machine_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_NOT_FOUND,
          "machine not found: " + machine_id,
        ),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot read machine: " + message,
        ),
      )
      return
    }
  }
  state.mutex.release()
  let target = machine_target(existing)
  let (ssh_effective, ssh_effective_error) = resolve_effective_for(target)
  let probed = @ssh.probe(target, timeout_seconds=timeout_seconds)
  let ts = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  // Re-check: the machine may have been removed while ssh was running.
  let current = match live_machine(state, machine_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_NOT_FOUND,
          "machine was removed while probing: " + machine_id,
        ),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot read machine: " + message,
        ),
      )
      return
    }
  }
  match probed {
    Ok(profile) => {
      let contract = contract_profile(profile)
      let status = if contract.is_complete() {
        @contracts.MACHINE_STATUS_ONLINE
      } else {
        @contracts.MACHINE_STATUS_DEGRADED
      }
      let updated : @contracts.MachineRecord = {
        ..current,
        status,
        profile: Some(contract),
        ssh_effective,
        ssh_effective_error,
        last_seen: ts,
        last_error: "",
        updated_at: ts,
      }
      let payload = @contracts.machine_event_payload(updated)
      // A transition from unknown/offline also emits `machine.connected`;
      // both events carry the final record so replay is order-insensitive
      // beyond "last one wins".
      if !current.is_reachable() {
        let connected = state.append_machine_event(
          @contracts.EVENT_MACHINE_CONNECTED,
          "machine/" + updated.id,
          payload,
          Some(updated),
          None,
        )
        match connected {
          Ok(_) => ()
          Err(message) => {
            state.mutex.release()
            send_machine_error(
              state,
              sink,
              request,
              client_request_id,
              @contracts.machine_error(
                @contracts.MACHINE_ERR_INTERNAL,
                "cannot persist machine state: " + message,
              ),
            )
            return
          }
        }
      }
      let appended = state.append_machine_event(
        @contracts.EVENT_MACHINE_PROBED,
        "machine/" + updated.id,
        payload,
        Some(updated),
        None,
      )
      match appended {
        Ok(_) => ()
        Err(message) => {
          state.mutex.release()
          send_machine_error(
            state,
            sink,
            request,
            client_request_id,
            @contracts.machine_error(
              @contracts.MACHINE_ERR_INTERNAL,
              "cannot persist probe result: " + message,
            ),
          )
          return
        }
      }
      state.mutex.release()
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_probe_result(updated, contract),
      )
    }
    Err(error) => {
      let kind = machine_error_kind_of_provider(error.kind)
      let readable =
        @contracts.machine_error_label(kind) + ": " + error.message
      let updated : @contracts.MachineRecord = {
        ..current,
        status: @contracts.MACHINE_STATUS_OFFLINE,
        ssh_effective,
        ssh_effective_error,
        last_error: readable,
        updated_at: ts,
      }
      let payload = @contracts.machine_event_payload(updated)
      let appended = state.append_machine_event(
        @contracts.EVENT_MACHINE_DISCONNECTED,
        "machine/" + updated.id,
        payload,
        Some(updated),
        None,
      )
      match appended {
        Ok(_) => ()
        Err(message) => println(
          "monexus-host: cannot persist disconnected state: " + message,
        )
      }
      state.mutex.release()
      let detail = match error.detail {
        Some(value) => value
        None => ""
      }
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.machine_error(kind, error.message, detail=detail),
      )
    }
  }
}
