///|
async test "create runs pinned argv, removes the secret env file and keeps 0700 dirs" {
  let root = @fs.tmpdir(prefix="env-create")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let environment_id = "env_01ARYZ6S41"
  let plan = test_plan(home, workspace, environment_id)
  let fake = fake_docker()
  let runner = fake_runner(fake, home, plan.identity)
  match create_container(runner, plan) {
    Ok(_) => ()
    Err(failure) =>
      fail("create failed: " + failure.failure.to_string() + " / " +
      failure.cleanup_log)
  }
  assert_eq(fake.env_file_mode.val, "600")
  assert_eq(test_file_mode(plan.env_dir), "700")
  assert_eq(test_file_mode(plan.scratch_dir), "700")
  assert_true(!(@fs.exists(plan.env_dir + "/env") catch { _ => true }))
  let pulls = calls_with_head(fake, "pull")
  let images = calls_with_head(fake, "image")
  let creates = calls_with_head(fake, "create")
  let starts = calls_with_head(fake, "start")
  assert_eq(pulls.length(), 1)
  assert_eq(images.length(), 1)
  assert_eq(creates.length(), 1)
  assert_eq(starts.length(), 1)
  let create = creates[0]
  assert_eq(create[0], "create")
  assert_true(argv_has(create, @docker.container_name(plan.identity)))
  assert_true(argv_has(create, "--label"))
  assert_true(argv_has(create, @docker.LABEL_MANAGED + "=true"))
  assert_true(
    argv_has(
      create,
      @docker.LABEL_ENVIRONMENT_ID + "=" + plan.identity.environment_id,
    ),
  )
  assert_true(
    argv_has(
      create,
      @docker.LABEL_WORKSPACE_ID + "=" + plan.identity.workspace_id,
    ),
  )
  assert_true(
    argv_has(
      create,
      @docker.LABEL_RECIPE_HASH + "=" + plan.identity.recipe_hash,
    ),
  )
  assert_true(argv_has(create, "--init"))
  assert_true(argv_has(create, "--restart=no"))
  assert_true(!argv_has(create, "--rm"))
  assert_true(!argv_has(create, "--privileged"))
  // No element may smuggle a combined shell string or a prune.
  for call in fake.calls.val {
    assert_true(!call_has_element_containing(call, " && "))
    assert_true(!call_has_element_containing(call, "docker system prune"))
    assert_true(!argv_has(call, "system"))
    assert_true(!argv_has(call, "--rm"))
  }
}

///|
async test "pull failure cleans up and never reaches create" {
  let root = @fs.tmpdir(prefix="env-pull-fail")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  fake.pull_ok.val = false
  let runner = fake_runner(fake, home, plan.identity)
  match create_container(runner, plan) {
    Ok(_) => fail("a missing image must not create a container")
    Err(failure) => {
      assert_eq(
        failure.failure.code,
        @contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE,
      )
      assert_true(failure.cleanup_ok)
      assert_true(failure.cleanup_log.contains("container: absent"))
      assert_true(!(@fs.exists(plan.env_dir) catch { _ => true }))
      assert_true(!(@fs.exists(plan.scratch_dir) catch { _ => true }))
    }
  }
  assert_eq(calls_with_head(fake, "create").length(), 0)
  assert_eq(calls_with_head(fake, "start").length(), 0)
}

///|
async test "pull timeout reports timeout after a clean reverse cleanup" {
  let root = @fs.tmpdir(prefix="env-pull-timeout")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  fake.pull_timeout.val = true
  let runner = fake_runner(fake, home, plan.identity)
  match create_container(runner, plan) {
    Ok(_) => fail("a pulled timeout must not create a container")
    Err(failure) => {
      assert_eq(failure.failure.code, @contracts.ENVIRONMENT_ERR_TIMEOUT)
      assert_true(failure.cleanup_ok)
    }
  }
  assert_eq(calls_with_head(fake, "create").length(), 0)
}

///|
async test "docker unreachable mid-create is reported as an unverified orphan" {
  let root = @fs.tmpdir(prefix="env-unreachable")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  fake.daemon_down_after_create.val = true
  let runner = fake_runner(fake, home, plan.identity)
  match create_container(runner, plan) {
    Ok(_) => fail("an unreachable daemon must never report success")
    Err(failure) => {
      assert_eq(
        failure.failure.code,
        @contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE,
      )
      assert_true(!failure.cleanup_ok)
      assert_true(failure.cleanup_log.contains("container ownership"))
      // Ownership could not be proven: no stop/rm was attempted.
      assert_eq(calls_with_head(fake, "stop").length(), 0)
      assert_eq(calls_with_head(fake, "rm").length(), 0)
      // The secret env file is still removed even when the daemon is gone.
      assert_true(!(@fs.exists(plan.env_dir + "/env") catch { _ => true }))
      // Scratch is kept because a possibly-running container may use it.
      assert_true(@fs.exists(plan.scratch_dir) catch { _ => false })
    }
  }
}

///|
async test "a same-named container with foreign labels is never removed" {
  let root = @fs.tmpdir(prefix="env-foreign")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  // A foreign container already holds the deterministic name.
  fake.created.val = true
  fake.running.val = true
  fake.labels_ok.val = false
  fake.create_ok.val = false
  let runner = fake_runner(fake, home, plan.identity)
  match create_container(runner, plan) {
    Ok(_) => fail("create must not report success")
    Err(failure) => {
      assert_true(failure.cleanup_ok)
      assert_true(
        failure.cleanup_log.contains("labels do not match; left untouched"),
      )
      assert_eq(calls_with_head(fake, "rm").length(), 0)
      assert_eq(calls_with_head(fake, "stop").length(), 0)
      assert_true(fake.created.val)
    }
  }
}

///|
async test "start adopts a labelled container and refuses a foreign one" {
  let root = @fs.tmpdir(prefix="env-start")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let record = test_record(@contracts.ENVIRONMENT_STATE_STOPPED)
  let fake = fake_docker()
  fake.created.val = true
  fake.running.val = false
  let runner = fake_runner(fake, home, plan.identity)
  match start_container(runner, record, test_recipe(), plan.identity) {
    Ok(_) => ()
    Err(error) => fail("start failed: " + error.to_string())
  }
  assert_eq(calls_with_head(fake, "start").length(), 1)
  // A foreign container is a conflict and is never started.
  let foreign = fake_docker()
  foreign.created.val = true
  foreign.labels_ok.val = false
  let foreign_runner = fake_runner(foreign, home, plan.identity)
  match
    start_container(
      foreign_runner,
      record,
      test_recipe(),
      plan.identity,
    ) {
    Ok(_) => fail("a foreign container must not be started")
    Err(error) =>
      assert_eq(error.code, @contracts.ENVIRONMENT_ERR_CONFLICT)
  }
  assert_eq(calls_with_head(foreign, "start").length(), 0)
  // A missing container is an orphan, not a success.
  let absent = fake_docker()
  let absent_runner = fake_runner(absent, home, plan.identity)
  match
    start_container(absent_runner, record, test_recipe(), plan.identity) {
    Ok(_) => fail("a missing container must not report success")
    Err(error) =>
      assert_eq(error.code, @contracts.ENVIRONMENT_ERR_ORPHAN_SUSPECTED)
  }
}

///|
async test "stop keeps the container and refuses a foreign name" {
  let root = @fs.tmpdir(prefix="env-stop")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  fake.created.val = true
  fake.running.val = true
  let runner = fake_runner(fake, home, plan.identity)
  match stop_container(runner, plan.identity) {
    Ok(_) => ()
    Err(error) => fail("stop failed: " + error.to_string())
  }
  assert_eq(calls_with_head(fake, "stop").length(), 1)
  assert_eq(calls_with_head(fake, "rm").length(), 0)
  assert_true(fake.created.val)
  assert_true(!fake.running.val)
  // Idempotent when already absent.
  fake.created.val = false
  match stop_container(runner, plan.identity) {
    Ok(_) => ()
    Err(error) => fail("absent stop failed: " + error.to_string())
  }
  // Foreign labels are a conflict and are not stopped.
  let foreign = fake_docker()
  foreign.created.val = true
  foreign.labels_ok.val = false
  let foreign_runner = fake_runner(foreign, home, plan.identity)
  match stop_container(foreign_runner, plan.identity) {
    Ok(_) => fail("a foreign container must not be stopped")
    Err(error) => assert_eq(error.code, @contracts.ENVIRONMENT_ERR_CONFLICT)
  }
  assert_eq(calls_with_head(foreign, "stop").length(), 0)
}

///|
async test "destroy is idempotent, removes only the managed name and redacts output" {
  let root = @fs.tmpdir(prefix="env-destroy")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  fake.created.val = true
  fake.running.val = true
  let runner = fake_runner(fake, home, plan.identity)
  let first = destroy_container(
    runner,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  assert_true(first.ok)
  let rms = calls_with_head(fake, "rm")
  assert_eq(rms.length(), 1)
  assert_eq(rms[0].length(), 3)
  assert_eq(rms[0][0], "rm")
  assert_eq(rms[0][1], "-f")
  assert_eq(rms[0][2], @docker.container_name(plan.identity))
  assert_true(!(@fs.exists(plan.env_dir) catch { _ => true }))
  assert_true(!(@fs.exists(plan.scratch_dir) catch { _ => true }))
  let second = destroy_container(
    runner,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  assert_true(second.ok)
  assert_eq(calls_with_head(fake, "rm").length(), 1)
  // A failing removal is never reported as clean, and secrets in stderr never
  // reach the cleanup log.
  let failing = fake_docker()
  failing.created.val = true
  failing.rm_ok.val = false
  let failing_runner = fake_runner(failing, home, plan.identity)
  let outcome = destroy_container(
    failing_runner,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  assert_true(!outcome.ok)
  assert_true(!outcome.log.contains("supersecret"))
  assert_true(outcome.log.contains("[redacted]"))
}

///|
async test "exec verifies ownership, keeps argv separate and never fakes success" {
  let root = @fs.tmpdir(prefix="env-exec")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let fake = fake_docker()
  fake.created.val = true
  fake.running.val = true
  let runner = fake_runner(fake, home, plan.identity)
  match
    exec_in_container(
      runner,
      plan.identity,
      ["printf", "hello"],
      "/workspace/project",
      10,
    ) {
    Ok(output) => {
      assert_eq(output.exit_code, 0)
      assert_eq(output.stdout, "hello")
      assert_true(!output.timed_out)
    }
    Err(error) => fail("exec failed: " + error.to_string())
  }
  let execs = calls_with_head(fake, "exec")
  assert_eq(execs.length(), 1)
  let call = execs[0]
  assert_true(argv_has(call, @docker.container_name(plan.identity)))
  assert_true(argv_has(call, "printf"))
  assert_true(argv_has(call, "hello"))
  assert_true(!call_has_element_containing(call, "printf hello"))
  // Non-zero exits stay data, not a transport error.
  fake.exec_mode.val = "exit7"
  match
    exec_in_container(runner, plan.identity, ["false"], "", 10) {
    Ok(output) => {
      assert_eq(output.exit_code, 7)
      assert_eq(output.stderr, "boom")
    }
    Err(error) => fail("exec exit code became an error: " + error.to_string())
  }
  // A timeout can never report success.
  fake.exec_mode.val = "timeout"
  match
    exec_in_container(runner, plan.identity, ["sleep", "9"], "", 1) {
    Ok(output) => {
      assert_true(output.timed_out)
      assert_eq(output.exit_code, -1)
      assert_eq(output.stdout, "")
    }
    Err(_) => fail("a timeout must be returned as timed_out data")
  }
  // A foreign or stopped container is not exec'd.
  let foreign = fake_docker()
  foreign.created.val = true
  foreign.labels_ok.val = false
  let foreign_runner = fake_runner(foreign, home, plan.identity)
  match
    exec_in_container(foreign_runner, plan.identity, ["true"], "", 10) {
    Ok(_) => fail("a foreign container must not be exec'd")
    Err(error) => assert_eq(error.code, @contracts.ENVIRONMENT_ERR_CONFLICT)
  }
  assert_eq(calls_with_head(foreign, "exec").length(), 0)
  let stopped = fake_docker()
  stopped.created.val = true
  stopped.running.val = false
  let stopped_runner = fake_runner(stopped, home, plan.identity)
  match
    exec_in_container(stopped_runner, plan.identity, ["true"], "", 10) {
    Ok(_) => fail("a stopped container must not be exec'd")
    Err(error) => assert_eq(error.code, @contracts.ENVIRONMENT_ERR_CONFLICT)
  }
}

///|
async test "doctor is read-only and reports missing containers as unhealthy" {
  let root = @fs.tmpdir(prefix="env-doctor")
  defer cleanup_root(root)
  let home = root + "/home"
  let workspace = root + "/workspace"
  @fs.mkdir(home, recursive=true) catch { _ => () }
  @fs.mkdir(workspace, recursive=true) catch { _ => () }
  let plan = test_plan(home, workspace, "env_01ARYZ6S41")
  let record = test_record(@contracts.ENVIRONMENT_STATE_RUNNING)
  let fake = fake_docker()
  let runner = fake_runner(fake, home, plan.identity)
  let report = doctor_container(
    runner,
    record,
    plan.identity,
    Some(test_recipe()),
    "2026-02-01T00:00:00Z",
  )
  assert_true(!report.healthy)
  assert_true(report.guidance.contains("monexus-env-env_01ARYZ6S41"))
  assert_eq(calls_with_head(fake, "stop").length(), 0)
  assert_eq(calls_with_head(fake, "rm").length(), 0)
  assert_eq(calls_with_head(fake, "create").length(), 0)
  // A healthy, labelled, running container.
  let healthy = fake_docker()
  healthy.created.val = true
  healthy.running.val = true
  let healthy_runner = fake_runner(healthy, home, plan.identity)
  let healthy_report = doctor_container(
    healthy_runner,
    record,
    plan.identity,
    Some(test_recipe()),
    "2026-02-01T00:00:00Z",
  )
  assert_true(healthy_report.healthy)
}

///|
async test "redaction removes credential values from failure details" {
  let failure = EnvFailure::new(
    @contracts.ENVIRONMENT_ERR_INTERNAL,
    "failed",
  ).with_detail("API_KEY=sk-live-supersecretvalue")
  assert_true(!failure.to_string().contains("supersecretvalue"))
  assert_true(failure.to_string().contains("[redacted]"))
}
