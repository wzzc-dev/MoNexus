///|
/// Opportunistic real-Docker end to end test. It is deliberately skipped when
/// the daemon, the `alpine` image or its repo digest are unavailable, so the
/// deterministic fake-runner suite remains the primary coverage. When it can
/// run it exercises the real create -> exec -> destroy path, including the
/// env-file, labels and argv the host will actually send.

///|
fn e2e_skip(reason : String) -> Unit {
  println("environment docker e2e skipped: " + reason)
}

///|
async fn e2e_docker_text(argv : Array[String]) -> (Int, String) {
  let result = @process.collect_output("docker", argv) catch {
    _ => return (-1, "")
  }
  let (code, stdout, _) = result
  let text = stdout.text() catch { _ => "" }
  (code, text.trim().to_owned())
}

///|
async fn e2e_nginx_digest() -> (String, String)? {
  let (daemon_code, _) = e2e_docker_text(
    ["info", "--format", "{{.ServerVersion}}"],
  )
  if daemon_code != 0 {
    e2e_skip("no reachable Docker daemon")
    return None
  }
  let (image_code, repo_digests) = e2e_docker_text(
    [
      "image",
      "inspect",
      "--format",
      "{{range .RepoDigests}}{{println .}}{{end}}",
      "nginx:alpine",
    ],
  )
  if image_code != 0 || repo_digests == "" {
    e2e_skip("nginx:alpine image with a repo digest is not available locally")
    return None
  }
  let mut image_ref = ""
  let mut image_digest = ""
  for line in repo_digests.split("\n") {
    if image_ref == "" && line.contains("@sha256:") {
      for part in line.split("@") {
        if image_ref == "" {
          image_ref = part.to_owned()
        } else if image_digest == "" {
          image_digest = part.to_owned()
        }
      }
    }
  }
  if image_ref == "" || !image_digest.starts_with("sha256:") {
    e2e_skip("nginx:alpine image has no usable repo digest")
    return None
  }
  Some((image_ref, image_digest))
}

///|
async test "real docker create, exec and destroy when a daemon is present" {
  let (image_ref, image_digest) = match e2e_nginx_digest() {
    Some(value) => value
    None => return
  }
  let root = @fs.tmpdir(prefix="monexus-env-e2e")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true, permission=0o755) catch { _ => () }
  @fs.mkdir(workspace, recursive=true, permission=0o777) catch { _ => () }
  @fs.mkdir(workspace + "/project", recursive=true, permission=0o777) catch {
    _ => ()
  }
  let environment_id = @contracts.new_id("env", @async.now())
  let base = test_recipe()
  let recipe = {
    ..base,
    image: {
      ..base.image,
      reference: image_ref,
      digest: image_digest,
    },
    user: Some("0:0"),
  }
  let inputs : PlanInputs = {
    environment_id,
    workspace_id: "wsp_01ARYZ6S41",
    worktree_id: "",
    machine_id: "",
    primary_id: @contracts.ORG_LOCAL,
    workspace_root: workspace,
    scratch_root: workspace + DEFAULT_SCRATCH_SUFFIX + environment_id,
    env_values: [
      { name: "HOME", value: "/home/dev" },
      {
        name: "PATH",
        value: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      },
    ],
    extra_mounts: [],
  }
  let plan = match
    compute_environment_plan(recipe, test_recipe_hash, inputs, home) {
    Ok(value) => value
    Err(error) => fail("e2e plan failed: " + error.to_string())
  }
  let runner = local_runner(machine_id="", home=home)
  match create_container(runner, plan) {
    Ok(_) => ()
    Err(failure) =>
      fail(
        "real docker create failed: " + failure.failure.to_string() + " / " +
        failure.cleanup_log,
      )
  }
  let exec = exec_in_container(
    runner,
    plan.identity,
    ["sh", "-c", "printf e2e-ok"],
    plan.workdir,
    20,
  )
  let destroyed = destroy_container(
    runner,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  let present = inspect_container(runner, plan.identity)
  match exec {
    Ok(output) => {
      assert_eq(output.exit_code, 0)
      assert_true(output.stdout.contains("e2e-ok"))
      assert_true(!output.timed_out)
    }
    Err(error) => fail("real docker exec failed: " + error.to_string())
  }
  assert_true(destroyed.ok)
  match present {
    Ok(Some(_)) => fail("destroy left the managed container behind")
    Ok(None) => ()
    Err(error) => fail("cannot confirm destroy: " + error.to_string())
  }
  let env_dir_exists = @fs.exists(plan.env_dir) catch { _ => true }
  assert_true(!env_dir_exists)
}

///|
async test "real docker cancelled exec stops mutating the workspace" {
  let (image_ref, image_digest) = match e2e_nginx_digest() {
    Some(value) => value
    None => return
  }
  let root = @fs.tmpdir(prefix="monexus-env-e2e-cancel")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true, permission=0o755) catch { _ => () }
  @fs.mkdir(workspace, recursive=true, permission=0o777) catch { _ => () }
  @fs.mkdir(workspace + "/project", recursive=true, permission=0o777) catch {
    _ => ()
  }
  let environment_id = @contracts.new_id("env", @async.now())
  let base = test_recipe()
  let recipe = {
    ..base,
    image: {
      ..base.image,
      reference: image_ref,
      digest: image_digest,
    },
    user: Some("0:0"),
  }
  let inputs : PlanInputs = {
    environment_id,
    workspace_id: "wsp_01ARYZ6S41",
    worktree_id: "",
    machine_id: "",
    primary_id: @contracts.ORG_LOCAL,
    workspace_root: workspace,
    scratch_root: workspace + DEFAULT_SCRATCH_SUFFIX + environment_id,
    env_values: [
      { name: "HOME", value: "/home/dev" },
      {
        name: "PATH",
        value: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      },
    ],
    extra_mounts: [],
  }
  let plan = match
    compute_environment_plan(recipe, test_recipe_hash, inputs, home) {
    Ok(value) => value
    Err(error) => fail("e2e plan failed: " + error.to_string())
  }
  let runner = local_runner(machine_id="", home=home)
  match create_container(runner, plan) {
    Ok(_) => ()
    Err(failure) =>
      fail(
        "real docker create failed: " + failure.failure.to_string() + " / " +
        failure.cleanup_log,
      )
  }
  let marker = workspace + "/project/marker.txt"
  let outcome : Ref[Result[ExecOutput, EnvFailure]?] = Ref(None)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let task = group.spawn(async fn() -> Unit {
      outcome.val = Some(
        exec_in_container(
          runner,
          plan.identity,
          [
            "sh",
            "-c",
            "while true; do printf x >> /workspace/project/marker.txt; sleep 0.05; done",
          ],
          plan.workdir,
          120,
        ),
      )
    })
    // Wait until the command is visibly mutating the bind-mounted workspace so
    // cancellation happens mid-stream, not before the process existed.
    let mut waited = 0
    while waited < 5_000 && !(@fs.exists(marker) catch { _ => false }) {
      @async.sleep(100)
      waited = waited + 100
    }
    task.cancel()
  })
  let outcome_value = match outcome.val {
    Some(value) => value
    None => {
      let _ = destroy_container(
        runner,
        plan.identity,
        plan.env_dir,
        plan.scratch_dir,
      )
      fail("cancelled exec left no outcome")
    }
  }
  let size_after = @fs.file_size(marker) catch { _ => 0L }
  @async.sleep(1_000)
  let size_later = @fs.file_size(marker) catch { _ => 0L }
  let running = inspect_container(runner, plan.identity)
  let destroyed = destroy_container(
    runner,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  assert_true(size_after > 0L)
  match outcome_value {
    Ok(_) => fail("a cancelled real exec must never report success")
    Err(error) => assert_true(error.message.contains("cancelled"))
  }
  // The container-side process group is gone: the workspace stops growing
  // while the container itself keeps running (cancel is not stop/destroy).
  assert_eq(size_later, size_after)
  match running {
    Ok(Some(value)) => assert_true(value.running)
    _ => fail("cancel must leave the managed container running")
  }
  assert_true(destroyed.ok)
}
