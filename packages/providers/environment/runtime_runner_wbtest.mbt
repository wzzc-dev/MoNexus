///|
/// Whitebox tests for the A2.2 runtime runner seam. The adapter's wire calls
/// are exercised end to end in `services/runtime-node`; here we pin the seam
/// itself: the Decision bound to the runner reaches every operation, the
/// runtime flag/terminal transport are set, and the unchanged lifecycle engine
/// produces the same behavior through a runtime runner as through a local one.

///|
struct RuntimeFakeOpsTrace {
  decisions : Ref[Array[String]]
  calls : Ref[Array[String]]
}

///|
fn runtime_fake_ops(trace : RuntimeFakeOpsTrace) -> RuntimeOps {
  let invoke = async fn(
    argv : Array[String],
    timeout_s : Int,
    decision_id : String,
  ) -> Result[DockerOutput, EnvFailure] {
    ignore(timeout_s)
    trace.decisions.val.push(decision_id)
    trace.calls.val.push("invoke " + argv.join(" "))
    Ok({ exit_code: 0, stdout: "ok", stderr: "" })
  }
  let make_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    trace.decisions.val.push(decision_id)
    trace.calls.val.push("mkdir " + path)
    Ok(())
  }
  let write_env = async fn(
    dir : String,
    variables : Array[@docker.EnvironmentVariable],
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    ignore(variables)
    trace.decisions.val.push(decision_id)
    trace.calls.val.push("write_env " + dir)
    Ok(())
  }
  let remove_file = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    trace.decisions.val.push(decision_id)
    trace.calls.val.push("remove_file " + path)
    Ok(())
  }
  let remove_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    trace.decisions.val.push(decision_id)
    trace.calls.val.push("remove_dir " + path)
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
    ignore(rows)
    ignore(cols)
    ignore(input)
    trace.decisions.val.push(decision_id)
    trace.calls.val.push("terminal " + argv.join(" "))
    output.put(@workspace.TerminalEvent::Data("fake-terminal")) catch {
      _ => ()
    }
    output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
    output.close()
  }
  { invoke, make_dir, write_env, remove_file, remove_dir, terminal }
}

///|
async test "runtime runner binds its Decision to every operation" {
  let trace : RuntimeFakeOpsTrace = {
    decisions: Ref([]),
    calls: Ref([]),
  }
  let ops = runtime_fake_ops(trace)
  let runner = runtime_runner(
    machine_id="mach_rt",
    home="/home/dev",
    ops~,
  )
  assert_true(runner.is_runtime())
  assert_true(runner.remote)
  match runner.target {
    None => ()
    Some(_) => fail("a runtime runner must not carry an SSH target")
  }
  runner.set_approval_decision("dec_plan")
  match (runner.invoke)(["pull", "docker.io/library/alpine"], 30) {
    Ok(_) => ()
    Err(error) => fail("runtime invoke failed: " + error.to_string())
  }
  match (runner.make_dir)("/home/dev/.monexus/environments/env_1") {
    Ok(_) => ()
    Err(error) => fail("runtime mkdir failed: " + error.to_string())
  }
  match
    (runner.write_secret)(
      "/home/dev/.monexus/environments/env_1",
      [{ name: "PATH", value: "/usr/bin:/bin" }],
    ) {
    Ok(_) => ()
    Err(error) => fail("runtime write failed: " + error.to_string())
  }
  match (runner.remove_file)("/home/dev/.monexus/environments/env_1/env") {
    Ok(_) => ()
    Err(error) => fail("runtime remove_file failed: " + error.to_string())
  }
  match (runner.remove_dir)("/home/dev/.monexus/environments/env_1") {
    Ok(_) => ()
    Err(error) => fail("runtime remove_dir failed: " + error.to_string())
  }
  let input : @aqueue.Queue[@workspace.TerminalInput] = @aqueue.Queue(
    kind=Unbounded,
  )
  let output : @aqueue.Queue[@workspace.TerminalEvent] = @aqueue.Queue(
    kind=Unbounded,
  )
  runner.set_approval_decision("dec_terminal")
  match runner.terminal {
    Some(terminal) => terminal(["exec", "-i", "-t", "c"], 24, 80, input, output)
    None => fail("a runtime runner must carry a terminal transport")
  }
  assert_eq(runner.authorization.unwrap().val, "dec_terminal")
  assert_eq(trace.calls.val[0], "invoke pull docker.io/library/alpine")
  assert_eq(trace.calls.val[1], "mkdir /home/dev/.monexus/environments/env_1")
  assert_eq(
    trace.calls.val[2],
    "write_env /home/dev/.monexus/environments/env_1",
  )
  assert_eq(trace.calls.val[5], "terminal exec -i -t c")
  // The plan Decision covered the docker/fs hand-off; the terminal has its
  // own binding. No operation sees an empty binding after it was set.
  for index in 0..<5 {
    assert_eq(trace.decisions.val[index], "dec_plan")
  }
  assert_eq(trace.decisions.val[5], "dec_terminal")
}

///|
fn runtime_parity_normalize_marker(text : String, marker : String) -> String {
  let out = StringBuilder()
  let mut rest = text
  for ;; {
    let index = match rest.find(marker) {
      Some(value) => value
      None => {
        out.write_string(rest)
        break
      }
    }
    out.write_string(rest.substring(start=0, end=index + marker.length()))
    let tail = rest.substring(start=index + marker.length())
    let cut = match tail.find(".pid") {
      Some(value) => value
      None => tail.length()
    }
    out.write_string("<id>")
    rest = tail.substring(start=cut)
  }
  out.to_string()
}

///|
/// Exec marker scripts carry a per-call run id, so the raw argv cannot be
/// compared across two independent lifecycle runs. Normalize the id part of
/// every `monexus/exec-<id>.pid` / `monexus-exec-<id>.pid` marker; everything
/// else in the argv vector is deterministic and must match exactly.
fn runtime_parity_normalize(call : String) -> String {
  runtime_parity_normalize_marker(
    runtime_parity_normalize_marker(call, "monexus/exec-"),
    "monexus-exec-",
  )
}

///|
fn runtime_parity_calls(
  calls : Array[Array[String]],
) -> Array[Array[String]] {
  calls.map(fn(argv) { argv.map(runtime_parity_normalize) })
}

///|
/// The fake `RuntimeOps` that delegates to a `FakeDocker`-backed runner, so
/// the exact same lifecycle vector can run on both seams.
fn runtime_parity_ops(backing : DockerRunner) -> RuntimeOps {
  let invoke = async fn(
    argv : Array[String],
    timeout_s : Int,
    decision_id : String,
  ) -> Result[DockerOutput, EnvFailure] {
    ignore(decision_id)
    (backing.invoke)(argv, timeout_s)
  }
  let make_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    ignore(decision_id)
    (backing.make_dir)(path)
  }
  let write_env = async fn(
    dir : String,
    variables : Array[@docker.EnvironmentVariable],
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    ignore(decision_id)
    (backing.write_secret)(dir, variables)
  }
  let remove_file = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    ignore(decision_id)
    (backing.remove_file)(path)
  }
  let remove_dir = async fn(
    path : String,
    decision_id : String,
  ) -> Result[Unit, EnvFailure] {
    ignore(decision_id)
    (backing.remove_dir)(path)
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
    ignore(decision_id)
    output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
    output.close()
  }
  { invoke, make_dir, write_env, remove_file, remove_dir, terminal }
}

///|
async test "local and runtime runners run the same lifecycle vector the same way" {
  let root = @fs.tmpdir(prefix="env-runtime-parity")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let local_fake = fake_docker()
  let local = fake_runner(local_fake, home, plan.identity)
  let runtime_fake = fake_docker()
  let backing = fake_runner(runtime_fake, home, plan.identity)
  let runtime = runtime_runner(
    machine_id="mach_rt",
    home=home,
    ops=runtime_parity_ops(backing),
  )
  let local_create = match create_container(local, plan) {
    Ok(_) => "ok"
    Err(failure) => "failed:" + failure.failure.code
  }
  let runtime_create = match create_container(runtime, plan) {
    Ok(_) => "ok"
    Err(failure) => "failed:" + failure.failure.code
  }
  assert_eq(local_create, "ok")
  assert_eq(runtime_create, local_create)
  assert_eq(runtime_parity_calls(local_fake.calls.val), runtime_parity_calls(runtime_fake.calls.val))
  assert_eq(local_fake.env_file_mode.val, runtime_fake.env_file_mode.val)
  let local_exec = match
    exec_in_container(
      local,
      plan.identity,
      ["sh", "-c", "printf parity"],
      plan.workdir,
      10,
    ) {
    Ok(value) => "ok:" + value.stdout
    Err(error) => "failed:" + error.code
  }
  let runtime_exec = match
    exec_in_container(
      runtime,
      plan.identity,
      ["sh", "-c", "printf parity"],
      plan.workdir,
      10,
    ) {
    Ok(value) => "ok:" + value.stdout
    Err(error) => "failed:" + error.code
  }
  assert_eq(local_exec, "ok:hello")
  assert_eq(runtime_exec, local_exec)
  let local_destroy = destroy_container(
    local,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  let runtime_destroy = destroy_container(
    runtime,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  assert_true(local_destroy.ok)
  assert_eq(runtime_destroy.ok, local_destroy.ok)
  assert_eq(local_fake.ops.val, runtime_fake.ops.val)
  assert_eq(runtime_parity_calls(local_fake.calls.val), runtime_parity_calls(runtime_fake.calls.val))
  // Destroy leaves no managed container and no environment directory.
  match inspect_container(runtime, plan.identity) {
    Ok(None) => ()
    Ok(Some(_)) => fail("runtime destroy left the container behind")
    Err(error) => fail("cannot confirm runtime destroy: " + error.to_string())
  }
  assert_true(!(@fs.exists(plan.env_dir) catch { _ => true }))
}
