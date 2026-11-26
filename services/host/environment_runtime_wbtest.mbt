///|
/// Whitebox tests for the A2.2 host seam: a `kind=runtime` machine is served
/// only through its paired link. There is no SSH or local fallback, an
/// unattached node is an honest `unreachable`, and the recorded plan mount is
/// authoritative for cleanup. Local machines keep their A2.1 runner.

///|
fn runtime_wbtest_machine(
  id : String,
  kind : String,
  host : String,
) -> @contracts.MachineRecord {
  {
    id,
    kind,
    name: id,
    host,
    port: 0,
    user: "",
    identity: "",
    use_ssh_config: false,
    host_key_policy: @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file: "",
    status: @contracts.MACHINE_STATUS_ONLINE,
    profile: None,
    ssh_effective: Map([]),
    ssh_effective_error: "",
    last_seen: "",
    last_error: "",
    created_at: "2026-02-01T00:00:00Z",
    updated_at: "2026-02-01T00:00:00Z",
  }
}

///|
async fn runtime_wbtest_primary() -> @transport.PrimaryState {
  match
    @transport.PrimaryState::open(
      @transport.StateStore::memory(),
      @transport.CredentialPolicy::until_revoked(),
    ) {
    Ok(value) => value
    Err(message) => abort("cannot open a primary state: " + message)
  }
}

///|
async fn runtime_wbtest_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
fn runtime_wbtest_noop_ops() -> @environment.RuntimeOps {
  let invoke = async fn(
    argv : Array[String],
    timeout_s : Int,
    decision_id : String,
  ) -> Result[@environment.DockerOutput, @environment.EnvFailure] {
    ignore(argv)
    ignore(timeout_s)
    ignore(decision_id)
    Ok({ exit_code: 0, stdout: "", stderr: "" })
  }
  let make_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, @environment.EnvFailure] {
    ignore(path)
    ignore(decision_id)
    Ok(())
  }
  let write_env = async fn(
    dir : String,
    variables : Array[@docker.EnvironmentVariable],
    decision_id : String,
  ) -> Result[Unit, @environment.EnvFailure] {
    ignore(dir)
    ignore(variables)
    ignore(decision_id)
    Ok(())
  }
  let remove_file = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, @environment.EnvFailure] {
    ignore(path)
    ignore(decision_id)
    Ok(())
  }
  let remove_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, @environment.EnvFailure] {
    ignore(path)
    ignore(decision_id)
    Ok(())
  }
  let terminal = async fn(
    argv : Array[String],
    rows : Int32,
    cols : Int32,
    input : @aqueue.Queue[@workspace.TerminalInput],
    output : @aqueue.Queue[@workspace.TerminalEvent],
    decision_id : String,
  ) -> Unit {
    ignore(argv)
    ignore(rows)
    ignore(cols)
    ignore(input)
    ignore(output)
    ignore(decision_id)
  }
  { invoke, make_dir, write_env, remove_file, remove_dir, terminal }
}

///|
async test "runtime kind without a link is unreachable and never falls back" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  match store.put_machine(runtime_wbtest_machine("mach_rt", @contracts.MACHINE_KIND_RUNTIME, "rt-test")) {
    Ok(_) => ()
    Err(message) => abort("cannot store the runtime machine: " + message)
  }
  match environment_runner_for_machine(state, "mach_rt") {
    Ok(_) =>
      fail("a runtime machine without a paired session must not build a runner")
    Err(error) => {
      assert_true(error.message.contains("unreachable"))
      assert_true(error.message.contains("paired transport session"))
    }
  }
}

///|
async test "a linked runtime machine builds a runtime runner, never a local one" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  match store.put_machine(runtime_wbtest_machine("mach_rt", @contracts.MACHINE_KIND_RUNTIME, "rt-test")) {
    Ok(_) => ()
    Err(message) => abort("cannot store the runtime machine: " + message)
  }
  let home = @fs.tmpdir(prefix="monexus-runtime-link-home-")
  defer runtime_wbtest_cleanup(home)
  let primary = runtime_wbtest_primary()
  let machine = @provider_runtime.RuntimeMachine::new(primary, "rt-test")
  state.mutex.acquire()
  state.runtimes.set(
    "mach_rt",
    {
      machine_id: "mach_rt",
      runtime_id: "rt-test",
      home,
      environment_root: home + "/.monexus/environments",
      workspace_root: home,
      machine,
    },
  )
  state.mutex.release()
  let runner = match environment_runner_for_machine(state, "mach_rt") {
    Ok(value) => value
    Err(error) => fail("linked runtime machine was refused: " + error.message)
  }
  assert_true(runner.is_runtime())
  // A runtime runner executes off-primary, so it is remote, but it is not an
  // SSH runner and must not carry an SSH target.
  assert_true(runner.remote)
  assert_eq(runner.home, home)
  match runner.target {
    None => ()
    Some(_) => fail("a runtime runner must not carry an SSH target")
  }
  // The node is linked but has no live channel here: every operation is an
  // honest unreachable error, never an in-process execution.
  match (runner.invoke)(["pull", "docker.io/library/alpine"], 5) {
    Ok(_) => fail("a disconnected runtime must not report a docker success")
    Err(error) => assert_eq(error.code, @contracts.ENVIRONMENT_ERR_UNREACHABLE)
  }
  match
    (runner.make_dir)(home + "/.monexus/environments/env_runtime_wbtest") {
    Ok(_) => fail("a disconnected runtime must not create a node directory")
    Err(error) => assert_eq(error.code, @contracts.ENVIRONMENT_ERR_UNREACHABLE)
  }
}

///|
async test "local machines keep the A2.1 local runner" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  match store.put_machine(runtime_wbtest_machine("mach_local", @contracts.MACHINE_KIND_LOCAL, "localhost")) {
    Ok(_) => ()
    Err(message) => abort("cannot store the local machine: " + message)
  }
  let runner = match environment_runner_for_machine(state, "mach_local") {
    Ok(value) => value
    Err(error) => fail("local machine was refused: " + error.message)
  }
  assert_true(!runner.is_runtime())
  assert_true(!runner.remote)
  match runner.target {
    None => ()
    Some(_) => fail("a local runner must not carry an SSH target")
  }
}

///|
test "scratch cleanup prefers the recorded plan mount" {
  let workspace_mount : @contracts.EnvironmentMount = {
    source: "workspace",
    host_path: "/srv/work",
    container_path: "/workspace",
    mode: "rw",
  }
  let scratch_mount : @contracts.EnvironmentMount = {
    source: "scratch",
    host_path: "/home/dev/.monexus/environments/env_1/scratch",
    container_path: "/scratch",
    mode: "ro",
  }
  let recorded = {
    ..environment_test_record("env_1", "wsp_1", ""),
    mounts: [workspace_mount, scratch_mount],
  }
  assert_eq(
    environment_scratch_dir(recorded),
    "/home/dev/.monexus/environments/env_1/scratch",
  )
  // A legacy record with only a workspace mount keeps the derived path.
  let legacy = {
    ..environment_test_record("env_2", "wsp_1", ""),
    mounts: [workspace_mount],
  }
  assert_eq(
    environment_scratch_dir(legacy),
    "/srv/work" + @environment.DEFAULT_SCRATCH_SUFFIX + "env_2",
  )
  let none = {
    ..environment_test_record("env_3", "wsp_1", ""),
    mounts: [],
  }
  assert_eq(environment_scratch_dir(none), "")
}

///|
async test "runtime plans keep the scratch under the node environment dir" {
  let local_runner_value = @environment.local_runner(
    machine_id="",
    home="/home/dev",
  )
  assert_eq(
    environment_scratch_root(local_runner_value, "/srv/work", "env_1"),
    "/srv/work" + @environment.DEFAULT_SCRATCH_SUFFIX + "env_1",
  )
  let home = "/home/dev"
  let runner = @environment.runtime_runner(
    machine_id="mach_rt",
    home=home,
    ops=runtime_wbtest_noop_ops(),
  )
  assert_true(runner.is_runtime())
  assert_eq(
    environment_scratch_root(runner, "/srv/work", "env_1"),
    home + "/.monexus/environments/env_1/scratch",
  )
}
