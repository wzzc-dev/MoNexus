///|
/// Adapter from the paired-runtime MachineProvider to the AgentRuntime
/// ProcessLauncher seam (A1.4).
///
/// This package is the only place that knows both `runtime.process.*` and the
/// agent launcher interface. `providers/runtime` stays ACP-free (it only knows
/// streaming processes), and `providers/agent` stays runtime-free (it only
/// knows a stdio handle), preserving the three-axis boundary
/// (ADR-0003, ADR-0012 §6).
///
/// The node launches the agent with its own environment and login credentials.
/// The adapter sends an explicit minimal allowlist — never a host environment
/// map — so model keys, private keys and `~/.ssh` never cross the transport.
/// `CLAUDECODE` is absent from the allowlist, which keeps the adapter's
/// nested-invocation rule without a shell wrapper.

///|
/// The only node environment names an ACP agent receives. Values are read from
/// the node's own environment by the runtime core; they are not sent by the
/// primary. Secret-named variables are rejected by the runtime's validator.
pub fn runtime_agent_env_allowlist() -> Array[String] {
  ["HOME", "PATH", "LANG"]
}

///|
fn exit_of(snapshot : @provider_runtime.ProcessSnapshot) -> @agent.RemoteExit {
  {
    status: snapshot.status,
    exit_code: snapshot.exit_code,
    signal: snapshot.signal,
    stop_reason: snapshot.stop_reason,
    success: snapshot.success,
  }
}

///|
fn chunk_of(
  stream : String,
  chunk : @provider_runtime.ProcessChunkSnapshot,
) -> Result[@agent.RemoteChunk, String] {
  let data = @base64.decode(chunk.data_b64) catch {
    _ => return Err("runtime " + stream + " chunk is not valid base64")
  }
  Ok({
    offset: chunk.offset,
    next_offset: chunk.next_offset,
    data,
    eof: chunk.eof,
    gap: chunk.gap,
    dropped: chunk.dropped,
    total_bytes: chunk.total_bytes,
  })
}

///|
/// Map a primary workspace path to the node-rooted path the runtime accepts.
///
/// The primary and node do not share a filesystem. A workspace opened on the
/// primary has a primary-side root (for example `/home/owner/project`), while
/// the node executes under its own `--workspace` root with the same relative
/// layout. `workspace_roots` are the primary-side roots the attach layer
/// registered for this machine; an absolute cwd below one of them is passed
/// as the relative suffix, and the node resolves it against its own root.
///
/// Relative cwds pass through unchanged (the node validates and contains
/// them). An absolute cwd outside every mapped root is rejected: silently
/// running in a different directory is worse than failing the start.
pub fn runtime_agent_cwd(
  cwd : String,
  workspace_roots : Array[String],
) -> Result[String, String] {
  let trimmed = cwd.trim().to_owned()
  if trimmed == "" || !trimmed.has_prefix("/") {
    return Ok(trimmed)
  }
  // Normalize trailing slashes on both sides so `/ws/` and `/ws` match.
  let normalized = if trimmed.length() > 1 && trimmed.has_suffix("/") {
    let mut value = trimmed
    while value.length() > 1 && value.has_suffix("/") {
      value = value[:value.length() - 1].to_owned()
    }
    value
  } else {
    trimmed
  }
  for root in workspace_roots {
    let mut base = root.trim().to_owned()
    if base == "" || !base.has_prefix("/") {
      continue
    }
    while base.length() > 1 && base.has_suffix("/") {
      base = base[:base.length() - 1].to_owned()
    }
    if normalized == base {
      return Ok("")
    }
    if normalized.has_prefix(base + "/") {
      return Ok(normalized[base.length() + 1:].to_owned())
    }
  }
  Err(
    "runtime agent cwd is outside the workspace roots mapped to this machine",
  )
}

///|
/// Build the launcher the host registers for one paired runtime machine. When
/// an `ApprovalContext` is supplied, `process.start` goes through the same
/// Decision/approval-binding path as `exec.start`; without one the node still
/// fails closed for a high-risk start, so no gate is bypassed.
///
/// `workspace_roots` are the primary-side workspace paths mapped to this
/// runtime; see `runtime_agent_cwd`.
pub fn runtime_agent_launcher(
  machine : @provider_runtime.RuntimeMachine,
  approval~ : @provider_runtime.ApprovalContext? = None,
  workspace_roots~ : Array[String] = [],
) -> @agent.RemoteLauncher {
  @agent.RemoteLauncher::new(start=async fn(spec) {
    let cwd = match runtime_agent_cwd(spec.cwd, workspace_roots) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    let now = @async.now()
    let run_id = @contracts.new_id("proc", now)
    let client_request_id = @contracts.new_id("crid", now)
    let allowlist = runtime_agent_env_allowlist()
    let started = match approval {
      Some(context) =>
        match
          machine.process_start_approved(
            run_id~,
            client_request_id~,
            argv=spec.argv,
            cwd=cwd,
            inherit_env=allowlist,
            risk=spec.risk,
            approval=context,
          ) {
          Ok((process, _existing)) => Ok(process)
          Err(failure) => Err(failure.error_text())
        }
      None =>
        match
          machine.process_start(
            run_id~,
            client_request_id~,
            argv=spec.argv,
            cwd=cwd,
            inherit_env=allowlist,
            risk=spec.risk,
          ) {
          Ok((process, _existing)) => Ok(process)
          Err(error) => Err(error.message)
        }
    }
    let process = match started {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    let stdin_seq : Ref[Int] = Ref(0)
    let cancel_seq : Ref[Int] = Ref(0)
    let api = @agent.RemoteApi::new(
      write_stdin=async fn(data) {
        let next = stdin_seq.val + 1
        stdin_seq.val = next
        let crid = run_id + "-in-" + next.to_string()
        let encoded = @base64.encode(data.exact_view(), padding=true)
        match machine.process_stdin(run_id, encoded, client_request_id=crid) {
          Ok(_) => Ok(())
          Err(error) => Err(error.message)
        }
      },
      read_stdout=async fn(offset) {
        match machine.process_stdout(run_id, offset) {
          Ok(chunk) => chunk_of("stdout", chunk)
          Err(error) => Err(error.message)
        }
      },
      read_stderr=async fn(offset) {
        match machine.process_stderr(run_id, offset) {
          Ok(chunk) => chunk_of("stderr", chunk)
          Err(error) => Err(error.message)
        }
      },
      exit=async fn() {
        // EOF can precede the durable exit record by a few milliseconds. Poll
        // briefly; an absent or unreachable record stays `None`, which the
        // agent layer classifies `lost` (never success).
        let mut attempts = 0
        while attempts < 40 {
          match machine.process_exit(process.run_id) {
            Ok(Some(snapshot)) =>
              if snapshot.is_terminal() || attempts >= 39 {
                return Ok(Some(exit_of(snapshot)))
              }
            Ok(None) => return Ok(None)
            Err(error) => return Err(error.message)
          }
          attempts = attempts + 1
          @async.sleep(50)
        }
        Ok(None)
      },
      cancel=async fn() {
        let next = cancel_seq.val + 1
        cancel_seq.val = next
        let crid = run_id + "-cancel-" + next.to_string()
        match machine.process_cancel(process.run_id, client_request_id=crid) {
          Ok(_) => Ok(())
          Err(error) => Err(error.message)
        }
      },
    )
    Ok(@agent.RemoteStarted::new(process.run_id, process.pid, api))
  })
}
