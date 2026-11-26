///|
/// A2.2: one paired runtime node attached to this primary, keyed by the
/// `kind=runtime` machine record that names it. The link holds only what the
/// environment path needs to build a runner: the live provider (which speaks
/// over the pinned transport session) and the node's home/workspace roots as
/// reported by `runtime.probe`.
///
/// The link is not an environment record or a lease store: those remain in the
/// host's single `EnvironmentStore`, exactly as for local and SSH machines. It
/// is also not an approval authority; every mutating call still mints a
/// one-time A1.3b grant against the published policy snapshot.
pub(all) struct RuntimeLink {
  machine_id : String
  runtime_id : String
  home : String
  environment_root : String
  workspace_root : String
  machine : @provider_runtime.RuntimeMachine
}

///|
/// The policy snapshot a primary publishes before running environment
/// lifecycles on a node. It grants exactly the operations the lifecycle and
/// terminal need; docker argv remains high risk, so each command still needs a
/// one-time grant from the primary's approval path.
fn environment_runtime_policy(
  version : String,
) -> Result[@policy.PolicySnapshot, String] {
  let now = @async.now()
  let rules = @policy.PolicyRules::new(
    allow_read_only=true,
    allowed_operations=[
      "control", "exec", "fs.write", "fs.delete", "pty", "git.write",
    ],
    env_allowlist=["HOME", "LANG", "PATH"],
  )
  @policy.PolicySnapshot::new(
    version~,
    issued_at_ms=now - 1_000L,
    expires_at_ms=now + 86_400_000L,
    rules~,
  )
}

///|
/// Attach a paired runtime node to the host. The machine record must be
/// `kind=runtime` and the node must be connected and ack the environment
/// policy before the link becomes usable; a node that cannot host environments
/// (no home directory) is refused rather than guessed at.
///
/// `workspace_root` is optional: when empty the first registered node root is
/// used. Environment files always live under `<home>/.monexus/environments`
/// and are addressed with `root=environments`, never as arbitrary host paths.
pub async fn attach_runtime_link(
  state : HostState,
  machine_id~ : String,
  primary~ : @transport.PrimaryState,
  runtime_id~ : String,
  workspace_root~ : String = "",
  policy_version~ : String = "",
) -> Result[RuntimeLink, @contracts.RpcError] {
  if machine_id == "" || runtime_id == "" {
    return Err(
      @contracts.machine_error(
        @contracts.MACHINE_ERR_INVALID,
        "a runtime link needs both a machine id and a runtime id",
      ),
    )
  }
  state.mutex.acquire()
  let loaded = state.store.get_machine(machine_id)
  state.mutex.release()
  let record = match loaded {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        @contracts.machine_error(
          @contracts.MACHINE_ERR_NOT_FOUND,
          "machine not found: " + machine_id,
        ),
      )
    Err(message) =>
      return Err(
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot read machine: " + message,
        ),
      )
  }
  if record.kind != @contracts.MACHINE_KIND_RUNTIME {
    return Err(
      @contracts.machine_error(
        @contracts.MACHINE_ERR_INVALID,
        "machine " + machine_id + " is not kind=runtime",
      ),
    )
  }
  if record.host != "" && record.host != runtime_id {
    return Err(
      @contracts.machine_error(
        @contracts.MACHINE_ERR_INVALID,
        "machine " + machine_id + " names runtime " + record.host +
        ", not " + runtime_id,
      ),
    )
  }
  let machine = @provider_runtime.RuntimeMachine::new(primary, runtime_id)
  let probe = match machine.probe() {
    Ok(value) => value
    Err(error) =>
      return Err(
        @contracts.machine_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "runtime.probe failed: " + error.message,
        ),
      )
  }
  if probe.home == "" || probe.environment_root == "" {
    return Err(
      @contracts.machine_error(
        @contracts.MACHINE_ERR_INVALID,
        "the runtime reported no home directory; it cannot host environments",
      ),
    )
  }
  let workspace_root = if workspace_root != "" {
    workspace_root
  } else if probe.workspace_roots.length() > 0 {
    probe.workspace_roots[0]
  } else {
    ""
  }
  let version = if policy_version != "" {
    policy_version
  } else {
    @contracts.new_id("pol", @async.now())
  }
  let snapshot = match environment_runtime_policy(version) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @contracts.machine_error(
          @contracts.MACHINE_ERR_INTERNAL,
          "cannot build the environment policy: " + message,
        ),
      )
  }
  let announcement = match primary.publish_policy(snapshot) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @contracts.machine_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "cannot publish the environment policy: " + message,
        ),
      )
  }
  let deadline = @async.now() + 10_000L
  while !primary.policy_installed(
    runtime_id,
    announcement.version,
    announcement.hash,
  ) {
    if @async.now() >= deadline {
      return Err(
        @contracts.machine_error(
          @contracts.MACHINE_ERR_UNREACHABLE,
          "the runtime did not acknowledge the environment policy",
        ),
      )
    }
    @async.sleep(50)
  }
  let link : RuntimeLink = {
    machine_id,
    runtime_id,
    home: probe.home,
    environment_root: probe.environment_root,
    workspace_root,
    machine,
  }
  state.mutex.acquire()
  state.runtimes.set(machine_id, link)
  state.mutex.release()
  Ok(link)
}

///|
/// Remove a link. Idempotent; the environment records and leases stay in the
/// store, so a later reattach can reconcile the same environments.
pub async fn detach_runtime_link(state : HostState, machine_id : String) -> Unit {
  state.mutex.acquire()
  state.runtimes.remove(machine_id)
  state.mutex.release()
}

///|
/// The link for one runtime machine, or `None` when no session is attached.
/// Callers must not hold `state.mutex`.
async fn runtime_link_for(
  state : HostState,
  machine_id : String,
) -> RuntimeLink? {
  state.mutex.acquire()
  let link = state.runtimes.get(machine_id)
  state.mutex.release()
  link
}
